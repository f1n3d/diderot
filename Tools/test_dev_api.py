#!/usr/bin/env python3
"""Tests of Tools/dev_api.py against a stand-in server on this Mac, without a Docmost instance. Tools/check-project.sh
runs them: python3 Tools/test_dev_api.py"""
import contextlib
import http.server
import io
import json
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

import dev_api


def serve(answer):
    """A server on 127.0.0.1 that records each request as (path, JSON body, headers) and answers with
    `answer(path, body)`, a (status, headers, JSON) triple. Returns (its URL, the recorded requests)."""
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length) or b"{}")
            requests.append((self.path, body, dict(self.headers)))
            status, headers, payload = answer(self.path, body)
            data = json.dumps(payload).encode()
            self.send_response(status)
            for key, value in headers.items():
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        do_GET = do_POST

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_port}", requests


class StandInTestCase(unittest.TestCase):
    def serve(self, answer):
        server, url, requests = serve(answer)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return url, requests


class CheckedURLTests(unittest.TestCase):
    def test_plain_http_only_to_this_mac(self):
        for url in ("http://localhost:3000/", "http://127.0.0.1:3001", "http://[::1]:3000", "https://docs.example.com"):
            self.assertEqual(dev_api.checked_url(url), url.rstrip("/"))
        for url in ("http://my-mac.local:3000", "http://192.168.1.5:3000", "ftp://localhost", "localhost:3000"):
            with self.assertRaises(SystemExit, msg=url):
                dev_api.checked_url(url)


class RedirectTests(StandInTestCase):
    def test_the_token_doesnt_follow_a_redirect(self):
        target, reached = self.serve(lambda path, body: (200, {}, {"data": {}}))
        origin, _ = self.serve(lambda path, body: (302, {"Location": f"{target}/api/users/me"}, {}))
        with self.assertRaises(dev_api.ApiError) as raised:
            dev_api.Api(origin, token="the-token").call("users/me")
        self.assertEqual(raised.exception.status, 302)
        self.assertIn(target, str(raised.exception))
        self.assertEqual(reached, [])


class DevPasswordTests(StandInTestCase):
    """The dev users' passwords, with an admin of its own and the files the tools keep in a folder of its own."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        for name, file in (("REPLACED", "gone.json"), ("TOKENS", "dev-tokens.json"), ("LEGACY_TOKEN", "seed-token.txt")):
            self.patch(name, Path(folder.name) / file)
        self.patch("admin", lambda: ("admin@docmost.local", "the admin's password"))
        quiet = contextlib.redirect_stderr(io.StringIO())
        quiet.__enter__()
        self.addCleanup(quiet.__exit__, None, None, None)

    def patch(self, name, value):
        patcher = mock.patch.object(dev_api, name, value)
        patcher.start()
        self.addCleanup(patcher.stop)

    @staticmethod
    def docmost(password):
        """Answers as Docmost for one user whose password is `password`."""
        def answer(path, body):
            if path == "/api/auth/login":
                if body.get("password") == password:
                    return 200, {"Set-Cookie": "authToken=session-token; HttpOnly"}, {"data": {}}
                return 401, {}, {"message": "Email or password does not match"}
            if path == "/api/auth/change-password":
                return 200, {}, {"data": {}}
            return 404, {}, {}
        return answer

    def test_a_password_is_the_users_own_and_follows_from_the_admins(self):
        password = dev_api.dev_password("kollegin@docmost.local")
        self.assertEqual(dev_api.dev_password("Kollegin@docmost.local"), password)
        self.assertNotEqual(dev_api.dev_password("alex@docmost.local"), password)
        self.assertNotIn(password, dev_api.FIXED_PASSWORDS.values())
        self.assertEqual(len(password), 24)
        self.patch("admin", lambda: ("admin@docmost.local", "another admin's password"))
        self.assertNotEqual(dev_api.dev_password("kollegin@docmost.local"), password)

    def test_a_fixed_password_is_replaced_and_each_server_asked_once(self):
        url, requests = self.serve(self.docmost("kollegin-dev-123"))
        self.assertTrue(dev_api.replace_fixed_password("kollegin@docmost.local", url))
        changes = [body for path, body, _ in requests if path == "/api/auth/change-password"]
        self.assertEqual(changes, [{"oldPassword": "kollegin-dev-123", "newPassword": dev_api.dev_password("kollegin@docmost.local")}])
        self.assertEqual(dev_api.load_tokens(), {f"{url}|kollegin@docmost.local": "session-token"})

        asked = len(requests)
        self.assertFalse(dev_api.replace_fixed_password("kollegin@docmost.local", url))
        self.assertEqual(len(requests), asked)
        # Asked again for a user who doesn't take the password, as after the dev data was restored from before.
        self.assertTrue(dev_api.replace_fixed_password("kollegin@docmost.local", url, again=True))
        self.assertEqual(len(requests), asked + 2)

    def test_a_user_without_the_fixed_password_keeps_its_own(self):
        url, requests = self.serve(self.docmost("another-password"))
        self.assertFalse(dev_api.replace_fixed_password("alex@docmost.local", url))
        self.assertEqual([path for path, _, _ in requests], ["/api/auth/login"])
        self.assertEqual(dev_api.load_replaced(), {f"{url}|alex@docmost.local"})

    def test_other_users_are_left_without_asking_the_server(self):
        url, requests = self.serve(self.docmost("kollegin-dev-123"))
        self.assertFalse(dev_api.replace_fixed_password("someone@example.com", url))
        self.assertEqual(requests, [])


if __name__ == "__main__":
    unittest.main()
