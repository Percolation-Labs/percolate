"""A public page kept as evidence: the bytes that were served, or a refusal that says why (REM-239).

Run: python -m unittest discover -s tests -p test_evidence.py

The fetch runs against a real socket, for the reason test_api_probe.py gives:
the byte cap and the redirect re-check are properties of the request as it goes
out. The route runs with the database and storage replaced, because what it owes
is the order of its calls -- budget, then storage, then registration as the
caller -- and a refusal that stores nothing.
"""
import asyncio
import json
import os
import threading
import unittest
from contextlib import asynccontextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import AsyncMock, patch
from uuid import UUID

from fastapi.testclient import TestClient

from percolate_core.content import evidence
from percolate_core.content.evidence import EvidenceRefused, fetch
from percolate_core.content.server import build_app, caller

PAGE = b"<html><body><p>The study found no effect.</p></body></html>"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        port = self.server.server_address[1]
        if self.path == "/study":
            self.reply(200, PAGE, "text/html; charset=utf-8")
        elif self.path == "/moved":
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{port}/study")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif self.path == "/metadata":
            self.send_response(302)
            self.send_header("Location", "http://169.254.169.254/latest/meta-data/")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif self.path == "/big":
            self.reply(200, b"x" * 2048, "application/pdf")
        elif self.path == "/empty":
            self.reply(200, b"", "text/html")
        else:
            self.reply(404, b"no", "text/plain")

    def reply(self, status, body, media):
        self.send_response(status)
        self.send_header("Content-Type", media)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class FetchTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = "http://127.0.0.1:%d" % cls.server.server_address[1]
        # Loopback is refused by the egress guard, and a URL a caller typed gets
        # no operator allowlist (REM-555). So the guard is told about exactly
        # this origin, and every other URL, a redirect hop included, gets the
        # real check.
        from percolate_core.content import probe as probe_module
        from percolate_core.core.credentials import origin
        real = probe_module.refuse_internal_egress

        def guard(url, **kw):
            if origin(url) != origin(cls.base) or cls.refuse_all:
                real(url, **kw)
        cls.refuse_all = False
        cls.env = patch.object(probe_module, "refuse_internal_egress", guard)
        cls.env.start()

    @classmethod
    def tearDownClass(cls):
        cls.env.stop()
        cls.server.shutdown()
        cls.server.server_close()

    def test_the_bytes_served_come_back_with_their_media_type(self):
        body, media = asyncio.run(fetch(self.base + "/study#results"))
        self.assertEqual((body, media), (PAGE, "text/html"))

    def test_a_redirect_is_followed_and_rechecked(self):
        self.assertEqual(asyncio.run(fetch(self.base + "/moved"))[0], PAGE)
        with self.assertRaises(EvidenceRefused):
            asyncio.run(fetch(self.base + "/metadata"))

    def test_a_page_past_the_cap_is_refused_not_truncated(self):
        with patch.object(evidence, "MAX_BYTES", 1024), self.assertRaises(EvidenceRefused) as refused:
            asyncio.run(fetch(self.base + "/big"))
        self.assertIn("larger than", str(refused.exception))

    def test_an_error_or_an_empty_page_is_refused_with_its_reason(self):
        for path, words in (("/gone", "answered 404"), ("/empty", "empty")):
            with self.subTest(path=path), self.assertRaises(EvidenceRefused) as refused:
                asyncio.run(fetch(self.base + path))
            self.assertIn(words, str(refused.exception))

    def test_an_internal_address_is_refused_before_any_request(self):
        type(self).refuse_all = True
        self.addCleanup(setattr, type(self), "refuse_all", False)
        with self.assertRaises(EvidenceRefused):
            asyncio.run(fetch(self.base + "/study"))

    def test_an_operator_endpoint_is_not_a_page_a_caller_may_keep(self):
        # REM-555: LLM_URL is sanctioned for the worker, not for a caller's URL.
        type(self).refuse_all = True
        self.addCleanup(setattr, type(self), "refuse_all", False)
        with patch.dict(os.environ, {"LLM_URL": self.base, "P8_TEMPLATE_ENV": "X", "X": self.base}), \
             self.assertRaises(EvidenceRefused):
            asyncio.run(fetch(self.base + "/study"))


class RouteTest(unittest.TestCase):
    def client(self, conn):
        @asynccontextmanager
        async def scoped(_claims):
            yield conn
        application = build_app(())
        application.dependency_overrides[caller] = lambda: {"sub": "00000000-0000-4000-8000-000000000239"}
        self.patches = [patch("percolate_core.content.server.as_caller", scoped),
                        patch("percolate_core.content.server.storage.bucket", return_value="evidence-bucket")]
        for p in self.patches:
            p.start()
        self.addCleanup(lambda: [p.stop() for p in self.patches])
        return TestClient(application)

    def test_a_kept_page_is_stored_then_registered_as_the_caller(self):
        conn = AsyncMock()
        conn.fetchval.side_effect = [json.dumps({"status": "finite", "remaining": 10_000}),
                                     UUID("11111111-1111-1111-1111-111111111111")]
        with patch("percolate_core.content.evidence.fetch", AsyncMock(return_value=(PAGE, "text/html"))), \
             patch("percolate_core.content.server.storage.put", return_value=("sum", "objects/su/sum")) as put:
            with self.client(conn) as client:
                response = client.post("/evidence", json={"url": "https://example.com/study", "title": "The study"})
        self.assertEqual(response.status_code, 201, response.text)
        self.assertEqual(response.json()["resource_id"], "11111111-1111-1111-1111-111111111111")
        put.assert_called_once_with(PAGE, "text/html")
        self.assertEqual(conn.fetchval.call_args.args[1:],
                         ("https://example.com/study", "sum", "evidence-bucket", "objects/su/sum", len(PAGE),
                          "text/html", "The study"))

    def test_a_page_not_kept_says_why_and_stores_nothing(self):
        conn = AsyncMock()
        with patch("percolate_core.content.evidence.fetch",
                   AsyncMock(side_effect=EvidenceRefused("The page answered 404, so there was nothing to keep."))), \
             patch("percolate_core.content.server.storage.put") as put:
            with self.client(conn) as client:
                response = client.post("/evidence", json={"url": "https://example.com/gone"})
        self.assertEqual((response.status_code, response.json()["saved"]), (422, False))
        self.assertIn("404", response.json()["reason"])
        put.assert_not_called()
        conn.fetchval.assert_not_called()

    def test_a_spent_allowance_refuses_before_storing(self):
        conn = AsyncMock()
        conn.fetchval.return_value = json.dumps({"status": "exhausted", "remaining": 0})
        with patch("percolate_core.content.evidence.fetch", AsyncMock(return_value=(PAGE, "text/html"))), \
             patch("percolate_core.content.server.storage.put") as put:
            with self.client(conn) as client:
                response = client.post("/evidence", json={"url": "https://example.com/study"})
        self.assertEqual(response.status_code, 403)
        put.assert_not_called()

    def test_signed_out_and_malformed_requests_are_refused(self):
        with TestClient(build_app(())) as client:
            self.assertEqual(client.post("/evidence", json={"url": "https://example.com"}).status_code, 401)
        with self.client(AsyncMock()) as client:
            self.assertEqual(client.post("/evidence", json={"link": "https://example.com"}).status_code, 400)


if __name__ == "__main__":
    unittest.main()
