"""A queued agent step carries its run owner's identity to one runtime only."""
import json
import tempfile
import unittest
from contextlib import asynccontextmanager
from pathlib import Path
from unittest.mock import AsyncMock, patch
from uuid import uuid4

import httpx
import asyncpg

from percolate_core.core.identity import claims_from_jwt
from percolate_core.core.config import ConfigError
from percolate_core.worker.agent_auth import AGENT_URL, agent_authorization
from percolate_core.worker.http import build_request, http_call
from percolate_core.worker.loop import run_once
from percolate_core.worker.templates import TerminalError

ALICE = "11111111-1111-1111-1111-111111111111"
BOB = "22222222-2222-2222-2222-222222222222"
KEY = "unit-test-key-never-used-outside-this-test"
TARGET = "http://agent:8080"


class WorkerAgentAuthTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        path = Path(self.directory.name) / "signing-key"
        path.write_text(KEY)
        self.env = patch.dict("os.environ", {
            "P8_AGENT_URL": TARGET, "P8_AGENT_SIGNING_KEY_FILE": str(path),
        }, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)

    def spec(self, **changes):
        return {"method":"POST", "url":AGENT_URL, "credential_ref":"P8_API_KEY",
                "body":{"model":"brief", "messages":[{"role":"user", "content":"{{run.question}}"}]}, **changes}

    def context(self, owner=ALICE):
        return {"_agent_caller":owner, "run_input":{"question":"Prepare a brief", "owner_id":BOB, "_agent_caller":BOB}}

    def decode(self, request):
        return claims_from_jwt(request["headers"]["Authorization"].removeprefix("Bearer "), KEY)

    def test_run_identity_overrides_headers_and_is_short_lived(self):
        spec = self.spec(headers={"authorization":"Bearer forged", "AUTHORIZATION":"also forged"})
        request, resolved = build_request(spec, self.context())
        claims = self.decode(request)
        self.assertEqual(claims["sub"], ALICE)
        self.assertEqual(claims["role"], "authenticated")
        self.assertEqual(claims["exp"] - claims["iat"], 300)
        self.assertEqual([k for k in request["headers"] if k.lower() == "authorization"], ["Authorization"])
        self.assertNotIn(request["headers"]["Authorization"], json.dumps(resolved))
        self.assertNotIn(KEY, json.dumps(resolved))

    def test_missing_verified_owner_cannot_fall_back_to_input(self):
        for owner in (None, "", "forged"):
            with self.subTest(owner=owner), self.assertRaisesRegex(TerminalError, "verified run owner"):
                build_request(self.spec(), self.context(owner))

    async def test_two_callers_receive_their_own_token(self):
        import asyncio
        async def prepare(owner):
            await asyncio.sleep(0)
            return self.decode(build_request(self.spec(), self.context(owner))[0])["sub"]
        self.assertEqual(await asyncio.gather(prepare(ALICE), prepare(BOB)), [ALICE, BOB])

    def test_template_cannot_read_signing_key(self):
        with self.assertRaises(TerminalError):
            build_request(self.spec(body="{{env.P8_AGENT_SIGNING_KEY}}"), self.context())

    def test_arbitrary_destination_receives_only_its_explicit_credential(self):
        with patch.dict("os.environ", {"EXTERNAL_KEY":"external-key"}):
            request, _ = build_request(self.spec(url="https://external.example/api", credential_ref="EXTERNAL_KEY"), self.context())
        self.assertEqual(request["headers"]["Authorization"], "Bearer external-key")
        # Even a URL that resolves to the runtime is not eligible unless it is
        # the canonical compiler template. No token minting via run input.
        ctx = self.context()
        ctx["run_input"]["target"] = TARGET + "/v1/chat/completions"
        with self.assertRaises(ConfigError):
            build_request(self.spec(url="{{run.target}}"), ctx)

    def test_invalid_runtime_configuration_is_refused(self):
        for target in ("https://user@agent:8080", "file:///tmp/agent", TARGET + "?redirect=elsewhere", TARGET + "#fragment"):
            with self.subTest(target=target), patch.dict("os.environ", {"P8_AGENT_URL":target}), self.assertRaises(TerminalError):
                build_request(self.spec(), self.context())
        with self.assertRaises(TerminalError):
            agent_authorization(self.spec(), {"url":"https://external.example"}, ALICE)

    def test_unreadable_secret_mount_is_a_terminal_configuration_error(self):
        with patch.dict("os.environ", {"P8_AGENT_SIGNING_KEY_FILE":str(Path(self.directory.name) / "missing")}):
            with self.assertRaisesRegex(TerminalError, "secret mount"):
                build_request(self.spec(), self.context())

    async def test_worker_uses_claimed_owner_rpc_and_keeps_identity_out_of_output(self):
        task = uuid4()
        context = {"kind":"http_call", "step_key":"brief", "task_input":self.spec(),
                   "run_input":{"question":"Prepare a brief", "owner_id":BOB, "_agent_caller":BOB}}
        conn = AsyncMock()
        conn.fetchval.side_effect = [task, json.dumps(context), ALICE]
        @asynccontextmanager
        async def service():
            yield conn
        async def execute(spec, ctx):
            self.assertEqual(self.decode(build_request(spec, ctx)[0])["sub"], ALICE)
            return {"result":"brief"}
        with patch("percolate_core.worker.loop.as_service", service), \
             patch.dict("percolate_core.worker.loop.HANDLERS", {"http_call":execute}), \
             patch("percolate_core.worker.loop.offload", AsyncMock(side_effect=lambda conn, task, out: out)):
            self.assertTrue(await run_once("briefs", "brief-worker"))
        conn.fetchval.assert_any_await("select workflow.task_owner($1, $2)", str(task), "brief-worker")
        conn.execute.assert_awaited_once_with("select workflow.complete_task($1, $2::jsonb)", str(task), {"result":"brief"})

    async def test_refused_owner_never_dispatches_or_retries(self):
        for error in (asyncpg.InsufficientPrivilegeError("agent execution requires a run owner"), asyncpg.UndefinedFunctionError("missing task_owner")):
            task = uuid4()
            conn = AsyncMock()
            conn.fetchval.side_effect = [task, json.dumps({"kind":"http_call", "task_input":self.spec()}), error]
            @asynccontextmanager
            async def service():
                yield conn
            execute = AsyncMock()
            with self.subTest(error=type(error).__name__), patch("percolate_core.worker.loop.as_service", service), \
                 patch.dict("percolate_core.worker.loop.HANDLERS", {"http_call":execute}):
                await run_once("briefs", "brief-worker")
            execute.assert_not_awaited()
            self.assertEqual(conn.execute.await_args.args[0], "select workflow.fail_task($1, $2::jsonb, true)")
            self.assertTrue(conn.execute.await_args.args[2]["terminal"])

    async def test_redirect_does_not_forward_the_run_token(self):
        requests = []
        def upstream(request):
            requests.append(request)
            return httpx.Response(302, headers={"location":"https://external.example"})
        client_type = httpx.AsyncClient
        def client(**kwargs):
            return client_type(transport=httpx.MockTransport(upstream), **kwargs)
        with patch("percolate_core.worker.http.httpx.AsyncClient", side_effect=client):
            await http_call(self.spec(), self.context())
        self.assertEqual(len(requests), 1)
        self.assertEqual(str(requests[0].url), TARGET + "/v1/chat/completions")


if __name__ == "__main__":
    unittest.main()
