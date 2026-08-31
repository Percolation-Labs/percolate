"""Structured output → automatic follow-on action (``brief.md`` §2, §4, §9).

p8k8's "chained tool call" reframed as **data, not a Python callable lookup**:
the agent row names a target, the runtime calls it, and both the call and its
result are persisted as message rows — with no second LLM round-trip.

This is also how a scheduled consolidation run's result actually lands: the
chained action writes ``entity``/``edge`` rows into ``ai-query-layer``'s tables,
which are not owned by this system (``ontology.md``).
"""

from __future__ import annotations

from typing import Any

import httpx

from ..contracts import ChainedAction, Message, Run, ToolResult
from ..db import Repository

CHAINED_CALL_ID = "chained"
"""The ``tool_call_id`` both rows of a chained action carry.

It is a marker, not a correlation key: these two rows record an action the
*runtime* took, and the persistence adapter uses this value to keep them out of
the history it replays to the model. See ``persistence.to_model_messages``.
"""


async def fire(
    repo: Repository,
    run: Run,
    action: ChainedAction,
    output: dict[str, Any],
    headers: dict[str, str] | None = None,
) -> ToolResult:
    """Dispatch the chained action for a run's structured output.

    Two kinds (``brief.md`` §9 settles that both exist, distinguished by
    ``kind``):

    - ``pg_function`` — a ``SECURITY DEFINER`` call in the same database. Fast,
      transactional with the rows it writes, and on ``brief.md`` §8's "pushed to
      Postgres" side of the line.
    - ``webhook`` — an outbound HTTP call to a PostgREST or external endpoint.
      Structurally the runtime's job, because Postgres cannot make it.

    Failure is classified the same way a tool call is (``brief.md`` §5.2's two
    error kinds), because from the conversation's point of view this *is* a tool
    call — one the runtime issued rather than the model. It is never raised:
    an action that fails leaves an ``is_error`` ``tool_response`` row and a
    finished run, so the failure is inspectable instead of taking the answer
    down with it.

    The webhook leaf carries the run's ambient-context headers, same as any
    outbound tool call — a chained action landing on a PostgREST endpoint needs
    the caller's identity as much as a tool does.
    """
    if action.kind == "pg_function":
        try:
            content = await repo.call_chained_action(action.target, output)
        except LookupError as exc:
            return ToolResult(
                call_id=CHAINED_CALL_ID,
                tool_name=action.target,
                content=str(exc),
                is_error=True,
                error_kind="dispatch_error",
            )
        return ToolResult(
            call_id=CHAINED_CALL_ID, tool_name=action.target, content=content
        )

    try:
        async with httpx.AsyncClient(timeout=30) as client:
            response = await client.post(action.target, json=output, headers=headers or {})
    except httpx.RequestError as exc:
        return ToolResult(
            call_id=CHAINED_CALL_ID,
            tool_name=action.target,
            content=f"{type(exc).__name__}: {exc}",
            is_error=True,
            error_kind="dispatch_error",
        )

    try:
        content = response.json()
    except ValueError:
        content = response.text
    return ToolResult(
        call_id=CHAINED_CALL_ID,
        tool_name=action.target,
        content=content,
        is_error=response.is_error,
        error_kind="tool_error" if response.is_error else None,
    )


def rows_for(run: Run, action: ChainedAction, output: dict[str, Any], result: ToolResult) -> list[Message]:
    """The two message rows a chained action leaves behind.

    Both the call and its result are persisted (``brief.md`` §2) — that is what
    makes an automatic action auditable after the fact instead of an invisible
    side effect. They are slow-path rows, because a chained action has no
    assistant turn to ride along on.
    """
    return [
        Message(
            run_id=run.id,
            session_id=run.session_id,
            role="tool_call",
            content=action.target,
            tool_call_id=CHAINED_CALL_ID,
            tool_calls=[{"tool_name": action.target, "arguments": output}],
        ),
        Message(
            run_id=run.id,
            session_id=run.session_id,
            role="tool_response",
            content=str(result.content),
            tool_call_id=CHAINED_CALL_ID,
            is_error=result.is_error,
            error_kind=result.error_kind,
        ),
    ]
