"""`percolate auth token` picks its lifetime from the issuer, and says when the token expires (REM-1326).

A token signed with the compose stack's published default secret is a local stack's: anyone can mint one, so a
short expiry protects nothing and only fails a reader halfway through a tutorial. It lasts eight hours. A token
signed with any other secret keeps the one-hour default, because that issuer may be a real deployment. `--ttl`
overrides both. The expiry goes to stderr, so `TOKEN=$(percolate auth token ...)` still captures the token alone.
"""
import base64
import json
import time
import unittest
from uuid import uuid4

from typer.testing import CliRunner

from percolate_core.core.cli import DEV_JWT_SECRET, app


def claims(token: str) -> dict:
    payload = token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))


class TokenLifetime(unittest.TestCase):
    def mint(self, *args: str, secret: str = DEV_JWT_SECRET):
        runner = CliRunner(mix_stderr=False) if "mix_stderr" in CliRunner.__init__.__code__.co_varnames else CliRunner()
        result = runner.invoke(app, ["token", "--sub", str(uuid4()), "--secret", secret, *args])
        self.assertEqual(result.exit_code, 0, result.output)
        token = result.stdout.strip()
        self.assertEqual(token.count("."), 2, f"stdout should be the token alone: {result.stdout!r}")
        return claims(token), result.stderr

    def lifetime(self, c: dict) -> int:
        return c["exp"] - c["iat"] if "iat" in c else c["exp"] - int(time.time())

    def test_a_local_stack_token_lasts_eight_hours(self):
        c, err = self.mint()
        self.assertAlmostEqual(self.lifetime(c), 8 * 3600, delta=5)
        self.assertIn("expires", err)

    def test_another_issuer_keeps_one_hour(self):
        c, err = self.mint(secret="a-deployment-secret-that-is-not-the-compose-default")
        self.assertAlmostEqual(self.lifetime(c), 3600, delta=5)
        self.assertIn("expires", err)

    def test_ttl_overrides_both(self):
        c, _ = self.mint("--ttl", "600")
        self.assertAlmostEqual(self.lifetime(c), 600, delta=5)


if __name__ == "__main__":
    unittest.main()
