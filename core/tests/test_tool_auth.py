"""Caller identity at real transport boundaries, without a provider or database."""
import asyncio
import unittest
from unittest.mock import patch

import httpx
from fastapi.testclient import TestClient

from percolate_core.agentic.contracts import CanonicalTool, ToolInvocation, ToolServer
from percolate_core.agentic.contracts.tools import InvocationTarget
from percolate_core.agentic.settings import Settings
from percolate_core.agentic.tools.auth import caller_credentials, outbound_headers
from percolate_core.agentic.tools.openapi import OpenApiProvider
from percolate_core.ui.server import build_app as ui_app

ORIGIN = "http://query-mcp:8090"


class CallerAuthTest(unittest.IsolatedAsyncioTestCase):
    def server(self, url=ORIGIN, credential_ref=None):
        return ToolServer(name="query", kind="mcp", url=url, credential_ref=credential_ref)

    async def test_deny_by_default_and_exact_destination(self):
        server = self.server()
        self.assertNotIn("Authorization", await outbound_headers(server, {"authorization":"forged"}))
        with caller_credentials("Bearer alice", ()):
            self.assertNotIn("Authorization", await outbound_headers(server))
        with caller_credentials("Bearer alice", (ORIGIN,)):
            self.assertEqual((await outbound_headers(server))["Authorization"], "Bearer alice")
            for url in ("http://query-mcp.evil:8090", "https://query-mcp:8090", "http://query-mcp:8091"):
                self.assertNotIn("Authorization", await outbound_headers(self.server(url)))
            self.assertNotIn("Authorization", await outbound_headers(server, url="http://evil.example"))
        self.assertNotIn("Authorization", await outbound_headers(server))

    async def test_async_callers_are_isolated_and_context_is_reset_on_failure(self):
        async def request(who):
            with caller_credentials("Bearer " + who, (ORIGIN,)):
                await asyncio.sleep(0)
                return (await outbound_headers(self.server()))["Authorization"]
        self.assertEqual(await asyncio.gather(request("alice"), request("bob")), ["Bearer alice", "Bearer bob"])
        with self.assertRaises(RuntimeError):
            with caller_credentials("Bearer alice", (ORIGIN,)):
                raise RuntimeError("test")
        self.assertNotIn("Authorization", await outbound_headers(self.server()))

    async def test_first_party_uses_caller_external_uses_its_own_credential(self):
        with patch.dict("os.environ", {"TEST_TOOL_KEY":"external"}), caller_credentials("Bearer alice", (ORIGIN,)):
            self.assertEqual((await outbound_headers(self.server(credential_ref="env:MISSING")))["Authorization"], "Bearer alice")
            self.assertEqual((await outbound_headers(self.server("http://external.example", "env:TEST_TOOL_KEY")))["Authorization"], "Bearer external")

    async def test_openapi_sends_verified_identity_and_does_not_follow_redirect(self):
        captured = []
        def upstream(request):
            captured.append(request)
            return httpx.Response(302, headers={"location":"http://untrusted.example"})
        client_type = httpx.AsyncClient
        def client(**kwargs):
            return client_type(transport=httpx.MockTransport(upstream), **kwargs)
        server = ToolServer(name="workflow", kind="openapi", url="http://postgrest:3000/", credential_ref="env:MISSING")
        tool = CanonicalTool(name="query", target=InvocationTarget(tool_name="query", path="/rpc/query", method="POST", param_in={"p_query":"body"}))
        with patch("percolate_core.agentic.tools.openapi.httpx.AsyncClient", side_effect=client), caller_credentials("Bearer alice", ("http://postgrest:3000",)):
            await OpenApiProvider().invoke(server, tool, ToolInvocation(call_id="test", tool_name="query", arguments={"p_query":"SCHEMA"}))
        self.assertEqual(len(captured), 1)
        self.assertEqual(captured[0].headers["authorization"], "Bearer alice")
        self.assertEqual(str(captured[0].url), "http://postgrest:3000/rpc/query")

    async def test_model_cannot_override_authorization(self):
        server = ToolServer(name="workflow", kind="openapi", url="http://postgrest:3000/")
        tool = CanonicalTool(name="query", target=InvocationTarget(tool_name="query", path="/rpc/query", method="POST", param_in={"Authorization":"header"}))
        with caller_credentials("Bearer alice", ("http://postgrest:3000",)):
            result = await OpenApiProvider().invoke(server, tool, ToolInvocation(call_id="test", tool_name="query", arguments={"Authorization":"Bearer mallory"}))
        self.assertTrue(result.is_error)
        self.assertEqual(result.error_kind, "dispatch_error")

    def test_settings_require_explicit_origins(self):
        for bad in ("*", "https://*.example", "http://query-mcp:8090/path", "http://user@query-mcp:8090"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                Settings(tool_auth_origins=(bad,))

    def test_frontend_modules_are_served(self):
        client = TestClient(ui_app())
        for module in ("reads.js", "workbench.js", "access.js", "views.js"):
            response = client.get("/" + module)
            self.assertEqual(response.status_code, 200)
            self.assertIn("javascript", response.headers["content-type"])
        self.assertEqual(client.get("/.env").status_code, 404)
        client.close()


class PersistedExecutionTest(unittest.IsolatedAsyncioTestCase):
    async def test_missing_catalogue_finishes_failed_and_keeps_user_prompt(self):
        from percolate_core.agentic.contracts import AgentSpec, ChatRequest, InboundMessage, RequestContext
        from percolate_core.agentic.sequencer import TurnSequencer
        from percolate_core.agentic.testing import MemoryRepository
        repo = MemoryRepository()
        await repo.upsert_tool_server(ToolServer(name="empty", kind="mcp", url=ORIGIN))
        await repo.upsert_agent(AgentSpec(name="brief", tools=[{"server":"empty"}]))
        result = await TurnSequencer(repo).run_turn(ChatRequest(model="brief", messages=[InboundMessage(role="user", content="prepare a brief")]), RequestContext())
        self.assertEqual(result.run.status, "failed")
        self.assertIn("sync its catalogue", result.run.state["error"])

    def test_tool_evidence_is_persisted_without_transport_context(self):
        from percolate_core.agentic.contracts import Run, ToolResult
        from percolate_core.agentic.runtime.persistence import PersistenceAdapter
        from percolate_core.agentic.testing import MemoryRepository
        adapter = PersistenceAdapter(MemoryRepository(), Settings())
        evidence = {"rows":[{"source":"runbook", "text":"Review the queue"}]}
        with caller_credentials("Bearer never-in-a-message", (ORIGIN,)):
            rows = adapter.build_turn_rows(Run(), None, "Review queue", [ToolResult(call_id="a", tool_name="query", content=evidence)], slow_path=False)
        self.assertEqual(rows[-1].tool_calls[0]["content"], evidence)
        self.assertNotIn("never-in-a-message", rows[-1].model_dump_json())


class McpResultTest(unittest.IsolatedAsyncioTestCase):
    async def test_sdk_field_names_preserve_errors_and_structured_evidence(self):
        from contextlib import asynccontextmanager
        from types import SimpleNamespace
        from unittest.mock import AsyncMock
        from percolate_core.agentic.tools.mcp import McpProvider

        server = ToolServer(name="query", kind="mcp", url=ORIGIN)
        tool = CanonicalTool(name="query", target=InvocationTarget(tool_name="query"))
        for fields in ({"is_error":True, "structured_content":{"reason":"denied"}, "meta":{}},
                       {"isError":True, "structuredContent":{"reason":"denied"}, "_meta":{}},
                       {"is_error":True, "structured_content":{"reason":"denied"}, "meta":{"errorKind":"dispatch_error"}}):
            response = SimpleNamespace(content=[], **fields)
            @asynccontextmanager
            async def session(*args):
                yield SimpleNamespace(call_tool=AsyncMock(return_value=response))
            with self.subTest(fields=fields), patch("percolate_core.agentic.tools.mcp._session", session):
                result = await McpProvider().invoke(server, tool, ToolInvocation(call_id="test", tool_name="query", arguments={"query":"SCHEMA"}))
            self.assertTrue(result.is_error)
            self.assertEqual(result.content, {"reason":"denied"})
            self.assertEqual(result.error_kind, "dispatch_error" if fields.get("meta") else "tool_error")


class GatewayIdentityTest(unittest.IsolatedAsyncioTestCase):
    async def test_ambient_identity_cannot_replace_missing_or_invalid_bearer(self):
        from uuid import uuid4
        from percolate_core.agentic.gateway import run_delegated, run_scheduled
        for auth in (None, "Bearer invalid"):
            headers = {"X-P8-User-Id":"11111111-1111-1111-1111-111111111111"}
            if auth:
                headers["Authorization"] = auth
            with patch.dict("os.environ", {"P8_JWT_SECRET":"test-only-secret-not-a-production-key"}):
                with self.assertRaises(PermissionError):
                    await run_delegated(Settings(), agent_name="brief", prompt="test", headers=headers)
                with self.assertRaises(PermissionError):
                    await run_scheduled(Settings(), task_id=uuid4(), agent_name="brief", session_id=None, prompt="test", headers=headers)


if __name__ == "__main__":
    unittest.main()
