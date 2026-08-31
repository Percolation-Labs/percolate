"""The agent gateway — this runtime's own agents, exposed as an MCP server.

``brief.md`` §5.1 item 3. This is what makes delegation possible *without* a
built-in tool: an agent that may delegate simply references this server in its
``agents.tools``, with an optional allowlist naming which agents it may reach.
Discovery is ``list_tools``, invocation is ``call_tool``, and the MCP provider
that talks to it does not know it is talking to itself.

Two things worth checking at review time, because both are load-bearing:

1. **The child run is created by the database, from the parent.** The gateway
   passes ``parent_run_id`` and lets ``agentic.start_run()`` derive ``depth``,
   ``parent_span_id`` and the inherited ``trace_id`` — a caller cannot assert a
   shallower depth or a different parent span than the tree actually has.
2. **The child streams to the same session channel.** Nothing fans events back
   into the parent's stream, because there is no parent stream to fan into: both
   runs publish to ``agui_<session_id>``, tagged with their own ``run_id``. That
   is the whole of ``brief.md`` §4's multiplexing claim, and it is why this file
   contains no queue, no ``ContextVar``, and no event forwarding.

Run it: ``percolate agent gateway`` (defaults to ``127.0.0.1:8765``).
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import json
import os
import time
from typing import Any
from uuid import UUID

from .contracts import ChatRequest, InboundMessage, RequestContext
from .db import connected
from .runtime import EventSink, inbound_delegation
from .runtime.delegation import TOOL_PREFIX
from .settings import Settings

LEEWAY_SECONDS = 30
"""Clock skew tolerance on `exp`/`nbf`, matching what JWT verifiers conventionally
allow. Not a grace period for expired sessions — thirty seconds, not thirty
minutes."""


def caller_id(headers: dict[str, str]) -> UUID | None:
    """Who is making this call, from the bearer token — verified, not trusted.

    The same HS256 JWT ``user-rbac`` mints and PostgREST verifies, checked here
    with the same shared secret. Reading ``sub`` without verifying the signature
    would have been three lines shorter and would have turned the gateway into
    an authentication bypass for every agent in the database, which is not a
    shortcut an experiment gets to take either.

    Falls back to the ``X-P8-User-Id`` header only when no secret is configured
    at all — a local, no-auth loop — and that fallback is why the gateway must
    never be exposed without ``P8_JWT_SECRET`` set.
    """
    secret = os.getenv("P8_JWT_SECRET")
    lower = {k.lower(): v for k, v in headers.items()}
    token = lower.get("authorization", "").removeprefix("Bearer ").strip()

    if not secret:
        raw = lower.get("x-p8-user-id")
        return UUID(raw) if raw else None
    if not token:
        return None

    try:
        header_b64, payload_b64, signature_b64 = token.split(".")
        header = json.loads(_b64url_decode(header_b64))
        # Pin the algorithm from *our* side. A verifier that trusts the token's
        # own header is the classic JWT confusion bug; even where HS256-only
        # verification makes it unexploitable, checking is one line.
        if header.get("alg") != "HS256":
            return None
        signing_input = f"{header_b64}.{payload_b64}".encode()
        expected = hmac.new(secret.encode(), signing_input, hashlib.sha256).digest()
        if not hmac.compare_digest(expected, _b64url_decode(signature_b64)):
            return None
        claims = json.loads(_b64url_decode(payload_b64))
    except (ValueError, KeyError):
        return None

    # A valid signature is not a valid token. Verifying the HMAC and skipping
    # `exp` makes every token this system ever issued permanent — and makes this
    # runtime *weaker* than the PostgREST it sits beside, which rejects the same
    # token. Found by presenting a 24-hour-stale token: PostgREST 401, this 200.
    now = time.time()
    exp, nbf = claims.get("exp"), claims.get("nbf")
    if exp is not None and now >= float(exp) + LEEWAY_SECONDS:
        return None
    if nbf is not None and now < float(nbf) - LEEWAY_SECONDS:
        return None

    sub = claims.get("sub")
    return UUID(sub) if sub else None


def _b64url_decode(segment: str) -> bytes:
    return base64.urlsafe_b64decode(segment + "=" * (-len(segment) % 4))


def build_server(settings: Settings | None = None) -> Any:
    """An MCP server with one tool per ``agents`` row.

    Tools are enumerated from the database on every ``list_tools`` rather than
    registered once at startup, because agents are rows: adding one is an insert
    (``brief.md`` §2), and a gateway that had to be restarted to see a new agent
    would quietly reintroduce "adding an agent is a deploy".
    """
    from mcp.server.mcpserver import MCPServer
    from mcp.types import CallToolResult, TextContent
    from mcp.types import Tool as MCPTool

    resolved = settings or Settings.from_env()

    class AgentGateway(MCPServer):
        """The MCP surface of this runtime's own agents."""

        async def list_tools(self) -> list[MCPTool]:
            async with connected(resolved, None) as repo:
                agents = await repo.list_agents()
            return [
                MCPTool(
                    name=f"{TOOL_PREFIX}{agent.name}",
                    description=(
                        (agent.system_prompt.splitlines() or [""])[0]
                        or f"Delegate a task to the {agent.name} agent."
                    ),
                    input_schema={
                        "type": "object",
                        "properties": {
                            "prompt": {
                                "type": "string",
                                "description": "What this agent should do.",
                            }
                        },
                        "required": ["prompt"],
                    },
                )
                for agent in agents
            ]

        async def call_tool(
            self, name: str, arguments: dict[str, Any], context: Any = None
        ) -> CallToolResult:
            headers = dict(getattr(context, "headers", None) or {}) if context else {}
            answer = await run_delegated(
                resolved,
                agent_name=name.removeprefix(TOOL_PREFIX),
                prompt=arguments.get("prompt", ""),
                headers=headers,
            )
            return CallToolResult(content=[TextContent(type="text", text=answer)])

    server = AgentGateway(
        name="p8-agents",
        instructions=(
            "Delegate to another agent in this Postgres-backed runtime. Each "
            "tool is one agents row; calling it runs a full sub-agent turn "
            "whose messages, run row and AG-UI events land in the same session."
        ),
    )

    @server.custom_route("/_build", methods=["GET"])
    async def _build(request: Any) -> Any:
        """Which source this process is running. See ``build_fingerprint``."""
        from starlette.responses import JSONResponse

        from . import build_fingerprint

        return JSONResponse({"build": build_fingerprint()})

    @server.custom_route("/internal/run", methods=["POST"])
    async def _trigger(request: Any) -> Any:
        """The scheduled-run trigger endpoint (``brief.md`` §3).

        "A ``mode: async`` ``http_call`` task dispatched at the runtime's
        internal trigger endpoint — **not the public AG-UI surface** — carrying
        the triggering task's id. The runtime creates the ``runs`` row
        (``workflow_task_id`` = that task's id), executes, and calls
        ``complete_task(task_id, output)`` itself once the run and any
        ``chained_action`` it fires finish."

        Separate from the MCP surface for exactly the reason the brief gives:
        this is machine-to-machine plumbing between two subsystems, not
        something a conversation client should be able to reach.
        """
        from starlette.responses import JSONResponse

        body = await request.json()
        # `mode: "async"` means dispatch-and-return (workflow-engine/spec.md
        # §14): the executor's job is only to hand the work over, and this
        # runtime completes the task itself when the run is genuinely done.
        # Awaiting the run here instead looks harmless and is not -- the
        # executor then parks the task in `waiting_external` *after* the
        # runtime already completed it, overwriting `done`. Found by running it.
        task = asyncio.create_task(_dispatch(
            resolved,
            task_id=UUID(body["workflow_task_id"]),
            agent_name=body["input"]["agent"],
            session_id=UUID(body["input"]["session_id"]) if body["input"].get("session_id") else None,
            prompt=body["input"].get("prompt", ""),
            for_agent=body["input"].get("for_agent"),
            headers=dict(request.headers),
        ))
        _in_flight.add(task)
        task.add_done_callback(_in_flight.discard)
        return JSONResponse({"accepted": True, "workflow_task_id": body["workflow_task_id"]}, 202)

    return server


_in_flight: set[Any] = set()
"""Strong references to running background dispatches.

asyncio only holds a weak reference to a task; without this, a scheduled run can
be garbage-collected mid-flight and simply vanish -- no error, no completion,
and a workflow task that waits forever.
"""


async def _dispatch(settings: Settings, **kwargs: Any) -> None:
    """Run a scheduled turn in the background, failing its task if it raises.

    A run that dies must not leave the task in `waiting_external` forever: the
    task is failed, which is what hands it back to workflow-engine's retry
    (`max_attempts`, backoff) instead of inventing a retry policy here.
    """
    try:
        await run_scheduled(settings, **kwargs)
    except Exception as exc:  # noqa: BLE001 - any failure must reach the task
        import traceback

        traceback.print_exc()
        async with (
            connected(settings, None) as repo,
            repo.client.as_user(None, role="worker") as conn,
        ):
            await conn.execute(
                "select workflow.fail_task($1, $2::jsonb)",
                kwargs["task_id"],
                {"error": f"{type(exc).__name__}: {exc}"},
            )


async def run_scheduled(
    settings: Settings,
    *,
    task_id: UUID,
    agent_name: str,
    session_id: UUID | None,
    prompt: str,
    headers: dict[str, str],
    for_agent: str | None = None,
) -> dict[str, Any]:
    """Execute one scheduled run: same agent config, same rows, no live client.

    The only differences from an interactive turn are the two columns §3 adds
    (``trigger_kind``, ``workflow_task_id``) and the fact that nobody is
    watching the stream — the events are still published, because a scheduled
    run in a session is exactly the kind of thing an open client *should* see
    appear.

    The prompt for a summarization run is built here rather than stored on the
    agent, because it is the *window that fell out* — data the summarizer agent
    row cannot know and should not have to.
    """
    from .sequencer import TurnSequencer

    context = RequestContext.from_headers(headers)
    user_id = caller_id(headers) or context.user_id

    async with connected(settings, user_id) as repo:
        if session_id is not None and not prompt:
            prompt = await _window_to_summarize(repo, settings, session_id, for_agent)

        sequencer = TurnSequencer(repo, settings, sink=EventSink(repo))
        sequencer.workflow_task_id = task_id
        result = await sequencer.run_turn(
            ChatRequest(
                model=agent_name,
                messages=[InboundMessage(role="user", content=prompt)],
                session_id=session_id,
            ),
            context,
        )
        return {"run_id": str(result.run.id), "status": result.run.status}


async def _window_to_summarize(
    repo: Any, settings: Settings, session_id: UUID, for_agent: str | None
) -> str:
    """The messages the window has already pushed out, as the summarizer's input.

    ``brief.md`` §3: the dispatched run is "an ordinary scheduled agent run over
    the messages about to fall out of the window" — *whose* window being the
    detail that matters: the agent being summarized, not the summarizer and not
    the process default. Getting this wrong is silent, and was: the summarizer
    ran on an empty segment and cheerfully summarized nothing. Everything older than the
    window, in order, rendered plainly — no cleverness, because whatever
    compression is wanted is the summarizer *agent's* job, and that agent is a
    row someone can change without touching this line.
    """
    subject = await repo.get_agent(for_agent) if for_agent else None
    window = (
        subject.context_policy.window_messages
        if subject and subject.context_policy.window_messages
        else settings.window_messages
    )
    messages = await repo.branch_messages(session_id, None)
    turns = [m for m in messages if m.role in ("user", "assistant")]
    fell_out = turns[: max(0, len(turns) - window)]
    return "\n".join(f"{m.role}: {m.content}" for m in fell_out) or "(nothing to summarize)"


async def run_delegated(
    settings: Settings, *, agent_name: str, prompt: str, headers: dict[str, str]
) -> str:
    """Run one delegated turn and return its answer to the calling agent.

    The return value is deliberately just the text: the *rows* are the record
    (child ``runs`` row, child ``messages``), and the parent persists this string
    as an ordinary ``tool_response``. A client that wants the sub-agent's full
    reasoning reads the child run, or watches the stream — it does not need the
    parent to have copied it.
    """
    from .sequencer import TurnSequencer

    context, session_id, parent_run_id, delegated_by = inbound_delegation(headers)
    user_id = caller_id(headers) or context.user_id

    async with connected(settings, user_id) as repo:
        parent = await repo.get_run(parent_run_id) if parent_run_id else None
        sequencer = TurnSequencer(repo, settings, sink=EventSink(repo))
        sequencer.delegated_by_message_id = delegated_by
        result = await sequencer.run_turn(
            ChatRequest(
                model=agent_name,
                messages=[InboundMessage(role="user", content=prompt)],
                session_id=session_id,
            ),
            context,
            parent=parent,
        )
        answer = next(
            (m.content for m in reversed(result.messages) if m.role == "assistant"), ""
        )
        return answer or ""
