// 日迹同步协议 v1 的参考实现（Node 20+，只用 WebCrypto 与标准库）。
//
// 这份代码是「规格的可执行版本」：spec/test-vectors/ 由它生成，Kotlin 与 Swift 的实现必须
// 对同一组向量得到逐字节相同的结果。它不是生产代码，不处理网络与存储。
// 协议文字说明见 spec/SYNC.md。

import { createHash } from "node:crypto";

const subtle = globalThis.crypto.subtle;
const encoder = new TextEncoder();
const decoder = new TextDecoder();

// ---------------------------------------------------------------- 编码

export function b64u(bytes) {
  return Buffer.from(bytes).toString("base64url");
}

export function fromB64u(text) {
  return new Uint8Array(Buffer.from(text, "base64url"));
}

export function hex(bytes) {
  return Buffer.from(bytes).toString("hex");
}

export function sha256Hex(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

export const GENESIS_PREV = "0".repeat(64);

// 规范 JSON：对象键按 UTF-16 码元排序、无空白；数组保持顺序；只允许 JSON 原生类型。
export function canonicalJson(value) {
  if (value === null || typeof value === "boolean") return JSON.stringify(value);
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error("non-finite number");
    return JSON.stringify(value);
  }
  if (typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (typeof value === "object") {
    const keys = Object.keys(value).filter((key) => value[key] !== undefined).sort();
    return `{${keys.map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;
  }
  throw new Error(`unsupported type ${typeof value}`);
}

// ---------------------------------------------------------------- 混合逻辑时钟（HLC）
//
// 文本形式：13 位十进制毫秒 "." 4 位十六进制计数 "." 设备 id，例如
//   1759889000000.0000.mac-1
// 固定宽度，所以字符串字典序 == 时钟顺序；设备 id 作为最后的平局裁决。

export function formatHlc({ ms, counter, device }) {
  if (!Number.isInteger(ms) || ms < 0 || ms > 9999999999999) throw new Error("hlc ms out of range");
  if (!Number.isInteger(counter) || counter < 0 || counter > 0xffff) throw new Error("hlc counter out of range");
  if (!/^[a-z0-9-]{1,36}$/.test(device)) throw new Error("hlc device id must match [a-z0-9-]{1,36}");
  return `${String(ms).padStart(13, "0")}.${counter.toString(16).padStart(4, "0")}.${device}`;
}

export function parseHlc(text) {
  const match = /^(\d{13})\.([0-9a-f]{4})\.([a-z0-9-]{1,36})$/.exec(text);
  if (!match) throw new Error(`invalid hlc ${text}`);
  return { ms: Number(match[1]), counter: parseInt(match[2], 16), device: match[3] };
}

export function compareHlc(a, b) {
  return a < b ? -1 : a > b ? 1 : 0;
}

// 本地事件：取 max(墙钟, 上次)；同一毫秒则计数 +1。
export function tickHlc(last, wallMs, device) {
  const previous = last ? parseHlc(last) : { ms: 0, counter: 0 };
  if (wallMs > previous.ms) return formatHlc({ ms: wallMs, counter: 0, device });
  return formatHlc({ ms: previous.ms, counter: previous.counter + 1, device });
}

// 收到远端时钟：新时钟 > 本地上次与远端两者。
export function receiveHlc(last, remote, wallMs, device) {
  const local = last ? parseHlc(last) : { ms: 0, counter: 0 };
  const other = parseHlc(remote);
  const ms = Math.max(wallMs, local.ms, other.ms);
  let counter = 0;
  if (ms === local.ms && ms === other.ms) counter = Math.max(local.counter, other.counter) + 1;
  else if (ms === local.ms) counter = local.counter + 1;
  else if (ms === other.ms) counter = other.counter + 1;
  return formatHlc({ ms, counter, device });
}

// ---------------------------------------------------------------- 密钥派生

async function hkdf(ikm, salt, info, length = 32) {
  const key = await subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  const bits = await subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info: encoder.encode(info) }, key, length * 8);
  return new Uint8Array(bits);
}

// 网站保险库根密钥 R → 日迹密钥 K_riji（每个 epoch 一把）。
export function deriveRijiKey(root, rijiSalt, epoch) {
  return hkdf(root, rijiSalt, `functionhx:riji:v1:epoch=${epoch}`);
}

// K_riji → 某台设备某一段的密钥。确定性派生：同一 (设备, 序号) 永远同一把钥匙，
// 每段只加密一次，因此随机 nonce 的重复风险只存在于单段之内（为零）。
export function deriveSegmentKey(rijiKey, device, seq) {
  return hkdf(rijiKey, new Uint8Array(32), `functionhx:riji:segment:v1|${device}|${seq}`);
}

export function segmentAad({ v, device, seq, prev, epoch }) {
  return encoder.encode(`riji-segment|v${v}|${device}|${seq}|${prev}|${epoch}`);
}

// ---------------------------------------------------------------- 日志段

// changes: [{ type, id, hlc, deleted?, value? }]，按 (type, id, hlc) 升序排列后写入。
export function sortChanges(changes) {
  return [...changes].sort((a, b) => (a.type < b.type ? -1 : a.type > b.type ? 1 : a.id < b.id ? -1 : a.id > b.id ? 1 : compareHlc(a.hlc, b.hlc)));
}

export async function sealSegment({ rijiKey, device, seq, prev, epoch, changes, nonce }) {
  if (!Number.isInteger(seq) || seq < 1) throw new Error("seq starts at 1");
  if (!/^[0-9a-f]{64}$/.test(prev)) throw new Error("prev must be 64 hex chars");
  if (seq === 1 && prev !== GENESIS_PREV) throw new Error("the first segment must point at the genesis prev");
  const sorted = sortChanges(changes);
  const plaintext = encoder.encode(canonicalJson({ changes: sorted }));
  const key = await subtle.importKey("raw", await deriveSegmentKey(rijiKey, device, seq), "AES-GCM", false, ["encrypt"]);
  const iv = nonce || globalThis.crypto.getRandomValues(new Uint8Array(12));
  const header = { v: 1, device, seq, prev, epoch };
  const sealed = new Uint8Array(await subtle.encrypt({ name: "AES-GCM", iv, additionalData: segmentAad(header), tagLength: 128 }, key, plaintext));
  const ct = new Uint8Array(iv.length + sealed.length);
  ct.set(iv);
  ct.set(sealed, iv.length);
  const hlcMax = sorted.reduce((max, change) => (compareHlc(change.hlc, max) > 0 ? change.hlc : max), sorted[0]?.hlc || "");
  return { ...header, hlc_max: hlcMax, ct: b64u(ct) };
}

export async function openSegment(rijiKey, segment) {
  const ct = fromB64u(segment.ct);
  const key = await subtle.importKey("raw", await deriveSegmentKey(rijiKey, segment.device, segment.seq), "AES-GCM", false, ["decrypt"]);
  const plain = await subtle.decrypt({ name: "AES-GCM", iv: ct.slice(0, 12), additionalData: segmentAad(segment), tagLength: 128 }, key, ct.slice(12));
  const body = JSON.parse(decoder.decode(plain));
  if (!Array.isArray(body.changes)) throw new Error("segment body has no changes");
  return body.changes;
}

// 下一段的 prev：上一段完整密文字节（含 nonce）的 SHA-256。
export function chainHash(segment) {
  return sha256Hex(fromB64u(segment.ct));
}

// ---------------------------------------------------------------- 副本与合并

// 校验一台设备的日志链：序号从 1 连续、prev 吻合。返回可用的最长前缀与问题列表。
export function verifyChain(segments) {
  const ordered = [...segments].sort((a, b) => a.seq - b.seq);
  const accepted = [];
  const problems = [];
  let expectedSeq = 1;
  let expectedPrev = GENESIS_PREV;
  for (const segment of ordered) {
    if (segment.seq < expectedSeq) {
      if (accepted.some((item) => item.seq === segment.seq && item.ct === segment.ct)) continue; // 重复段：忽略
      problems.push({ code: "fork", seq: segment.seq });
      break;
    }
    if (segment.seq > expectedSeq) {
      problems.push({ code: "gap", missing: expectedSeq });
      break;
    }
    if (segment.prev !== expectedPrev) {
      problems.push({ code: "broken_chain", seq: segment.seq });
      break;
    }
    accepted.push(segment);
    expectedSeq += 1;
    expectedPrev = chainHash(segment);
  }
  return { accepted, problems };
}

// 版本向量：每台设备已接受的最大序号。
export function versionVector(segmentsByDevice) {
  const vector = {};
  for (const [device, segments] of Object.entries(segmentsByDevice)) {
    vector[device] = verifyChain(segments).accepted.length;
  }
  return vector;
}

// 把一批变更合并进状态：同一 (type, id) 取 HLC 最大者；与到达顺序无关。
export function mergeChanges(state, changes) {
  const next = { ...state };
  for (const change of changes) {
    const key = `${change.type}:${change.id}`;
    const current = next[key];
    if (!current || compareHlc(change.hlc, current.hlc) > 0) {
      next[key] = change.deleted ? { hlc: change.hlc, deleted: true } : { hlc: change.hlc, value: change.value };
    }
  }
  return next;
}

// 从一组段（可能来自多个副本、乱序、重复）得到状态：先逐设备验链，再合并全部已接受段。
export async function materialize(rijiKey, allSegments) {
  const byDevice = {};
  for (const segment of allSegments) (byDevice[segment.device] ||= []).push(segment);
  let state = {};
  const problems = {};
  const devices = Object.keys(byDevice).sort();
  for (const device of devices) {
    const { accepted, problems: found } = verifyChain(byDevice[device]);
    if (found.length) problems[device] = found;
    for (const segment of accepted) state = mergeChanges(state, await openSegment(rijiKey, segment));
  }
  const ordered = Object.fromEntries(Object.keys(state).sort().map((key) => [key, state[key]]));
  return { state: ordered, vector: Object.fromEntries(devices.map((d) => [d, verifyChain(byDevice[d]).accepted.length])), problems };
}

// 状态摘要：规范 JSON 的 SHA-256，两端比对用。
export function stateDigest(state) {
  return sha256Hex(encoder.encode(canonicalJson(state)));
}
