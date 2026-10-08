"""python3 -m unittest server/reminder/test_reminder.py —— 不发真邮件（假的 Mailer），HTTP 走本机随机端口。"""

import hashlib
import json
import os
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(__file__))
import reminder  # noqa: E402

BJ = timezone(timedelta(hours=8))
TOKEN = "test-token-1234"


def at(hour, minute, day=8):
    return datetime(2026, 10, day, hour, minute, tzinfo=BJ)


class FakeMailer:
    configured = True

    def __init__(self, fail=0):
        self.sent = []
        self.fail = fail

    def send(self, recipients, subject, body):
        if self.fail:
            self.fail -= 1
            raise OSError("smtp down")
        self.sent.append((recipients, subject, body))


SETTINGS = {"email": True, "reminder": True, "recipients": ["a@qq.com", "b@163.com"], "minutes": 22 * 60 + 30, "delay": 60, "updated_at": 1}


class NudgeTests(unittest.TestCase):
    def test_wording_matches_the_apps(self):
        self.assertEqual(reminder.nudge({"has_summary": True, "plans": 1}), None)
        title, body = reminder.nudge({"has_summary": False, "plans": 0, "done": 1, "total": 2, "pending": 1})
        self.assertEqual(title, "今晚总结")
        self.assertIn("今天完成 1/2", body)
        self.assertIn("没做完的 1 件会自动延续", body)
        self.assertEqual(reminder.nudge({"has_summary": False, "plans": 2})[0], "今日总结还没写")
        self.assertEqual(reminder.nudge({"has_summary": True, "plans": 0})[0], "明天做什么？")
        self.assertEqual(reminder.nudge(None)[0], "今天还没打开日迹")

    def test_devices_are_merged(self):
        merged = reminder.merged_evening({
            "mac": {"has_summary": True, "plans": 0, "done": 1, "total": 3, "received_at": 1},
            "android": {"has_summary": False, "plans": 2, "done": 2, "total": 3, "received_at": 2},
        })
        self.assertTrue(merged["has_summary"])
        self.assertEqual(merged["plans"], 2)
        self.assertEqual(merged["done"], 2)


class TickTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.state = reminder.State(os.path.join(self.dir.name, "state.json"))
        self.state.data["settings"] = dict(SETTINGS)
        self.mailer = FakeMailer()
        self.log = []

    def tearDown(self):
        self.dir.cleanup()

    def tick(self, when):
        return reminder.tick(self.state, self.mailer, when, log=self.log.append)

    def test_waits_until_notification_plus_delay_then_sends_once(self):
        self.assertIsNone(self.tick(at(22, 45)))
        self.assertEqual(self.tick(at(23, 30)), "sent")
        recipients, subject, body = self.mailer.sent[0]
        self.assertEqual(recipients, ["a@qq.com", "b@163.com"])
        self.assertEqual(subject, "日迹 · 今天还没打开日迹")
        self.assertIn("22:30 的通知之后还空着", body)
        self.assertIsNone(self.tick(at(23, 45)))
        self.assertEqual(len(self.mailer.sent), 1)
        # 第二天重新开始
        self.assertEqual(self.tick(at(23, 31, day=9)), "sent")

    def test_complete_day_sends_nothing(self):
        self.state.data["days"]["2026-10-08"] = {"mac": {"has_summary": True, "plans": 1, "received_at": 1}}
        self.assertEqual(self.tick(at(23, 30)), "skipped")
        self.assertEqual(self.mailer.sent, [])

    def test_only_mentions_what_is_missing(self):
        self.state.data["days"]["2026-10-08"] = {"mac": {"has_summary": False, "plans": 2, "done": 3, "total": 4, "received_at": 1}}
        self.tick(at(23, 30))
        self.assertEqual(self.mailer.sent[0][1], "日迹 · 今日总结还没写")
        self.assertIn("今天完成 3/4", self.mailer.sent[0][2])

    def test_disabled_or_unconfigured_does_nothing(self):
        self.state.data["settings"]["email"] = False
        self.assertIsNone(self.tick(at(23, 30)))
        self.state.data["settings"]["email"] = True
        self.mailer.configured = False
        self.assertIsNone(self.tick(at(23, 30)))

    def test_late_reminders_are_capped_before_midnight(self):
        self.state.data["settings"].update(minutes=23 * 60 + 30, delay=120)
        self.assertIsNone(self.tick(at(23, 50)))
        self.assertEqual(self.tick(at(23, 55)), "sent")

    def test_smtp_errors_retry_three_times(self):
        self.mailer.fail = 5
        self.assertEqual(self.tick(at(23, 30)), "error")
        self.assertIsNone(self.tick(at(23, 31)))  # 五分钟内不重试
        self.assertEqual(self.tick(at(23, 36)), "error")
        self.assertEqual(self.tick(at(23, 42)), "error")
        self.assertIsNone(self.tick(at(23, 50)))  # 三次后放弃
        self.assertEqual(self.state.data["sent"]["2026-10-08"]["attempts"], 3)

    def test_state_survives_restart_and_old_days_are_pruned(self):
        self.state.data["days"]["2026-09-01"] = {"mac": {"has_summary": True, "plans": 1}}
        self.tick(at(23, 30))
        reopened = reminder.State(self.state.path)
        self.assertEqual(reopened.data["sent"]["2026-10-08"]["result"], "sent")
        self.assertNotIn("2026-09-01", reopened.data["days"])


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.state = reminder.State(os.path.join(self.dir.name, "state.json"))
        self.mailer = FakeMailer()
        self.now = at(21, 0)
        handler = reminder.make_handler(self.state, self.mailer, hashlib.sha256(TOKEN.encode()).hexdigest(), clock=lambda: self.now)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.dir.cleanup()

    def call(self, path, payload=None, token=TOKEN):
        data = None if payload is None else json.dumps(payload).encode()
        request = urllib.request.Request(self.base + path, data=data, headers={"Content-Type": "application/json"})
        if token:
            request.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read())

    def status(self, **overrides):
        payload = {"device": "mac-1234", "date": "2026-10-08",
                   "evening": {"has_summary": False, "plans": 1, "done": 2, "total": 3, "pending": 1}, "settings": dict(SETTINGS)}
        payload.update(overrides)
        return self.call("/status", payload)

    def test_health_is_public_and_reveals_no_addresses(self):
        status, body = self.call("/health", token=None)
        self.assertEqual(status, 200)
        self.assertNotIn("qq.com", json.dumps(body))

    def test_requires_the_token(self):
        self.assertEqual(self.call("/status", {"x": 1}, token="wrong")[0], 401)
        self.assertEqual(self.call("/status", {"x": 1}, token=None)[0], 401)

    def test_status_is_stored_and_newest_settings_win(self):
        status, body = self.status()
        self.assertEqual(status, 200)
        self.assertEqual(body["settings"]["recipients"], ["a@qq.com", "b@163.com"])
        self.assertEqual(self.state.data["days"]["2026-10-08"]["mac-1234"]["plans"], 1)
        # 旧设置（另一台设备没改过设置）不覆盖新的；返回的是服务器上最新的一份，设备可以照着更新
        old = dict(SETTINGS, recipients=["old@qq.com"], updated_at=0)
        _, body = self.status(device="android-5678", settings=old)
        self.assertEqual(body["settings"]["recipients"], ["a@qq.com", "b@163.com"])
        newer = dict(SETTINGS, recipients=["new@outlook.com"], updated_at=5)
        _, body = self.status(settings=newer)
        self.assertEqual(body["settings"]["recipients"], ["new@outlook.com"])

    def test_rejects_bad_input(self):
        self.assertEqual(self.status(settings=dict(SETTINGS, recipients=["x@qq.com\nBcc: y@z.com"]))[0], 400)
        self.assertEqual(self.status(settings=dict(SETTINGS, recipients=[f"u{i}@qq.com" for i in range(6)]))[0], 400)
        self.assertEqual(self.status(date="../etc")[0], 400)
        self.assertEqual(self.status(evening={"plans": -1})[0], 400)

    def test_unconfigured_smtp_does_not_use_up_test_mails(self):
        self.status()
        self.mailer.configured = False
        self.assertEqual(self.call("/test", {})[0], 503)
        self.assertEqual(self.state.data["tests"], {})

    def test_test_mail_and_its_daily_limit(self):
        self.status()
        status, body = self.call("/test", {})
        self.assertEqual((status, body["sent_to"]), (200, 2))
        self.assertIn("测试", self.mailer.sent[0][1])
        for _ in range(4):
            self.call("/test", {})
        self.assertEqual(self.call("/test", {})[0], 429)


if __name__ == "__main__":
    unittest.main()
