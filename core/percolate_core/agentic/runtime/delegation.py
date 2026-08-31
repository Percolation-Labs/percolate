"""Component 3 — declarative multi-agent delegation (``brief.md`` §5.1 item 3).

The mechanism is already in the schema: ``agents`` rows plus ``parent_run_id``.
This module is the part the spec asks to be "a *tested* reference
implementation, not only a schema" — ``sequence.md``'s Gate 3 exists to prove a
multi-level delegation tree round-trips before anything builds on top of it.

Three invariants worth checking at review time:

1. A delegation **is a tool call**. It produces a ``tool_call`` message, forcing
   the slow path (``brief.md`` §2), and the child's whole streamed turn is the
   payload of a ``ToolCallStart``/``ToolCallEnd`` pair in the parent's AG-UI
   stream — no new event types (``brief.md`` §5.1 item 2).
2. The child ``runs`` row carries ``parent_run_id`` **and**
   ``delegated_by_message_id``, so the tree is walkable from either direction.
3. ``parent_span_id`` is the parent run's ``span_id`` — the delegation tree and
   the trace tree are the same tree (``brief.md`` §7).

**How an agent declares who it may delegate to** — the gap this module raised,
now settled in ``brief.md`` §5.1 item 3: the runtime exposes its own agents as
an MCP server (``p8agentic.gateway``), so delegation is an ordinary
``tool_servers`` reference with an ordinary per-agent allowlist. Nothing in the
tool path knows a delegation is happening, which is exactly what keeps "zero
built-in tools" true rather than nearly true.
"""

from __future__ import annotations

from uuid import UUID

from ..contracts import RequestContext, Run
from ..settings import Settings

# There is deliberately no constant for the gateway's server name here. The
# runtime does not special-case that row — it is an ordinary ``tool_servers``
# entry an agent references like any other, and a constant naming it would be
# the first crack in that.

TOOL_PREFIX = "agent__"
"""How the gateway names an agent-as-tool. A prefix rather than the bare agent
name so a delegation is legible in a message row and in an AG-UI stream without
having to cross-reference the agents table."""

SESSION_HEADER = "x-p8-session-id"
PARENT_RUN_HEADER = "x-p8-parent-run-id"
DELEGATED_BY_HEADER = "x-p8-delegated-by-message-id"


# There is no `is_delegation(name)` here any more, deliberately. Delegation was
# detected by the `agent__` prefix, which made a *naming convention* decide the
# persistence granularity and who receives a delegated-by header — so any
# registered MCP server could claim the namespace, and a server named `agent`
# fell into it by accident when collision-prefixing. It is now read from
# `tool_servers.serves_agents` via `ResolvedToolset.delegations()`. The prefix
# survives only as naming, so a delegation is legible in a row and in a stream.


def outbound_headers(context: RequestContext, run: Run) -> dict[str, str]:
    """The headers a delegated call carries to the gateway.

    Ambient context (``brief.md`` §5.1 item 4) plus the two facts that make the
    child a *child*: which session it belongs to, and which run spawned it. The
    gateway needs nothing else — depth, ``parent_span_id`` and the inherited
    ``trace_id`` are all derived in ``agentic.start_run()`` from the parent row,
    so a caller cannot assert a shallower depth or a different parent span than
    the database will compute.
    """
    headers = context.to_headers()
    if run.session_id:
        headers[SESSION_HEADER] = str(run.session_id)
    headers[PARENT_RUN_HEADER] = str(run.id)
    return headers


def inbound_delegation(
    headers: dict[str, str],
) -> tuple[RequestContext, UUID | None, UUID | None, UUID | None]:
    """The gateway's side of the same contract."""
    lower = {k.lower(): v for k, v in headers.items()}
    # The two routing headers are not ambient context — they are how the child
    # is attached to the tree — so they are removed before parsing rather than
    # ending up in ``extra`` and being injected into the sub-agent's prompt.
    routing = (SESSION_HEADER, PARENT_RUN_HEADER, DELEGATED_BY_HEADER)
    context = RequestContext.from_headers(
        {k: v for k, v in headers.items() if k.lower() not in routing}
    )
    session = lower.get(SESSION_HEADER)
    parent = lower.get(PARENT_RUN_HEADER)
    delegated_by = lower.get(DELEGATED_BY_HEADER)
    return (
        context,
        UUID(session) if session else None,
        UUID(parent) if parent else None,
        UUID(delegated_by) if delegated_by else None,
    )


def child_run(parent: Run, agent_id, agent_name: str, delegated_by_message_id, span_id: str) -> Run:
    """Build the child ``runs`` row for one delegation.

    Everything inherited here is inherited *because the spec says the trees are
    the same tree*, not as a convenience: same ``session_id`` (the conversation
    is one thread), same ``trace_id`` (one trace per top-level session or
    scheduled trigger), and ``parent_span_id`` taken directly from the parent's
    ``span_id``.
    """
    return Run(
        session_id=parent.session_id,
        agent_id=agent_id,
        agent_name=agent_name,
        parent_run_id=parent.id,
        delegated_by_message_id=delegated_by_message_id,
        trigger_kind=parent.trigger_kind,
        workflow_task_id=parent.workflow_task_id,
        trace_id=parent.trace_id,
        span_id=span_id,
        parent_span_id=parent.span_id,
        depth=parent.depth + 1,
        status="pending",
    )


def check_depth(run: Run, settings: Settings) -> None:
    """Refuse a delegation past the configured depth.

    OPEN (``brief.md`` §9): "How deep a delegation tree is allowed to go before
    it's treated as a bug rather than a feature — needs a hard limit, decided
    alongside ``workflow-engine``'s own cascading-cancellation limits since the
    failure mode rhymes." The limit exists here so the failure is a clean,
    inspectable terminal status rather than an unbounded recursion; the *number*
    is still undecided.
    """
    if run.depth >= settings.max_delegation_depth:
        raise RecursionError(
            f"delegation depth {run.depth} reached the limit "
            f"({settings.max_delegation_depth}); brief.md §9 leaves the real limit open"
        )
