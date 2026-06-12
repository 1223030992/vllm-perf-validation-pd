#!/usr/bin/env python3

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "ops" / "proxy_readiness.py"


class Handler(BaseHTTPRequestHandler):
    post_codes = [200]
    post_count = 0
    post_delay = 0

    def log_message(self, *_args):
        return

    def do_GET(self):
        if self.path in {"/openapi.json", "/health", "/query"}:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b"{}")
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        if type(self).post_delay:
            time.sleep(type(self).post_delay)
        index = min(type(self).post_count, len(type(self).post_codes) - 1)
        code = type(self).post_codes[index]
        type(self).post_count += 1
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        try:
            self.wfile.write(b'{"ok": true}')
        except OSError:
            pass


def start_server(post_codes=None, post_delay=0):
    class TestHandler(Handler):
        pass

    TestHandler.post_codes = list(post_codes or [200])
    TestHandler.post_count = 0
    TestHandler.post_delay = post_delay
    server = ThreadingHTTPServer(("127.0.0.1", 0), TestHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def unused_port():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


class ProxyReadinessTest(unittest.TestCase):
    def cleanup_server(self, server):
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

    def run_case(self, proxy_port, prefill_port, decode_port, bootstrap_port, timeout=2):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            state = root / "state.json"
            log = root / "proxy.log"
            pid = root / "proxy.pid"
            log.write_text("proxy started\n", encoding="utf-8")
            pid.write_text(str(os.getpid()), encoding="utf-8")
            command = [
                sys.executable,
                str(SCRIPT),
                "--state", str(state),
                "--log", str(log),
                "--pid-file", str(pid),
                "--proxy-url", "http://127.0.0.1:{}".format(proxy_port),
                "--prefill-url", "http://127.0.0.1:{}".format(prefill_port),
                "--decode-url", "http://127.0.0.1:{}".format(decode_port),
                "--prefill-transfer-port", str(bootstrap_port),
                "--model-id", "/model/test",
                "--timeout", str(timeout),
                "--request-timeout", "1",
                "--interval", "0",
            ]
            result = subprocess.run(command, capture_output=True, text=True, timeout=10)
            return result, json.loads(state.read_text(encoding="utf-8"))

    def test_503_then_success(self):
        proxy = start_server([503, 200])
        prefill = start_server()
        decode = start_server()
        bootstrap = start_server()
        for server in (proxy, prefill, decode, bootstrap):
            self.cleanup_server(server)
        result, state = self.run_case(
            proxy.server_port, prefill.server_port, decode.server_port, bootstrap.server_port
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(state["pd"]["proxy"]["smoke"]["status"], "READY")

    def test_smoke_4xx_fails_immediately(self):
        proxy = start_server([400])
        prefill = start_server()
        decode = start_server()
        bootstrap = start_server()
        for server in (proxy, prefill, decode, bootstrap):
            self.cleanup_server(server)
        result, state = self.run_case(
            proxy.server_port, prefill.server_port, decode.server_port, bootstrap.server_port
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["failure"]["reason"], "proxy_smoke_http_error")

    def test_listener_failure_is_classified(self):
        prefill = start_server()
        decode = start_server()
        bootstrap = start_server()
        for server in (prefill, decode, bootstrap):
            self.cleanup_server(server)
        result, state = self.run_case(
            unused_port(), prefill.server_port, decode.server_port, bootstrap.server_port, timeout=0
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["failure"]["reason"], "proxy_listener_timeout")

    def test_bootstrap_failure_is_classified(self):
        proxy = start_server()
        prefill = start_server()
        decode = start_server()
        for server in (proxy, prefill, decode):
            self.cleanup_server(server)
        result, state = self.run_case(
            proxy.server_port, prefill.server_port, decode.server_port, unused_port(), timeout=0
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["failure"]["reason"], "prefill_bootstrap_unreachable")

    def test_smoke_5xx_is_classified(self):
        proxy = start_server([500])
        prefill = start_server()
        decode = start_server()
        bootstrap = start_server()
        for server in (proxy, prefill, decode, bootstrap):
            self.cleanup_server(server)
        result, state = self.run_case(
            proxy.server_port, prefill.server_port, decode.server_port, bootstrap.server_port, timeout=0
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["failure"]["reason"], "proxy_smoke_http_error")

    def test_smoke_timeout_is_classified(self):
        proxy = start_server([200], post_delay=2)
        prefill = start_server()
        decode = start_server()
        bootstrap = start_server()
        for server in (proxy, prefill, decode, bootstrap):
            self.cleanup_server(server)
        result, state = self.run_case(
            proxy.server_port, prefill.server_port, decode.server_port, bootstrap.server_port, timeout=0
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["failure"]["reason"], "proxy_smoke_timeout")


if __name__ == "__main__":
    unittest.main()
