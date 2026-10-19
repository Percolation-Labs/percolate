"""Tool contracts — one canonical shape, whatever the provider was.

Spec intent (``brief.md`` §5.2): "MCP already defines the canonical shape a tool
needs to be usable — name, description, input schema, an invocation target
``call_tool`` can reach. An OpenAPI binding is an *adapter*, not a second,
parallel mechanism." So there is exactly one tool type in this package, and the
only place ``kind`` is ever consulted is inside the provider that resolves and
invokes it — never downstream, and never by the agent runtime.
"""

from __future__ import annotations

from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, Field

ToolServerKind = Literal["mcp", "openapi"]
"""How a tool server is reached. Not a behavioural switch anywhere above the
provider layer — see module docstring."""

ToolErrorKind = Literal["tool_error", "dispatch_error"]
"""``brief.md`` §5.2: "the tool ran and said no" and "the tool was unreachable"
are different facts an agent (or a human reading the run afterward) needs to
tell apart, so they are never collapsed into one generic error."""


class InvocationTarget(BaseModel):
    """Everything a provider needs to actually make the call, and nothing more.

    For ``mcp``: ``tool_name`` is the MCP tool name; ``method``/``path`` unused.
    For ``openapi``: ``method``/``path`` come from the operation, ``tool_name``
    is the ``operationId`` that was normalised into the canonical name.

    Deliberately *not* here: credentials. A target carries a
    ``credential_ref`` on its owning ``ToolServer``, never a literal secret —
    same boundary ``workflow-engine``'s ``http_call`` draws (``brief.md`` §5.2).
    """

    tool_name: str
    method: str | None = None
    path: str | None = None
    param_in: dict[str, str] = Field(
        default_factory=dict,
        description=(
            "OpenAPI only: where each input-schema property goes on the way "
            "out (path/query/header/body). The LLM sees one flat object; this "
            "is what lets the provider re-split it into a real HTTP request "
            "without re-parsing the spec at call time."
        ),
    )


class CanonicalTool(BaseModel):
    """One callable tool, normalised out of an MCP ``list_tools`` entry or an
    OpenAPI operation.

    This is what gets cached on ``tool_servers.cached_tools`` (``brief.md``
    §5.2, "registration is a sync step, not just a stored URL") and what the
    runtime hands to pydantic-ai as a tool definition.
    """

    name: str = Field(description="Unique within its server; prefixed on collision.")
    description: str = ""
    input_schema: dict[str, Any] = Field(default_factory=dict)
    server_id: UUID | None = None
    server_name: str | None = None
    kind: ToolServerKind = "mcp"
    target: InvocationTarget | None = None


class ToolInvocation(BaseModel):
    """A model-issued call, before dispatch."""

    call_id: str
    tool_name: str
    arguments: dict[str, Any] = Field(default_factory=dict)


class ToolResult(BaseModel):
    """The outcome of a dispatch, in the shape a ``tool_response`` message row
    stores it (``brief.md`` §5.2, §7).

    ``is_error``/``error_kind`` are carried all the way to the row on purpose:
    a failed tool call is a normal observation the LLM sees and decides what to
    do about — there is no automatic retry at the runtime level.
    """

    call_id: str
    tool_name: str
    content: Any = None
    is_error: bool = False
    error_kind: ToolErrorKind | None = None
    citable: bool = Field(
        default=False,
        description=(
            "Set by the provider from its server's emits_citations flag, so "
            "citation derivation never has to guess which responses were "
            "retrieval (brief.md §5.3)."
        ),
    )
    latency_ms: int | None = None
