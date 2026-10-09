"""python3 -m unittest server/riji-server/test_riji_server.py —— 假的发信器、本机随机端口、临时 SQLite。"""

import base64
import hashlib
import json
import os
import sqlite3
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(__file__))
import riji_server as rs  # noqa: E402

BJ = timezone(timedelta(hours=8))
ADMIN = "riji-admin-token"
PUB_A = base64.urlsafe_b64encode(b"\x04" + b"\x01" * 64).decode().rstrip("=")
PUB_B = base64.urlsafe_b64encode(b"\x04" + b"\x02" * 64).decode().rstrip("=")
SETTINGS = {"email": True, "reminder": True, "recipients": ["a@qq.com", "b@163.com"], "minutes": 22 * 60 + 30, "delay": 60, "updated_at": 1}


def at(hour, minute, day=8):
    return datetime(2026, 10, day, hour, minute, tzinfo=BJ)


def segment(device, seq, prev, body=b"x"):
    ct = base64.urlsafe_b64encode(body * 40 + seq.to_bytes(2, "big")).decode().rstrip("=")
    return {"v": 1, "device": device, "seq": seq, "prev": prev, "epoch": 0, "hlc_max": "", "ct": ct}


def chain_hash(seg):
    return hashlib.sha256(rs.b64u_decode(seg["ct"])).hexdigest()


class FakeMailer:
    configured = True

    def __init__(self, fail=0):
        self.sent, self.fail = [], fail

    def send(self, recipients, subject, body):
        if self.fail:
            self.fail -= 1
            raise OSError("smtp down")
        self.sent.append((recipients, subject, body))


class Clock:
    def __init__(self, now=1000.0):
        self.now = now

    def __call__(self):
        return self.now


# ---------------------------------------------------------------- 提醒规则（与旧 riji-reminder 相同，按空间）


class ReminderRules(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = rs.Store(os.path.join(self.dir.name, "r.sqlite3"))
        self.store.ensure_admin(hashlib.sha256(ADMIN.encode()).hexdigest())
        self.store.put_settings("owner", dict(SETTINGS))
        self.mailer = FakeMailer()

    def tearDown(self):
        self.dir.cleanup()

    def tick(self, when):
        return rs.tick(self.store, self.mailer, when, log=lambda _: None).get("owner")

    def test_wording(self):
        self.assertIsNone(rs.nudge({"has_summary": True, "plans": 1}))
        title, body = rs.nudge({"has_summary": False, "plans": 0, "done": 1, "total": 2, "pending": 1})
        self.assertEqual(title, "今晚总结")
        self.assertIn("今天完成 1/2", body)
        self.assertEqual(rs.nudge({"has_summary": False, "plans": 2})[0], "今日总结还没写")
        self.assertEqual(rs.nudge({"has_summary": True, "plans": 0})[0], "明天做什么？")
        self.assertEqual(rs.nudge(None)[0], "今天还没打开日迹")

    def test_waits_for_reminder_plus_delay_then_sends_once(self):
        self.assertIsNone(self.tick(at(22, 45)))
        self.assertEqual(self.tick(at(23, 30)), "sent")
        self.assertEqual(self.mailer.sent[0][1], "日迹 · 今天还没打开日迹")
        self.assertIsNone(self.tick(at(23, 45)))
        self.assertEqual(self.tick(at(23, 31, day=9)), "sent")

    def test_complete_day_and_missing_parts(self):
        self.store.put_day("owner", "2026-10-08", "mac", {"has_summary": True, "plans": 1, "received_at": 1})
        self.assertEqual(self.tick(at(23, 30)), "skipped")
        self.store.put_day("owner", "2026-10-09", "mac", {"has_summary": False, "plans": 2, "done": 3, "total": 4, "received_at": 1})
        self.tick(at(23, 30, day=9))
        self.assertEqual(self.mailer.sent[0][1], "日迹 · 今日总结还没写")

    def test_day_boundary_and_retries(self):
        self.store.put_settings("owner", dict(SETTINGS, minutes=23 * 60 + 30, day_start=240))
        self.assertIsNone(self.tick(at(23, 59)))
        self.mailer.fail = 5
        self.assertEqual(self.tick(at(0, 30, day=9)), "error")
        self.assertIsNone(self.tick(at(0, 31, day=9)))
        self.assertEqual(self.tick(at(0, 36, day=9)), "error")
        self.assertEqual(self.tick(at(0, 42, day=9)), "error")
        self.assertIsNone(self.tick(at(0, 50, day=9)))
        self.assertEqual(self.store.sent("owner", "2026-10-08")["attempts"], 3)

    def test_each_space_has_its_own_schedule(self):
        friend = self.store.redeem_invite(self.store.create_invite("owner", 0), 1)
        friend_space = self.store.space_for(friend)[0]
        self.store.put_settings(friend_space, dict(SETTINGS, recipients=["f@outlook.com"], minutes=21 * 60, delay=30))
        results = rs.tick(self.store, self.mailer, at(21, 40), log=lambda _: None)
        self.assertEqual(results, {"owner": None, friend_space: "sent"})
        self.assertEqual(self.mailer.sent[0][0], ["f@outlook.com"])


# ---------------------------------------------------------------- HTTP：空间、邀请、同步、配对、提醒


class Server(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = rs.Store(os.path.join(self.dir.name, "s.sqlite3"))
        self.store.ensure_admin(hashlib.sha256(ADMIN.encode()).hexdigest())
        self.mailer = FakeMailer()
        self.clock = Clock()
        self.pairings = rs.Pairings(clock=self.clock)
        self.throttle = rs.Throttle(clock=self.clock)
        handler = rs.make_handler(self.store, self.mailer, self.pairings, self.throttle, clock=lambda: at(21, 0))
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.dir.cleanup()

    def call(self, method, path, payload=None, token=ADMIN):
        data = None if payload is None else json.dumps(payload).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method, headers={"Content-Type": "application/json"})
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(req, timeout=5) as res:
                return res.status, json.loads(res.read())
        except urllib.error.HTTPError as err:
            return err.code, json.loads(err.read())

    def friend(self):
        invite = self.call("POST", "/api/invites", {})[1]["invite"]
        return self.call("POST", "/api/spaces", {"invite": invite}, token=None)[1]["token"]

    def test_invites_create_isolated_spaces(self):
        status, body = self.call("POST", "/api/invites", {})
        self.assertEqual(status, 200)
        invite = body["invite"]
        self.assertRegex(invite, r"^[A-Z2-9]{10}$")
        # 小写、带空格或连字符也认
        status, body = self.call("POST", "/api/spaces", {"invite": invite[:5].lower() + "-" + invite[5:]}, token=None)
        self.assertEqual(status, 200)
        friend = body["token"]
        # 一次性
        self.assertEqual(self.call("POST", "/api/spaces", {"invite": invite}, token=None)[0], 404)
        # 朋友不是站长：不能发邀请
        self.assertEqual(self.call("POST", "/api/invites", {}, token=friend)[0], 403)
        self.assertEqual(self.call("GET", "/api/spaces/me", token=friend)[1]["admin"], False)
        self.assertEqual(self.call("GET", "/api/spaces/me")[1]["admin"], True)

    def test_invites_expire(self):
        code = self.store.create_invite("owner", 1000)
        self.assertIsNone(self.store.redeem_invite(code, 1000 + rs.INVITE_TTL + 1))

    def test_segments_are_per_space(self):
        friend = self.friend()
        s1 = segment("mac-1", 1, rs.GENESIS)
        self.assertEqual(self.call("POST", "/sync/segments", {"segments": [s1]})[0], 200)
        # 朋友的空间看不见站长的段，同名设备也是各自的链
        self.assertEqual(self.call("GET", "/sync/heads", token=friend)[1]["devices"], {})
        f1 = segment("mac-1", 1, rs.GENESIS, b"f")
        self.assertEqual(self.call("POST", "/sync/segments", {"segments": [f1]}, token=friend)[0], 200)
        self.assertEqual(self.call("GET", "/sync/heads")[1]["devices"]["mac-1"]["hash"], chain_hash(s1))
        self.assertEqual(self.call("GET", "/sync/heads", token=friend)[1]["devices"]["mac-1"]["hash"], chain_hash(f1))
        self.assertEqual(self.call("GET", "/sync/segments?device=mac-1&from=1", token=friend)[1]["segments"][0]["ct"], f1["ct"])

    def test_chain_rules(self):
        s1 = segment("mac-1", 1, rs.GENESIS)
        s2 = segment("mac-1", 2, chain_hash(s1))
        self.assertEqual(self.call("POST", "/sync/segments", {"segments": [s1, s2]})[0], 200)
        self.assertEqual(self.call("POST", "/sync/segments", {"segments": [s2]})[1]["results"], ["duplicate"])
        self.assertEqual(self.call("POST", "/sync/segments", {"segments": [segment("mac-1", 4, chain_hash(s2))]})[0], 409)
        self.assertEqual(self.call("POST", "/sync/segments", {"segments": [segment("mac-1", 2, chain_hash(s1), b"y")]})[1]["error"], "fork")
        self.assertEqual(self.call("POST", "/sync/segments", {"segments": [segment("Mac 1", 1, rs.GENESIS)]})[0], 400)

    def test_quota(self):
        old = rs.SPACE_QUOTA
        rs.SPACE_QUOTA = 500
        try:
            self.assertEqual(self.call("POST", "/sync/segments", {"segments": [segment("mac-1", 1, rs.GENESIS, b"q" * 20)]})[0], 413)
        finally:
            rs.SPACE_QUOTA = old

    def test_delete_my_space(self):
        friend = self.friend()
        self.call("POST", "/sync/segments", {"segments": [segment("android-1", 1, rs.GENESIS)]}, token=friend)
        self.call("POST", "/api/status", {"device": "android-1", "date": "2026-10-08", "evening": {"plans": 1}, "settings": dict(SETTINGS, recipients=["f@qq.com"])}, token=friend)
        self.assertEqual(self.call("DELETE", "/api/spaces/me", token=friend)[0], 200)
        # 连接码失效，数据全删
        self.assertEqual(self.call("GET", "/sync/heads", token=friend)[0], 401)
        self.assertEqual(self.store.q("SELECT COUNT(*) FROM segments")[0][0], 0)
        self.assertEqual(self.store.q("SELECT COUNT(*) FROM reminder_settings")[0][0], 0)
        # 站长空间不能删
        self.assertEqual(self.call("DELETE", "/api/spaces/me")[0], 403)

    def test_auth_and_public_health(self):
        self.assertEqual(self.call("GET", "/sync/heads", token=None)[0], 401)
        self.assertEqual(self.call("GET", "/sync/heads", token="wrong")[0], 401)
        status, body = self.call("GET", "/api/health", token=None)
        self.assertEqual((status, set(body)), (200, {"ok", "smtp"}))  # 不透露有几个空间

    def test_pairing_is_scoped_to_the_space(self):
        friend = self.friend()
        code = self.call("POST", "/sync/pair/start", {"pub": PUB_A})[1]["code"]
        self.assertEqual(self.call("POST", "/sync/pair/join", {"code": code, "pub": PUB_B}, token=None)[1]["pub"], PUB_A)
        # 别的空间看不到、也封不了这个会话
        self.assertEqual(self.call("GET", f"/sync/pair/status?code={code}", token=friend)[0], 404)
        self.assertEqual(self.call("POST", "/sync/pair/seal", {"code": code, "sealed": "abc"}, token=friend)[0], 404)
        self.assertEqual(self.call("GET", f"/sync/pair/status?code={code}")[1], {"pub_b": PUB_B})
        self.assertEqual(self.call("POST", "/sync/pair/fetch", {"code": code, "pub": PUB_B}, token=None)[0], 202)
        self.assertEqual(self.call("POST", "/sync/pair/seal", {"code": code, "sealed": "abc_DEF"})[0], 200)
        self.assertEqual(self.call("POST", "/sync/pair/fetch", {"code": code, "pub": PUB_B}, token=None)[1]["sealed"], "abc_DEF")
        self.assertEqual(self.call("POST", "/sync/pair/fetch", {"code": code, "pub": PUB_B}, token=None)[0], 404)

    def test_unauthenticated_entries_are_throttled(self):
        for _ in range(rs.ATTEMPTS_PER_IP):
            self.call("POST", "/api/spaces", {"invite": "AAAAAAAAAA"}, token=None)
        self.assertEqual(self.call("POST", "/api/spaces", {"invite": "AAAAAAAAAA"}, token=None)[0], 429)
        self.assertEqual(self.call("POST", "/sync/pair/join", {"code": "12345678", "pub": PUB_B}, token=None)[0], 429)
        self.clock.now += 601
        self.assertEqual(self.call("POST", "/api/spaces", {"invite": "AAAAAAAAAA"}, token=None)[0], 404)

    def test_status_and_test_mail_per_space(self):
        friend = self.friend()
        payload = {"device": "mac-1", "date": "2026-10-08", "evening": {"has_summary": False, "plans": 1, "done": 2, "total": 3, "pending": 1}, "settings": dict(SETTINGS)}
        self.assertEqual(self.call("POST", "/api/status", payload)[1]["settings"]["recipients"], SETTINGS["recipients"])
        friend_settings = dict(SETTINGS, recipients=["f@outlook.com"], updated_at=9)
        self.assertEqual(self.call("POST", "/api/status", dict(payload, settings=friend_settings), token=friend)[1]["settings"]["recipients"], ["f@outlook.com"])
        # 站长的设置没被朋友覆盖
        self.assertEqual(self.store.settings("owner")["recipients"], SETTINGS["recipients"])
        self.assertEqual(self.call("POST", "/api/test", {}, token=friend)[1]["sent_to"], 1)
        self.assertEqual(self.mailer.sent[-1][0], ["f@outlook.com"])
        self.assertEqual(self.call("POST", "/api/status", dict(payload, settings=dict(SETTINGS, recipients=["x@qq.com\nBcc: y@z.com"])))[0], 400)


# ---------------------------------------------------------------- 迁移


class Migration(unittest.TestCase):
    def test_old_data_moves_into_the_owner_space(self):
        with tempfile.TemporaryDirectory() as folder:
            state = os.path.join(folder, "state.json")
            with open(state, "w") as handle:
                json.dump({"settings": dict(SETTINGS), "days": {"2026-10-08": {"mac": {"plans": 1}}}, "sent": {"2026-10-07": {"result": "sent"}}, "tests": {}}, handle)
            old = sqlite3.connect(os.path.join(folder, "sync.sqlite3"))
            old.execute("CREATE TABLE segments (device TEXT, seq INTEGER, prev TEXT, hash TEXT, body TEXT, size INTEGER, received_at REAL)")
            s1 = segment("mac-1", 1, rs.GENESIS)
            old.execute("INSERT INTO segments VALUES (?, ?, ?, ?, ?, ?, ?)", ("mac-1", 1, rs.GENESIS, chain_hash(s1), json.dumps(s1), 10, 1.0))
            old.commit()
            store = rs.Store(os.path.join(folder, "new.sqlite3"))
            store.ensure_admin(hashlib.sha256(ADMIN.encode()).hexdigest())
            done = rs.migrate(store, state, os.path.join(folder, "sync.sqlite3"))
            self.assertEqual(done, {"settings": 1, "days": 1, "sent": 1, "segments": 1})
            self.assertEqual(store.heads("owner")["mac-1"]["seq"], 1)
            self.assertEqual(store.settings("owner")["recipients"], SETTINGS["recipients"])
            self.assertEqual(store.space_for(ADMIN), ("owner", True))


if __name__ == "__main__":
    unittest.main()
