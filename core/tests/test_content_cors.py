"""Content browser transport must preserve upload authentication."""
import os
import unittest
from unittest.mock import AsyncMock, patch
from contextlib import asynccontextmanager
from urllib.parse import quote
from uuid import UUID
from fastapi.testclient import TestClient
from percolate_core.content.server import build_app, caller

ORIGIN = "http://localhost:8083"

class ContentCorsTest(unittest.TestCase):
    def test_explicit_origins_only(self):
        for bad in ("*", "null", "https://ui.example/path", "https://*.example", "https://user@ui.example"):
            with self.subTest(origin=bad), self.assertRaises(ValueError):
                build_app((bad,))
        for origins, origin, permitted in (((),ORIGIN,False), ((ORIGIN,),ORIGIN,True), ((ORIGIN,),"https://untrusted.example",False)):
            with TestClient(build_app(origins)) as client:
                response = client.options("/files", headers={"Origin":origin,
                    "Access-Control-Request-Method":"POST",
                    "Access-Control-Request-Headers":"authorization,content-type,x-p8-title-utf8,x-p8-channel"})
                self.assertEqual(response.headers.get("access-control-allow-origin") == origin, permitted)
                self.assertNotIn("access-control-allow-credentials", response.headers)

    def test_invalid_token_cannot_write_bytes(self):
        with patch.dict(os.environ,{"P8_JWT_SECRET":"public-test-secret-not-a-real-signing-key"}), patch("percolate_core.content.server.storage.put") as put:
            with TestClient(build_app((ORIGIN,))) as client:
                response = client.post("/files", headers={"Origin":ORIGIN,"Authorization":"Bearer invalid"}, content=b"test")
                self.assertEqual(response.status_code,401)
                self.assertEqual(response.headers["access-control-allow-origin"],ORIGIN)
                put.assert_not_called()
                response = client.post("/files", headers={"Origin":ORIGIN}, content=b"test")
                self.assertEqual(response.status_code,401)
                put.assert_not_called()

    def test_unicode_title_round_trips_at_registration(self):
        title = "café — handover.md"
        conn = AsyncMock()
        conn.fetchval.return_value = UUID("11111111-1111-1111-1111-111111111111")
        @asynccontextmanager
        async def scoped(_claims):
            yield conn
        application = build_app(())
        application.dependency_overrides[caller] = lambda: {"sub":"test-user"}
        with patch("percolate_core.content.server.as_caller", scoped), patch("percolate_core.content.server.storage.put", return_value=("checksum","object-key")), patch("percolate_core.content.server.storage.bucket", return_value="test-bucket"):
            with TestClient(application) as client:
                response = client.post("/files", content=b"note", headers={"X-P8-Title-Utf8":quote(title)})
                self.assertEqual(response.status_code,201)
                self.assertEqual(conn.fetchval.call_args.args[7],title)


class UploadIsAuthorizedBeforeItIsStored(unittest.TestCase):
    """REM-566: /files wrote to object storage before the database said yes,
    and took a body of any size."""

    def post(self, body, *, register=None, env=None, headers=None, put_fails=False):
        events = []
        conn = AsyncMock()

        async def fetchval(*args):
            events.append("register")
            if isinstance(register, Exception):
                raise register
            return UUID("11111111-1111-1111-1111-111111111111")
        conn.fetchval.side_effect = fetchval

        @asynccontextmanager
        async def scoped(_claims):
            events.append("begin")
            try:
                yield conn
            except BaseException:
                events.append("rollback")
                raise
            events.append("commit")

        def put(data, content_type=None):
            events.append("put")
            if put_fails:
                raise ConnectionError("storage is down")
            return ("checksum", "object-key")

        application = build_app(())
        application.dependency_overrides[caller] = lambda: {"sub": "test-user"}
        with patch("percolate_core.content.server.as_caller", scoped), \
             patch("percolate_core.content.server.storage.put", side_effect=put), \
             patch("percolate_core.content.server.storage.bucket", return_value="test-bucket"), \
             patch.dict(os.environ, env or {}):
            with TestClient(application, raise_server_exceptions=False) as client:
                response = client.post("/files", content=body, headers=headers or {})
        return response, events

    def test_the_object_is_written_after_the_database_accepts_it(self):
        response, events = self.post(b"note")
        self.assertEqual(response.status_code, 201, response.text)
        self.assertEqual(events, ["begin", "register", "put", "commit"])

    def test_a_refused_upload_writes_nothing(self):
        import asyncpg
        refused = asyncpg.PostgresError.new(
            {"C": "42501", "M": "not authorized to upload content", "H": "needs resources:create"})
        response, events = self.post(b"note", register=refused)
        self.assertEqual(response.status_code, 403, response.text)
        self.assertNotIn("put", events)

    def test_a_failed_write_rolls_the_registration_back(self):
        response, events = self.post(b"note", put_fails=True)
        self.assertEqual(response.status_code, 500)
        self.assertEqual(events, ["begin", "register", "put", "rollback"])

    def test_a_body_past_the_cap_is_413_and_nothing_happens(self):
        response, events = self.post(b"x" * 11, env={"P8_UPLOAD_MAX_BYTES": "10"})
        self.assertEqual(response.status_code, 413, response.text)
        self.assertEqual(events, [])
        response, events = self.post(b"x" * 10, env={"P8_UPLOAD_MAX_BYTES": "10"})
        self.assertEqual(response.status_code, 201, response.text)

    def test_a_chunked_body_is_counted_as_it_arrives(self):
        def chunks():
            for _ in range(4):
                yield b"x" * 5
        response, events = self.post(chunks(), env={"P8_UPLOAD_MAX_BYTES": "10"})
        self.assertEqual(response.status_code, 413, response.text)
        self.assertEqual(events, [])
