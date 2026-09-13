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
import os
from typing import Any
from uuid import UUID

from ..core import identity
from ..core.identity import claims_from_jwt
from .contracts import ChatRequest, InboundMessage, RequestContext
from .db import connected
from .runtime import EventSink, inbound_delegation
from .runtime.budget import Budget
from .runtime.delegation import TOOL_PREFIX
from .settings import Settings
from .task_outcome import failure_is_terminal


def caller_claims(headers: dict[str, str]) -> dict[str, Any] | None:
    """Who is making this call, from the bearer token — verified, not trusted.

    Returns the verified payload WHOLE, and ``None`` for no identity. It
    returned only ``sub``, and everything below it rebuilt ``{"sub": ...}``
    from that: a token carrying ``orgs: [A]`` reached the database with no
    ``orgs`` claim, which ``rbac.current_org_ids()`` reads as every org the
    user belongs to. The Content Server, handed the same token, kept it to A.

    Verified by ``core.identity.claims_from_jwt`` — the one verifier, the one
    the Content Server uses. This file carried its own HS256/``exp``/``nbf``
    check beside it; two verifiers of one token are two answers waiting to
    differ, and the difference is authorisation. A bad signature, a foreign
    algorithm or an expired token is ``None`` here rather than an exception:
    every caller turns ``None`` into its own refusal (401, ``PermissionError``).

    WITHOUT ``P8_JWT_SECRET`` THIS REFUSES, and the paragraph that used to be
    here is why it has to. It said: "this is the local no-auth dev loop: the
    ``X-P8-User-Id`` header names the user ... which is why the gateway must
    never be exposed without the secret set." That sentence identified the
    hazard correctly and then left it to whoever deployed the thing, in a
    docstring they would have to read first. An operator who omits one
    environment variable turned every endpoint below into *act as any user id*:
    ``as_caller`` faithfully sets ``request.jwt.claims`` from it, and every row
    policy in the database believes it.

    The Content Server, handed the same problem, answers 500 rather than
    guessing (``content/server.py``, ``caller``). Two halves of one collection
    disagreeing about whether an unverifiable request is an error is the kind of
    disagreement that becomes authorisation, so this half now agrees with that
    one.

    ``P8_DEV_NO_AUTH=1`` restores the header path for a local loop. It is a
    second variable on purpose: forgetting to set a secret is an accident,
    setting this is a decision, and that difference is the whole of the fix.
    """
    secret = os.getenv("P8_JWT_SECRET")
    lower = {k.lower(): v for k, v in headers.items()}

    if not secret:
        if os.getenv("P8_DEV_NO_AUTH") != "1":
            raise RuntimeError(
                "P8_JWT_SECRET is not set, so no caller can be identified. Set it, "
                "or set P8_DEV_NO_AUTH=1 to trust the X-P8-User-Id header on a loop "
                "that is not reachable from a network -- on that path the header is "
                "an assertion by the caller, not a verified identity.")
        raw = lower.get("x-p8-user-id")
        try:
            return {"sub": str(UUID(raw))} if raw else None
        except ValueError:
            return None

    token = lower.get("authorization", "").removeprefix("Bearer ").strip()
    if not token:
        return None
    try:
        claims = claims_from_jwt(token, secret)
    except ValueError:
        return None
    # A token that names nobody authenticates nobody, and one whose `sub` is
    # not a user id would fail later as a cast error inside the database.
    return claims if user_id_of(claims) is not None else None


def user_id_of(claims: dict[str, Any] | None) -> UUID | None:
    """The ``sub`` of verified claims as a UUID, or None."""
    try:
        return UUID(str(claims["sub"])) if claims and claims.get("sub") else None
    except ValueError:
        return None


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
        """The scheduled-run trigger endpoint (``brief.md`` §3). See ``accept_run``."""
        from starlette.responses import JSONResponse

        status, payload = await accept_run(resolved, dict(request.headers), await request.json())
        return JSONResponse(payload, status)

    return server


async def accept_run(
    settings: Settings, headers: dict[str, str], body: Any
) -> tuple[int, dict[str, Any]]:
    """The scheduled-run trigger (``brief.md`` §3): check the call, then hand it over.

    "A ``mode: async`` ``http_call`` task dispatched at the runtime's internal
    trigger endpoint — not the public AG-UI surface — carrying the triggering
    task's id. The runtime creates the ``runs`` row (``workflow_task_id`` = that
    task's id), executes, and calls ``complete_task(task_id, output)`` itself
    once the run and any ``chained_action`` it fires finish."

    ONE IMPLEMENTATION, SERVED TWICE: by ``percolate agent gateway`` and by
    ``percolate agent serve``. The worker sends a run owner's token only to
    ``P8_AGENT_URL``'s origin, for ``/v1/chat/completions`` and ``/internal/run``
    alike (``worker/agent_auth.py``, ``AGENT_PATHS``). So one origin has to serve
    both, and the one every deployment points ``P8_AGENT_URL`` at is the agent
    service. get-percolate's compose file and chart ran no gateway, so every
    scheduled run got a 404.

    WHAT IS CHECKED BEFORE THE 202, because afterwards nothing can be refused:

    * the body names a task and an agent (400);
    * a verified caller (401). This used to be checked inside the background
      turn, which then failed the named task *terminally*. So a request with no
      token at all could fail any task whose id it knew;
    * the caller can see that task through ``workflow.tasks_api`` (404, the same
      answer for "no such task" and "not yours"). Otherwise any signed-in caller
      could have a turn complete somebody else's task with their own output.
      The worker's token names the run's owner, who can see it;
    * this process can complete and fail tasks at all (503). If it cannot, a
      202 means the step waits out its whole ``wait_ms``, and the runtime
      could not even report why (``identity.task_worker_problem``).

    Returns ``(status, body)`` so each server wraps it in its own response type.
    """
    body = body if isinstance(body, dict) else {}

    # WHAT A MALFORMED CALL IS TOLD, which this endpoint predates REM-67
    # and did not do. `body["workflow_task_id"]` and `body["input"]["agent"]`
    # were read unconditionally, so a caller that omitted either got a
    # KeyError and a 500 -- the shape REM-67 exists to end, since a 500
    # says the server is broken when the request was. The seeded reference
    # definition sent no body at all (REM-126), so 500 was the answer the
    # documented path actually produced.
    #
    # Named individually rather than as "invalid body", because the whole
    # defect was that nobody could tell WHICH field was missing.
    missing = [
        name for name, present in (
            ("workflow_task_id", bool(body.get("workflow_task_id"))),
            ("input", isinstance(body.get("input"), dict)),
            ("input.agent", isinstance(body.get("input"), dict)
                            and bool(body["input"].get("agent"))),
        ) if not present
    ]
    if missing:
        return 400, {"error": "missing required field(s): " + ", ".join(missing),
                     "hint": "a scheduled step sends {\"workflow_task_id\": "
                             "\"{{task.id}}\", \"input\": {\"agent\": ...}} -- see "
                             "specs/workflow-engine/README.md, scheduled runs"}
    run_input = body["input"]
    try:
        task_id = UUID(str(body["workflow_task_id"]))
        session_id = UUID(str(run_input["session_id"])) if run_input.get("session_id") else None
    except ValueError as exc:
        return 400, {"error": f"workflow_task_id and input.session_id must be uuids: {exc}"}

    claims = caller_claims(headers)
    if claims is None:
        return 401, {"error": "a verified bearer token is required"}
    async with connected(settings, claims) as repo:
        visible = await repo.can_see_task(task_id)
    if not visible:
        return 404, {"error": f"no task {task_id} -- it does not exist, or is not yours"}
    problem = await identity.task_worker_problem()
    if problem:
        return 503, {"error": problem}

    # `mode: "async"` means dispatch-and-return (workflow-engine/spec.md
    # §14): the executor's job is only to hand the work over, and this
    # runtime completes the task itself when the run is genuinely done.
    # Awaiting the run here instead looks harmless and is not -- the
    # executor then parks the task in `waiting_external` *after* the
    # runtime already completed it, overwriting `done`. Found by running it.
    task = asyncio.create_task(_dispatch(
        settings,
        task_id=task_id,
        agent_name=run_input["agent"],
        session_id=session_id,
        prompt=run_input.get("prompt", ""),
        for_agent=run_input.get("for_agent"),
        headers=headers,
    ))
    _in_flight.add(task)
    task.add_done_callback(_in_flight.discard)
    return 202, {"accepted": True, "workflow_task_id": str(task_id)}


_in_flight: set[Any] = set()
"""Strong references to running background dispatches.

asyncio only holds a weak reference to a task; without this, a scheduled run can
be garbage-collected mid-flight and simply vanish -- no error, no completion,
and a workflow task that waits forever.
"""


async def _dispatch(settings: Settings, **kwargs: Any) -> None:
    """Run a scheduled turn in the background, failing its task if it raises.

    A run that dies must not leave its task unanswered: the workflow waits for
    this runtime's completion. The sequencer fails the task for what it catches
    (an exception inside the turn, a quota cutoff, a failed chained action);
    this covers what escapes it -- an unknown agent, a refused `start_run`, no
    verified caller, a database that is down -- and the turn being cancelled.

    Every one of these was failed RETRYABLE, whatever the cause, so an agent
    name nobody registered was dispatched `max_attempts` times.
    `task_outcome.failure_is_terminal` decides now.
    """
    try:
        await run_scheduled(settings, **kwargs)
    except asyncio.CancelledError:
        # The runtime is stopping with the turn unfinished. Nothing about the
        # turn is wrong, so it goes back for another attempt -- and it is said
        # now, because nobody else will say it.
        await _fail_task(settings, kwargs["task_id"],
                         "CancelledError: the runtime stopped before the turn finished",
                         terminal=False)
        raise
    except Exception as exc:  # noqa: BLE001 - any failure must reach the task
        import traceback

        traceback.print_exc()
        await _fail_task(settings, kwargs["task_id"], f"{type(exc).__name__}: {exc}",
                         terminal=failure_is_terminal(exc))


async def _fail_task(settings: Settings, task_id: UUID, message: str, *, terminal: bool) -> None:
    error: dict[str, Any] = {"error": message}
    if terminal:
        error["terminal"] = True
    async with connected(settings, None) as repo:
        await repo.fail_task(task_id, error, terminal)


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
    claims = caller_claims(headers)
    if claims is None:
        raise PermissionError("a verified caller is required")
    context = context.model_copy(update={"user_id": user_id_of(claims)})

    async with connected(settings, claims) as repo:
        if session_id is not None and not prompt:
            prompt = await _window_to_summarize(repo, settings, session_id, for_agent)

        authorization = next((v for k, v in headers.items() if k.lower() == "authorization"), None)
        sequencer = TurnSequencer(repo, settings, sink=EventSink(repo), caller_authorization=authorization)
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
    claims = caller_claims(headers)
    if claims is None:
        raise PermissionError("a verified caller is required")
    context = context.model_copy(update={"user_id": user_id_of(claims)})

    async with connected(settings, claims) as repo:
        parent = await repo.get_run(parent_run_id) if parent_run_id else None
        authorization = next((v for k, v in headers.items() if k.lower() == "authorization"), None)
        sequencer = TurnSequencer(repo, settings, sink=EventSink(repo), caller_authorization=authorization)
        sequencer.delegated_by_message_id = delegated_by
        # THE CHILD INHERITS THE TREE'S BUDGET RATHER THAN STARTING AT ZERO.
        # Without this the sequencer keeps the fresh `Budget.from_env()` its
        # constructor made, and a parent's limit binds one level of a tree that
        # `max_delegation_depth` lets go three deep with unbounded fan-out at
        # each. This is the over-the-wire form of pydantic-ai's "pass ctx.usage
        # to the delegate agent run".
        #
        # Only when the parent actually sent one: a direct call to this gateway
        # that is not a delegation carries no budget headers, and falling back
        # to the deployment default is the right answer for it.
        inherited = Budget.from_headers(headers)
        if inherited.limits or inherited.spent:
            sequencer.budget = inherited
        result = await sequencer.run_turn(
            ChatRequest(
                model=agent_name,
                messages=[InboundMessage(role="user", content=prompt)],
                session_id=session_id,
            ),
            context,
            parent=parent,
        )
        # A CHILD THAT DID NOT SUCCEED IS A FAILED TOOL CALL. This returned the
        # last assistant text whatever the run's status, so a child that failed
        # handed its parent an empty, successful result -- and on a compose
        # stack whose children all failed after answering, the parent's model
        # read `None` as an answer and delegated again, 42 times in one turn.
        # Raised rather than returned: MCPServer turns an exception from
        # call_tool into `isError`, which is the channel the parent reads.
        if result.run.status != "succeeded":
            cause = (result.run.state or {}).get("error") or "no error was recorded"
            raise RuntimeError(
                f"the delegated {agent_name} run {result.run.id} finished "
                f"{result.run.status}: {cause}")
        answer = next(
            (m.content for m in reversed(result.messages) if m.role == "assistant"), ""
        )
        return answer or ""
