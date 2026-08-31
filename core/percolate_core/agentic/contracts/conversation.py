"""Conversation-side contracts — sessions, runs, messages, citations.

Spec intent (``brief.md`` §7, ``ontology.md``): the delegation tree, the trace
tree, and the message log are all *rows*, so a multi-agent conversation is
queryable after the fact instead of living in application memory. Every type
here is a row mirror; none of them carries behaviour.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any, Literal
from uuid import UUID, uuid4

from pydantic import BaseModel, Field

from .tools import ToolErrorKind

Role = Literal["system", "user", "assistant", "tool_call", "tool_response", "summary"]
"""``brief.md`` §2/§3/§7. ``tool_call``/``tool_response`` are the slow path —
used whenever a tool call *is* a delegated run. ``summary`` is "not a turn at
all": one row per session, injected at the tail of the reloaded window and
superseded (never appended to) each time the summarizer reruns."""

TriggerKind = Literal["interactive", "scheduled"]
"""``brief.md`` §3. Both kinds are the same table, same config, same messages
shape — a scheduled run just has no live client attached."""

RunStatus = Literal[
    "pending", "running", "succeeded", "failed", "cancelled", "quota_exceeded"
]
"""``quota_exceeded`` is a *terminal status, not a crash* (``brief.md`` §5.1):
whatever partial answer and state already exist stay inspectable."""


class ChunkCitation(BaseModel):
    """Provenance pointing at ``world-model-ingestion``'s own tables.

    ``brief.md`` §5.3: ``resource_chunk`` rows are machine-generated data-plane
    rows, not graph nodes, so a chunk citation never carries a ``node_id``.
    """

    kind: Literal["chunk"] = "chunk"
    resource_type: str
    resource_id: UUID
    chunk_id: UUID | None = None


class NodeCitation(BaseModel):
    """Provenance for a GRAPH-mode result that genuinely *is* a node."""

    kind: Literal["node"] = "node"
    node_id: UUID


Citation = ChunkCitation | NodeCitation
"""A tagged union, deliberately — "not one column trying to mean both things"
(``brief.md`` §5.3)."""


class Session(BaseModel):
    """One AG-UI thread (``threadId``), and the unit access control hangs off.

    RLS-scoped to ``rbac.current_user_id()`` — the runtime reads and writes it
    as an ordinary client, with no privileged backdoor (``brief.md`` §4, §5).
    """

    id: UUID = Field(default_factory=uuid4)
    user_id: UUID | None = None
    agui_thread_id: str | None = None
    title: str | None = None
    created_at: datetime | None = None


class Run(BaseModel):
    """One agent invocation — *including* a delegated sub-agent run.

    ``brief.md`` §4/§7: ``parent_run_id`` makes delegation a queryable tree
    rather than an in-memory call stack, and that tree *is already structurally
    a span tree* — ``parent_span_id`` is simply the parent run's ``span_id``,
    not a second thing to keep in sync, and ``trace_id`` is shared across the
    whole delegation tree.
    """

    id: UUID = Field(default_factory=uuid4)
    session_id: UUID | None = None
    agent_id: UUID | None = None
    agent_name: str | None = None
    owner_id: UUID | None = Field(
        default=None,
        description=(
            "The run's own owner, not derived from the session: a scheduled run "
            "has no session to scope RLS through (brief.md §3)."
        ),
    )
    parent_run_id: UUID | None = None
    delegated_by_message_id: UUID | None = Field(
        default=None, description="The tool_call message that spawned this sub-run."
    )
    trigger_kind: TriggerKind = "interactive"
    workflow_task_id: UUID | None = Field(
        default=None,
        description=(
            "Set only for scheduled runs: the workflow-engine task that "
            "triggered this, so retry/rate-limit/observability come from that "
            "system rather than a second scheduler here (brief.md §3)."
        ),
    )
    trace_id: str | None = None
    span_id: str | None = None
    parent_span_id: str | None = None
    state: dict[str, Any] = Field(
        default_factory=dict,
        description="AG-UI `state`, persisted so a resumed run needs no server affinity.",
    )
    status: RunStatus = "pending"
    depth: int = Field(default=0, description="Derived from parent_run_id; guards §9's depth limit.")
    created_at: datetime | None = None
    finished_at: datetime | None = None


class Message(BaseModel):
    """One row in a run's message log.

    Both persistence granularities live in this one type (``brief.md`` §2):
    the *fast path* rides tool calls along on the assistant row as
    ``tool_calls`` JSONB; the *slow path* emits discrete ``tool_call`` /
    ``tool_response`` rows, which is mandatory when the tool call is itself a
    delegation, because the sub-agent's run has to be independently queryable.
    """

    id: UUID = Field(default_factory=uuid4)
    run_id: UUID | None = None
    session_id: UUID | None = None
    role: Role
    content: str | None = None
    tool_calls: list[dict[str, Any]] = Field(
        default_factory=list, description="Fast path only; empty on slow-path rows."
    )
    tool_call_id: str | None = Field(
        default=None, description="Correlates a tool_response row to its tool_call row."
    )
    is_error: bool = False
    error_kind: ToolErrorKind | None = None
    citations: list[Citation] = Field(
        default_factory=list,
        description=(
            "Assistant messages only, and derived by the runtime from this "
            "turn's tool_response rows — provenance by construction, never "
            "authored by the model (brief.md §5.3)."
        ),
    )
    seq: int | None = None
    created_at: datetime | None = None
