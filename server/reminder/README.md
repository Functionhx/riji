# 日迹 · 邮件提醒（兜底）

系统通知之后，今日总结或明日目标仍然空着、或者今天还没在任何设备上打开日迹，就给设置里的邮箱发一封信，
一天最多一封。跑在腾讯云（国内的手机直连稳定），用 QQ / 163 等邮箱的 SMTP 发信。

## 它知道什么

设备在内容变化时上报**今天的几个数字**：总结写没写、明日目标几条、完成 / 总数、没做完几件；外加邮件设置
（收件人、通知时间、兜底延迟）。**不上报任何笔记内容**。状态文件只保留最近 14 天。

同步上线前各台设备各记各的，所以合起来看：任一台写了总结就算写了，目标取最多的一台。
「今天」按设置里的一天分界线（`day_start`，默认凌晨 4 点）计算，兜底邮件因此可以在零点后发出，
最晚在分界线前 5 分钟。设置以最近一次修改为准，服务器把最新的一份返回给每台设备，在 Mac 上改了收件人，手机下次上报时就跟着更新。

## 接口（nginx：`https://fanyuchen.com.cn/riji/api/` → `127.0.0.1:8791`）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/health` | 公开；只报是否配置好、收件人个数、今天的结果 |
| POST | `/status` | `Authorization: Bearer <连接码>`；`{device, date, evening:{has_summary, plans, done, total, pending}, settings?}` |
| POST | `/test` | 同上鉴权；立即发一封测试邮件（每天最多 5 封） |

连接码只在设备上（macOS 应用沙盒里的文件 / Android 应用私有偏好）；服务器只存它的 SHA-256。

## 部署

```bash
scp reminder.py configure.sh riji-reminder.service ubuntu@82.157.7.183:/tmp/
ssh ubuntu@82.157.7.183
sudo install -d /opt/riji-reminder && sudo install -m 644 /tmp/reminder.py /opt/riji-reminder/
sudo install -m 755 /tmp/configure.sh /opt/riji-reminder/
sudo install -m 644 /tmp/riji-reminder.service /etc/systemd/system/
echo "RIJI_REMINDER_TOKEN_SHA256=<连接码的 sha256>" | sudo tee /etc/riji-reminder/env && sudo chmod 600 /etc/riji-reminder/env
sudo systemctl daemon-reload && sudo systemctl enable --now riji-reminder
sudo /opt/riji-reminder/configure.sh        # 发信邮箱与授权码
```

nginx 的 `location ^~ /riji/api/` 见博客仓库 `deploy/nginx/fanyuchen.com.cn.conf`。

## 测试

```bash
python3 -m unittest server/reminder/test_reminder.py   # 假的发信器，不发真邮件
```
