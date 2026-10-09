# 日迹同步规格 v1

协议的文字说明在 [docs/DESIGN.md §8](../docs/DESIGN.md)。这里是它的可执行部分：

- `reference/riji.mjs`：参考实现（Node 20+，只用 WebCrypto）——规范 JSON、HLC、密钥派生、日志段封装与校验、合并。
- `reference/generate-vectors.mjs`：用固定密钥与 nonce 生成 `test-vectors/`（确定性输出）。
- `reference/verify-vectors.mjs`：只读向量独立复算，并检查重新生成不产生变化。
- `test-vectors/`：Kotlin 与 Swift 实现**必须逐字节通过**的用例。

```bash
node spec/reference/verify-vectors.mjs
```

| 向量 | 覆盖 |
| --- | --- |
| `canonical-json.json` | 键排序、转义、中文、数字 |
| `hlc.json` | 格式、非法输入、比较、本地 tick、接收远端 |
| `kdf.json` | 根密钥 → 日迹密钥（按 epoch）→ 段密钥 |
| `segments.json` | 段封装、哈希链、篡改 / 改头 / 换设备必须解密失败 |
| `merge.json` | 按序、乱序 + 重复、缺段（gap）、链被改（broken_chain）、平局按设备 id、删除墓碑 |
| `pairing.json` | 设备配对：ECDH(P-256) 共享秘密、transcript、配对密钥、6 位比对码、配对信封、中间人比对码不同 |
