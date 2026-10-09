#!/usr/bin/env python3
"""日迹服务端（riji-server）：邮件提醒 + 同步副本 + 设备配对中转，按「空间」隔离多用户。只用标准库与 SQLite。

nginx：/riji/api/ → 本服务的 /api/，/riji/sync/ → /sync/。

空间：每个用户一个，有自己的连接码（服务器只存 SHA-256）。站长空间（admin）可以发一次性邀请码；朋友用邀请码
创建自己的空间。所有数据都带空间 id，一个连接码只能读写自己的空间。

服务器能看到的：每个空间有几台设备、每段的大小与到达时间；开了邮件提醒的，还有收件邮箱、提醒时间与每天的几个数字
（总结写没写、目标几条、完成几件）——发不发邮件要靠它们决定。看不到的：笔记内容（端到端加密，密钥只在用户的设备上）。

环境变量（/etc/riji-server/env）：
  RIJI_ADMIN_TOKEN_SHA256   站长空间的连接码 SHA-256（第一次启动时建站长空间；兼容旧的 RIJI_REMINDER_TOKEN_SHA256）
  SMTP_HOST / SMTP_PORT / SMTP_USER / SMTP_PASSWORD / SMTP_FROM
  RIJI_DB                   SQLite，默认 /var/lib/riji-server/riji.sqlite3
  RIJI_HOST / RIJI_PORT     默认 127.0.0.1:8793
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import smtplib
import sqlite3
import ssl
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from email.utils import formataddr, make_msgid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ZONE = timezone(timedelta(hours=8))  # 与应用的 DayClock 相同：北京时间
GENESIS = "0" * 64
DEFAULT_MINUTES = 22 * 60 + 30
DEFAULT_DELAY = 60
MAX_RECIPIENTS = 5
MAX_BODY = 4 * 1024 * 1024
MAX_SEGMENT = 2 * 1024 * 1024
SPACE_QUOTA = 100 * 1024 * 1024
TEST_MAILS_PER_DAY = 5
KEEP_DAYS = 14
RETRY_SECONDS = 300
MAX_ATTEMPTS = 3
PAIR_TTL = 600
INVITE_TTL = 7 * 86400
ATTEMPTS_PER_IP = 20  # 加入配对、使用邀请码：每 IP 每 10 分钟
EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+\-]{1,64}@[A-Za-z0-9.\-]{1,190}\.[A-Za-z]{2,24}$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
DEVICE_RE = re.compile(r"^[a-z0-9\-]{1,40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
B64U = re.compile(r"^[A-Za-z0-9_\-]+$")
INVITE_RE = re.compile(r"^[A-Z2-9]{10}$")
INVITE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # 去掉容易看错的 0 O 1 I


def sha256(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def b64u_decode(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


# ---------------------------------------------------------------- 提醒的文字与规则（与应用里的 Evening.nudge 相同）


def nudge(evening: dict | None) -> tuple[str, str] | None:
    """返回 (标题, 正文)；都写好了返回 None。evening 为 None 表示今天还没在任何设备上打开日迹。"""
    if evening is None:
        return "今天还没打开日迹", "今天还没有在任何设备上打开日迹。花一分钟：勾掉做完的事，写一句总结，再定下明天要做的事。"
    has_summary = bool(evening.get("has_summary"))
    plans = int(evening.get("plans") or 0)
    total = int(evening.get("total") or 0)
    pending = int(evening.get("pending") or 0)
    done = f"今天完成 {int(evening.get('done') or 0)}/{total}。" if total > 0 else ""
    carry = f"没做完的 {pending} 件会带到明天，不用再抄一遍。" if pending > 0 else ""
    if has_summary and plans > 0:
        return None
    if not has_summary and plans == 0:
        return "今晚总结", done + "用一句话记下今天，再定下明天要做的事。" + carry
    if not has_summary:
        return "今日总结还没写", done + "明天的目标定好了，再用一句话记下今天。"
    return "明天做什么？", "总结写好了。定一两件明天的事，明早会出现在今日目标里。" + carry


def merged_evening(devices: dict) -> dict | None:
    """多台设备合起来看：任一台写了总结就算写了，目标取最多的一台，数字取最近上报的一台。"""
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
        lines.append(f"到了 {minutes // 60:02d}:{minutes % 60:02d} 的提醒时间之后还空着，所以发了这封邮件兜底。今天不会再发。")
    lines += ["", "—— 日迹", "在日迹的设置里可以更改收件人、兜底时间，或关掉邮件提醒。", "邮件里只有这几个数字：日迹不会把笔记内容发给服务器。"]
    return subject, "\n".join(lines)


def logical_day(local: datetime, settings: dict) -> tuple[str, int]:
    """按一天的分界线（day_start）算「今天」和此刻离这一天日历零点过了多少分钟。"""
    day_start = int(settings.get("day_start", 0))
    shifted = local - timedelta(minutes=day_start)
    midnight = shifted.replace(hour=0, minute=0, second=0, microsecond=0)
    return shifted.strftime("%Y-%m-%d"), int((local - midnight).total_seconds() // 60)


def due_minutes(settings: dict) -> int:
    """兜底时刻（从这一天日历零点起的分钟数，可以过零点）；最晚在分界线前 5 分钟。"""
    day_start = int(settings.get("day_start", 0))
    minutes = int(settings.get("minutes", DEFAULT_MINUTES))
    if minutes < day_start:
        minutes += 1440
    return min(minutes + int(settings.get("delay", DEFAULT_DELAY)), 1440 + day_start - 5)


def clean_settings(raw) -> dict | None:
    if not isinstance(raw, dict):
        return None
    recipients = raw.get("recipients")
    if not isinstance(recipients, list) or len(recipients) > MAX_RECIPIENTS:
        raise ValueError("recipients")
    recipients = [r.strip() for r in recipients if isinstance(r, str) and r.strip()]
    if any(not EMAIL_RE.match(r) for r in recipients):
        raise ValueError("recipients")
    minutes, delay, day_start = raw.get("minutes", DEFAULT_MINUTES), raw.get("delay", DEFAULT_DELAY), raw.get("day_start", 0)
    updated_at = raw.get("updated_at", 0)
    if not (isinstance(minutes, int) and 0 <= minutes < 1440 and isinstance(delay, int) and 0 <= delay <= 360):
        raise ValueError("time")
    if not (isinstance(day_start, int) and 0 <= day_start < 360) or not isinstance(updated_at, (int, float)):
        raise ValueError("settings")
    return {"email": bool(raw.get("email")), "reminder": bool(raw.get("reminder", True)), "recipients": recipients,
            "minutes": minutes, "delay": delay, "day_start": day_start, "updated_at": updated_at}


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


def clean_segment(raw) -> dict:
    if not isinstance(raw, dict):
        raise ValueError("segment")
    seg = {"v": raw.get("v"), "device": raw.get("device"), "seq": raw.get("seq"), "prev": raw.get("prev"),
           "epoch": raw.get("epoch"), "hlc_max": raw.get("hlc_max", ""), "ct": raw.get("ct")}
    if seg["v"] != 1 or not isinstance(seg["device"], str) or not DEVICE_RE.match(seg["device"]):
        raise ValueError("segment")
    if not isinstance(seg["seq"], int) or seg["seq"] < 1 or not isinstance(seg["epoch"], int) or seg["epoch"] < 0:
        raise ValueError("segment")
    if not isinstance(seg["prev"], str) or not HEX64.match(seg["prev"]):
        raise ValueError("segment")
    if not isinstance(seg["hlc_max"], str) or len(seg["hlc_max"]) > 80:
        raise ValueError("segment")
    if not isinstance(seg["ct"], str) or not B64U.match(seg["ct"]) or not 40 <= len(seg["ct"]) <= MAX_SEGMENT:
        raise ValueError("segment")
    return seg


def valid_pub(text) -> bool:
    if not isinstance(text, str) or not B64U.match(text) or len(text) != 87:
        return False
    raw = b64u_decode(text)
    return len(raw) == 65 and raw[0] == 4


# ---------------------------------------------------------------- 存储


class QuotaExceeded(Exception):
    pass


class Store:
    """一个 SQLite：空间、邀请、日志段、提醒（设置 / 每天每台设备的数字 / 发信结果 / 测试次数）。"""

    def __init__(self, path: str):
        if os.path.dirname(path):
            os.makedirs(os.path.dirname(path), exist_ok=True)
        self.db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA foreign_keys=ON")
        self.lock = threading.RLock()
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS spaces (id TEXT PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE, admin INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL, invited_by TEXT);
            CREATE TABLE IF NOT EXISTS invites (code_hash TEXT PRIMARY KEY, created_by TEXT NOT NULL, created_at REAL NOT NULL,
                expires_at REAL NOT NULL, used_at REAL);
            CREATE TABLE IF NOT EXISTS segments (space TEXT NOT NULL, device TEXT NOT NULL, seq INTEGER NOT NULL, prev TEXT NOT NULL,
                hash TEXT NOT NULL, body TEXT NOT NULL, size INTEGER NOT NULL, received_at REAL NOT NULL, PRIMARY KEY (space, device, seq));
            CREATE TABLE IF NOT EXISTS reminder_settings (space TEXT PRIMARY KEY, json TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS reminder_days (space TEXT NOT NULL, date TEXT NOT NULL, device TEXT NOT NULL, json TEXT NOT NULL,
                PRIMARY KEY (space, date, device));
            CREATE TABLE IF NOT EXISTS reminder_sent (space TEXT NOT NULL, date TEXT NOT NULL, json TEXT NOT NULL, PRIMARY KEY (space, date));
            CREATE TABLE IF NOT EXISTS reminder_tests (space TEXT NOT NULL, date TEXT NOT NULL, count INTEGER NOT NULL, PRIMARY KEY (space, date));
        """)

    def q(self, sql: str, args=()) -> list:
        with self.lock:
            return self.db.execute(sql, args).fetchall()

    # ---- 空间

    def ensure_admin(self, token_hash: str) -> None:
        if not token_hash:
            return
        with self.lock:
            if not self.q("SELECT 1 FROM spaces WHERE admin = 1"):
                self.db.execute("INSERT INTO spaces (id, token_hash, admin, created_at) VALUES (?, ?, 1, ?)", ("owner", token_hash, time.time()))

    def space_for(self, token: str) -> tuple[str, bool] | None:
        if not token:
            return None
        digest = sha256(token)
        for space, stored, admin in self.q("SELECT id, token_hash, admin FROM spaces WHERE token_hash = ?", (digest,)):
            if hmac.compare_digest(stored, digest):
                return space, bool(admin)
        return None

    def create_invite(self, admin_space: str, now: float) -> str:
        code = "".join(secrets.choice(INVITE_ALPHABET) for _ in range(10))
        with self.lock:
            self.db.execute("INSERT INTO invites (code_hash, created_by, created_at, expires_at) VALUES (?, ?, ?, ?)",
                            (sha256(code), admin_space, now, now + INVITE_TTL))
        return code

    def redeem_invite(self, code: str, now: float) -> str | None:
        """邀请码有效就建一个新空间，返回它的连接码（只此一次给出）。"""
        token = "riji-" + secrets.token_urlsafe(18)
        with self.lock:
            row = self.q("SELECT created_by, expires_at, used_at FROM invites WHERE code_hash = ?", (sha256(code),))
            if not row or row[0][2] is not None or row[0][1] < now:
                return None
            space = secrets.token_hex(8)
            self.db.execute("UPDATE invites SET used_at = ? WHERE code_hash = ?", (now, sha256(code)))
            self.db.execute("INSERT INTO spaces (id, token_hash, admin, created_at, invited_by) VALUES (?, ?, 0, ?, ?)",
                            (space, sha256(token), now, row[0][0]))
        return token

    def delete_space(self, space: str) -> None:
        with self.lock:
            for table in ("segments", "reminder_settings", "reminder_days", "reminder_sent", "reminder_tests"):
                self.db.execute(f"DELETE FROM {table} WHERE space = ?", (space,))
            self.db.execute("DELETE FROM spaces WHERE id = ?", (space,))

    def space_info(self, space: str) -> dict:
        devices, segments, size = self.q("SELECT COUNT(DISTINCT device), COUNT(*), COALESCE(SUM(size), 0) FROM segments WHERE space = ?", (space,))[0]
        return {"devices": devices, "segments": segments, "bytes": size, "quota": SPACE_QUOTA}

    def totals(self) -> dict:
        spaces = self.q("SELECT COUNT(*) FROM spaces")[0][0]
        segments, size = self.q("SELECT COUNT(*), COALESCE(SUM(size), 0) FROM segments")[0]
        return {"spaces": spaces, "segments": segments, "bytes": size}

    # ---- 日志段

    def heads(self, space: str) -> dict:
        rows = self.q("SELECT device, seq, hash FROM segments s WHERE space = ? AND seq = "
                      "(SELECT MAX(seq) FROM segments WHERE space = s.space AND device = s.device)", (space,))
        return {device: {"seq": seq, "hash": digest} for device, seq, digest in rows}

    def fetch(self, space: str, device: str, start: int, limit: int) -> list:
        rows = self.q("SELECT body FROM segments WHERE space = ? AND device = ? AND seq >= ? ORDER BY seq LIMIT ?", (space, device, start, limit))
        return [json.loads(body) for (body,) in rows]

    def append(self, space: str, segment: dict) -> str:
        device, seq, prev = segment["device"], segment["seq"], segment["prev"]
        digest = hashlib.sha256(b64u_decode(segment["ct"])).hexdigest()
        body = json.dumps(segment, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        with self.lock:
            same = self.q("SELECT hash FROM segments WHERE space = ? AND device = ? AND seq = ?", (space, device, seq))
            if same:
                if same[0][0] == digest:
                    return "duplicate"
                raise ValueError("fork")
            head = self.q("SELECT seq, hash FROM segments WHERE space = ? AND device = ? ORDER BY seq DESC LIMIT 1", (space, device))
            head_seq, head_hash = head[0] if head else (0, GENESIS)
            if seq != head_seq + 1 or prev != head_hash:
                raise ValueError("not_next")
            used = self.q("SELECT COALESCE(SUM(size), 0) FROM segments WHERE space = ?", (space,))[0][0]
            if used + len(body) > SPACE_QUOTA:
                raise QuotaExceeded()
            self.db.execute("INSERT INTO segments (space, device, seq, prev, hash, body, size, received_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                            (space, device, seq, prev, digest, body, len(body), time.time()))
        return "stored"

    # ---- 提醒

    def settings(self, space: str) -> dict:
        row = self.q("SELECT json FROM reminder_settings WHERE space = ?", (space,))
        return json.loads(row[0][0]) if row else {}

    def put_settings(self, space: str, settings: dict) -> None:
        with self.lock:
            self.db.execute("INSERT OR REPLACE INTO reminder_settings (space, json) VALUES (?, ?)", (space, json.dumps(settings, ensure_ascii=False)))

    def put_day(self, space: str, date: str, device: str, evening: dict) -> None:
        with self.lock:
            self.db.execute("INSERT OR REPLACE INTO reminder_days (space, date, device, json) VALUES (?, ?, ?, ?)",
                            (space, date, device, json.dumps(evening)))

    def day(self, space: str, date: str) -> dict:
        return {device: json.loads(body) for device, body in self.q("SELECT device, json FROM reminder_days WHERE space = ? AND date = ?", (space, date))}

    def sent(self, space: str, date: str) -> dict:
        row = self.q("SELECT json FROM reminder_sent WHERE space = ? AND date = ?", (space, date))
        return json.loads(row[0][0]) if row else {}

    def put_sent(self, space: str, date: str, record: dict) -> None:
        with self.lock:
            self.db.execute("INSERT OR REPLACE INTO reminder_sent (space, date, json) VALUES (?, ?, ?)", (space, date, json.dumps(record)))

    def bump_tests(self, space: str, date: str) -> int:
        with self.lock:
            row = self.q("SELECT count FROM reminder_tests WHERE space = ? AND date = ?", (space, date))
            count = (row[0][0] if row else 0) + 1
            self.db.execute("INSERT OR REPLACE INTO reminder_tests (space, date, count) VALUES (?, ?, ?)", (space, date, count))
            return count

    def prune(self, today: str) -> None:
        cutoff = (datetime.strptime(today, "%Y-%m-%d") - timedelta(days=KEEP_DAYS)).strftime("%Y-%m-%d")
        with self.lock:
            for table in ("reminder_days", "reminder_sent", "reminder_tests"):
                self.db.execute(f"DELETE FROM {table} WHERE date < ?", (cutoff,))
            self.db.execute("DELETE FROM invites WHERE expires_at < ? AND used_at IS NULL", (time.time() - 86400,))

    def mail_spaces(self) -> list[tuple[str, dict]]:
        return [(space, json.loads(body)) for space, body in self.q("SELECT space, json FROM reminder_settings")]


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


def tick_space(store: Store, mailer: Mailer, space: str, settings: dict, now: datetime, log=print) -> str | None:
    """一个空间到点就检查并发信：sent / skipped / error / None（还没到点、已处理或没开）。"""
    if not settings.get("email") or not settings.get("recipients") or not mailer.configured:
        return None
    today, elapsed = logical_day(now.astimezone(ZONE), settings)
    if elapsed < due_minutes(settings):
        return None
    record = store.sent(space, today)
    if record.get("result") in ("sent", "skipped"):
        return None
    if record.get("attempts", 0) >= MAX_ATTEMPTS or now.timestamp() - record.get("at", 0) < RETRY_SECONDS:
        return None
    found = nudge(merged_evening(store.day(space, today)))
    error = None
    if found is None:
        result = "skipped"
    else:
        subject, body = compose(settings, *found)
        try:
            mailer.send(list(settings["recipients"]), subject, body)
            result = "sent"
        except Exception as exc:  # noqa: BLE001 — 记下来，过五分钟再试
            result, error = "error", f"{type(exc).__name__}: {exc}"[:200]
    attempts = record.get("attempts", 0) + (result != "skipped")
    store.put_sent(space, today, {"result": result, "at": now.timestamp(), "attempts": attempts, **({"error": error} if error else {})})
    log(f"{space} {today} reminder: {result}" + (f" ({error})" if error else ""))
    return result


def tick(store: Store, mailer: Mailer, now: datetime, log=print) -> dict:
    results = {space: tick_space(store, mailer, space, settings, now, log) for space, settings in store.mail_spaces()}
    store.prune(now.astimezone(ZONE).strftime("%Y-%m-%d"))
    return results


# ---------------------------------------------------------------- 配对中转


class Pairings:
    """内存里的配对会话：code → {space, pub_a, pub_b, sealed, expires}。"""

    def __init__(self, clock=time.time):
        self.sessions: dict[str, dict] = {}
        self.lock = threading.Lock()
        self.clock = clock

    def _gc(self):
        now = self.clock()
        for code in [c for c, s in self.sessions.items() if s["expires"] < now]:
            del self.sessions[code]

    def start(self, space: str, pub_a: str) -> dict:
        with self.lock:
            self._gc()
            code = "".join(secrets.choice("0123456789") for _ in range(8))
            while code in self.sessions:
                code = "".join(secrets.choice("0123456789") for _ in range(8))
            self.sessions[code] = {"space": space, "pub_a": pub_a, "pub_b": None, "sealed": None, "expires": self.clock() + PAIR_TTL}
            return {"code": code, "expires_in": PAIR_TTL}

    def join(self, code: str, pub_b: str):
        with self.lock:
            self._gc()
            session = self.sessions.get(code)
            if not session:
                return "not_found", None
            if session["pub_b"] and session["pub_b"] != pub_b:
                return "taken", None
            session["pub_b"] = pub_b
            return "ok", session["pub_a"]

    def status(self, space: str, code: str):
        with self.lock:
            self._gc()
            session = self.sessions.get(code)
            return None if session is None or session["space"] != space else {"pub_b": session["pub_b"]}

    def seal(self, space: str, code: str, sealed: str) -> str:
        with self.lock:
            self._gc()
            session = self.sessions.get(code)
            if not session or session["space"] != space:
                return "not_found"
            if not session["pub_b"]:
                return "not_joined"
            session["sealed"] = sealed
            return "ok"

    def fetch(self, code: str, pub_b: str):
        with self.lock:
            self._gc()
            session = self.sessions.get(code)
            if not session or session["pub_b"] != pub_b:
                return "not_found", None
            if not session["sealed"]:
                return "waiting", None
            sealed = session["sealed"]
            del self.sessions[code]
            return "ok", sealed


class Throttle:
    """每个 IP 每 10 分钟最多 ATTEMPTS_PER_IP 次（不需要连接码的入口：加入配对、使用邀请码）。只在内存里，不落盘。"""

    def __init__(self, clock=time.time):
        self.hits: dict[str, list[float]] = {}
        self.lock = threading.Lock()
        self.clock = clock

    def allow(self, key: str) -> bool:
        with self.lock:
            now = self.clock()
            hits = [t for t in self.hits.get(key, []) if now - t < 600]
            if len(hits) >= ATTEMPTS_PER_IP:
                self.hits[key] = hits
                return False
            hits.append(now)
            self.hits[key] = hits
            return True


# ---------------------------------------------------------------- HTTP


def make_handler(store: Store, mailer: Mailer, pairings: Pairings, throttle: Throttle, clock=lambda: datetime.now(timezone.utc)):
    class Handler(BaseHTTPRequestHandler):
        server_version = "riji-server"
        sys_version = ""

        def log_message(self, fmt, *args):  # 不记录请求（不留 IP、路径与内容）
            pass

        def reply(self, status: int, payload: dict):
            data = json.dumps(payload, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def ip(self) -> str:
            return self.headers.get("X-Real-IP") or self.client_address[0]

        def space(self):
            header = self.headers.get("Authorization", "")
            found = store.space_for(header[7:].strip() if header.startswith("Bearer ") else "")
            if found is None:
                time.sleep(0.5)
            return found

        def body(self):
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > MAX_BODY:
                raise ValueError("body")
            payload = json.loads(self.rfile.read(length))
            if not isinstance(payload, dict):
                raise ValueError("body")
            return payload

        def do_GET(self):
            url = urlparse(self.path)
            query = {k: v[0] for k, v in parse_qs(url.query).items()}
            if url.path in ("/api/health", "/sync/health"):
                return self.reply(200, {"ok": True, "smtp": mailer.configured})
            found = self.space()
            if found is None:
                return self.reply(401, {"error": "unauthorized"})
            space, admin = found
            if url.path == "/api/spaces/me":
                settings = store.settings(space)
                today = logical_day(clock().astimezone(ZONE), settings)[0]
                return self.reply(200, {"admin": admin, **store.space_info(space), "email": bool(settings.get("email")),
                                        "today": store.sent(space, today).get("result")})
            if url.path == "/sync/heads":
                return self.reply(200, {"devices": store.heads(space)})
            if url.path == "/sync/segments":
                device = query.get("device", "")
                try:
                    start, limit = max(1, int(query.get("from", "1"))), min(500, max(1, int(query.get("limit", "200"))))
                except ValueError:
                    return self.reply(400, {"error": "invalid"})
                if not DEVICE_RE.match(device):
                    return self.reply(400, {"error": "invalid"})
                return self.reply(200, {"segments": store.fetch(space, device, start, limit)})
            if url.path == "/sync/pair/status":
                status = pairings.status(space, query.get("code", ""))
                return self.reply(404, {"error": "not_found"}) if status is None else self.reply(200, status)
            return self.reply(404, {"error": "not_found"})

        def do_DELETE(self):
            if urlparse(self.path).path != "/api/spaces/me":
                return self.reply(404, {"error": "not_found"})
            found = self.space()
            if found is None:
                return self.reply(401, {"error": "unauthorized"})
            if found[1]:
                return self.reply(403, {"error": "admin_space"})
            store.delete_space(found[0])
            return self.reply(200, {"ok": True})

        def do_POST(self):
            path = urlparse(self.path).path
            try:
                payload = self.body()
            except (ValueError, TypeError):
                return self.reply(400, {"error": "invalid"})

            # 不需要连接码的入口（新设备 / 新朋友还没有连接码），按 IP 限流
            if path in ("/sync/pair/join", "/api/spaces"):
                if not throttle.allow(self.ip()):
                    return self.reply(429, {"error": "rate_limited"})
                if path == "/api/spaces":
                    code = str(payload.get("invite", "")).strip().upper().replace("-", "").replace(" ", "")
                    token = store.redeem_invite(code, time.time()) if INVITE_RE.match(code) else None
                    return self.reply(200, {"token": token}) if token else self.reply(404, {"error": "invite_invalid"})
                code, pub = payload.get("code"), payload.get("pub")
                if not isinstance(code, str) or not re.fullmatch(r"\d{8}", code) or not valid_pub(pub):
                    return self.reply(400, {"error": "invalid"})
                result, pub_a = pairings.join(code, pub)
                return self.reply(200, {"pub": pub_a}) if result == "ok" else self.reply(404 if result == "not_found" else 409, {"error": result})
            if path == "/sync/pair/fetch":
                code, pub = payload.get("code"), payload.get("pub")
                if not isinstance(code, str) or not valid_pub(pub):
                    return self.reply(400, {"error": "invalid"})
                result, sealed = pairings.fetch(code, pub)
                return self.reply(200, {"sealed": sealed}) if result == "ok" else self.reply(202 if result == "waiting" else 404, {"error": result})

            found = self.space()
            if found is None:
                return self.reply(401, {"error": "unauthorized"})
            space, admin = found
            now = clock()

            if path == "/api/invites":
                if not admin:
                    return self.reply(403, {"error": "not_admin"})
                return self.reply(200, {"invite": store.create_invite(space, time.time()), "expires_in": INVITE_TTL})
            if path in ("/api/status", "/api/test"):
                try:
                    settings = clean_settings(payload.get("settings"))
                except (ValueError, TypeError, AttributeError):
                    return self.reply(400, {"error": "invalid"})
                current = store.settings(space)
                if settings and settings["updated_at"] >= current.get("updated_at", 0):
                    store.put_settings(space, settings)
                    current = settings
                if path == "/api/status":
                    try:
                        date, device = payload["date"], payload["device"]
                        if not (isinstance(date, str) and DATE_RE.match(date) and isinstance(device, str) and DEVICE_RE.match(device)):
                            raise ValueError("id")
                        evening = clean_evening(payload.get("evening"))
                    except (KeyError, ValueError, TypeError):
                        return self.reply(400, {"error": "invalid"})
                    evening["received_at"] = now.timestamp()
                    store.put_day(space, date, device, evening)
                    return self.reply(200, {"ok": True, "settings": current, "smtp": mailer.configured})
                if not mailer.configured:
                    return self.reply(503, {"error": "smtp_not_configured"})
                if not current.get("recipients"):
                    return self.reply(400, {"error": "no_recipients"})
                today = logical_day(now.astimezone(ZONE), current)[0]
                if store.bump_tests(space, today) > TEST_MAILS_PER_DAY:
                    return self.reply(429, {"error": "rate_limited"})
                subject, body = compose(current, "邮件提醒已接通", "以后每天到点时，如果今日总结或明日目标还空着，就会收到这样一封邮件。", test=True)
                try:
                    mailer.send(current["recipients"], subject, body)
                except Exception as exc:  # noqa: BLE001
                    return self.reply(502, {"error": "send_failed", "detail": type(exc).__name__})
                return self.reply(200, {"ok": True, "sent_to": len(current["recipients"])})
            if path == "/sync/segments":
                segments = payload.get("segments")
                if not isinstance(segments, list) or not 1 <= len(segments) <= 100:
                    return self.reply(400, {"error": "invalid"})
                results = []
                for raw in segments:
                    try:
                        results.append(store.append(space, clean_segment(raw)))
                    except QuotaExceeded:
                        return self.reply(413, {"error": "quota", "stored": len(results)})
                    except ValueError as error:
                        return self.reply(409 if str(error) in ("fork", "not_next") else 400,
                                          {"error": str(error), "stored": len(results), "heads": store.heads(space)})
                return self.reply(200, {"ok": True, "results": results})
            if path == "/sync/pair/start":
                if not valid_pub(payload.get("pub")):
                    return self.reply(400, {"error": "invalid"})
                return self.reply(200, pairings.start(space, payload["pub"]))
            if path == "/sync/pair/seal":
                code, sealed = payload.get("code"), payload.get("sealed")
                if not isinstance(code, str) or not isinstance(sealed, str) or not B64U.match(sealed) or len(sealed) > 8192:
                    return self.reply(400, {"error": "invalid"})
                result = pairings.seal(space, code, sealed)
                return self.reply(200 if result == "ok" else 409 if result == "not_joined" else 404, {"ok": result == "ok"})
            return self.reply(404, {"error": "not_found"})

    return Handler


# ---------------------------------------------------------------- 从单用户版迁移


def migrate(store: Store, reminder_state: str | None, sync_db: str | None) -> dict:
    """把旧的 riji-reminder（state.json）与 riji-sync（sync.sqlite3）的数据并入站长空间。"""
    done = {"settings": 0, "days": 0, "sent": 0, "segments": 0}
    if reminder_state and os.path.exists(reminder_state):
        with open(reminder_state, encoding="utf-8") as handle:
            data = json.load(handle)
        if data.get("settings"):
            store.put_settings("owner", data["settings"]); done["settings"] = 1
        for date, devices in data.get("days", {}).items():
            for device, evening in devices.items():
                store.put_day("owner", date, device, evening); done["days"] += 1
        for date, record in data.get("sent", {}).items():
            store.put_sent("owner", date, record); done["sent"] += 1
    if sync_db and os.path.exists(sync_db):
        old = sqlite3.connect(sync_db)
        for row in old.execute("SELECT device, seq, prev, hash, body, size, received_at FROM segments ORDER BY device, seq"):
            with store.lock:
                store.db.execute("INSERT OR IGNORE INTO segments (space, device, seq, prev, hash, body, size, received_at) VALUES ('owner', ?, ?, ?, ?, ?, ?, ?)", row)
            done["segments"] += 1
    return done


def main() -> None:
    env = os.environ
    store = Store(env.get("RIJI_DB", "/var/lib/riji-server/riji.sqlite3"))
    store.ensure_admin((env.get("RIJI_ADMIN_TOKEN_SHA256") or env.get("RIJI_REMINDER_TOKEN_SHA256") or "").strip().lower())
    if len(sys.argv) > 1 and sys.argv[1] == "--migrate":
        print(json.dumps(migrate(store, sys.argv[2] if len(sys.argv) > 2 else None, sys.argv[3] if len(sys.argv) > 3 else None)))
        return
    mailer = Mailer(env)

    def loop():
        while True:
            try:
                tick(store, mailer, datetime.now(timezone.utc))
            except Exception as exc:  # noqa: BLE001
                print(f"tick failed: {exc}", file=sys.stderr)
            time.sleep(30)

    threading.Thread(target=loop, daemon=True).start()
    address = (env.get("RIJI_HOST", "127.0.0.1"), int(env.get("RIJI_PORT", "8793")))
    print(f"riji-server listening on {address[0]}:{address[1]} (smtp {'ready' if mailer.configured else 'not configured'}, {store.totals()['spaces']} spaces)", flush=True)
    ThreadingHTTPServer(address, make_handler(store, mailer, Pairings(), Throttle())).serve_forever()


if __name__ == "__main__":
    main()
