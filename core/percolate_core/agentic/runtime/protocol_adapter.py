"""Component 2 — the two protocol adapters (``brief.md`` §5.1 item 2).

Inbound: an OpenAI-chat-completions-shaped request, "so nothing upstream needs a
bespoke client just to talk to this runtime."

Outbound: AG-UI events — "this system's richer wire protocol on the way out, the
common one on the way in."

The asymmetry is the design, not an oversight.
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any
from uuid import UUID

from ..contracts import AgentSpec, AGUIEvent, ChatRequest
from ..db import PgClient, Repository


def latest_user_prompt(request: ChatRequest) -> str:
    """The turn's actual input.

    Note what this does *not* do: trust the client's full ``messages`` array as
    history. History comes from Postgres via the persistence adapter's window
    (``brief.md`` §5.1) — a client cannot rewrite a session's past by sending a
    different array, which matters once RLS is the thing protecting a
    conversation.
    """
    for message in reversed(request.messages):
        if message.role == "user" and message.content:
            return message.content
    return ""


def apply_response_format(agent: AgentSpec, request: ChatRequest) -> AgentSpec:
    """Let one request ask for a shape, without editing the agent row.

    ``response_format`` is OpenAI's own field for this and it is borrowed
    unchanged, so a stock client asking for structured output gets it. The
    row's ``structured_output_schema`` stays the default for every caller who
    does not ask.

    WHY IT HAD TO EXIST. A workflow's ``agent:`` step may declare
    ``output_schema:``, and that schema was used to VALIDATE the answer and
    never to ASK for it -- the agent ran against whatever its own row said and
    was then judged against a shape nobody had mentioned to it. The README's
    front-page example is exactly that: a `verdict` constrained to
    ``[SAFETY, FINANCE, OTHER]`` against an agent whose row returns free text,
    so the step failed on

        verdict: value "Port state control raised deficiency PSC-441 ..." is
        not one of ["SAFETY", "FINANCE", "OTHER"]

    which is the validator working correctly on a question the model was never
    asked. A declared shape that only judges is a shape that only fails.

    Returns the agent unchanged when nothing is requested, so this is inert for
    every existing caller.
    """
    # Authoring clients can narrow a turn to a proposal. This must be enforced
    # here, before binding tools, rather than entrusted to a prompt. A chained
    # action would also execute the proposal, so it is disabled for this turn.
    updates = {}
    schema = (request.response_format or {}).get("json_schema", {}).get("schema")
    if schema:
        updates['structured_output_schema'] = schema
    if request.tool_choice == 'none':
        updates.update(tools=[], chained_action=None)
    return agent.model_copy(update=updates) if updates else agent


class EventSink:
    """Where AG-UI events go on their way to a client.

    ``brief.md`` §4/§8: the durable path is ``pg_notify`` on the session's
    channel, relayed by the FastAPI SSE bridge — the same NOTIFY-relay pattern
    as ``workflow-engine`` and ``user-rbac``, not a new mechanism. The CLI uses
    the same sink with a local collector, which is what lets the CLI and the
    eventual HTTP surface prove the *same* event sequence.
    """

    def __init__(self, repo: Repository | None = None, collect: bool = True) -> None:
        self.repo = repo
        self.events: list[AGUIEvent] = []
        self._collect = collect
        self._publish: Any = None

    @asynccontextmanager
    async def publishing(self) -> AsyncIterator[None]:
        """Hold one connection for the turn instead of taking one per event.

        Falls back to the per-event path when the repository has no client (the
        in-memory one), so the fast path is an optimisation of the same
        behaviour rather than a second one.
        """
        client = getattr(self.repo, "client", None)
        if client is None:
            yield
            return
        async with client.publisher(getattr(self.repo, "claims", None)) as publish:
            self._publish = publish
            try:
                yield
            finally:
                self._publish = None

    async def emit(self, event: AGUIEvent) -> None:
        if self._collect:
            self.events.append(event)
        if event.thread_id is None:
            return
        if self._publish is not None:
            await self._publish(channel(event.thread_id), event.model_dump_json())
        elif self.repo is not None:
            await self.repo.notify(channel(event.thread_id), event.model_dump_json())


def channel(session_id: UUID) -> str:
    """The NOTIFY channel for one session. One channel per thread, so a listener
    subscribes to exactly the conversation it is watching."""
    return f"agui_{session_id.hex}"


async def relay(client: PgClient, session_id: UUID) -> AsyncIterator[dict[str, Any]]:
    """``LISTEN`` on a session's channel and yield everything published there.

    Yields raw JSON objects rather than parsed event models, deliberately: the
    relay's job is to forward frames it did not author, and a typed parse here
    would mean this file needs updating every time an event type is added —
    turning a dumb pipe into a second place the protocol is defined.

    Both kinds of message arrive here (``brief.md`` §4): AG-UI events published
    by whichever run produced them — parent and delegated children alike, since
    they all share one channel — and ``MESSAGE_PERSISTED`` checkpoints from the
    ``messages`` trigger, which is what lets a client that missed a delta resume
    from the row.

    The FastAPI SSE bridge is this loop plus ``to_sse``; ``percolate agent listen`` is
    this loop plus a console. Neither adds protocol logic, which is the point.
    """
    queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
    conn = await client.listen(channel(session_id), queue)
    try:
        while True:
            yield await queue.get()
    finally:
        await conn.close()
