"""A router is offered the agents its caller may read, not a list cached for everyone (REM-971).

The agent gateway was synced like any MCP server: asked once, with no caller,
and its answer stored on the `tool_servers` row. Row security shows a caller of
nobody only the agents nobody owns, so an agent pushed with `percolate agent
push` (its pusher's own, private) was never in the list, and a router naming it
got `Unknown tool name: 'agent__story'`. One stored list also cannot be right
for two callers who may read different agents.

The repository here plays the database's row security: each instance answers
`list_agents` as one caller would be answered. percolate's test
`dev/tests/rbac/22-a-router-reaches-what-its-caller-may.sql` is the other half:
that `agentic.agents_api` really answers alice and bob differently.

Run: python -m unittest discover -s tests -p test_a_router_offers_what_its_caller_may_read.py
"""

from __future__ import annotations

import asyncio
import unittest

from percolate_core.agentic.contracts import AgentSpec, CanonicalTool, ToolRef, ToolServer
from percolate_core.agentic.testing import MemoryRepository
from percolate_core.agentic.tools.registry import resolve_toolset

WRITERS = ["story", "joke", "poem"]


class CallerRepository(MemoryRepository):
    """`list_agents` answers as one caller: only the names that caller may read."""

    def __init__(self, readable: set[str]) -> None:
        super().__init__()
        self.readable = readable

    async def list_agents(self) -> list[AgentSpec]:
        return [a for a in await super().list_agents() if a.name in self.readable]


def stack(readable: set[str], cached: list[str] | None = None) -> tuple[CallerRepository, AgentSpec]:
    repo = CallerRepository(readable)
    gateway = ToolServer(
        name="p8-agents", kind="mcp", url="http://agent:8080/mcp", serves_agents=True,
        cached_tools=[CanonicalTool(name=f"agent__{n}") for n in (cached or [])],
    )
    repo.tool_servers[gateway.name] = gateway
    for w in WRITERS:
        repo.agents[w] = AgentSpec(name=w, system_prompt=f"Write a short {w} about what you are given.")
    router = AgentSpec(
        name="router",
        system_prompt="Hand the request to the story, joke or poem writer.",
        tools=[ToolRef(server="p8-agents", tools=[f"agent__{w}" for w in WRITERS])],
    )
    repo.agents[router.name] = router
    return repo, router


def offered(readable: set[str], cached: list[str] | None = None) -> list[str]:
    repo, router = stack(readable, cached)
    toolset = asyncio.run(resolve_toolset(repo, router))
    return sorted(t.name for t in toolset.tools)


class RouterCatalogueIsTheCallers(unittest.TestCase):
    def test_the_owner_is_offered_her_private_writers_with_nothing_synced(self) -> None:
        # Nothing cached: the old path raised "has no discovered tools".
        self.assertEqual(offered({"router", *WRITERS}),
                         ["agent__joke", "agent__poem", "agent__story"])

    def test_a_caller_who_may_read_none_is_offered_none(self) -> None:
        self.assertEqual(offered({"router"}), [])

    def test_a_cached_list_does_not_offer_what_this_caller_may_not_read(self) -> None:
        # A sync made by somebody who could read every writer must not hand them on.
        self.assertEqual(offered({"router", "poem"}, cached=WRITERS), ["agent__poem"])

    def test_the_tool_is_what_the_gateway_lists(self) -> None:
        repo, router = stack({"router", "story"})
        (tool,) = asyncio.run(resolve_toolset(repo, router)).tools
        self.assertEqual(tool.description, "Write a short story about what you are given.")
        self.assertEqual(tool.input_schema["required"], ["prompt"])
        self.assertEqual(tool.target.tool_name, "agent__story")
        self.assertEqual(tool.server_name, "p8-agents")


if __name__ == "__main__":
    unittest.main()
