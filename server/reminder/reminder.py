#!/usr/bin/env python3
"""日迹 · 邮件提醒（兜底）。

设备在内容变化时上报「今天」的几个数字（总结写没写、明日目标几条、完成几件），不上报任何笔记内容。
每天到「通知时间 + 兜底延迟」时检查：今日总结或明日目标还空着、或者今天还没在任何设备上打开日迹，
就给设置里的邮箱发一封信，一天最多一封。只用标准库；跑在腾讯云，经 nginx 的 /riji/api/ 转发进来。

环境变量（/etc/riji-reminder/env，见 README）：
  RIJI_REMINDER_TOKEN_SHA256  设备连接码的 SHA-256（十六进制）；连接码本身不落在服务器上
  SMTP_HOST / SMTP_PORT / SMTP_USER / SMTP_PASSWORD / SMTP_FROM   发信邮箱（QQ / 163 的 SMTP 授权码）
  RIJI_REMINDER_STATE  状态文件，默认 /var/lib/riji-reminder/state.json
  RIJI_REMINDER_HOST / RIJI_REMINDER_PORT   默认 127.0.0.1:8791
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import smtplib
import ssl
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from email.utils import formataddr, make_msgid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ZONE = timezone(timedelta(hours=8))  # 与应用的 DayClock 相同：北京时间
DEFAULT_MINUTES = 22 * 60 + 30
DEFAULT_DELAY = 60
MAX_RECIPIENTS = 5
MAX_BODY = 16 * 1024
TEST_MAILS_PER_DAY = 5
KEEP_DAYS = 14
RETRY_SECONDS = 300
MAX_ATTEMPTS = 3
EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+\-]{1,64}@[A-Za-z0-9.\-]{1,190}\.[A-Za-z]{2,24}$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
DEVICE_RE = re.compile(r"^[a-z0-9\-]{1,40}$")


# ---------------------------------------------------------------- 文字（与应用里的 Evening.nudge 相同）


def nudge(evening: dict | None) -> tuple[str, str] | None:
    """返回 (标题, 正文)；都写好了返回 None。evening 为 None 表示今天还没在任何设备上打开日迹。"""
    if evening is None:
        return "今天还没打开日迹", "今天还没有在任何设备上打开日迹。花一分钟：勾掉做完的事，写一句总结，再定下明天要做的事。"
    has_summary = bool(evening.get("has_summary"))
    plans = int(evening.get("plans") or 0)
    total = int(evening.get("total") or 0)
    pending = int(evening.get("pending") or 0)
    done = f"今天完成 {int(evening.get('done') or 0)}/{total}。" if total > 0 else ""
    carry = f"没做完的 {pending} 件会自动延续，不用再抄一遍。" if pending > 0 else ""
    if has_summary and plans > 0:
        return None
    if not has_summary and plans == 0:
        return "今晚总结", done + "用一句话记下今天，再定下明天要做的事。" + carry
    if not has_summary:
        return "今日总结还没写", done + "明天的目标定好了，再用一句话记下今天。"
    return "明天做什么？", "总结写好了。定一两件明天的事，明早会出现在今日目标里。" + carry


def merged_evening(devices: dict) -> dict | None:
    """多台设备（同步上线前各记各的）合起来看：任一台写了总结就算写了，目标取最多的一台，数字取最近上报的一台。"""
    if not devices:
        return None
    latest = max(devices.values(), key=lambda d: d.get("received_at", 0))
    merged = dict(latest)
    merged["has_summary"] = any(d.get("has_summary") for d in devices.values())
    merged["plans"] = max(int(d.get("plans") or 0) for d in devices.values())
    return merged


def compose(settings: dict, title: str, body: str, test: bool = False) -> tuple[str, str]:
    minutes = int(settings.get("minutes", DEFAULT_MINUTES))
    subject = f"日迹 · {title}" + ("（测试）" if test else "")
    lines = [body, ""]
    if test:
        lines.append("这是一封测试邮件：收到它，说明邮件提醒已经接通。")
    else:
        lines.append(f"{minutes // 60:02d}:{minutes % 60:02d} 的通知之后还空着，所以发了这封邮件兜底。今天不会再发。")
    lines += ["", "—— 日迹", "在日迹的设置里可以更改收件人、兜底时间，或关掉邮件提醒。", "邮件里只有这几个数字：日迹不会把笔记内容发给服务器。"]
    return subject, "\n".join(lines)


# ---------------------------------------------------------------- 状态


class State:
    """一个 JSON 文件：settings（最新的一份设置）、days（日期 → 设备 → 数字）、sent（日期 → 发信结果）、tests。"""

    def __init__(self, path: str):
        self.path = path
        self.lock = threading.Lock()
        try:
            with open(path, encoding="utf-8") as handle:
                self.data = json.load(handle)
        except (FileNotFoundError, ValueError):
            self.data = {}
        self.data.setdefault("settings", {})
        self.data.setdefault("days", {})
        self.data.setdefault("sent", {})
        self.data.setdefault("tests", {})

    def save(self) -> None:
        os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(self.data, handle, ensure_ascii=False, sort_keys=True)
        os.replace(tmp, self.path)

    def prune(self, today: str) -> None:
        cutoff = (datetime.strptime(today, "%Y-%m-%d") - timedelta(days=KEEP_DAYS)).strftime("%Y-%m-%d")
        for key in ("days", "sent", "tests"):
            for date in [d for d in self.data[key] if d < cutoff]:
                del self.data[key][date]


def clean_settings(raw) -> dict | None:
    if not isinstance(raw, dict):
        return None
    recipients = raw.get("recipients")
    if not isinstance(recipients, list) or len(recipients) > MAX_RECIPIENTS:
        raise ValueError("recipients")
    recipients = [r.strip() for r in recipients if isinstance(r, str) and r.strip()]
    if any(not EMAIL_RE.match(r) for r in recipients):
        raise ValueError("recipients")
    minutes = raw.get("minutes", DEFAULT_MINUTES)
    delay = raw.get("delay", DEFAULT_DELAY)
    updated_at = raw.get("updated_at", 0)
    if not (isinstance(minutes, int) and 0 <= minutes < 24 * 60 and isinstance(delay, int) and 0 <= delay <= 6 * 60):
        raise ValueError("time")
    if not isinstance(updated_at, (int, float)):
        raise ValueError("updated_at")
    return {
        "email": bool(raw.get("email")), "reminder": bool(raw.get("reminder", True)), "recipients": recipients,
        "minutes": minutes, "delay": delay, "updated_at": updated_at,
    }


def clean_evening(raw) -> dict:
    if not isinstance(raw, dict):
        raise ValueError("evening")
    out = {"has_summary": bool(raw.get("has_summary"))}
    for key in ("plans", "done", "total", "pending"):
        value = raw.get(key, 0)
        if not isinstance(value, int) or not 0 <= value <= 10000:
            raise ValueError(key)
        out[key] = value
    return out


# ---------------------------------------------------------------- 发信


class Mailer:
    def __init__(self, env: dict):
        self.host = env.get("SMTP_HOST", "")
        self.port = int(env.get("SMTP_PORT") or 465)
        self.user = env.get("SMTP_USER", "")
        self.password = env.get("SMTP_PASSWORD", "")
        self.sender = env.get("SMTP_FROM") or self.user

    @property
    def configured(self) -> bool:
        return bool(self.host and self.user and self.password)

    def send(self, recipients: list[str], subject: str, body: str) -> None:
        message = EmailMessage()
        message["From"] = formataddr(("日迹", self.sender))
        message["To"] = ", ".join(recipients)
        message["Subject"] = subject
        message["Message-ID"] = make_msgid(domain=self.sender.split("@")[-1])
        message.set_content(body)
        context = ssl.create_default_context()
        if self.port == 465:
            with smtplib.SMTP_SSL(self.host, self.port, context=context, timeout=20) as smtp:
                smtp.login(self.user, self.password)
                smtp.send_message(message)
        else:
            with smtplib.SMTP(self.host, self.port, timeout=20) as smtp:
                smtp.starttls(context=context)
                smtp.login(self.user, self.password)
                smtp.send_message(message)


# ---------------------------------------------------------------- 每天的检查


def due_minutes(settings: dict) -> int:
    """兜底时刻（当天的分钟数）；超过 23:55 就在 23:55 发，不拖到第二天。"""
    return min(int(settings.get("minutes", DEFAULT_MINUTES)) + int(settings.get("delay", DEFAULT_DELAY)), 23 * 60 + 55)


def tick(state: State, mailer: Mailer, now: datetime, log=print) -> str | None:
    """到点就检查并发信。返回这次做了什么（测试用）：sent / skipped / error / None（还没到点或已处理）。"""
    local = now.astimezone(ZONE)
    today = local.strftime("%Y-%m-%d")
    with state.lock:
        settings = state.data["settings"]
        if not settings.get("email") or not settings.get("recipients") or not mailer.configured:
            return None
        if local.hour * 60 + local.minute < due_minutes(settings):
            return None
        record = state.data["sent"].get(today, {})
        if record.get("result") in ("sent", "skipped"):
            return None
        if record.get("attempts", 0) >= MAX_ATTEMPTS or now.timestamp() - record.get("at", 0) < RETRY_SECONDS:
            return None
        found = nudge(merged_evening(state.data["days"].get(today, {})))
        recipients = list(settings["recipients"])
    if found is None:
        result, error = "skipped", None
    else:
        subject, body = compose(settings, *found)
        try:
            mailer.send(recipients, subject, body)
            result, error = "sent", None
        except Exception as exc:  # noqa: BLE001 — 记下来，过五分钟再试
            result, error = "error", f"{type(exc).__name__}: {exc}"[:200]
    with state.lock:
        attempts = state.data["sent"].get(today, {}).get("attempts", 0) + (result != "skipped")
        state.data["sent"][today] = {"result": result, "at": now.timestamp(), "attempts": attempts, **({"error": error} if error else {})}
        state.prune(today)
        state.save()
    log(f"{today} reminder: {result}" + (f" ({error})" if error else ""))
    return result


# ---------------------------------------------------------------- HTTP


def make_handler(state: State, mailer: Mailer, token_sha256: str, clock=lambda: datetime.now(timezone.utc)):
    class Handler(BaseHTTPRequestHandler):
        server_version = "riji-reminder"
        sys_version = ""

        def log_message(self, fmt, *args):  # 不记录请求内容
            pass

        def reply(self, status: int, payload: dict) -> None:
            data = json.dumps(payload, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def authorized(self) -> bool:
            header = self.headers.get("Authorization", "")
            token = header[7:].strip() if header.startswith("Bearer ") else ""
            ok = bool(token_sha256) and hmac.compare_digest(hashlib.sha256(token.encode()).hexdigest(), token_sha256)
            if not ok:
                time.sleep(0.5)
            return ok

        def body(self):
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > MAX_BODY:
                raise ValueError("body")
            return json.loads(self.rfile.read(length))

        def do_GET(self):
            if self.path != "/health":
                return self.reply(404, {"error": "not_found"})
            with state.lock:
                settings = state.data["settings"]
                today = clock().astimezone(ZONE).strftime("%Y-%m-%d")
                self.reply(200, {
                    "ok": True, "smtp": mailer.configured, "email": bool(settings.get("email")),
                    "recipients": len(settings.get("recipients", [])), "today": state.data["sent"].get(today, {}).get("result"),
                })

        def do_POST(self):
            if self.path not in ("/status", "/test"):
                return self.reply(404, {"error": "not_found"})
            if not self.authorized():
                return self.reply(401, {"error": "unauthorized"})
            try:
                payload = self.body()
                settings = clean_settings(payload.get("settings"))
            except (ValueError, TypeError, AttributeError):
                return self.reply(400, {"error": "invalid"})
            now = clock()
            today = now.astimezone(ZONE).strftime("%Y-%m-%d")
            with state.lock:
                if settings and settings["updated_at"] >= state.data["settings"].get("updated_at", 0):
                    state.data["settings"] = settings
                current = dict(state.data["settings"])
                if self.path == "/status":
                    try:
                        date, device = payload["date"], payload["device"]
                        if not (isinstance(date, str) and DATE_RE.match(date) and isinstance(device, str) and DEVICE_RE.match(device)):
                            raise ValueError("id")
                        evening = clean_evening(payload.get("evening"))
                    except (KeyError, ValueError, TypeError):
                        return self.reply(400, {"error": "invalid"})
                    evening["received_at"] = now.timestamp()
                    state.data["days"].setdefault(date, {})[device] = evening
                    state.prune(today)
                    state.save()
                    return self.reply(200, {"ok": True, "settings": current, "smtp": mailer.configured})
                state.save()
                if not mailer.configured:
                    return self.reply(503, {"error": "smtp_not_configured"})
                if not current.get("recipients"):
                    return self.reply(400, {"error": "no_recipients"})
                count = state.data["tests"].get(today, 0)
                if count >= TEST_MAILS_PER_DAY:
                    return self.reply(429, {"error": "rate_limited"})
                state.data["tests"][today] = count + 1
                state.save()
            subject, body = compose(current, "邮件提醒已接通", "以后每天到点时，如果今日总结或明日目标还空着，就会收到这样一封邮件。", test=True)
            try:
                mailer.send(current["recipients"], subject, body)
            except Exception as exc:  # noqa: BLE001
                return self.reply(502, {"error": "send_failed", "detail": type(exc).__name__})
            return self.reply(200, {"ok": True, "sent_to": len(current["recipients"])})

    return Handler


def main() -> None:
    env = os.environ
    state = State(env.get("RIJI_REMINDER_STATE", "/var/lib/riji-reminder/state.json"))
    mailer = Mailer(env)
    token = env.get("RIJI_REMINDER_TOKEN_SHA256", "").strip().lower()
    if not token:
        print("RIJI_REMINDER_TOKEN_SHA256 is not set; every request will be refused", file=sys.stderr)

    def loop():
        while True:
            try:
                tick(state, mailer, datetime.now(timezone.utc))
            except Exception as exc:  # noqa: BLE001
                print(f"tick failed: {exc}", file=sys.stderr)
            time.sleep(30)

    threading.Thread(target=loop, daemon=True).start()
    address = (env.get("RIJI_REMINDER_HOST", "127.0.0.1"), int(env.get("RIJI_REMINDER_PORT", "8791")))
    print(f"riji-reminder listening on {address[0]}:{address[1]} (smtp {'ready' if mailer.configured else 'not configured'})", flush=True)
    ThreadingHTTPServer(address, make_handler(state, mailer, token)).serve_forever()


if __name__ == "__main__":
    main()
