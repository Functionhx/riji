# 日迹 · 同步副本（riji-sync）

腾讯云上的加密日志副本与设备配对中转（docs/DESIGN.md §8）。只用 Python 标准库与 SQLite。

## 它知道什么

每台设备只追加的日志段：设备 id、序号、prev 哈希、大小、到达时间，以及**密文**。
密钥只在设备上（第一台设备随机生成，配对时封装给新设备），服务器解不开任何一段。
只接受接在这台设备最后一段后面、prev 吻合的段；重复推送同一段无害，同序号不同内容（分叉）拒绝。

配对时只转交双方的临时公钥与加密信封：会话 10 分钟过期，信封取走即删。
服务器若替换公钥做中间人，两台设备显示的 6 位比对码会不一致——这一步由站长当面核对。

## 接口（nginx：`https://fanyuchen.com.cn/riji/sync/` → `127.0.0.1:8792`）

| 方法 | 路径 | 鉴权 | 说明 |
| --- | --- | --- | --- |
| GET | `/health` | — | 设备数、段数、总大小 |
| GET | `/heads` | 连接码 | `{devices: {<设备>: {seq, hash}}}` |
| GET | `/segments?device=&from=&limit=` | 连接码 | 一台设备从某序号起的段 |
| POST | `/segments` | 连接码 | `{segments: [...]}`，最多 100 段 |
| POST | `/pair/start` | 连接码 | 发起端公钥 → 8 位配对码 |
| GET | `/pair/status?code=` | 连接码 | 加入端公钥（还没加入时为 null） |
| POST | `/pair/join` | — | 配对码 + 加入端公钥 → 发起端公钥（每 IP 10 分钟 20 次） |
| POST | `/pair/seal` | 连接码 | 发起端放入加密信封 |
| POST | `/pair/fetch` | — | 配对码 + 加入端公钥 → 信封（取走即删） |

连接码与 riji-reminder 共用（`/etc/riji-reminder/env` 里的 SHA-256）。

## 部署

```bash
scp sync.py riji-sync.service ubuntu@82.157.7.183:/tmp/
ssh ubuntu@82.157.7.183 'sudo install -d /opt/riji-sync && sudo install -m 644 /tmp/sync.py /opt/riji-sync/ \
  && sudo install -m 644 /tmp/riji-sync.service /etc/systemd/system/ && sudo systemctl daemon-reload \
  && sudo systemctl enable --now riji-sync'
```

## 测试

```bash
python3 -m unittest server/sync/test_sync.py
```
