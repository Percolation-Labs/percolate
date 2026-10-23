"""The agentic runtime's phase gates, as data this package reports on: the order it is built in, and what proves each step.

The point of writing the gates down here rather than leaving them in prose: the
runtime can then answer "which gates does this actually pass today, and what is
missing for the rest" mechanically (``percolate agent gates``), which is the honest
version of a progress report — and it makes the reason for that order survive
contact with an implementation.

``proves`` names the sequencer step(s) or module(s) a gate exercises, so a gate
that no code path touches is visibly a gate nothing is being built toward.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class Gate:
    number: int
    phase: str
    criterion: str
    proves: str
    status: str
    blocker: str = ""


GATES: tuple[Gate, ...] = (
    Gate(
        0,
        "Schema",
        "pgTAP: delegation tree insert/query fixtures",
        "specs/agentic/schema.sql, loaded by dev/db.sh",
        "passing (by hand)",
        "Asserted by dev/verify.py, not by pgTAP fixtures yet.",
    ),
    Gate(
        1,
        "REST CRUD",
        "RLS test: user A cannot read user B's sessions",
        "PostgREST over the *_api views; PgClient.as_user for every statement",
        "passing",
        "Asserted in dev/e2e.sh as the real `authenticated` role: the second "
        "user sees 0 sessions and 0 messages of the first user's conversation.",
    ),
    Gate(
        2,
        "Fast-path persistence",
        "round-trip a full turn in one RPC call",
        "persistence.build_turn_rows + agentic.persist_turn(jsonb)",
        "passing",
        "",
    ),
    Gate(
        3,
        "Slow-path + delegation",
        "3-level delegation tree, queried via ai-query-layer GRAPH mode",
        "gateway + McpProvider + delegation.child_run; dev/e2e.sh",
        "passing (tree), pending (GRAPH)",
        "Tree, span tree and back-references verified in SQL. GRAPH mode now "
        "exists in ai-query-layer; the delegation tree has not been read through it yet.",
    ),
    Gate(
        4,
        "Chained action",
        "structured output triggers action, both persisted as rows",
        "chained_action.fire + rows_for; agentic.apply_summary as the target",
        "passing",
        "Verified end to end: a structured-output summarizer run fires "
        "agentic.apply_summary, which writes the session's summary row.",
    ),
    Gate(
        5,
        "Streaming",
        "an AG-UI client observes a live delegated run end to end",
        "engine.map_stream_event → EventSink → pg_notify → PgClient.listen",
        "passing",
        "Observed via the CLI relay; the FastAPI SSE bridge is the same bytes.",
    ),
    Gate(
        6,
        "Background/batch",
        "a scheduled run produces a queryable insight edge, no human session",
        "start_workflow -> http_call task -> /internal/run -> scheduled run",
        "passing (summarization)",
        "The reference background workflow (summarize_session_window) runs end "
        "to end and completes its own task. The ai-query-layer node and edge "
        "tables exist; consolidating insights into them is not built yet.",
    ),
    Gate(
        7,
        "Agent runtime",
        "passes Gate 3/4/5 fixtures through the contract only; a migrated agent "
        "calls a real bound OpenAPI tool end to end",
        "TurnSequencer via Repository only; schema document → agents row",
        "passing",
        "dev/verify.py asserts Gate 3/4/5 behaviour against a live LLM through "
        "the contract only. §6 migration tooling is still the CLI, not a "
        "versioned file format.",
    ),
)


def summary() -> str:
    """One line per gate — what the CLI prints."""
    width = max(len(g.phase) for g in GATES)
    return "\n".join(
        f"Gate {g.number}  {g.phase.ljust(width)}  {g.status:<12} {g.criterion}"
        for g in GATES
    )
