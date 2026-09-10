"""Registration and resolution: rows in, one flat toolset out.

Two distinct moments, deliberately not the same code path (``brief.md`` §5.2):

- **Registration/sync** — connect to the server, discover its tools, cache them
  on the row. Happens on insert and on a scheduled ``workflow-engine`` re-sync
  task. Slow, network-bound, rare.
- **Resolution** — turn one agent's ``tools`` references into a flat list of
  canonical tools, from the cache. Happens per run. Fast, no network, "so the
  runtime isn't re-fetching a spec on every single agent invocation."
"""

from __future__ import annotations

from dataclasses import dataclass

from ..contracts import AgentSpec, CanonicalTool, ToolInvocation, ToolResult, ToolServer
from ..db import Repository
from .mcp import McpProvider
from .openapi import OpenApiProvider
from .provider import ToolProvider

PROVIDERS: dict[str, ToolProvider] = {
    "mcp": McpProvider(),
    "openapi": OpenApiProvider(),
}
"""The complete set of ways this runtime can reach a tool. Adding an entry here
is the only kind of change §5.2 permits — and even that is a new *transport*,
never a new tool."""


@dataclass(slots=True)
class ResolvedToolset:
    """One agent's callable surface for one run.

    Flat on purpose: by this point nothing knows or cares which tools came from
    MCP and which from OpenAPI (``brief.md`` §5.2).
    """

    tools: list[CanonicalTool]
    servers: dict[str, ToolServer]

    def find(self, name: str) -> CanonicalTool | None:
        return next((t for t in self.tools if t.name == name), None)

    def delegations(self) -> set[str]:
        """The resolved tool names that are agents, by data rather than by name.

        Read from ``tool_servers.serves_agents``, so a server cannot claim the
        delegation namespace by naming a tool `agent__x`, and a server merely
        *named* `agent` cannot fall into it through collision-prefixing.
        """
        return {
            t.name
            for t in self.tools
            if t.server_name and self.servers[t.server_name].serves_agents
        }


async def sync_server(repo: Repository, server: ToolServer) -> ToolServer:
    """Discover a server's tools and cache them on its row.

    ``brief.md`` §5.2: "Inserting a ``tool_servers`` row triggers fetching the
    OpenAPI spec (or connecting to the MCP server and calling its
    ``list_tools``) and caching the resulting tool/operation list on that row."

    Shell: the flow is real (pick provider by kind → list_tools → write back),
    the providers underneath are stubs. Staleness handling is an open question
    (§9) and is *not* silently decided here.
    """
    provider = PROVIDERS[server.kind]
    server.cached_tools = await provider.list_tools(server)
    return await repo.upsert_tool_server(server)


async def resolve_toolset(repo: Repository, agent: AgentSpec) -> ResolvedToolset:
    """Turn ``agent.tools`` references into one flat, canonical toolset.

    Reads only the cache — no network. Applies each ``ToolRef``'s optional
    allowlist. Name collisions across servers are resolved by prefixing with the
    server name, because two servers legitimately both exposing ``search`` must
    not silently shadow one another.

    Shell: real, because it is pure data manipulation over the contracts and
    reviewing it is how you check the ``tool_servers``-reference design actually
    holds together.
    """
    tools: list[CanonicalTool] = []
    servers: dict[str, ToolServer] = {}
    seen: set[str] = set()

    for ref in agent.tools:
        server = await repo.get_tool_server(ref.server)
        if server is None:
            raise LookupError(
                f"agent {agent.name!r} references unknown tool server {ref.server!r}"
            )
        if not server.cached_tools and ref.tools != []:
            raise LookupError(f"tool server {server.name!r} has no discovered tools; sync its catalogue in Agents")
        servers[server.name] = server
        allow = set(ref.tools) if ref.tools is not None else None
        for tool in server.cached_tools:
            if allow is not None and tool.name not in allow:
                continue
            resolved = tool.model_copy(
                update={"server_id": server.id, "server_name": server.name, "kind": server.kind}
            )
            if resolved.name in seen:
                resolved = resolved.model_copy(
                    update={"name": f"{server.name}__{resolved.name}"}
                )
            seen.add(resolved.name)
            tools.append(resolved)

    return ResolvedToolset(tools=tools, servers=servers)


async def invoke(
    toolset: ResolvedToolset,
    call: ToolInvocation,
    headers: dict[str, str] | None = None,
) -> ToolResult:
    """Dispatch one call to whichever provider owns its tool.

    This is the single choke point where a tool call leaves the process — which
    is what makes "zero built-in tools" auditable: there is exactly one function
    to read to confirm the runtime never answers a tool call itself.
    """
    tool = toolset.find(call.tool_name)
    if tool is None:
        return ToolResult(
            call_id=call.call_id,
            tool_name=call.tool_name,
            content=f"no such tool: {call.tool_name}",
            is_error=True,
            error_kind="dispatch_error",
        )
    server = toolset.servers[tool.server_name or ""]
    result = await PROVIDERS[server.kind].invoke(server, tool, call, headers)
    # Stamped here, once, rather than in each provider: whether a response is
    # citable is a property of the server row, and a provider that forgot to
    # copy it would silently drop provenance (brief.md §5.3).
    result.citable = server.emits_citations
    return result
