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
