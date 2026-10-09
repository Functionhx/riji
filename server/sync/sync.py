#!/usr/bin/env python3
"""日迹 · 同步副本（riji-sync）。只用标准库；跑在腾讯云，经 nginx 的 /riji/sync/ 转发进来。

只存每台设备只追加的加密日志段（docs/DESIGN.md §8.3）：看得到设备 id、序号、大小和时间，看不到内容。
只接受「接在这台设备最后一段后面、prev 吻合」的段；重复推送同一段是无害的。

另外负责设备配对的中转（spec/reference/riji.mjs「设备配对」）：只转交双方的临时公钥与加密信封，
会话 10 分钟过期、信封取走即删；替换公钥做中间人会让两边的比对码不一致，由站长当面核对。

环境变量（与 riji-reminder 共用 /etc/riji-reminder/env）：
  RIJI_REMINDER_TOKEN_SHA256  连接码的 SHA-256；同步与发起配对都要它，加入配对不要（新设备还没有连接码）
  RIJI_SYNC_DB                SQLite 文件，默认 /var/lib/riji-sync/sync.sqlite3
  RIJI_SYNC_HOST / RIJI_SYNC_PORT   默认 127.0.0.1:8792
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import sqlite3
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

GENESIS = "0" * 64
MAX_BODY = 4 * 1024 * 1024
MAX_SEGMENT = 2 * 1024 * 1024
PAIR_TTL = 600
JOIN_ATTEMPTS_PER_IP = 20  # 每 10 分钟
DEVICE_RE = re.compile(r"^[a-z0-9\-]{1,40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
B64U = re.compile(r"^[A-Za-z0-9_\-]+$")


def b64u_decode(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


class Store:
    def __init__(self, path: str):
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        self.db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute(
            "CREATE TABLE IF NOT EXISTS segments (device TEXT NOT NULL, seq INTEGER NOT NULL, prev TEXT NOT NULL, "
            "hash TEXT NOT NULL, body TEXT NOT NULL, size INTEGER NOT NULL, received_at REAL NOT NULL, PRIMARY KEY (device, seq))"
        )
        self.lock = threading.Lock()

    def heads(self) -> dict:
        with self.lock:
            rows = self.db.execute(
                "SELECT device, seq, hash FROM segments s WHERE seq = (SELECT MAX(seq) FROM segments WHERE device = s.device)"
            ).fetchall()
        return {device: {"seq": seq, "hash": digest} for device, seq, digest in rows}

    def fetch(self, device: str, start: int, limit: int) -> list:
        with self.lock:
            rows = self.db.execute(
                "SELECT body FROM segments WHERE device = ? AND seq >= ? ORDER BY seq LIMIT ?", (device, start, limit)
            ).fetchall()
        return [json.loads(body) for (body,) in rows]

    def append(self, segment: dict) -> str:
        """→ "stored" / "duplicate"；不接续时抛 ValueError（附当前头部）。"""
        device, seq, prev = segment["device"], segment["seq"], segment["prev"]
        digest = hashlib.sha256(b64u_decode(segment["ct"])).hexdigest()
        body = json.dumps(segment, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        with self.lock:
            same = self.db.execute("SELECT hash FROM segments WHERE device = ? AND seq = ?", (device, seq)).fetchone()
            if same:
                if same[0] == digest:
                    return "duplicate"
                raise ValueError("fork")
            head = self.db.execute("SELECT seq, hash FROM segments WHERE device = ? ORDER BY seq DESC LIMIT 1", (device,)).fetchone()
            head_seq, head_hash = head if head else (0, GENESIS)
            if seq != head_seq + 1 or prev != head_hash:
                raise ValueError("not_next")
            self.db.execute(
                "INSERT INTO segments (device, seq, prev, hash, body, size, received_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                (device, seq, prev, digest, body, len(body), time.time()),
            )
        return "stored"

    def stats(self) -> dict:
        with self.lock:
            devices, segments, size = self.db.execute("SELECT COUNT(DISTINCT device), COUNT(*), COALESCE(SUM(size), 0) FROM segments").fetchone()
        return {"devices": devices, "segments": segments, "bytes": size}


def clean_segment(raw) -> dict:
    if not isinstance(raw, dict):
        raise ValueError("segment")
    seg = {
        "v": raw.get("v"), "device": raw.get("device"), "seq": raw.get("seq"), "prev": raw.get("prev"),
        "epoch": raw.get("epoch"), "hlc_max": raw.get("hlc_max", ""), "ct": raw.get("ct"),
    }
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


class Pairings:
    """内存里的配对会话：code → {pub_a, pub_b, sealed, expires, failures}。"""

    def __init__(self, clock=time.time):
        self.sessions: dict[str, dict] = {}
        self.attempts: dict[str, list[float]] = {}
        self.lock = threading.Lock()
        self.clock = clock

    def _gc(self):
        now = self.clock()
        for code in [c for c, s in self.sessions.items() if s["expires"] < now]:
            del self.sessions[code]
        for ip in list(self.attempts):
            self.attempts[ip] = [t for t in self.attempts[ip] if now - t < PAIR_TTL]
            if not self.attempts[ip]:
                del self.attempts[ip]

    def start(self, pub_a: str) -> dict:
        with self.lock:
            self._gc()
            code = "".join(secrets.choice("0123456789") for _ in range(8))
            while code in self.sessions:
                code = "".join(secrets.choice("0123456789") for _ in range(8))
            self.sessions[code] = {"pub_a": pub_a, "pub_b": None, "sealed": None, "expires": self.clock() + PAIR_TTL}
            return {"code": code, "expires_in": PAIR_TTL}

    def join(self, code: str, pub_b: str, ip: str):
        with self.lock:
            self._gc()
            tries = self.attempts.setdefault(ip, [])
            if len(tries) >= JOIN_ATTEMPTS_PER_IP:
                return "rate_limited", None
            tries.append(self.clock())
            session = self.sessions.get(code)
            if not session:
                return "not_found", None
            if session["pub_b"] and session["pub_b"] != pub_b:
                return "taken", None
            session["pub_b"] = pub_b
            return "ok", session["pub_a"]

    def status(self, code: str):
        with self.lock:
            self._gc()
            session = self.sessions.get(code)
            return None if session is None else {"pub_b": session["pub_b"]}

    def seal(self, code: str, sealed: str) -> str:
        with self.lock:
            self._gc()
            session = self.sessions.get(code)
            if not session:
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


def valid_pub(text) -> bool:
    if not isinstance(text, str) or not B64U.match(text) or len(text) != 87:
        return False
    raw = b64u_decode(text)
    return len(raw) == 65 and raw[0] == 4


def make_handler(store: Store, pairings: Pairings, token_sha256: str):
    class Handler(BaseHTTPRequestHandler):
        server_version = "riji-sync"
        sys_version = ""

        def log_message(self, fmt, *args):
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
            url = urlparse(self.path)
            query = {k: v[0] for k, v in parse_qs(url.query).items()}
            if url.path == "/health":
                return self.reply(200, {"ok": True, **store.stats()})
            if not self.authorized():
                return self.reply(401, {"error": "unauthorized"})
            if url.path == "/heads":
                return self.reply(200, {"devices": store.heads()})
            if url.path == "/segments":
                device = query.get("device", "")
                try:
                    start = max(1, int(query.get("from", "1")))
                    limit = min(500, max(1, int(query.get("limit", "200"))))
                except ValueError:
                    return self.reply(400, {"error": "invalid"})
                if not DEVICE_RE.match(device):
                    return self.reply(400, {"error": "invalid"})
                return self.reply(200, {"segments": store.fetch(device, start, limit)})
            if url.path == "/pair/status":
                status = pairings.status(query.get("code", ""))
                return self.reply(404, {"error": "not_found"}) if status is None else self.reply(200, status)
            return self.reply(404, {"error": "not_found"})

        def do_POST(self):
            path = urlparse(self.path).path
            try:
                payload = self.body()
            except (ValueError, TypeError):
                return self.reply(400, {"error": "invalid"})
            if not isinstance(payload, dict):
                return self.reply(400, {"error": "invalid"})
            # 加入配对与取信封：新设备还没有连接码
            if path == "/pair/join":
                code, pub = payload.get("code"), payload.get("pub")
                if not isinstance(code, str) or not re.fullmatch(r"\d{8}", code) or not valid_pub(pub):
                    return self.reply(400, {"error": "invalid"})
                result, pub_a = pairings.join(code, pub, self.ip())
                if result != "ok":
                    return self.reply(429 if result == "rate_limited" else 404 if result == "not_found" else 409, {"error": result})
                return self.reply(200, {"pub": pub_a})
            if path == "/pair/fetch":
                code, pub = payload.get("code"), payload.get("pub")
                if not isinstance(code, str) or not valid_pub(pub):
                    return self.reply(400, {"error": "invalid"})
                result, sealed = pairings.fetch(code, pub)
                if result == "ok":
                    return self.reply(200, {"sealed": sealed})
                return self.reply(202 if result == "waiting" else 404, {"error": result})
            if not self.authorized():
                return self.reply(401, {"error": "unauthorized"})
            if path == "/segments":
                segments = payload.get("segments")
                if not isinstance(segments, list) or not 1 <= len(segments) <= 100:
                    return self.reply(400, {"error": "invalid"})
                results = []
                for raw in segments:
                    try:
                        results.append(store.append(clean_segment(raw)))
                    except ValueError as error:
                        return self.reply(409 if str(error) in ("fork", "not_next") else 400,
                                          {"error": str(error), "stored": len(results), "heads": store.heads()})
                return self.reply(200, {"ok": True, "results": results})
            if path == "/pair/start":
                if not valid_pub(payload.get("pub")):
                    return self.reply(400, {"error": "invalid"})
                return self.reply(200, pairings.start(payload["pub"]))
            if path == "/pair/seal":
                code, sealed = payload.get("code"), payload.get("sealed")
                if not isinstance(code, str) or not isinstance(sealed, str) or not B64U.match(sealed) or len(sealed) > 8192:
                    return self.reply(400, {"error": "invalid"})
                result = pairings.seal(code, sealed)
                return self.reply(200 if result == "ok" else 409 if result == "not_joined" else 404, {"ok": result == "ok", "error": None if result == "ok" else result})
            return self.reply(404, {"error": "not_found"})

    return Handler


def main():
    env = os.environ
    store = Store(env.get("RIJI_SYNC_DB", "/var/lib/riji-sync/sync.sqlite3"))
    token = env.get("RIJI_REMINDER_TOKEN_SHA256", "").strip().lower()
    if not token:
        print("RIJI_REMINDER_TOKEN_SHA256 is not set; every authorised request will be refused", file=sys.stderr)
    address = (env.get("RIJI_SYNC_HOST", "127.0.0.1"), int(env.get("RIJI_SYNC_PORT", "8792")))
    print(f"riji-sync listening on {address[0]}:{address[1]}", flush=True)
    ThreadingHTTPServer(address, make_handler(store, Pairings(), token)).serve_forever()


if __name__ == "__main__":
    main()
