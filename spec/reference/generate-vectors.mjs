// 生成 spec/test-vectors/*.json。所有密钥与 nonce 都是固定常量，输出是确定的：
// 重新运行不应该产生任何 diff（verify-vectors.mjs 会检查这一点）。
//
//   node spec/reference/generate-vectors.mjs

import { writeFile } from "node:fs/promises";
import {
  GENESIS_PREV,
  canonicalJson,
  chainHash,
  compareHlc,
  deriveRijiKey,
  deriveSegmentKey,
  formatHlc,
  hex,
  materialize,
  parseHlc,
  receiveHlc,
  sealSegment,
  stateDigest,
  tickHlc,
} from "./riji.mjs";

const OUT = new URL("../test-vectors/", import.meta.url);
const bytes = (hexText) => new Uint8Array(Buffer.from(hexText, "hex"));
const ROOT = bytes("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
const SALT = bytes("a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf");
const nonce = (n) => bytes(`${"00".repeat(11)}${n.toString(16).padStart(2, "0")}`);

async function write(name, data) {
  await writeFile(new URL(name, OUT), `${JSON.stringify(data, null, 2)}\n`);
}

// ---------------------------------------------------------------- 规范 JSON
await write("canonical-json.json", {
  description: "规范 JSON：对象键按 UTF-16 码元排序、无空白、数组保序、字符串按 JSON 标准转义（非 ASCII 原样输出）。",
  cases: [
    { input: { b: 1, a: [3, 2, { d: null, c: true }] }, output: canonicalJson({ b: 1, a: [3, 2, { d: null, c: true }] }) },
    { input: { 标题: "电路 18 讲", text: "引号\"与\\反斜杠\n换行" }, output: canonicalJson({ 标题: "电路 18 讲", text: "引号\"与\\反斜杠\n换行" }) },
    { input: { n: -0.5, big: 1759889000000, z: 0 }, output: canonicalJson({ n: -0.5, big: 1759889000000, z: 0 }) },
    { input: { "B": 1, "a": 2, "_": 3 }, output: canonicalJson({ B: 1, a: 2, _: 3 }) },
  ],
});

// ---------------------------------------------------------------- HLC
const t0 = 1759889000000;
await write("hlc.json", {
  description: "混合逻辑时钟：文本格式、比较、本地 tick 与接收远端。",
  format: [
    { ms: t0, counter: 0, device: "mac-1", text: formatHlc({ ms: t0, counter: 0, device: "mac-1" }) },
    { ms: 0, counter: 65535, device: "a", text: formatHlc({ ms: 0, counter: 65535, device: "a" }) },
  ],
  invalid: ["1759889000000.0000.Mac", "175988900000.0000.mac", "1759889000000.00000.mac", "1759889000000.0000."],
  compare: [
    { a: formatHlc({ ms: t0, counter: 0, device: "mac-1" }), b: formatHlc({ ms: t0, counter: 1, device: "mac-1" }), result: -1 },
    { a: formatHlc({ ms: t0, counter: 1, device: "phone-1" }), b: formatHlc({ ms: t0, counter: 1, device: "mac-1" }), result: 1 },
    { a: formatHlc({ ms: t0 + 1, counter: 0, device: "a" }), b: formatHlc({ ms: t0, counter: 9, device: "z" }), result: 1 },
  ].map((item) => ({ ...item, result: compareHlc(item.a, item.b) })),
  tick: [
    { last: null, wall: t0, device: "mac-1" },
    { last: formatHlc({ ms: t0, counter: 0, device: "mac-1" }), wall: t0, device: "mac-1" },
    { last: formatHlc({ ms: t0 + 500, counter: 3, device: "mac-1" }), wall: t0, device: "mac-1" },
  ].map((item) => ({ ...item, result: tickHlc(item.last, item.wall, item.device) })),
  receive: [
    { last: formatHlc({ ms: t0, counter: 2, device: "mac-1" }), remote: formatHlc({ ms: t0, counter: 5, device: "phone-1" }), wall: t0 - 10, device: "mac-1" },
    { last: formatHlc({ ms: t0, counter: 2, device: "mac-1" }), remote: formatHlc({ ms: t0 + 40, counter: 0, device: "phone-1" }), wall: t0, device: "mac-1" },
    { last: null, remote: formatHlc({ ms: t0, counter: 0, device: "phone-1" }), wall: t0 + 100, device: "mac-1" },
  ].map((item) => ({ ...item, result: receiveHlc(item.last, item.remote, item.wall, item.device) })),
});
void parseHlc;

// ---------------------------------------------------------------- 密钥派生
const rijiKey1 = await deriveRijiKey(ROOT, SALT, 1);
const rijiKey2 = await deriveRijiKey(ROOT, SALT, 2);
await write("kdf.json", {
  description: "K_riji = HKDF-SHA256(R, riji_salt, \"functionhx:riji:v1:epoch=<n>\")；K_seg = HKDF-SHA256(K_riji, 32 个零字节, \"functionhx:riji:segment:v1|<device>|<seq>\")。全部 32 字节，十六进制。",
  root: hex(ROOT),
  riji_salt: hex(SALT),
  riji_keys: [
    { epoch: 1, key: hex(rijiKey1) },
    { epoch: 2, key: hex(rijiKey2) },
  ],
  segment_keys: [
    { epoch: 1, device: "mac-1", seq: 1, key: hex(await deriveSegmentKey(rijiKey1, "mac-1", 1)) },
    { epoch: 1, device: "mac-1", seq: 2, key: hex(await deriveSegmentKey(rijiKey1, "mac-1", 2)) },
    { epoch: 1, device: "phone-1", seq: 1, key: hex(await deriveSegmentKey(rijiKey1, "phone-1", 1)) },
  ],
});

// ---------------------------------------------------------------- 日志段
const hlc = (ms, counter, device) => formatHlc({ ms, counter, device });
const block = (id, text, extra = {}) => ({ id, note_id: "n-1008", type: "check", order: "a0", attrs: { checked: false, indent: 0, ...extra }, text: [{ text }] });

const mac1 = await sealSegment({
  rijiKey: rijiKey1, device: "mac-1", seq: 1, prev: GENESIS_PREV, epoch: 1, nonce: nonce(1),
  changes: [
    { type: "block", id: "b-english", hlc: hlc(t0, 0, "mac-1"), value: block("b-english", "英语单词") },
    { type: "block", id: "b-circuit", hlc: hlc(t0, 1, "mac-1"), value: block("b-circuit", "电路 18 讲") },
  ],
});
const mac2 = await sealSegment({
  rijiKey: rijiKey1, device: "mac-1", seq: 2, prev: chainHash(mac1), epoch: 1, nonce: nonce(2),
  changes: [{ type: "block", id: "b-english", hlc: hlc(t0 + 60000, 0, "mac-1"), value: block("b-english", "英语单词", { checked: true }) }],
});
const phone1 = await sealSegment({
  rijiKey: rijiKey1, device: "phone-1", seq: 1, prev: GENESIS_PREV, epoch: 1, nonce: nonce(3),
  changes: [
    { type: "block", id: "b-english", hlc: hlc(t0 + 30000, 0, "phone-1"), value: block("b-english", "英语单词 50 个") },
    { type: "block", id: "b-circuit", hlc: hlc(t0 + 90000, 0, "phone-1"), deleted: true },
    { type: "spark", id: "s-wechat", hlc: hlc(t0 + 90000, 1, "phone-1"), value: { id: "s-wechat", note_id: "n-1008", color: "yellow", text: [{ text: "微信文件传输助手分析历史" }] } },
  ],
});
const phone2 = await sealSegment({
  rijiKey: rijiKey1, device: "phone-1", seq: 2, prev: chainHash(phone1), epoch: 1, nonce: nonce(4),
  changes: [{ type: "block", id: "b-tie", hlc: hlc(t0 + 120000, 0, "phone-1"), value: block("b-tie", "手机写的") }],
});
const mac3 = await sealSegment({
  rijiKey: rijiKey1, device: "mac-1", seq: 3, prev: chainHash(mac2), epoch: 1, nonce: nonce(5),
  changes: [{ type: "block", id: "b-tie", hlc: hlc(t0 + 120000, 0, "mac-1"), value: block("b-tie", "Mac 写的") }],
});

const tamperedCt = (() => {
  const raw = Buffer.from(mac2.ct, "base64url");
  raw[raw.length - 1] ^= 0x01;
  return raw.toString("base64url");
})();
const forgedPrev = { ...phone2, prev: GENESIS_PREV.replace(/0$/, "1") };

await write("segments.json", {
  description:
    "日志段：AES-256-GCM(K_seg, nonce, 明文 = 规范 JSON {changes: 按 (type,id,hlc) 排序})；ct = base64url(nonce ‖ 密文 ‖ 16 字节标签)；" +
    "AAD = \"riji-segment|v1|<device>|<seq>|<prev>|<epoch>\"；prev = 上一段 ct 字节的 SHA-256，首段为 64 个 0。",
  riji_key_epoch_1: hex(rijiKey1),
  segments: { "mac-1#1": mac1, "mac-1#2": mac2, "mac-1#3": mac3, "phone-1#1": phone1, "phone-1#2": phone2 },
  chain_hashes: { "mac-1#1": chainHash(mac1), "mac-1#2": chainHash(mac2), "phone-1#1": chainHash(phone1) },
  must_fail_to_open: [
    { reason: "ciphertext tampered", segment: { ...mac2, ct: tamperedCt } },
    { reason: "header seq changed (AAD mismatch)", segment: { ...mac2, seq: 3 } },
    { reason: "header epoch changed (AAD mismatch)", segment: { ...mac2, epoch: 2 } },
    { reason: "wrong device in header (different key and AAD)", segment: { ...mac2, device: "phone-1" } },
  ],
});

// ---------------------------------------------------------------- 合并场景
const scenarios = [
  { name: "全部按序到达", segments: [mac1, mac2, mac3, phone1, phone2] },
  { name: "乱序且来自两个副本、含重复段", segments: [phone2, mac3, mac1, phone1, mac2, mac1, phone2] },
  { name: "mac-1 缺第 2 段：只接受第 1 段，报告 gap", segments: [mac1, mac3, phone1, phone2] },
  { name: "phone-1 第 2 段的 prev 被改：报告 broken_chain", segments: [mac1, mac2, mac3, phone1, forgedPrev] },
  { name: "只有手机的段", segments: [phone1, phone2] },
];
const merge = [];
for (const scenario of scenarios) {
  const { state, vector, problems } = await materialize(rijiKey1, scenario.segments);
  merge.push({
    name: scenario.name,
    segments: scenario.segments.map((s) => `${s.device}#${s.seq}${s === forgedPrev ? "(forged-prev)" : ""}`),
    expected_vector: vector,
    expected_problems: problems,
    expected_state: state,
    expected_state_digest: stateDigest(state),
  });
}
await write("merge.json", {
  description:
    "合并：逐设备验链（序号从 1 连续、prev 吻合，重复段忽略），只合并可接受的最长前缀；同一 (type,id) 取 HLC 最大者，HLC 相同不可能（设备 id 不同即不同）。" +
    "状态键为 \"<type>:<id>\"，值为 {hlc, value} 或 {hlc, deleted: true}；摘要 = 规范 JSON 的 SHA-256。segments 里的名字对应 segments.json。",
  forged_prev_segment: forgedPrev,
  scenarios: merge,
});

console.log("test vectors written to spec/test-vectors/");
