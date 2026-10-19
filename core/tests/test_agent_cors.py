"""Browser integration gate B1: transport permission never replaces identity.

Run: python -m unittest discover -s tests -p test_agent_cors.py
No database or paid model. The live browser/persistence check is recorded in
p8-subsystems/specs/agentic/browser-ui.md. Candidate regressions also include
request field drift, SSE parsing, provider mismatch, port collision, stale
processes and UI secret leakage; this small test targets the security boundary.
"""

import os
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

from percolate_core.agentic.api import build_app
from percolate_core.agentic.settings import Settings


ORIGIN = "http://localhost:8083"


class BrowserTransportTest(unittest.TestCase):
    def client(self, origins=()):
        settings = Settings(cors_origins=origins)
        app = build_app(settings)
        # Do not enter the lifespan: these requests must not reach a database.
        app.state.percolate_agent_client = object()
        app.state.percolate_agent_settings = settings
        return TestClient(app)

    def preflight(self, client, origin=ORIGIN, path="/chat", method="POST"):
        return client.options(path, headers={
            "Origin": origin,
            "Access-Control-Request-Method": method,
            "Access-Control-Request-Headers": "authorization,content-type,x-p8-session-id",
        })

    def test_opt_in_and_explicit_origins(self):
        with patch.dict(os.environ, {"P8_CORS_ORIGINS": ""}):
            self.assertEqual(Settings().cors_origins, ())
        with patch.dict(os.environ, {"P8_CORS_ORIGINS": f" {ORIGIN}, https://ui.example "}):
            self.assertEqual(Settings().cors_origins, (ORIGIN, "https://ui.example"))
        for bad in ("*", "https://*.example", "null", "https://ui.example/path"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                Settings(cors_origins=(bad,))

    def test_default_and_unlisted_origins_have_no_permission(self):
        client = self.client()
        response = self.preflight(client)
        self.assertNotIn("access-control-allow-origin", response.headers)
        client.close()
        client = self.client((ORIGIN,))
        response = self.preflight(client, origin="https://untrusted.example")
        self.assertEqual(response.status_code, 400)
        self.assertNotIn("access-control-allow-origin", response.headers)
        response = self.preflight(client, method="DELETE")
        self.assertEqual(response.status_code, 400)
        client.close()

    def test_allowed_transport_still_requires_verified_bearer(self):
        client = self.client((ORIGIN,))
        for path, method in (("/chat", "POST"), ("/v1/chat/completions", "POST"),
                             ("/sessions/11111111-1111-1111-1111-111111111111/events", "GET")):
            with self.subTest(path=path):
                response = self.preflight(client, path=path, method=method)
                self.assertEqual(response.status_code, 200)
                self.assertEqual(response.headers["access-control-allow-origin"], ORIGIN)
                self.assertNotIn("access-control-allow-credentials", response.headers)
        with patch.dict(os.environ, {"P8_JWT_SECRET": "test-only-secret-not-a-production-key"}):
            response = client.post("/chat", headers={"Origin": ORIGIN}, json={
                "model": "percolate", "messages": [{"role": "user", "content": "hello"}],
                "stream": True,
            })
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.headers["access-control-allow-origin"], ORIGIN)
        self.assertIn("X-P8-Session-Id", response.headers["access-control-expose-headers"])
        client.close()


if __name__ == "__main__":
    unittest.main()
