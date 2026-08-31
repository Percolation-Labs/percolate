"""Agent-side configuration contracts — the rows an agent *is*.

Spec intent (``brief.md`` §2): "Agents as rows, not code. An agent is config —
name, system prompt, tools, model, structured-output schema — not a Python
class. Adding an agent is an insert." Everything in this module is therefore a
faithful typed mirror of a table row, not an in-process registry entry: it must
round-trip to and from Postgres losslessly (see ``p8agentic.authoring`` for the
authored form of the same data — a JSON Schema document, whose ``description``
*is* the system prompt and whose ``properties`` *are* the structured output).
"""

from __future__ import annotations

from datetime import datetime
from typing import Any, Literal
from uuid import UUID, uuid4

from pydantic import BaseModel, Field

from .tools import CanonicalTool, ToolServerKind


class ToolServer(BaseModel):
    """One registered MCP server or OpenAPI service (``brief.md`` §5.2).

    Registered *once* and referenced by every agent that uses it — the whole
    point of the table is that "the same OpenAPI service used by ten agents"
    does not mean its URL and credentials copied into ``agents.tools`` ten
    times.
    """

    id: UUID = Field(default_factory=uuid4)
    name: str
    kind: ToolServerKind
    url: str
    credential_ref: str | None = Field(
        default=None,
        description=(
            "An indirection to a secret, never the secret. brief.md §9 flags "
            "credential resolution as unresolved collection-wide; this column "
            "is the seam that resolution plugs into later."
        ),
    )
    emits_citations: bool = Field(
        default=False,
        description=(
            "Whether this server's responses are citable retrieval results "
            "(brief.md §5.2/§5.3). A flag rather than a tool-name convention, "
            "because a convention breaks the first time someone renames a tool."
        ),
    )
    serves_agents: bool = Field(
        default=False,
        description=(
            "Whether this server's tools ARE agents — i.e. it is the runtime's "
            "own gateway (brief.md §5.1 item 3). A flag rather than an "
            "`agent__` name prefix, because delegation decides persistence "
            "granularity and hands the callee a delegated-by header, and any "
            "registered server could otherwise claim that namespace."
        ),
    )
    cached_tools: list[CanonicalTool] = Field(
        default_factory=list,
        description=(
            "Filled by the registration sync step, refreshed by a scheduled "
            "workflow-engine task — not re-fetched per agent invocation."
        ),
    )
    synced_at: datetime | None = None


class ToolRef(BaseModel):
    """An agent's reference *into* a tool server, optionally narrowed.

    ``brief.md`` §5.2: "``agents.tools`` becomes a list of *references* into
    ``tool_servers`` (optionally scoped to a subset of that server's tools),
    not raw URLs and auth config duplicated inline per agent."
    """

    server: str = Field(description="ToolServer.name — resolved at toolset build time.")
    tools: list[str] | None = Field(
        default=None, description="Allowlist; None means every tool that server exposes."
    )


ChainedActionKind = Literal["pg_function", "webhook"]


class ChainedAction(BaseModel):
    """What fires automatically when structured output matches the schema.

    ``brief.md`` §2/§4: p8k8's "chained tool call" reframed as *data* rather
    than a Python callable lookup. §9 leaves the reference shape open between a
    Postgres function (same-DB, fastest) and a PostgREST/webhook URL (works for
    external side effects) — "probably both, distinguished by a ``kind``
    column", which is what this models.
    """

    kind: ChainedActionKind
    target: str = Field(description="Schema-qualified function name, or an absolute URL.")


class ContextPolicy(BaseModel):
    """The persistence adapter's context-reload policy (``brief.md`` §3, §5.1).

    Default is windowing plus a reserved slot for a rolling summary — never
    "everything ever said in this session". The *parameters* are explicitly an
    open question (§9: "message count vs. token estimate, and what number"), so
    they live here as per-agent data with a settings-level default rather than
    as constants in the adapter. Count only, for now: a ``window_tokens`` field
    with no implementation behind it would be a promise, not a policy.
    """

    window_messages: int | None = None
    summarize_after_messages: int | None = None


class AgentSpec(BaseModel):
    """An ``agents`` row (``brief.md`` §7, ``ontology.md``).

    Authored either as an insert, or in code as a real ``pydantic_ai.Agent`` and
    exported to this shape by a build step (``brief.md`` §6: "authored in code,
    deployed as data"). Either way, applying it is a migration, never a deploy —
    the runtime is not redeployed to add, change, or retire an agent.
    """

    id: UUID = Field(default_factory=uuid4)
    name: str
    system_prompt: str = ""
    model: str | None = Field(
        default=None, description="None falls back to Settings.default_model."
    )
    tools: list[ToolRef] = Field(default_factory=list)
    structured_output_schema: dict[str, Any] | None = Field(
        default=None,
        description="JSON Schema. Its presence is what makes chained_action reachable.",
    )
    chained_action: ChainedAction | None = None
    summarizer_agent_id: UUID | None = Field(
        default=None,
        description=(
            "brief.md §3: who summarizes is data, not code. Null falls back to "
            "one system-wide default summarizer agent."
        ),
    )
    context_policy: ContextPolicy = Field(default_factory=ContextPolicy)
    created_at: datetime | None = None
    updated_at: datetime | None = None
