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
import logging
import os
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import Any
from uuid import UUID

from fastapi import APIRouter, FastAPI, HTTPException, Request, Response
from fastapi.responses import JSONResponse, StreamingResponse
from fastapi.routing import APIRoute

from ..core import identity
from ..core.refusal import STATUS as REFUSED_STATUS, refusal
from .contracts import ChatRequest, RequestContext, RunError, Session, to_sse
from .db import PgClient, PgRepository
from .gateway import caller_claims, user_id_of
from .runtime import EventSink, channel, relay
from .sequencer import TurnSequencer
from .settings import Settings
from . import telemetry


@asynccontextmanager
async def lifespan(app: FastAPI, settings: Settings | None = None) -> AsyncIterator[None]:
    """Own the connection pool for as long as the app is up.

    A host app composes this into its own lifespan; ``build_app`` uses it
    directly. Either way the pool is per *process*, not per request — the one
    piece of state this module needs, kept on ``app.state`` so a mounted router
    finds it exactly where a standalone one does.
    """
    resolved = settings or Settings.from_env()
    # Before the pool. Instrumentation is global and `instrument_all` only
    # reaches agents constructed after it runs -- and agents here are built per
    # turn from a row, so an early request would otherwise produce an untraced
    # turn. A no-op unless OTEL_EXPORTER_OTLP_ENDPOINT is set, and it cannot
    # raise: see agentic/telemetry.py.
    if telemetry.start():
        logging.getLogger(__name__).info(
            "OpenTelemetry exporting to %s",
            os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"),
        )
    app.state.percolate_agent_settings = resolved
    app.state.percolate_agent_client = PgClient(resolved)
    await app.state.percolate_agent_client.connect()
    # AFTER THE POOL, BEFORE THE FIRST REQUEST -- and it raises, so the process
    # exits rather than serving. A runtime that cannot open a session as the
    # caller role serves nothing but errors, and it reports them IN BAND: AG-UI
    # answers 200 with a well-formed stream carrying one RUN_ERROR, so
    # `docker compose ps` calls the container healthy and every watchdog agrees
    # with it. REM-10 found the live instance of that only by asserting on the
    # events inside the stream. Failing here costs one connection once and
    # turns a per-turn mystery into a startup message (REM-136).
    await identity.verify_can_open_a_session()
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


class RefusedRoute(APIRoute):
    """A database refusal is a 403 here, on every endpoint of this router.

    ONE MAPPING, at the boundary, rather than a `try` per endpoint. Every
    authorization rule this runtime obeys lives in Postgres (`brief.md` §10.2),
    so any statement any endpoint runs can come back refused -- a turn refused
    by `agentic.start_run`, a sync refused by `agentic.upsert_tool_server`, a
    read refused by a grant. Each of those reached the caller as its own kind
    of wrong answer: a bare 500 for the turn, and `502 Tool discovery failed
    (RaiseError)` for the sync, blaming a tool server that had just answered.

    A route class rather than an exception handler because this router is
    *mountable*: handlers belong to the host app, and a host that mounted this
    router would have had to know to install ours. The route class travels with
    the router (`core/refusal.py` has the rule itself).
    """

    def get_route_handler(self):
        handle = super().get_route_handler()

        async def refusals_are_403(request: Request) -> Response:
            try:
                return await handle(request)
            except Exception as exc:
                refused = refusal(exc)
                if refused is None:
                    raise
                return JSONResponse(refused.body(), status_code=REFUSED_STATUS)

        return refusals_are_403


def router() -> APIRouter:
    """The two endpoints, ready to mount under any prefix."""
    api = APIRouter(route_class=RefusedRoute)

    def _identity(request: Request) -> tuple[dict[str, Any] | None, RequestContext]:
        """Who is calling, and what ambient context they brought.

        Identity comes from the bearer token, verified with the same secret
        PostgREST uses (``gateway.caller_claims``) — never from a header a
        client can set. What comes back is the verified claims, whole, and the
        repository hands them to the database unchanged: a token narrowed to
        one org stays narrowed here. Ambient context comes from ``X-P8-*``
        (``brief.md`` §5.1 item 4) and is trusted only for what it is: context,
        not authorization.
        """
        headers = dict(request.headers)
        claims = caller_claims(headers)
        context = RequestContext.from_headers(headers)
        return claims, context.model_copy(update={"user_id": user_id_of(claims)})

    @api.post("/tools/{name}/sync")
    async def sync_tools(name: str, request: Request) -> dict:
        from .tools import DiscoveryFailed, sync_server
        from .tools.auth import caller_credentials

        client, settings = _state(request)
        claims, _ = _identity(request)
        if claims is None:
            raise HTTPException(401, "a verified bearer token is required")
        repo = PgRepository(client, claims)
        server = await repo.get_tool_server(name)
        if server is None:
            raise HTTPException(404, "tool server not found")
        try:
            with caller_credentials(request.headers.get("authorization"), settings.tool_auth_origins):
                synced = await sync_server(repo, server)
        except DiscoveryFailed as exc:
            # 502 IS ABOUT THE TOOL SERVER, and only the tool server. Catching
            # every exception here made the database refusing this caller a
            # verdict on a service that had already answered -- see
            # DiscoveryFailed. Its text is the failure's type name, because
            # upstream error bodies quote requests and requests carry tokens.
            raise HTTPException(502, f"Tool discovery failed ({exc}); catalogue was not updated") from None
        return {"name": synced.name, "tools": [t.name for t in synced.cached_tools]}

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

    # TWO PATHS, ONE HANDLER, and the second one is the OpenAI-shaped claim
    # made true rather than restated. `/v1/chat/completions` is where every
    # OpenAI client sends a chat request -- the SDK builds it from `base_url`
    # and nothing lets a caller override just the path -- so a runtime that
    # serves only `/chat` cannot be driven by one, whatever the docstring
    # below says. It 404s, which is also what `agent:` workflow steps got:
    # the compiler emits `POST {{env.P8_AGENT_URL}}/v1/chat/completions`.
    @api.post("/v1/chat/completions")
    @api.post("/chat")
    async def chat(request: Request, body: ChatRequest) -> Response:
        """Run one turn: an OpenAI completion, or AG-UI events over SSE.

        ``model`` names an **agent**, not an LLM — which is what lets an
        off-the-shelf OpenAI-shaped client drive this runtime with no bespoke
        fields (``brief.md`` §5.1 item 2). ``tools`` is accepted by the shape
        and ignored: an agent's tool surface is whatever ``tool_servers`` its
        row points at.

        ``stream`` selects between the two, and defaults to ``false`` because
        that is what the shape being borrowed defaults to. It used to default
        to ``true`` and *reject* ``false`` outright, on the reasoning that
        streaming is the one thing PostgREST cannot do and a caller wanting the
        finished answer should read ``messages_api``. That is a good argument
        for why the SSE mode exists and not an argument against the other one,
        and it cost more than it looks:

        * every stock OpenAI client sends ``stream: false``, so the
          compatibility this module's own docstring claims was refused with a
          400 by the line that implemented it;
        * the workflow compiler emits an ``agent:`` step whose http_call reads
          ``choices.0.message.content`` and sets no ``stream`` key at all, so
          **no `agent:` step in any workflow could ever complete** — it got an
          event stream and failed with `output_schema was declared, but the
          result is not JSON`, five attempts, the worker logging `ok` each time
          because the HTTP call genuinely succeeded.

        Buffering here is not a "fake" non-streaming mode: the turn is run to
        completion and its persisted assistant message is returned, which is
        exactly the read from ``messages_api`` that callers were being told to
        do for themselves — one round trip instead of two, and no window in
        which the answer exists and the caller cannot see it yet.
        """
        client, settings = _state(request)
        claims, context = _identity(request)
        if claims is None:
            raise HTTPException(401, "a verified bearer token is required")

        repo = PgRepository(client, claims)
        session = await _resume_or_open(repo, body, request)

        if not body.stream:
            return await _completion(repo, settings, body, context, session, request.headers.get("authorization"))

        stream = await _start_stream(
            client, repo, settings, body, context, session, request.headers.get("authorization")
        )
        return StreamingResponse(
            _forward(stream, session),
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
        claims, _ = _identity(request)
        if claims is None:
            raise HTTPException(401, "a verified bearer token is required")
        repo = PgRepository(client, claims)
        # The ONLY authorization this route has. `relay` LISTENs on a connection
        # opened as the login role, where RLS does not apply and LISTEN checks
        # nothing, so whoever passes this line hears every event of the session.
        #
        # It asked `session_messages(...) is None`, and that method returns a
        # list: RLS turns someone else's session into `[]`, never `None`, so the
        # 404 could not fire and any signed-in caller could listen to any
        # session whose id they had. The test stubbed the method to return
        # `None`, which is the one value the real one never does.
        #
        # `get_session` is the same question `_resume_or_open` asks before a
        # turn -- one row of `agentic.sessions_api`, as the caller -- so "may
        # continue this session" and "may watch it" cannot drift apart. It also
        # answers for a session that has no messages yet, which a message read
        # could not.
        if await repo.get_session(session_id) is None:
            raise HTTPException(404, f"no session {session_id} — it does not exist, or is not yours")

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

    from .. import __version__

    app = FastAPI(title="percolate-agent", version=__version__, lifespan=_lifespan)
    # Standalone deployment policy. A host mounting router()/lifespan() owns
    # its own policy. No cookies and no wildcard; bearer verification and RLS
    # still run in the existing handler, including on cross-origin requests.
    if resolved.cors_origins:
        from fastapi.middleware.cors import CORSMiddleware

        app.add_middleware(
            CORSMiddleware,
            allow_origins=list(resolved.cors_origins),
            allow_methods=["GET", "POST"],
            allow_headers=["Authorization", "Content-Type", "X-P8-Session-Id"],
            expose_headers=["X-P8-Session-Id"],
            allow_credentials=False,
        )
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


async def _completion(
    repo: PgRepository,
    settings: Settings,
    body: ChatRequest,
    context: RequestContext,
    session: Session,
    authorization: str | None = None,
) -> Response:
    """Run the turn to completion and answer in the OpenAI envelope.

    No ``LISTEN`` here, deliberately. The streaming path relays events off the
    NOTIFY channel because a delegated sub-run executing in another task has to
    appear in the parent's stream; a caller who asked for the finished answer
    wants the *result*, and the result is the assistant row the sequencer
    persisted. Reading the return value rather than the channel also means this
    path has no drain window and cannot truncate.

    A FAILED RUN IS AN HTTP ERROR HERE, which the streaming path cannot do:
    once a 200 and the first event have gone out, `RUN_ERROR` is something the
    client has to parse out of the stream. That asymmetry is the reason a
    missing `OPENAI_API_KEY` read as "the runtime is fine, the answer is
    strange" for as long as it did.
    """
    sequencer = TurnSequencer(repo, settings, sink=EventSink(repo), caller_authorization=authorization)
    result = await sequencer.run_turn(
        body.model_copy(update={"session_id": session.id}), context
    )

    status = getattr(result.run, "status", None)
    answer = next(
        (m.content for m in reversed(result.messages or []) if m.role == "assistant"),
        None,
    )
    if status not in (None, "succeeded") or answer is None:
        # 502: this process is working and the thing it called did not. The
        # detail is whatever the run recorded, because "the model refused" and
        # "no credential was configured" are different problems and a caller
        # cannot act on either from a bare 500.
        raise HTTPException(
            502,
            f"run {result.run.id} finished {status or 'without an assistant message'}"
            + (f": {result.run.state['error']}" if result.run.state.get("error") else ""),
        )

    return JSONResponse(
        {
            "id": f"chatcmpl-{result.run.id}",
            "object": "chat.completion",
            "created": int(time.time()),
            # The AGENT name, echoed back, because that is what the caller put
            # in `model`. The LLM actually used is on the agents row and is
            # deliberately not leaked here: swapping it is an UPDATE, and a
            # client that learned the real model name would start depending on
            # a value the deployment considers its own business.
            "model": body.model,
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": answer},
                    "finish_reason": "stop",
                }
            ],
        },
        headers={"X-P8-Session-Id": str(session.id)},
    )


@dataclass
class _Stream:
    """A turn that has started, and the listener carrying its events."""

    conn: Any
    queue: asyncio.Queue
    turn: asyncio.Task
    first: dict[str, Any] | None


async def _start_stream(
    client: PgClient,
    repo: PgRepository,
    settings: Settings,
    body: ChatRequest,
    context: RequestContext,
    session: Session,
    authorization: str | None = None,
) -> _Stream:
    """Start listening, start the turn, and wait for the turn to say anything.

    The order matters: ``LISTEN`` is established *before* the run starts, or the
    first events are published to nobody. And the events forwarded here come off
    the channel, not out of the sequencer — which is why a delegated sub-run
    executing in the gateway process appears in this stream at all.

    THE STATUS CODE IS DECIDED HERE, before the response begins, which is why
    this is not inside the generator. Starlette sends the 200 as soon as a
    ``StreamingResponse`` is returned, so everything that happens afterwards
    can only be said *in* the stream — a caller refused `agents:invoke` got a
    200 and a RUN_ERROR frame, while the same refusal on the non-streaming
    path was a bare 500. So the generator is not built until the turn has
    either published its first event — it is running, and anything later is
    genuinely mid-stream — or ended. A turn the database refused before it
    published anything raises here, and the route class answers 403.

    The wait costs one NOTIFY round trip, and nothing else: RUN_STARTED is
    emitted the moment ``agentic.start_run`` returns, and it is the stream's
    first byte either way.
    """
    queue: asyncio.Queue = asyncio.Queue()
    conn = await client.listen(channel(session.id), queue)
    turn: asyncio.Task | None = None
    try:
        sequencer = TurnSequencer(repo, settings, sink=EventSink(repo), caller_authorization=authorization)
        turn = asyncio.create_task(
            sequencer.run_turn(
                body.model_copy(update={"session_id": session.id}), context
            )
        )
        first = await _first_event(queue, turn)
        failure = turn.exception() if turn.done() and not turn.cancelled() else None
        if first is None and failure is not None and refusal(failure) is not None:
            raise failure
        return _Stream(conn, queue, turn, first)
    except BaseException:
        _unwatched(turn)
        await conn.close()
        raise


async def _first_event(queue: asyncio.Queue, turn: asyncio.Task) -> dict[str, Any] | None:
    """The turn's first published event, or None if it ended without one.

    Whichever comes first. A cancelled getter leaves the queue alone — an item
    already delivered stays in it for the relay to pick up — so this cannot
    swallow the event it was waiting for.
    """
    getter: asyncio.Future = asyncio.ensure_future(queue.get())
    try:
        await asyncio.wait({getter, turn}, return_when=asyncio.FIRST_COMPLETED)
    finally:
        if not getter.done():
            getter.cancel()
    return getter.result() if getter.done() and not getter.cancelled() else None


def _unwatched(turn: asyncio.Task | None) -> None:
    """A client that disconnects mid-turn does not cancel the run — the rows
    still land, which is the point of rows being the record. But nobody is left
    to await the task, so retrieve its exception rather than let it surface as
    "Task exception was never retrieved" at some later GC."""
    if turn is not None and not turn.done():
        turn.add_done_callback(lambda t: t.exception() if not t.cancelled() else None)


async def _forward(stream: _Stream, session: Session) -> AsyncIterator[str]:
    """Forward the started turn's events until it is done."""
    conn, queue, turn = stream.conn, stream.queue, stream.turn
    try:
        if stream.first is not None:
            yield to_sse(stream.first)
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

        if turn.done() and not turn.cancelled() and turn.exception() is not None:
            error = turn.exception()
            # A REFUSAL THAT ARRIVES MID-STREAM cannot change the status line,
            # so it is said in the stream instead — as the database said it,
            # message and hint, rather than as a Python type name. That is the
            # sentence a person can act on ("needs agents:invoke").
            refused = refusal(error)
            yield to_sse(
                RunError(
                    thread_id=session.id,
                    message=str(refused) if refused else f"{type(error).__name__}: {error}",
                )
            )
    finally:
        _unwatched(turn)
        await conn.close()

