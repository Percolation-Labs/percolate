"""MCP provider — the canonical shape, natively.

``brief.md`` §5.2: MCP "already defines the canonical shape a tool needs to be
usable", so this provider is close to an identity mapping — an MCP ``list_tools``
entry *is* a ``CanonicalTool``, and ``call_tool`` *is* the invocation.

This is also the provider delegation runs through: the agent gateway
(``percolate_core.agentic.gateway``) is an ordinary MCP server as far as this file is
concerned, and nothing here knows that one of its tools happens to be another
agent (``brief.md`` §5.1 item 3).
"""

from __future__ import annotations

import time
from contextlib import asynccontextmanager
from typing import Any

import httpx

from ..contracts import (
    CanonicalTool,
    InvocationTarget,
    ToolInvocation,
    ToolResult,
    ToolServer,
)
from .auth import outbound_headers


@asynccontextmanager
async def _session(server: ToolServer, headers: dict[str, str] | None) -> Any:
    """One initialised MCP session over streamable HTTP.

    A session per call, not a pooled one, and that is a real decision rather
    than laziness: ambient context (``brief.md`` §5.1 item 4) travels as headers
    on the HTTP connection, so a connection shared across runs would be a
    connection carrying the wrong tenant. If the round-trip cost ever matters,
    the fix is pooling *per context*, never one shared session.
    """
    from mcp import ClientSession
    from mcp.client.streamable_http import streamable_http_client

    outbound = await outbound_headers(server, headers)

    async with (
        httpx.AsyncClient(headers=outbound, timeout=60, follow_redirects=False) as http_client,
        streamable_http_client(server.url, http_client=http_client) as streams,
        ClientSession(streams[0], streams[1]) as session,
    ):
        await session.initialize()
        yield session


class McpProvider:
    """Talks MCP over streamable HTTP."""

    kind = "mcp"

    async def list_tools(self, server: ToolServer) -> list[CanonicalTool]:
        """Connect, ``list_tools``, map each entry across one-for-one."""
        async with _session(server, None) as session:
            listed = await session.list_tools()

        return [
            CanonicalTool(
                name=tool.name,
                description=tool.description or "",
                input_schema=tool.input_schema or {"type": "object", "properties": {}},
                server_id=server.id,
                server_name=server.name,
                kind="mcp",
                target=InvocationTarget(tool_name=tool.name),
            )
            for tool in listed.tools
        ]

    async def invoke(
        self,
        server: ToolServer,
        tool: CanonicalTool,
        call: ToolInvocation,
        headers: dict[str, str] | None = None,
    ) -> ToolResult:
        """``call_tool``, with the two failure modes kept apart (``brief.md`` §5.2).

        - A result with ``isError`` — the tool ran and said no — is
          ``error_kind='tool_error'``.
        - A connection that never got there is ``'dispatch_error'``.

        Both persist as an ordinary ``tool_response`` message so the model sees
        the failure as a normal observation and decides what to do next. No
        retry: retrying is a decision the agent makes, not a policy this
        runtime accumulates.
        """
        started = time.monotonic()
        try:
            async with _session(server, headers) as session:
                result = await session.call_tool(tool.target.tool_name, call.arguments)
        except Exception as exc:  # noqa: BLE001 — see below
            # Deliberately blind: every way a transport can fail (timeout, DNS,
            # refused connection, a protocol error mid-handshake) is the same
            # fact to an agent — the tool was never reached — and narrowing this
            # to a list of exception types would silently reclassify whichever
            # one the list forgot as a crash instead of an observation.
            return ToolResult(
                call_id=call.call_id,
                tool_name=tool.name,
                content=f"{type(exc).__name__}: {exc}",
                is_error=True,
                error_kind="dispatch_error",
                latency_ms=int((time.monotonic() - started) * 1000),
            )

        is_error = bool(getattr(result, "is_error", getattr(result, "isError", False)))
        meta = getattr(result, "meta", getattr(result, "_meta", None)) or {}
        error_kind = "dispatch_error" if meta.get("errorKind") == "dispatch_error" else "tool_error"
        return ToolResult(
            call_id=call.call_id,
            tool_name=tool.name,
            content=_content(result),
            is_error=is_error,
            error_kind=error_kind if is_error else None,
            latency_ms=int((time.monotonic() - started) * 1000),
        )


def _content(result: Any) -> Any:
    """Structured content when the server provides it, text otherwise.

    Structured first because ``brief.md`` §5.3 derives citations from the *rows*
    a retrieval tool returned — flattening everything to text would throw away
    exactly the fields provenance is built from.
    """
    structured = getattr(result, "structured_content", getattr(result, "structuredContent", None))
    if structured is not None:
        return structured
    parts = [getattr(block, "text", None) for block in getattr(result, "content", [])]
    text = "\n".join(p for p in parts if p)
    return text or None
