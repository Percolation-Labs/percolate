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
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from uuid import UUID

from fastapi import APIRouter, FastAPI, HTTPException, Request, Response
from fastapi.responses import JSONResponse, StreamingResponse

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

    @api.post("/tools/{name}/sync")
    async def sync_tools(name: str, request: Request) -> dict:
        from .tools import sync_server
        from .tools.auth import caller_credentials

        client, settings = _state(request)
        user_id, _ = _identity(request)
        if user_id is None:
            raise HTTPException(401, "a verified bearer token is required")
        repo = PgRepository(client, user_id)
        server = await repo.get_tool_server(name)
        if server is None:
            raise HTTPException(404, "tool server not found")
        try:
            with caller_credentials(request.headers.get("authorization"), settings.tool_auth_origins):
                synced = await sync_server(repo, server)
        except Exception as exc:
            # Do not return upstream headers or credential-bearing error text.
            raise HTTPException(502, f"Tool discovery failed ({type(exc).__name__}); catalogue was not updated") from None
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
        user_id, context = _identity(request)
        if user_id is None:
            raise HTTPException(401, "a verified bearer token is required")

        repo = PgRepository(client, user_id)
        session = await _resume_or_open(repo, body, request)

        if not body.stream:
            return await _completion(repo, settings, body, context, session, request.headers.get("authorization"))

        return StreamingResponse(
            _run_and_stream(client, repo, settings, body, context, session, request.headers.get("authorization")),
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


async def _run_and_stream(
    client: PgClient,
    repo: PgRepository,
    settings: Settings,
    body: ChatRequest,
    context: RequestContext,
    session: Session,
    authorization: str | None = None,
) -> AsyncIterator[str]:
    """Start listening, start the turn, forward until the turn is done.

    The order matters: ``LISTEN`` is established *before* the run starts, or the
    first events are published to nobody. And the events forwarded here come off
    the channel, not out of the sequencer — which is why a delegated sub-run
    executing in the gateway process appears in this stream at all.
    """
    queue: asyncio.Queue = asyncio.Queue()
    conn = await client.listen(channel(session.id), queue)
    sequencer = TurnSequencer(repo, settings, sink=EventSink(repo), caller_authorization=authorization)
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

