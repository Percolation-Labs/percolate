"""`agent serve` answers MCP at /mcp: the agent gateway is not a second service.

`brief.md` §5.1 item 3 says the gateway "is the same deployed runtime, so this
is not a second service", and get-percolate's agents page registers delegation
at `http://agent:8080/mcp`. Only `percolate agent gateway` served MCP, on 8765,
and no shipped deployment runs that command, so the registration answered 404
and a stock install could not delegate.

Driven through the MCP SDK's own client against the app `agent serve` runs,
in-process, with the Host a container network sends (`agent:8080`), so the
checks are the route, the transport, and the SDK's DNS-rebinding guard
together. The database is a MemoryRepository and no model is called.

Run: python -m unittest discover -s tests -p test_gateway_on_agent_serve.py
"""

from __future__ import annotations

import os
import unittest
from contextlib import asynccontextmanager
from unittest.mock import patch

import httpx

from percolate_core.agentic import gateway as gateway_module
from percolate_core.agentic.api import GATEWAY_PATH, build_app
from percolate_core.agentic.contracts import AgentSpec
from percolate_core.agentic.settings import Settings
from percolate_core.agentic.testing import MemoryRepository

URL = "http://agent:8080/mcp"


class GatewayOnAgentServe(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        repo = MemoryRepository()
        await repo.upsert_agent(AgentSpec(name="analyst", system_prompt="Answer in two sentences."))

        @asynccontextmanager
        async def connected(settings, claims):
            yield repo

        self.enterContext(patch.object(gateway_module, "connected", connected))
        self.enterContext(patch.dict(os.environ, {"P8_JWT_SECRET": "test-only-secret-not-a-production-key"}))
        self.app = build_app(Settings())

    @asynccontextmanager
    async def session(self):
        from mcp import ClientSession
        from mcp.client.streamable_http import streamable_http_client

        # The lifespan would open a database pool; only the gateway's session
        # manager, which the mounted route needs, is run here.
        async with self.app.state.percolate_agent_gateway.session_manager.run():
            transport = httpx.ASGITransport(app=self.app)
            async with (
                httpx.AsyncClient(transport=transport, follow_redirects=False) as http,
                streamable_http_client(URL, http_client=http) as streams,
                ClientSession(streams[0], streams[1]) as session,
            ):
                await session.initialize()
                yield session

    def test_the_route_is_on_the_app_agent_serve_runs(self):
        paths = {getattr(r, "path", None) for r in self.app.router.routes}
        self.assertIn(GATEWAY_PATH, paths)
        self.assertEqual(GATEWAY_PATH, "/mcp")

    async def test_an_agent_is_one_tool_listed_at_agent_8080_mcp(self):
        async with self.session() as session:
            listed = await session.list_tools()
        self.assertEqual([t.name for t in listed.tools], ["agent__analyst"])

    async def test_a_call_without_a_verified_caller_is_an_error_result(self):
        async with self.session() as session:
            result = await session.call_tool("agent__analyst", {"prompt": "which vessels?"})
        self.assertTrue(result.is_error)
        self.assertIn("a verified caller is required", result.content[0].text)


if __name__ == "__main__":
    unittest.main()
