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

from typing import Protocol

from ...core.credentials import credential_for
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


async def resolve_credential(credential_ref: str | None, url: str) -> str | None:
    """The secret named by ``credential_ref``, if ``url`` is an origin it is bound to.

    THE BINDING IS THE POINT, and this function used to have none. It read
    ``env:VAR_NAME`` straight out of the environment and handed it back, and
    ``auth.py`` then sent it as a Bearer to whatever ``tool_servers.url`` said.
    Its own docstring called that a placeholder awaiting a secrets mechanism —
    and ``core.credentials.credential_for`` **is** that mechanism, shipped in
    REM-49, one package away. So this is no longer a second, narrower credential
    path: it is the same one, reached from here.

    What it closes: a holder of ``tool_servers:update`` registering a server at
    their own host with ``credential_ref: env:OPENAI_API_KEY`` and calling
    ``POST /tools/<name>/sync``. ``list_tools`` fetches the document *with
    credentials*, so the provider key left the process to an origin nobody had
    sanctioned. ``outbound_headers``' same-origin check cannot see it, because
    the attacker's host **is** the registration origin.

    Now the operator's ``P8_CREDENTIAL_ORIGINS`` decides, the destination is
    checked before the secret is read, and a refusal names the variable and the
    origin it would need. ``env:`` stays the only accepted shape, for the reason
    the old docstring gave: nothing should accumulate around a placeholder.
    """
    if credential_ref is None:
        return None
    if credential_ref.startswith("env:"):
        return credential_for(credential_ref[4:], url)
    raise NotImplementedError(
        f"credential_ref {credential_ref!r}: only env: references are supported "
        "until this collection has a secrets mechanism (brief.md §9)"
    )
