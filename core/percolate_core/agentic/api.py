"""The HTTP surface — one POST that streams, and one GET that replays.

``brief.md`` §4/§8 give FastAPI exactly one job here: "the SSE/WebSocket fan-out
(FastAPI, relaying Postgres NOTIFY)". CRUD is PostgREST's — `sessions_api`,
`runs_api`, `messages_api`, `agents_api` are already a REST API, and
hand-rolling a second one over the same tables is the thing this collection's
ground rules explicitly rule out. So this module is deliberately two endpoints:

    POST /chat                      OpenAI-shaped in, AG-UI events out (SSE)
    GET  /sessions/{id}/events      the same stream, for an observer or a reconnect

**Mountable, not just runnable.** The endpoints live on a ``router()`` and the
pool lives in a ``lifespan()``; ``build_app()`` is the twenty lines that put
them in an app of their own. A larger service — the ``p8`` image, which also
carries the Content Server — mounts the same two things under whatever prefix
it likes, and gets identical behaviour, because standalone mode is a *caller*
of the mountable pieces rather than a second implementation of them.

The second endpoint is not a convenience. It is the proof that the stream is a
*relay*, not a side effect of the request that started the run: a client that
drops mid-turn reconnects here and keeps receiving, and a second client can
watch a conversation it did not start. Both endpoints read from the same
``NOTIFY`` channel, so both see a delegation tree's parent and child events
interleaved, correlated by ``run_id``.
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from uuid import UUID

from fastapi import APIRouter, FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse

from .contracts import ChatRequest, RequestContext, RunError, Session, to_sse
from .db import PgClient, PgRepository
from .gateway import caller_id
from .runtime import EventSink, channel, relay
from .sequencer import TurnSequencer
from .settings import Settings


@asynccontextmanager
async def lifespan(app: FastAPI, settings: Settings | None = None) -> AsyncIterator[None]:
    """Own the connection pool for as long as the app is up.

    A host app composes this into its own lifespan; ``build_app`` uses it
    directly. Either way the pool is per *process*, not per request — the one
    piece of state this module needs, kept on ``app.state`` so a mounted router
    finds it exactly where a standalone one does.
    """
    resolved = settings or Settings.from_env()
    app.state.percolate_agent_settings = resolved
    app.state.percolate_agent_client = PgClient(resolved)
    await app.state.percolate_agent_client.connect()
    try:
        yield
    finally:
        await app.state.percolate_agent_client.close()


def _state(request: Request) -> tuple[PgClient, Settings]:
    """The pool and settings, from wherever this router was mounted.

    Namespaced attribute names, deliberately: in a mounted deployment
    ``app.state`` belongs to the host, and a module that claims ``state.client``
    is a module that collides with the next one to do the same.
    """
    app = request.app
    client = getattr(app.state, "percolate_agent_client", None)
    if client is None:
        raise HTTPException(
            500,
            "the agent runtime is mounted but its lifespan is not installed — compose "
            "percolate_core.agentic.api.lifespan into the host app's lifespan",
        )
    return client, app.state.percolate_agent_settings


def router() -> APIRouter:
    """The two endpoints, ready to mount under any prefix."""
    api = APIRouter()

    def _identity(request: Request) -> tuple[UUID | None, RequestContext]:
        """Who is calling, and what ambient context they brought.

        Identity comes from the bearer token, verified with the same secret
        PostgREST uses (``gateway.caller_id``) — never from a header a client
        can set. Ambient context comes from ``X-P8-*`` (``brief.md`` §5.1 item
        4) and is trusted only for what it is: context, not authorization.
        """
        headers = dict(request.headers)
        user_id = caller_id(headers)
        context = RequestContext.from_headers(headers)
        return user_id, context.model_copy(update={"user_id": user_id})

    @api.get("/_build")
    async def build() -> dict[str, str]:
        """Which source this process is running.

        A stale server fails in the shape of a bug — a tool that "returned an
        unexpected keyword argument", a run stuck in `running`. This makes
        "you are talking to yesterday's code" a one-line answer instead of a
        debugging session.
        """
        from . import build_fingerprint

        return {"build": build_fingerprint()}

    @api.post("/chat")
    async def chat(request: Request, body: ChatRequest) -> StreamingResponse:
        """Run one turn and stream it as AG-UI events.

        ``model`` names an **agent**, not an LLM — which is what lets an
        off-the-shelf OpenAI-shaped client drive this runtime with no bespoke
        fields (``brief.md`` §5.1 item 2). ``tools`` is accepted by the shape
        and ignored: an agent's tool surface is whatever ``tool_servers`` its
        row points at.

        ``stream: false`` is not supported and says so, rather than silently
        buffering: this endpoint exists *because* streaming is the one thing
        PostgREST cannot do. A caller who wants the finished answer reads
        ``messages_api``, which is a better answer than a fake non-streaming
        mode.
        """
        client, settings = _state(request)
        user_id, context = _identity(request)
        if user_id is None:
            raise HTTPException(401, "a verified bearer token is required")
        if not body.stream:
            raise HTTPException(
                400, "stream=false is not supported; read messages_api for the finished turn"
            )

        repo = PgRepository(client, user_id)
        session = await _resume_or_open(repo, body, request)

        return StreamingResponse(
            _run_and_stream(client, repo, settings, body, context, session),
            media_type="text/event-stream",
            headers={
                # The session is in the response headers as well as in every
                # event, so a client can reconnect to GET /sessions/{id}/events
                # without having to parse the stream it just lost.
                "X-P8-Session-Id": str(session.id),
                "Cache-Control": "no-cache",
                "X-Accel-Buffering": "no",
            },
        )

    @api.get("/sessions/{session_id}/events")
    async def events(session_id: UUID, request: Request) -> StreamingResponse:
        """Relay a session's stream to an observer. Nothing is run."""
        client, _settings = _state(request)
        user_id, _ = _identity(request)
        if user_id is None:
            raise HTTPException(401, "a verified bearer token is required")
        repo = PgRepository(client, user_id)
        if await repo.session_messages(session_id) is None:  # pragma: no cover
            raise HTTPException(404, "no such session")

        async def _observe() -> AsyncIterator[str]:
            async for payload in relay(client, session_id):
                yield to_sse(payload)

        return StreamingResponse(_observe(), media_type="text/event-stream")

    return api


DRAIN_SECONDS = 0.5
"""How long to keep reading the channel after the turn returns. Half a second is
far longer than local NOTIFY delivery and short enough that a client is not left
waiting on a stream that is already finished."""


def build_app(settings: Settings | None = None) -> FastAPI:
    """Standalone mode: an app whose only job is to host this router.

    Thin on purpose. Everything it does — install the lifespan, include the
    router — a host app does the same way, so there is no behaviour that only
    exists when this subsystem runs alone.
    """
    resolved = settings or Settings.from_env()

    @asynccontextmanager
    async def _lifespan(app: FastAPI) -> AsyncIterator[None]:
        async with lifespan(app, resolved):
            yield

    app = FastAPI(title="percolate-agent", version="0.1.0", lifespan=_lifespan)
    app.include_router(router())
    return app


async def _resume_or_open(
    repo: PgRepository, body: ChatRequest, request: Request
) -> Session:
    """Continue the named conversation, or start one.

    The id may arrive in the body (`session_id`) **or** as the
    `X-P8-Session-Id` header, and the header is the one that matters: the
    inbound contract is the OpenAI chat shape (`brief.md` §5.1 item 2), which
    has nowhere to put a thread id, so a client using an off-the-shelf SDK can
    only reach for a header. It is the same name the response sends back, so
    resuming is echoing what you were given.

    An unknown or someone else's id fails **here**, with a status code, rather
    than mid-stream: once the response has begun the status is already sent,
    and "your session id was wrong" is not something a client should have to
    parse out of an event.
    """
    header = request.headers.get("x-p8-session-id")
    session_id = body.session_id or (UUID(header) if header else None)
    if session_id is None:
        return await repo.create_session(Session())

    session = await repo.get_session(session_id)
    if session is None:
        raise HTTPException(404, f"no session {session_id} — it does not exist, or is not yours")
    return session


async def _run_and_stream(
    client: PgClient,
    repo: PgRepository,
    settings: Settings,
    body: ChatRequest,
    context: RequestContext,
    session: Session,
) -> AsyncIterator[str]:
    """Start listening, start the turn, forward until the turn is done.

    The order matters: ``LISTEN`` is established *before* the run starts, or the
    first events are published to nobody. And the events forwarded here come off
    the channel, not out of the sequencer — which is why a delegated sub-run
    executing in the gateway process appears in this stream at all.
    """
    queue: asyncio.Queue = asyncio.Queue()
    conn = await client.listen(channel(session.id), queue)
    sequencer = TurnSequencer(repo, settings, sink=EventSink(repo))
    turn = asyncio.create_task(
        sequencer.run_turn(
            body.model_copy(update={"session_id": session.id}), context
        )
    )
    try:
        drain_until: float | None = None
        loop = asyncio.get_running_loop()
        while True:
            if turn.done():
                # A NOTIFY is published on the *runtime's* connection and
                # delivered on the *listener's*, so "the turn returned" does not
                # mean "the events arrived". Closing on `done() and empty()`
                # dropped whatever was still in flight — most often
                # RUN_FINISHED, since it is emitted last.
                if drain_until is None:
                    drain_until = loop.time() + DRAIN_SECONDS
                if queue.empty() and loop.time() >= drain_until:
                    break
            try:
                payload = await asyncio.wait_for(queue.get(), timeout=0.05)
            except TimeoutError:
                continue
            yield to_sse(payload)

        if turn.exception() is not None:
            error = turn.exception()
            yield to_sse(
                RunError(thread_id=session.id, message=f"{type(error).__name__}: {error}")
            )
    finally:
        # A client that disconnects mid-turn does not cancel the run — the rows
        # still land, which is the point of rows being the record. But nobody is
        # left to await the task, so retrieve its exception rather than let it
        # surface as "Task exception was never retrieved" at some later GC.
        if not turn.done():
            turn.add_done_callback(lambda t: t.exception() if not t.cancelled() else None)
        await conn.close()


