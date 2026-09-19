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
from percolate_core.worker.agent_auth import (
    AGENT_RUN_URL, AGENT_URL, AGENT_URL_TEMPLATE, agent_authorization)
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

    def test_task_provenance_comes_from_worker_context_not_the_body(self):
        task = str(uuid4())
        forged = str(uuid4())
        ctx = self.context()
        ctx["_task_id"] = task
        ctx["_worker_id"] = "worker-1"
        ctx["attempt"] = 2
        request, _ = build_request(self.spec(body={"workflow_task_id": forged}), ctx)
        self.assertEqual(self.decode(request)["workflow_task_id"], task)
        self.assertEqual(self.decode(request)["workflow_attempt"], 2)
        self.assertEqual(self.decode(request)["workflow_worker_id"], "worker-1")
        request, _ = build_request(self.spec(body={"workflow_task_id": forged}), self.context())
        self.assertNotIn("workflow_task_id", self.decode(request))

    async def test_older_extension_needs_no_receipt_worker_connection(self):
        from percolate_core.agentic.db.repository import PgRepository
        class Client:
            @asynccontextmanager
            async def as_user(self, claims):
                conn = AsyncMock()
                conn.fetchval.return_value = False
                yield conn
        repo = PgRepository(Client(), {"sub": ALICE, "workflow_task_id": str(uuid4())})
        with patch("percolate_core.core.identity.as_task_worker", side_effect=AssertionError("worker connection on old extension")):
            await repo.record_execution_receipt(uuid4(), {"method_version": "test", "usage": {}})

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
        # Bound by the operator: a credential with no binding for the
        # destination is refused (tests/test_credential_origins.py).
        with patch.dict("os.environ", {"EXTERNAL_KEY":"external-key",
                                       "P8_CREDENTIAL_ORIGINS":'{"EXTERNAL_KEY": "https://external.example"}'}):
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
        # A database from before workflow.task_principal (REM-247): the owner alone, as it always was.
        task = uuid4()
        context = {"kind":"http_call", "attempt":1, "step_key":"brief", "task_input":self.spec(),
                   "run_input":{"question":"Prepare a brief", "owner_id":BOB, "_agent_caller":BOB}}
        conn = AsyncMock()
        conn.fetchval.side_effect = [task, json.dumps(context), False, ALICE]
        @asynccontextmanager
        async def service():
            yield conn
        async def execute(spec, ctx):
            claims = self.decode(build_request(spec, ctx)[0])
            self.assertEqual(claims["sub"], ALICE)
            self.assertNotIn("actor", claims)
            return {"result":"brief"}
        with patch("percolate_core.worker.loop.as_service", service), \
             patch.dict("percolate_core.worker.loop.HANDLERS", {"http_call":execute}), \
             patch("percolate_core.worker.loop.offload", AsyncMock(side_effect=lambda conn, task, out: out)):
            self.assertTrue(await run_once("briefs", "brief-worker"))
        conn.fetchval.assert_any_await("select workflow.task_owner($1, $2)", str(task), "brief-worker")
        conn.execute.assert_awaited_once_with("select workflow.complete_task($1, $2::jsonb, $3)", str(task), {"result":"brief"}, "brief-worker")

    async def test_refused_owner_never_dispatches_or_retries(self):
        for error in (asyncpg.InsufficientPrivilegeError("agent execution requires a run owner"), asyncpg.UndefinedFunctionError("missing task_owner")):
            task = uuid4()
            conn = AsyncMock()
            conn.fetchval.side_effect = [task, json.dumps({"kind":"http_call", "task_input":self.spec()}), False, error]
            @asynccontextmanager
            async def service():
                yield conn
            execute = AsyncMock()
            with self.subTest(error=type(error).__name__), patch("percolate_core.worker.loop.as_service", service), \
                 patch.dict("percolate_core.worker.loop.HANDLERS", {"http_call":execute}):
                await run_once("briefs", "brief-worker")
            execute.assert_not_awaited()
            self.assertEqual(conn.execute.await_args.args[0], "select workflow.fail_task($1, $2::jsonb, true, $3)")
            self.assertEqual(conn.execute.await_args.args[3], "brief-worker")
            self.assertTrue(conn.execute.await_args.args[2]["terminal"])

    async def test_an_agent_started_run_carries_its_starter_into_the_step_token(self):
        task, key = uuid4(), uuid4()
        context = {"kind":"http_call", "attempt":1, "step_key":"brief", "task_input":self.spec(), "run_input":{"question":"Q"}}
        conn = AsyncMock()
        conn.fetchval.side_effect = [task, json.dumps(context), True]
        conn.fetchrow.return_value = {"owner_id": ALICE, "started_actor": "agent", "started_credential_id": key}
        seen = {}
        @asynccontextmanager
        async def service():
            yield conn
        async def execute(spec, ctx):
            seen.update(self.decode(build_request(spec, ctx)[0]))
            return {"result":"brief"}
        with patch("percolate_core.worker.loop.as_service", service), \
             patch.dict("percolate_core.worker.loop.HANDLERS", {"http_call":execute}), \
             patch("percolate_core.worker.loop.offload", AsyncMock(side_effect=lambda conn, task, out: out)):
            self.assertTrue(await run_once("briefs", "brief-worker"))
        self.assertIn("workflow.task_principal", conn.fetchrow.await_args.args[0])
        self.assertEqual((seen["sub"], seen["actor"], seen["api_key_id"]), (ALICE, "agent", str(key)))

    def test_the_starter_decides_which_claims_are_minted(self):
        key = str(uuid4())
        for starter, expected in (
                (None, {}),
                ({"actor": "person", "credential_id": None}, {}),
                ({"actor": None, "credential_id": None}, {}),
                ({"actor": "agent", "credential_id": None}, {"actor": "agent"}),
                ({"actor": "agent", "credential_id": key}, {"actor": "agent", "api_key_id": key})):
            with self.subTest(starter=starter):
                request, _ = build_request(self.spec(), {**self.context(), "_agent_starter": starter})
                claims = self.decode(request)
                self.assertEqual(claims["sub"], ALICE)
                self.assertEqual({k: claims[k] for k in ("actor", "api_key_id") if k in claims}, expected)
        with self.assertRaisesRegex(TerminalError, "starting credential"):
            build_request(self.spec(), {**self.context(), "_agent_starter": {"actor": "agent", "credential_id": "not-a-key"}})

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

    # -- The scheduled path, which is the one that was not covered (REM-96) ----
    #
    # Everything above tests `/v1/chat/completions`. The endpoint a SCHEDULED
    # run actually calls is `/internal/run` (specs/workflow-engine/README.md
    # §"scheduled runs"), and it matched nothing here -- so every scheduled
    # agent run in the shipped deployment authenticated with the shared
    # `P8_API_KEY` and RLS applied one identity's scope to the whole night's
    # work. The tests passed throughout, because they only ever asked about the
    # interactive endpoint.

    def run_spec(self, **changes):
        """The scheduled step of `specs/workflow-engine/README.md` §"scheduled runs".

        The body is that example's shape with one deliberate difference: the
        README writes `workflow_task_id: "{{task.id}}"` and `task` is not a
        resolvable namespace -- `worker/templates.py` accepts `steps`, `run`
        and `env` only, and nothing else injects the id either. That is a real
        defect in the documented example and it is NOT this test's subject, so
        the id is a literal here rather than quietly depending on a template
        that raises. Reported on REM-96.
        """
        return {"method":"POST", "url":AGENT_RUN_URL, "credential_ref":"P8_API_KEY",
                "mode":"async", "timeout_ms":120000,
                "body":{"workflow_task_id":"3f4a1c88-0000-4000-8000-000000000001",
                        "input":{"agent":"classifier", "prompt":"Classify - {{run.question}}"}},
                **changes}

    def test_a_scheduled_run_is_authenticated_as_whoever_scheduled_it(self):
        # Fails before the fix: the url did not match, no token was minted, and
        # the step went out with the deployment's shared key instead.
        request, resolved = build_request(self.run_spec(), self.context())
        claims = self.decode(request)
        self.assertEqual(claims["sub"], ALICE)
        self.assertEqual(claims["role"], "authenticated")
        self.assertEqual(claims["exp"] - claims["iat"], 300)
        self.assertNotIn(KEY, json.dumps(resolved))

    def test_the_scheduled_step_names_its_lease_holder(self):
        # REM-553: the runtime completes this task while this worker holds the
        # lease, and lease_violation compares holders only when told one.
        ctx = {**self.context(), "_worker_id": "worker-7"}
        request, _ = build_request(self.run_spec(), ctx)
        self.assertEqual(request["headers"]["X-P8-Worker-Id"], "worker-7")
        # Only /internal/run completes a task; a chat completion is not told.
        request, _ = build_request(self.spec(), ctx)
        self.assertNotIn("X-P8-Worker-Id", request["headers"])

    def test_both_runtime_endpoints_mint_and_nothing_else_does(self):
        # The eligible set is exactly what the compiler emits. A third path on
        # the same host is not a runtime endpoint, and adding one to AGENT_PATHS
        # should be a decision somebody makes on purpose.
        for url in (AGENT_URL, AGENT_RUN_URL):
            with self.subTest(url=url):
                self.assertEqual(self.decode(build_request(self.spec(url=url), self.context())[0])["sub"], ALICE)
        # An unlisted path on the same host is not a runtime endpoint. Asserted
        # against agent_authorization directly rather than through
        # build_request, because a step with no eligible credential fails at
        # credential resolution first and would pass this for the wrong reason.
        with self.subTest(url="an unlisted path on the runtime"):
            spec = self.spec(url=AGENT_URL_TEMPLATE + "/internal/other")
            self.assertIsNone(agent_authorization(spec, {"url":TARGET + "/internal/other"}, ALICE))

    def test_the_scheduled_step_reaches_only_the_configured_runtime(self):
        # The resolved url is what the request is sent to, so it is what has to
        # match -- not the template it came from.
        with self.assertRaises(TerminalError):
            agent_authorization(self.run_spec(), {"url":"https://external.example/internal/run"}, ALICE)
        # ...and a misconfigured runtime fails loudly rather than falling back
        # to the shared key, which is the silent version of this whole bug.
        for target in ("", "file:///tmp/agent", "https://user@agent:8080"):
            with self.subTest(target=target), patch.dict("os.environ", {"P8_AGENT_URL":target}):
                with self.assertRaises(TerminalError):
                    build_request(self.run_spec(), self.context())

    def test_a_scheduled_run_with_no_verified_owner_does_not_borrow_the_shared_key(self):
        for owner in (None, "", "forged"):
            with self.subTest(owner=owner), self.assertRaisesRegex(TerminalError, "verified run owner"):
                build_request(self.run_spec(), self.context(owner))


if __name__ == "__main__":
    unittest.main()
