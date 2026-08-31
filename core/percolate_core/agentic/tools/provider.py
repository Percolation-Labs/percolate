"""Tool providers — the only place ``kind`` is allowed to matter.

``brief.md`` §5.2, the two rules this module exists to enforce:

1. **Zero built-in tools, ever.** "There is no code path in this runtime that
   implements tool logic itself, for any agent, ever." A provider *reaches* a
   tool; it never *is* one. If a function in this package ever computes an
   answer instead of forwarding a call, that is the rule being broken.
2. **OpenAPI extends the MCP shape, it does not duplicate it.** MCP's tool shape
   is canonical; the OpenAPI provider is an adapter onto it. Downstream of
   resolution "the runtime never needs to know ... whether a given tool came
   from an MCP server or an OpenAPI spec."
"""

from __future__ import annotations

import os
from typing import Protocol

from ..contracts import CanonicalTool, ToolInvocation, ToolResult, ToolServer


class ToolProvider(Protocol):
    """Two operations: discover, and call. Nothing else belongs here."""

    kind: str

    async def list_tools(self, server: ToolServer) -> list[CanonicalTool]:
        """Discover what this server currently exposes, in canonical shape.

        Called at *registration* and by the scheduled re-sync task — never per
        agent invocation (``brief.md`` §5.2).
        """
        ...

    async def invoke(
        self,
        server: ToolServer,
        tool: CanonicalTool,
        call: ToolInvocation,
        headers: dict[str, str] | None = None,
    ) -> ToolResult:
        """Dispatch one call and classify its outcome.

        ``headers`` is the run's ambient context on its way out (``brief.md``
        §5.1 item 4) — the same ``X-P8-*`` contract that carried it in. Every
        provider forwards it, not just the one delegation happens to use: a
        CRUD tool server has as much right to know the tenant as an agent does.

        The classification is the load-bearing part (``brief.md`` §5.2): a
        server that responded with a failure produces ``error_kind =
        'tool_error'``; a server that could not be reached produces
        ``'dispatch_error'``. No retry happens here — retrying is a decision the
        agent makes from the observation, and the only transport-level retry the
        spec allows comes from ``workflow-engine``'s ``http_call``, reused rather
        than reinvented.
        """
        ...


async def resolve_credential(credential_ref: str | None) -> str | None:
    """Turn a ``credential_ref`` into an actual credential.

    OPEN, and deliberately unimplemented (``brief.md`` §9): "How the agent
    runtime gets credentials for the microservices it binds to ... is exactly
    where the delegated-credential/secrets-vault gap ``specs/README.md`` already
    named as explicitly out of the core five would bite first — worth resolving
    alongside that, not inventing a second, narrower credential mechanism just
    for this runtime."

    One scheme is implemented, deliberately the most boring one:
    ``env:VAR_NAME`` reads a process environment variable. It is enough to bind
    a real authenticated service today, it is obviously not a secrets
    mechanism, and it fails loudly (rather than sending no auth) for any other
    reference shape — so nothing accumulates around a placeholder pretending to
    be the answer. One function; whatever this collection settles on lands here.
    """
    if credential_ref is None:
        return None
    if credential_ref.startswith("env:"):
        name = credential_ref[4:]
        value = os.getenv(name)
        if value is None:
            raise LookupError(f"credential_ref {credential_ref!r}: ${name} is not set")
        return value
    raise NotImplementedError(
        f"credential_ref {credential_ref!r}: only env: references are supported "
        "until this collection has a secrets mechanism (brief.md §9)"
    )
