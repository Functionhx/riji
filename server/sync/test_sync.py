"""python3 -m unittest server/sync/test_sync.py —— 本机随机端口，临时 SQLite。"""

import base64
import hashlib
import json
import os
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(__file__))
import sync  # noqa: E402

TOKEN = "riji-test-token"
PUB_A = base64.urlsafe_b64encode(b"\x04" + b"\x01" * 64).decode().rstrip("=")
PUB_B = base64.urlsafe_b64encode(b"\x04" + b"\x02" * 64).decode().rstrip("=")


def segment(device, seq, prev, body=b"x"):
    ct = base64.urlsafe_b64encode(body * 40 + seq.to_bytes(2, "big")).decode().rstrip("=")
    return {"v": 1, "device": device, "seq": seq, "prev": prev, "epoch": 0, "hlc_max": "", "ct": ct}


def chain_hash(seg):
    return hashlib.sha256(sync.b64u_decode(seg["ct"])).hexdigest()


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class SyncServerTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.clock = Clock()
        self.pairings = sync.Pairings(clock=self.clock)
        handler = sync.make_handler(sync.Store(os.path.join(self.dir.name, "s.sqlite3")), self.pairings, hashlib.sha256(TOKEN.encode()).hexdigest())
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.dir.cleanup()

    def call(self, path, payload=None, token=TOKEN):
        data = None if payload is None else json.dumps(payload).encode()
        req = urllib.request.Request(self.base + path, data=data, headers={"Content-Type": "application/json"})
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(req, timeout=5) as res:
                return res.status, json.loads(res.read())
        except urllib.error.HTTPError as err:
            return err.code, json.loads(err.read())

    def test_segments_must_chain(self):
        s1 = segment("mac-1", 1, sync.GENESIS)
        s2 = segment("mac-1", 2, chain_hash(s1))
        self.assertEqual(self.call("/segments", {"segments": [s1, s2]})[0], 200)
        status, body = self.call("/heads")
        self.assertEqual(body["devices"]["mac-1"], {"seq": 2, "hash": chain_hash(s2)})
        # 重复推送无害
        self.assertEqual(self.call("/segments", {"segments": [s2]})[1]["results"], ["duplicate"])
        # 跳号、prev 不对、同序号不同内容都拒绝
        self.assertEqual(self.call("/segments", {"segments": [segment("mac-1", 4, chain_hash(s2))]})[0], 409)
        self.assertEqual(self.call("/segments", {"segments": [segment("mac-1", 3, sync.GENESIS)]})[0], 409)
        status, body = self.call("/segments", {"segments": [segment("mac-1", 2, chain_hash(s1), b"y")]})
        self.assertEqual((status, body["error"]), (409, "fork"))
        # 拉取
        _, body = self.call("/segments?device=mac-1&from=2")
        self.assertEqual([s["seq"] for s in body["segments"]], [2])
        self.assertEqual(body["segments"][0]["ct"], s2["ct"])

    def test_auth_and_validation(self):
        self.assertEqual(self.call("/heads", token=None)[0], 401)
        self.assertEqual(self.call("/segments", {"segments": [segment("mac-1", 1, sync.GENESIS)]}, token="wrong")[0], 401)
        bad = segment("Mac 1", 1, sync.GENESIS)
        self.assertEqual(self.call("/segments", {"segments": [bad]})[0], 400)
        self.assertEqual(self.call("/segments?device=../x")[0], 400)
        status, body = self.call("/health", token=None)
        self.assertEqual((status, body["segments"]), (200, 0))

    def test_pairing_round_trip(self):
        status, started = self.call("/pair/start", {"pub": PUB_A})
        self.assertEqual(status, 200)
        code = started["code"]
        self.assertRegex(code, r"^\d{8}$")
        # 发起配对需要连接码，加入不需要
        self.assertEqual(self.call("/pair/start", {"pub": PUB_A}, token=None)[0], 401)
        self.assertEqual(self.call("/pair/status?code=" + code)[1], {"pub_b": None})
        status, joined = self.call("/pair/join", {"code": code, "pub": PUB_B}, token=None)
        self.assertEqual((status, joined["pub"]), (200, PUB_A))
        self.assertEqual(self.call("/pair/status?code=" + code)[1], {"pub_b": PUB_B})
        # 还没封装信封：等待
        self.assertEqual(self.call("/pair/fetch", {"code": code, "pub": PUB_B}, token=None)[0], 202)
        self.assertEqual(self.call("/pair/seal", {"code": code, "sealed": "abc_DEF-123"})[0], 200)
        # 公钥不对取不到；对的取走后会话即删
        self.assertEqual(self.call("/pair/fetch", {"code": code, "pub": PUB_A}, token=None)[0], 404)
        status, body = self.call("/pair/fetch", {"code": code, "pub": PUB_B}, token=None)
        self.assertEqual((status, body["sealed"]), (200, "abc_DEF-123"))
        self.assertEqual(self.call("/pair/fetch", {"code": code, "pub": PUB_B}, token=None)[0], 404)

    def test_pairing_expires_and_is_rate_limited(self):
        code = self.call("/pair/start", {"pub": PUB_A})[1]["code"]
        # 另一把公钥不能抢已经加入的会话
        self.call("/pair/join", {"code": code, "pub": PUB_B}, token=None)
        self.assertEqual(self.call("/pair/join", {"code": code, "pub": PUB_A}, token=None)[0], 409)
        self.clock.now += sync.PAIR_TTL + 1
        self.assertEqual(self.call("/pair/join", {"code": code, "pub": PUB_B}, token=None)[0], 404)
        for _ in range(sync.JOIN_ATTEMPTS_PER_IP):
            self.call("/pair/join", {"code": "00000000", "pub": PUB_B}, token=None)
        self.assertEqual(self.call("/pair/join", {"code": "00000000", "pub": PUB_B}, token=None)[0], 429)
        self.assertEqual(self.call("/pair/join", {"code": "1234", "pub": "short"}, token=None)[0], 400)


if __name__ == "__main__":
    unittest.main()
