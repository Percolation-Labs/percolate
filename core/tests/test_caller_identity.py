"""The caller's verified claims reach the database whole, and before the role.

REM-48: the agent runtime verified a token, kept only its `sub`, and rebuilt
`{"sub": ...}` for the database -- so a token carrying `orgs: [A]` arrived with
no `orgs` claim, which `rbac.current_org_ids()` reads as every org the user
belongs to. REM-44: `authenticated` may no longer call `set_config`, so claims
have to be written while the connection is still its login role.

No database: the pool is a recorder of the statements a transaction runs,
installed with `identity.set_pool`. What these prove is what reaches the
connection; that RLS then narrows on `orgs` is the database's half and is
tested there (p8-subsystems dev/tests).
"""
import base64
import json
import time
import unittest
from contextlib import asynccontextmanager
from unittest.mock import patch
from uuid import uuid4

from fastapi import FastAPI
from fastapi.testclient import TestClient

from percolate_core.agentic.api import router
from percolate_core.agentic.db import PgClient, PgRepository
from percolate_core.agentic.gateway import caller_claims, run_delegated, run_scheduled
from percolate_core.agentic.settings import Settings
from percolate_core.core import identity
from percolate_core.core.identity import mint_jwt

SECRET = "test-only-secret-not-a-production-key"
ALICE = "11111111-1111-1111-1111-111111111111"
ORG_A = "aaaaaaaa-0000-0000-0000-00000000000a"
SET_CLAIMS = "select set_config('request.jwt.claims', $1, "


class RecordingConn:
    def __init__(self):
        self.statements = []

    async def execute(self, sql, *args):
        self.statements.append((sql, args))

    async def fetch(self, sql, *args):
        self.statements.append((sql, args))
        return []

    def transaction(self):
        @asynccontextmanager
        async def tx():
            yield
        return tx()


class RecordingPool:
    def __init__(self):
        self.conn = RecordingConn()

    def acquire(self):
        @asynccontextmanager
        async def held():
            yield self.conn
        return held()


def token(secret=SECRET, **extra):
    return mint_jwt(ALICE, secret, extra={"orgs": [ORG_A], **extra})


def bearer(value):
    return {"Authorization": "Bearer " + value}


class Stop(Exception):
    """Raised by a stand-in once it has seen what it was checking for."""


class ClaimsReachTheConnectionTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.pool = RecordingPool()
        identity.set_pool(self.pool)
        self.addCleanup(identity.set_pool, None)
        env = patch.dict("os.environ", {"P8_JWT_SECRET": SECRET})
        env.start()
        self.addCleanup(env.stop)

    def assert_claims_then_role(self, claims, role_statement):
        (first, args), (second, _) = self.pool.conn.statements[:2]
        self.assertTrue(first.startswith(SET_CLAIMS), first)
        self.assertEqual(json.loads(args[0]), claims)
        self.assertEqual(second, role_statement)

    async def test_as_caller_sets_claims_before_switching_role(self):
        claims = {"sub": ALICE, "orgs": [ORG_A]}
        async with identity.as_caller(claims):
            pass
        self.assert_claims_then_role(claims, f"set local role {identity.ROLE}")

    async def test_repository_sets_the_verified_claims_not_a_rebuilt_sub(self):
        verified = caller_claims(bearer(token()))
        self.assertEqual(verified["orgs"], [ORG_A])
        await PgRepository(PgClient(Settings()), verified).list_agents()
        # The whole payload -- orgs, role, iat, exp -- exactly as verified.
        self.assert_claims_then_role(verified, f"set local role {identity.ROLE}")

    async def test_publisher_sets_the_same_claims_before_its_session_role(self):
        verified = caller_claims(bearer(token()))
        client = PgClient(Settings())
        client._pool = self.pool
        async with client.publisher(verified) as publish:
            await publish("agui_x", "{}")
        (first, args), (second, _) = self.pool.conn.statements[:2]
        self.assertEqual(first, SET_CLAIMS + "false)")
        self.assertEqual(json.loads(args[0]), verified)
        self.assertEqual(second, f"set role {identity.ROLE}")

    async def test_a_user_id_where_claims_belong_is_refused(self):
        with self.assertRaises(TypeError):
            async with PgClient(Settings()).as_user(uuid4()):
                pass

    async def test_gateway_hands_the_verified_claims_to_the_db_layer(self):
        seen = []

        @asynccontextmanager
        async def connected(settings, claims):
            seen.append(claims)
            raise Stop
            yield

        signed = token()
        verified = caller_claims(bearer(signed))
        with patch("percolate_core.agentic.gateway.connected", connected):
            with self.assertRaises(Stop):
                await run_delegated(Settings(), agent_name="brief", prompt="x",
                                    headers=bearer(signed))
            with self.assertRaises(Stop):
                await run_scheduled(Settings(), task_id=uuid4(), agent_name="brief",
                                    session_id=None, prompt="x", headers=bearer(signed))
        self.assertEqual(seen, [verified, verified])
        self.assertEqual(seen[0]["orgs"], [ORG_A])


class RuntimeHttpIdentityTest(unittest.TestCase):
    """The HTTP surface: what reaches the repository, and what is refused."""

    def setUp(self):
        env = patch.dict("os.environ", {"P8_JWT_SECRET": SECRET})
        env.start()
        self.addCleanup(env.stop)
        self.seen = []
        test = self

        class Repository:
            def __init__(self, client, claims):
                test.seen.append(claims)

            async def session_messages(self, session_id):
                return None  # the endpoint's 404, reached only past identity

        patcher = patch("percolate_core.agentic.api.PgRepository", Repository)
        patcher.start()
        self.addCleanup(patcher.stop)
        app = FastAPI()
        app.include_router(router())
        app.state.percolate_agent_client = object()
        app.state.percolate_agent_settings = Settings()
        self.client = TestClient(app)
        self.addCleanup(self.client.close)

    def events(self, headers):
        return self.client.get(f"/sessions/{uuid4()}/events", headers=headers)

    def test_a_token_narrowed_to_one_org_stays_narrowed(self):
        self.assertEqual(self.events(bearer(token())).status_code, 404)
        self.assertEqual(self.seen[0]["orgs"], [ORG_A])
        self.assertEqual(self.seen[0]["sub"], ALICE)

    def test_bad_expired_or_foreign_tokens_get_no_identity(self):
        now = int(time.time())
        unsigned = ".".join(
            base64.urlsafe_b64encode(json.dumps(part).encode()).rstrip(b"=").decode()
            for part in ({"alg": "none", "typ": "JWT"}, {"sub": ALICE, "orgs": [ORG_A]})
        ) + "."
        cases = {
            "expired": token(exp=now - 3600),
            "not yet valid": token(nbf=now + 3600),
            "signed with another secret": token(secret="some-other-secret"),
            "alg none": unsigned,
            "no sub": mint_jwt("", SECRET),
            "sub is not a user id": mint_jwt("alice", SECRET),
            "garbage": "not.a.token",
        }
        for label, value in cases.items():
            with self.subTest(label):
                self.assertIsNone(caller_claims(bearer(value)))
                self.assertEqual(self.events(bearer(value)).status_code, 401)
        self.assertEqual(self.seen, [])

    def test_the_user_id_header_is_ignored_when_a_secret_is_set(self):
        self.assertIsNone(caller_claims({"X-P8-User-Id": ALICE}))
        self.assertEqual(self.events({"X-P8-User-Id": ALICE}).status_code, 401)

    def test_without_a_secret_the_dev_loop_names_only_a_sub(self):
        with patch.dict("os.environ", {}, clear=True):
            self.assertEqual(caller_claims({"X-P8-User-Id": ALICE}), {"sub": ALICE})
            self.assertIsNone(caller_claims({"X-P8-User-Id": "not-a-uuid"}))
            self.assertIsNone(caller_claims(bearer(token())))


if __name__ == "__main__":
    unittest.main()
