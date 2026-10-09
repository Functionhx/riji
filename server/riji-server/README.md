# 日迹服务端（riji-server）

腾讯云上的一个进程：邮件提醒、加密同步副本、设备配对中转，按**空间**隔离多用户。只用 Python 标准库与 SQLite。
取代了单用户时期的 `riji-reminder` 与 `riji-sync`（接口路径不变，旧应用照常工作）。

## 空间与邀请

- 每个用户一个空间，有自己的连接码；服务器只存连接码的 SHA-256。所有数据都带空间 id，一个连接码只能读写自己的空间。
- 站长空间（`owner`，admin）在第一次启动时由 `RIJI_ADMIN_TOKEN_SHA256` 建立，可以发**一次性邀请码**（10 位，7 天有效）。
- 朋友在日迹里输入邀请码 → 服务器新建一个空间、只此一次返回它的连接码；朋友的第一台设备生成自己的日迹密钥。
- 朋友可以随时「删除我的空间」：日志段、提醒设置与记录、连接码全部删除。站长空间不能这样删。
- 每个空间 100 MB 上限；不需要连接码的入口（使用邀请码、加入配对）按 IP 每 10 分钟 20 次。

## 隐私：服务器（站长）能看到什么

| 看得到 | 看不到 |
| --- | --- |
| 每个空间有几台设备、每段日志的大小与到达时间 | 任何笔记内容：今日目标、Spark、随记、总结、明日目标、进度、设置——都在设备上用只属于这个空间的密钥加密 |
| 开了邮件提醒的：收件邮箱、提醒时间、兜底时间、一天的分界线，以及每天的几个数字（总结写没写、目标几条、完成几件） | 改了哪条记录、写了几个字 |

- 服务进程不记录任何请求（不留 IP、路径与内容）；nginx 里 `/riji/` 的访问日志关闭。
- 公开的 `/health` 只回答服务是否正常、发信是否配置好，不透露有几个空间。
- 配对中转只经手临时公钥与加密信封，会话 10 分钟过期、信封取走即删；中间人会让两台设备的比对码不一致。

## 接口（nginx：`/riji/api/` → `/api/`，`/riji/sync/` → `/sync/`）

| 方法 | 路径 | 鉴权 | 说明 |
| --- | --- | --- | --- |
| GET | `/api/health`、`/sync/health` | — | `{ok, smtp}` |
| GET | `/api/spaces/me` | 连接码 | 是否站长、设备数、用量与上限、今天的邮件结果 |
| DELETE | `/api/spaces/me` | 连接码 | 删除自己的空间（站长空间 403） |
| POST | `/api/invites` | 站长 | 新的一次性邀请码 |
| POST | `/api/spaces` | —（限流） | `{invite}` → `{token}` |
| POST | `/api/status`、`/api/test` | 连接码 | 上报今天的几个数字与提醒设置 / 测试邮件（同旧 riji-reminder） |
| GET | `/sync/heads`、`/sync/segments` | 连接码 | 同旧 riji-sync |
| POST | `/sync/segments` | 连接码 | 只收接续的段；超出用量 413 |
| POST | `/sync/pair/start`、`/sync/pair/seal`；GET `/sync/pair/status` | 连接码 | 配对发起端 |
| POST | `/sync/pair/join`（限流）、`/sync/pair/fetch` | — | 配对加入端 |

## 部署与从单用户版迁移

```bash
scp riji_server.py riji-server.service ubuntu@82.157.7.183:/tmp/
ssh ubuntu@82.157.7.183
sudo install -d /opt/riji-server && sudo install -m 644 /tmp/riji_server.py /opt/riji-server/
sudo install -d -m 700 /etc/riji-server
sudo sed 's/^RIJI_REMINDER_TOKEN_SHA256=/RIJI_ADMIN_TOKEN_SHA256=/' /etc/riji-reminder/env | sudo tee /etc/riji-server/env >/dev/null
sudo chmod 600 /etc/riji-server/env
sudo install -m 644 /tmp/riji-server.service /etc/systemd/system/ && sudo systemctl daemon-reload
sudo systemctl start riji-server && sudo systemctl stop riji-server          # 让 systemd 建好状态目录
sudo systemctl stop riji-reminder riji-sync
sudo env $(sudo cat /etc/riji-server/env | xargs) RIJI_DB=/var/lib/private/riji-server/riji.sqlite3 \
  python3 /opt/riji-server/riji_server.py --migrate /var/lib/private/riji-reminder/state.json /var/lib/private/riji-sync/sync.sqlite3
sudo systemctl enable --now riji-server && sudo systemctl disable riji-reminder riji-sync
# nginx：/riji/api/ → http://127.0.0.1:8793/api/，/riji/sync/ → http://127.0.0.1:8793/sync/，两处 access_log off
```

## 测试

```bash
python3 -m unittest server/riji-server/test_riji_server.py
```
