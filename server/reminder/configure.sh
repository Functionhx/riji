#!/bin/sh
# 在腾讯云上设置发信邮箱：sudo /opt/riji-reminder/configure.sh
# 授权码不是邮箱登录密码：QQ 邮箱「设置 → 账号 → POP3/SMTP 服务」，163 邮箱「设置 → POP3/SMTP/IMAP」里开启后生成。
set -eu
ENV=/etc/riji-reminder/env
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
mkdir -p /etc/riji-reminder
touch "$ENV" && chmod 600 "$ENV"
TOKEN_LINE=$(grep '^RIJI_REMINDER_TOKEN_SHA256=' "$ENV" || true)

printf '发信邮箱类型 [qq/163/其他]: '; read -r KIND
case "$KIND" in
  qq|QQ) HOST=smtp.qq.com; PORT=465 ;;
  163) HOST=smtp.163.com; PORT=465 ;;
  *) printf 'SMTP 服务器: '; read -r HOST; printf '端口 [465]: '; read -r PORT; PORT=${PORT:-465} ;;
esac
printf '发信邮箱地址: '; read -r USER
printf 'SMTP 授权码（输入时不显示）: '; stty -echo; read -r PASS; stty echo; echo

{
  [ -n "$TOKEN_LINE" ] && echo "$TOKEN_LINE"
  echo "SMTP_HOST=$HOST"
  echo "SMTP_PORT=$PORT"
  echo "SMTP_USER=$USER"
  echo "SMTP_PASSWORD=$PASS"
  echo "SMTP_FROM=$USER"
} > "$ENV.new"
chmod 600 "$ENV.new" && mv "$ENV.new" "$ENV"

python3 - "$HOST" "$PORT" "$USER" "$PASS" <<'PY'
import smtplib, ssl, sys
host, port, user, password = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
try:
    if port == 465:
        smtp = smtplib.SMTP_SSL(host, port, context=ssl.create_default_context(), timeout=15)
    else:
        smtp = smtplib.SMTP(host, port, timeout=15); smtp.starttls(context=ssl.create_default_context())
    smtp.login(user, password); smtp.quit()
    print("登录发信服务器成功。")
except Exception as exc:
    print(f"登录失败：{type(exc).__name__}: {exc}\n检查授权码，或稍后在应用里点「发一封测试邮件」再看。")
PY
systemctl restart riji-reminder
echo "已保存并重启 riji-reminder。回到日迹设置里点「发一封测试邮件」。"
