// 独立复算 spec/test-vectors/*.json，并检查重新生成不产生 diff。
// Kotlin / Swift 端的向量测试照这个文件的结构写。
//
//   node spec/reference/verify-vectors.mjs

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import {
  canonicalJson,
  chainHash,
  compareHlc,
  deriveRijiKey,
  deriveSegmentKey,
  ecdhShared,
  formatHlc,
  hex,
  materialize,
  openPairPayload,
  openSegment,
  pairKeys,
  pairTranscript,
  parseHlc,
  receiveHlc,
  stateDigest,
  tickHlc,
} from "./riji.mjs";

const load = async (name) => JSON.parse(await readFile(new URL(`../test-vectors/${name}`, import.meta.url), "utf8"));
const bytes = (hexText) => new Uint8Array(Buffer.from(hexText, "hex"));

const canonical = await load("canonical-json.json");
for (const item of canonical.cases) assert.equal(canonicalJson(item.input), item.output);

const hlc = await load("hlc.json");
for (const item of hlc.format) {
  assert.equal(formatHlc(item), item.text);
  assert.deepEqual(parseHlc(item.text), { ms: item.ms, counter: item.counter, device: item.device });
}
for (const text of hlc.invalid) assert.throws(() => parseHlc(text));
for (const item of hlc.compare) assert.equal(compareHlc(item.a, item.b), item.result);
for (const item of hlc.tick) assert.equal(tickHlc(item.last, item.wall, item.device), item.result);
for (const item of hlc.receive) {
  const result = receiveHlc(item.last, item.remote, item.wall, item.device);
  assert.equal(result, item.result);
  assert.ok(compareHlc(result, item.remote) > 0 && (!item.last || compareHlc(result, item.last) > 0), "received clock moves past both");
}

const kdf = await load("kdf.json");
const keys = {};
for (const item of kdf.riji_keys) {
  keys[item.epoch] = await deriveRijiKey(bytes(kdf.root), bytes(kdf.riji_salt), item.epoch);
  assert.equal(hex(keys[item.epoch]), item.key);
}
for (const item of kdf.segment_keys) assert.equal(hex(await deriveSegmentKey(keys[item.epoch], item.device, item.seq)), item.key);

const segments = await load("segments.json");
const rijiKey = bytes(segments.riji_key_epoch_1);
for (const segment of Object.values(segments.segments)) {
  const changes = await openSegment(rijiKey, segment);
  assert.ok(changes.length > 0);
  assert.equal(segment.hlc_max, changes.map((c) => c.hlc).sort().at(-1));
}
for (const [name, hash] of Object.entries(segments.chain_hashes)) assert.equal(chainHash(segments.segments[name]), hash);
assert.equal(segments.segments["mac-1#2"].prev, segments.chain_hashes["mac-1#1"]);
for (const item of segments.must_fail_to_open) await assert.rejects(openSegment(rijiKey, item.segment), item.reason);

const merge = await load("merge.json");
for (const scenario of merge.scenarios) {
  const list = scenario.segments.map((name) => (name.endsWith("(forged-prev)") ? merge.forged_prev_segment : segments.segments[name]));
  const { state, vector, problems } = await materialize(rijiKey, list);
  assert.deepEqual(vector, scenario.expected_vector, scenario.name);
  assert.deepEqual(problems, scenario.expected_problems, scenario.name);
  assert.deepEqual(state, scenario.expected_state, scenario.name);
  assert.equal(stateDigest(state), scenario.expected_state_digest, scenario.name);
}

const pairing = await load("pairing.json");
{
  // 只用私钥标量与对方公钥复算（JWK 需要的 x / y 从对方视角取自己的公钥）
  const jwkOf = (dHex, pub) => {
    const raw = Buffer.from(pub, "base64url");
    return { d: Buffer.from(dHex, "hex").toString("base64url"), x: raw.subarray(1, 33).toString("base64url"), y: raw.subarray(33).toString("base64url") };
  };
  const sharedA = await ecdhShared(jwkOf(pairing.a.private_d_hex, pairing.a.public), Buffer.from(pairing.b.public, "base64url"));
  const sharedB = await ecdhShared(jwkOf(pairing.b.private_d_hex, pairing.b.public), Buffer.from(pairing.a.public, "base64url"));
  assert.equal(hex(sharedA), pairing.shared_hex);
  assert.equal(hex(sharedB), pairing.shared_hex);
  const transcript = await pairTranscript(pairing.code, pairing.a.public, pairing.b.public);
  assert.equal(hex(transcript), pairing.transcript_hex);
  const { key, sas } = await pairKeys(sharedB, transcript);
  assert.equal(hex(key), pairing.pair_key_hex);
  assert.equal(sas, pairing.sas);
  assert.deepEqual(await openPairPayload(key, pairing.code, pairing.sealed), pairing.payload);
  await assert.rejects(openPairPayload(key, "00000000", pairing.sealed));
  assert.notEqual(pairing.mitm.sas_seen_by_a, pairing.sas);
}

// 生成器是确定的：重新生成后向量文件逐字节不变。
const names = ["canonical-json.json", "hlc.json", "kdf.json", "segments.json", "merge.json", "pairing.json"];
const before = await Promise.all(names.map((name) => readFile(new URL(`../test-vectors/${name}`, import.meta.url), "utf8")));
execFileSync(process.execPath, [new URL("./generate-vectors.mjs", import.meta.url).pathname], { stdio: "ignore" });
const after = await Promise.all(names.map((name) => readFile(new URL(`../test-vectors/${name}`, import.meta.url), "utf8")));
names.forEach((name, i) => assert.equal(after[i], before[i], `regenerating ${name} changed it`));

console.log("riji spec vectors verified: canonical JSON, HLC, key derivation, segments, tamper detection, merge scenarios, pairing, determinism.");
