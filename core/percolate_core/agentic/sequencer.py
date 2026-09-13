"""The sequencer — one agent turn, as an explicit ordered sequence of steps.

Why this exists as its own module rather than as one long ``run()`` method: the
order *is* the spec. ``brief.md`` assigns each step to a named component and says
what it must and must not do, and ``sequence.md`` gates them in a specific order
for stated reasons ("schema and RLS before anything streams", "fast path proven
before slow path", "chained action before streaming"). A sequencer whose steps
are individually named, individually documented, and individually recorded makes
those claims checkable — at review time by reading, and at run time by looking at
``TurnSequencer.trace``.

Every step method here is a wrapper: the actual work belongs to the component
that owns it (``runtime.persistence``, ``runtime.engine``, ``tools.registry``,
…). If a step ever grows logic of its own beyond ordering and recording, it has
started duplicating a component.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field
from typing import Any
from uuid import UUID, uuid4

from .contracts import (
    AgentSpec,
    ChatRequest,
    Message,
    RequestContext,
    Run,
    RunFinished,
    RunStarted,
    Session,
    TextMessageContent,
    TextMessageEnd,
    TextMessageStart,
    ToolCallEnd,
    ToolCallStart,
)
from .db import Repository
from .runtime import (
    AgentEngine,
    EventSink,
    ExecutionResult,
    PersistenceAdapter,
    apply_response_format,
    build_deps,
    derive_citations,
    fire_chained_action,
    latest_user_prompt,
    outbound_headers,
)
from .runtime.budget import Budget
from .runtime.delegation import DELEGATED_BY_HEADER
from .settings import Settings
from .task_outcome import failure_is_terminal
from .tools import ResolvedToolset, resolve_toolset
from .tools.auth import caller_credentials


log = logging.getLogger(__name__)

# brief.md §3's reference background workflow. A name, not a code path: the
# definition is a `workflow.definitions` row an install may not have.
SUMMARY_WORKFLOW = "summarize_session_window"


@dataclass(slots=True)
class StepRecord:
    """One executed step: what ran, which part of the spec it serves, what it did."""

    name: str
    spec_ref: str
    detail: str = ""


class AgentNotFound(LookupError):
    """No agent by that name that this caller can see.

    One exception for "does not exist" and "exists, and RLS hides it from you",
    because `get_agent` cannot tell them apart and a caller must not be able to
    either: an answer that differed would say which agent names exist.
    """


@dataclass(slots=True)
class TurnResult:
    run: Run
    session: Session | None
    messages: list[Message] = field(default_factory=list)
    execution: ExecutionResult | None = None
    trace: list[StepRecord] = field(default_factory=list)
    error: BaseException | None = None
    """What failed the turn, when one did after it started. The run records
    the sentence; this keeps the exception, so the HTTP boundary can tell a
    refusal by the database from a failure of the thing the turn called."""


class TurnSequencer:
    """Executes one turn, step by step, against the repository contract only.

    Constructed per turn (it holds that turn's trace), cheap to make. A delegated
    sub-run gets its own sequencer with ``parent`` set — which is what makes the
    delegation tree fall out of ordinary recursion rather than needing a
    scheduler of its own.
    """

    def __init__(
        self,
        repo: Repository,
        settings: Settings | None = None,
        *,
        sink: EventSink | None = None,
        engine: AgentEngine | None = None,
        caller_authorization: str | None = None,
    ) -> None:
        self._caller_authorization = caller_authorization
        self.repo = repo
        self.settings = settings or Settings.from_env()
        self.persistence = PersistenceAdapter(repo, self.settings)
        self.engine = engine or AgentEngine(self.settings)
        self.sink = sink or EventSink()
        self.trace: list[StepRecord] = []
        # Minted up front so the streamed deltas and the persisted row agree on
        # which message they are talking about — see _stream_event.
        self.message_id: UUID = uuid4()
        # Which tools this turn delegated to — decides fast vs slow path, and
        # is populated during the run rather than inspected after it, because
        # the delegation rows are written as they happen.
        self.delegated_calls: set[str] = set()
        # Set by the gateway on a delegated run: the parent's tool_call row this
        # run answers, so the tree is walkable from either direction.
        self.delegated_by_message_id: UUID | None = None
        # Set by the gateway's trigger endpoint on a scheduled run (brief.md
        # §3): the workflow-engine task that dispatched it. Its presence is
        # what makes this run 'scheduled' rather than 'interactive', and what
        # obliges this runtime to complete that task when the run finishes.
        self.workflow_task_id: UUID | None = None
        # The delegation tree's allowance and running total. A root run takes
        # the deployment default; the gateway replaces this with what the parent
        # sent, so every run in one tree spends against one budget rather than
        # each level starting fresh. See runtime/budget.py for why the parent's
        # object cannot simply be passed the way pydantic-ai's own guidance says.
        self.budget: Budget = Budget.from_env()
        self.chained_action_failed = False
        self._text_started = False
        self.trace_id: str | None = None
        self._headers: dict[str, str] = {}

    def _record(self, name: str, spec_ref: str, detail: str = "") -> None:
        self.trace.append(StepRecord(name=name, spec_ref=spec_ref, detail=detail))

    # -- the sequence ------------------------------------------------------

    async def run_turn(
        self,
        request: ChatRequest,
        context: RequestContext,
        *,
        model: Any = None,
        parent: Run | None = None,
    ) -> TurnResult:
        """The canonical order. Read this method as the spec's control flow.

         1. resolve the agent row              (brief §2  — agents are rows)
         2. open or attach the session         (brief §4  — threadId = sessions.id)
         3. start the run                      (brief §7  — run/span tree)
         4. reload the bounded window          (brief §3/§5.1 — never the full session)
         5. persist the user's turn            (brief §5.1 — before the quota gate)
         6. check quota                        (brief §5.1 — before every LLM call)
         7. bind tools from tool_servers       (brief §5.2 — zero built-in tools)
         8. invoke the model                   (brief §5  — pydantic-ai owns this)
         9. derive citations from tool responses (brief §5.3 — by construction)
        10. persist the assistant's turn       (brief §2  — fast path / slow path)
        11. fire the chained action            (brief §2/§4 — no second round-trip)
        12. maybe fire summarization           (brief §3  — scheduled, never inline)
        13. finish the run                     (brief §5.1 — terminal statuses)

        Steps 4 and 5 are in that order for a reason worth not re-deriving: the
        window is read *before* the user's row is written, because the prompt is
        passed to the model separately — reload after the write and the model
        sees the same message twice.
        """
        with caller_credentials(self._caller_authorization, self.settings.tool_auth_origins):
            async with self.sink.publishing():
                return await self._run_turn(request, context, model=model, parent=parent)

    async def _run_turn(
        self,
        request: ChatRequest,
        context: RequestContext,
        *,
        model: Any = None,
        parent: Run | None = None,
    ) -> TurnResult:
        agent = await self.resolve_agent(request.model)
        agent = apply_response_format(agent, request)
        session = await self.open_session(request, context)
        run = await self.start_run(agent, session, context, parent=parent)

        prompt = latest_user_prompt(request)
        history = await self.reload_context(session, agent, run)
        await self.persist_user_turn(run, prompt)

        if not await self.guard_quota(run, context):
            return await self.finish(run, session, status="quota_exceeded")

        try:
            toolset = await self.bind_tools(agent)
            execution = await self.invoke_model(
                agent, run, context, prompt, history, toolset, model=model
            )
            citations = self.attribute_citations(execution)
            messages = await self.persist(run, execution, citations)
            # A STRUCTURED ANSWER NEVER STREAMS, so it is sent once here. With a
            # structured_output_schema pydantic-ai returns the answer through
            # an output tool, which map_stream_event neither turns into text nor
            # reports as a function call. The stream carried RUN_STARTED, two
            # MESSAGE_PERSISTED, a TEXT_MESSAGE_END with no START and
            # RUN_FINISHED(result=null): a 200 with no answer in it, while
            # stream:false returned the same turn's JSON as
            # choices.0.message.content. This sends the text that turn
            # persisted, so both paths return the same answer.
            if not self._text_started and execution.text:
                common = {"run_id": run.id, "thread_id": run.session_id}
                self._text_started = True
                await self.sink.emit(TextMessageStart(message_id=self.message_id, **common))
                await self.sink.emit(
                    TextMessageContent(message_id=self.message_id, delta=execution.text, **common)
                )
            await self.sink.emit(
                TextMessageEnd(
                    run_id=run.id,
                    thread_id=run.session_id,
                    message_id=self.message_id,
                )
            )
            await self.maybe_chain(agent, run, execution)
            await self.maybe_summarize(session, agent, execution)
            result = await self.finish(run, session, status="succeeded")
            result.messages = messages
            result.execution = execution
            return result
        except Exception as exc:
            from .contracts import RunError
            message = f"{type(exc).__name__}: {exc}"
            if self._caller_authorization:
                message = message.replace(self._caller_authorization, "[redacted]")
                message = message.replace(self._caller_authorization.split(" ", 1)[-1], "[redacted]")
            run = await self.repo.update_run(run.id, status="failed", state={**run.state, "error": message})
            await self.sink.emit(RunError(thread_id=run.session_id, run_id=run.id, message=message))
            # A scheduled run's task hears about it too. This path recorded the
            # run as failed and returned, so the task was neither completed nor
            # failed and the workflow waited out whatever bound came first.
            await self.fail_workflow_task(run, message, terminal=failure_is_terminal(exc))
            self._record("finish", "brief §5.1", "failed")
            return TurnResult(run=run, session=session, trace=list(self.trace), error=exc)

    # -- steps -------------------------------------------------------------

    async def resolve_agent(self, name: str) -> AgentSpec:
        """Step 1 — an agent is a row, looked up by name (``brief.md`` §2).

        The inbound request's ``model`` field carries the agent name, not an LLM
        name (``contracts.protocol``). Failing loudly on an unknown agent is
        deliberate: silently falling back to a default agent would make a typo
        look like a working conversation.
        """
        agent = await self.repo.get_agent(name)
        if agent is None:
            raise AgentNotFound(f"no agent row named {name!r}")
        self._record("resolve_agent", "brief §2", agent.name)
        return agent

    async def open_session(self, request: ChatRequest, context: RequestContext) -> Session:
        """Step 2 — attach to the AG-UI thread, or start one (``brief.md`` §4).

        A scheduled run may have no session at all (``brief.md`` §3: "a
        'scheduled' run's ``session_id`` may be null, or may point at a synthetic
        session used only for record-keeping — decided in the full spec"). The
        runtime creates one either way and flags the open question rather than
        quietly settling it.
        """
        if request.session_id is not None:
            self._record("open_session", "brief §4", f"attached {request.session_id}")
            return Session(id=request.session_id, owner_id=context.user_id)
        session = await self.repo.create_session(
            Session(owner_id=context.user_id, agui_thread_id=None)
        )
        self._record("open_session", "brief §4", f"created {session.id}")
        return session

    async def start_run(
        self,
        agent: AgentSpec,
        session: Session | None,
        context: RequestContext,
        *,
        parent: Run | None = None,
    ) -> Run:
        """Step 3 — one ``runs`` row per invocation, including delegated ones.

        The trace tree and the delegation tree are the same tree (``brief.md``
        §7): a child's ``parent_span_id`` is simply its parent's ``span_id``, and
        ``trace_id`` is inherited — never restarted — whenever an upstream trace
        exists (an interactive request's ``traceparent`` header, or a scheduled
        run's triggering workflow task).
        """
        from .runtime import check_depth, child_run

        span_id = os.urandom(8).hex()
        if parent is not None:
            check_depth(parent, self.settings)
            run = child_run(
                parent, agent.id, agent.name, self.delegated_by_message_id, span_id
            )
        else:
            run = Run(
                session_id=session.id if session else None,
                agent_id=agent.id,
                agent_name=agent.name,
                trigger_kind="scheduled" if self.workflow_task_id else "interactive",
                workflow_task_id=self.workflow_task_id,
                trace_id=context.trace_id or os.urandom(16).hex(),
                span_id=span_id,
                status="running",
            )
        run = await self.repo.create_run(run)
        await self.sink.emit(
            RunStarted(
                run_id=run.id,
                thread_id=run.session_id,
                agent_name=agent.name,
                parent_run_id=run.parent_run_id,
            )
        )
        self._record("start_run", "brief §7", f"run {run.id} depth {run.depth}")
        return run

    async def guard_quota(self, run: Run, context: RequestContext) -> bool:
        """Step 6 — ``rbac.has_quota_remaining()`` before every LLM call.

        Returning False (rather than raising) is the point: a denial is an
        expected terminal outcome that preserves partial state, not a crash
        (``brief.md`` §5.1).
        """
        allowed = await self.persistence.check_quota(context.user_id)
        self._record("guard_quota", "brief §5.1", "allowed" if allowed else "denied")
        return allowed

    async def reload_context(
        self, session: Session | None, agent: AgentSpec, run: Run
    ) -> list[Any]:
        """Step 4 — the bounded window plus its reserved summary slot.

        Never the whole session — and, once delegation exists, never even the
        whole *conversation*: the window is scoped to this run's branch of the
        tree. See ``runtime.persistence.reload_window``.
        """
        if session is None:
            self._record("reload_context", "brief §5.1", "no session (scheduled run)")
            return []
        rows = await self.persistence.reload_window(session.id, agent, run)
        self._record("reload_context", "brief §3/§5.1", f"{len(rows)} rows in window")
        return self.persistence.to_model_messages(rows)

    async def bind_tools(self, agent: AgentSpec) -> ResolvedToolset:
        """Step 7 — resolve ``agents.tools`` references into one flat toolset.

        From cache, not from the network (``brief.md`` §5.2). An agent with no
        tool references legitimately gets an empty toolset — that is a
        conversational agent, not a misconfiguration.
        """
        toolset = await resolve_toolset(self.repo, agent)
        self._record("bind_tools", "brief §5.2", f"{len(toolset.tools)} tools")
        return toolset

    async def invoke_model(
        self,
        agent: AgentSpec,
        run: Run,
        context: RequestContext,
        prompt: str,
        history: list[Any],
        toolset: ResolvedToolset,
        *,
        model: Any = None,
    ) -> ExecutionResult:
        """Step 8 — hand off to pydantic-ai, and collect what its tools returned.

        The tool-result collection is not incidental bookkeeping: it is the raw
        material step 8 turns into citations, and the spec is explicit that this
        must come from what the tools actually returned rather than from the
        model's own account of them (``brief.md`` §5.3).
        """
        collected: list[Any] = []
        delegating = toolset.delegations()
        base_headers = outbound_headers(context, run)
        self._headers = base_headers
        self.trace_id = run.trace_id

        async def before_call(
            tool_name: str, arguments: dict[str, Any], model_call_id: str
        ) -> tuple[str, dict]:
            """Write the ``tool_call`` row for a delegation *before* dispatching it.

            This is what the slow path actually costs, and the brief's
            description of it ("every tool call and tool response is its own
            message row") does not say out loud: the call row has to exist
            before the child run does, or ``runs.delegated_by_message_id`` has
            nothing to point at. A turn that persists everything at the end
            cannot populate that column at all.

            An ordinary tool call takes neither the row nor the round trip —
            it rides along on the assistant row as JSONB, which is the fast path
            being the cheap default rather than a special case.
            """
            if tool_name not in delegating:
                # An ordinary tool call is recorded on the assistant row with
                # the model's own call id, so the TOOL_CALL_START a client saw
                # and the row it later reads name the same call.
                return model_call_id, base_headers
            call_row = Message(
                run_id=run.id,
                session_id=run.session_id,
                role="tool_call",
                content=tool_name,
                tool_calls=[{"tool_name": tool_name, "arguments": arguments}],
            )
            # The row's own id *is* the call id, set on both sides of the pair
            # so the correlation is data rather than a convention the reader has
            # to know: tool_response.tool_call_id == tool_call.tool_call_id.
            call_row.tool_call_id = str(call_row.id)
            row = (await self.persistence.persist_turn([call_row]))[0]
            self.delegated_calls.add(tool_name)
            # The budget rides the delegation and nothing else. An ordinary MCP
            # server has no business knowing this tree's token spend, and
            # `base_headers` goes to every tool -- so these are added here, on
            # the branch that is by definition talking to our own gateway.
            #
            # The figure is the tree's total as of the START of this turn: the
            # parent's own current turn is still in flight and its usage is
            # inside pydantic-ai's run context, which `before_call` has no
            # handle on. So a child is charged for every completed ancestor turn
            # and not for the partial one that spawned it. Bounded and stated
            # rather than exact; runtime/budget.py records why.
            return str(row.id), {
                **base_headers,
                DELEGATED_BY_HEADER: str(row.id),
                **self.budget.to_headers(),
            }

        async def after_call(result: Any) -> None:
            collected.append(result)
            if result.tool_name not in delegating:
                return
            await self.persistence.persist_turn(
                [
                    Message(
                        run_id=run.id,
                        session_id=run.session_id,
                        role="tool_response",
                        content=str(result.content),
                        tool_call_id=result.call_id,
                        is_error=result.is_error,
                        error_kind=result.error_kind,
                    )
                ]
            )

        deps = build_deps(agent, context, session_id=run.session_id, run_id=run.id)
        pai_agent = self.engine.build(
            agent,
            toolset,
            context,
            model=model,
            on_tool_result=after_call,
            headers=base_headers,
            before_call=before_call,
        )
        execution = await self.engine.execute(
            pai_agent,
            prompt,
            history,
            deps,
            on_event=self._stream_event(run),
            budget=self.budget,
            run=run,
        )
        # What this turn spent joins what the tree had already spent, so the
        # next delegation out of this run carries the running total downward
        # rather than handing a child a clean slate.
        self.budget = self.budget.charge(execution.usage)
        execution.tool_results = collected
        self._record("invoke_model", "brief §5", f"{len(collected)} tool calls")
        return execution

    def _stream_event(self, run: Run) -> Any:
        """Turn the engine's mapped stream events into AG-UI events on the wire.

        The assistant message's id is minted *before* the turn runs and reused
        when the row is written, so a client that watched the deltas and a client
        that only saw the ``MESSAGE_PERSISTED`` checkpoint are talking about the
        same message. Without that, resuming a dropped stream would mean
        reconciling two different ids for one answer.
        """

        async def emit(mapped: dict[str, Any]) -> None:
            kind = mapped["kind"]
            common = {
                "run_id": run.id,
                "thread_id": run.session_id,
            }
            if kind == "text_start":
                # Once per turn. pydantic-ai emits a part-start for every text
                # part, but the turn persists as one assistant row with one id —
                # a second START under the same id would tell a client to open a
                # message it has already opened.
                if self._text_started:
                    return
                self._text_started = True
                await self.sink.emit(TextMessageStart(message_id=self.message_id, **common))
            elif kind == "text_delta":
                await self.sink.emit(
                    TextMessageContent(
                        message_id=self.message_id, delta=mapped["delta"], **common
                    )
                )
            elif kind == "tool_start":
                await self.sink.emit(
                    ToolCallStart(
                        tool_call_id=mapped["tool_call_id"],
                        tool_name=mapped["tool_name"],
                        **common,
                    )
                )
            elif kind == "tool_end":
                await self.sink.emit(
                    ToolCallEnd(tool_call_id=mapped["tool_call_id"],
                                is_error=mapped.get("is_error", False), **common)
                )

        return emit

    def attribute_citations(self, execution: ExecutionResult) -> list[Any]:
        """Step 9 — provenance by construction, per answer, never per run."""
        citations = derive_citations(execution.tool_results)
        self._record("attribute_citations", "brief §5.3", f"{len(citations)} citations")
        return citations

    async def persist_user_turn(self, run: Run, prompt: str) -> Message:
        """Step 5 — write what the user said before deciding anything else.

        Its own step, not folded into step 10, precisely because the ordering is
        the point: a turn that dies at the quota gate still has the user's
        message on it.
        """
        rows = await self.persistence.persist_turn([self.persistence.user_row(run, prompt)])
        self._record("persist_user_turn", "brief §5.1", "user row written")
        return rows[0]

    async def persist(
        self,
        run: Run,
        execution: ExecutionResult,
        citations: list[Any],
    ) -> list[Message]:
        """Step 10 — lay out the turn's rows and write them in one transaction.

        Granularity choice: slow path whenever any tool call was a delegation,
        fast path otherwise (``brief.md`` §2). The choice is per *turn*, not per
        agent — the spec is explicit that the schema "supports both without
        forcing a choice per-agent".
        """
        # Delegated calls already wrote their own rows, before dispatch — see
        # `before_call`. What is left for the assistant row is the fast path's
        # JSONB summary of the ordinary tool calls.
        fast = [r for r in execution.tool_results if r.tool_name not in self.delegated_calls]
        slow = bool(self.delegated_calls)
        rows = self.persistence.build_turn_rows(
            run,
            None,
            execution.text,
            fast,
            slow_path=False,
            citations=citations,
            assistant_message_id=self.message_id,
        )
        written = await self.persistence.persist_turn(rows)
        self._record(
            "persist",
            "brief §2",
            f"{len(written)} rows, {'slow' if slow else 'fast'} path"
            + (f" (+{len(self.delegated_calls)} delegated, written inline)" if slow else ""),
        )
        return written

    async def maybe_chain(self, agent: AgentSpec, run: Run, execution: ExecutionResult) -> None:
        """Step 11 — structured output fires the chained action, no LLM round-trip.

        Both the call and its result become message rows, so the automatic action
        is auditable (``brief.md`` §2). Only reachable when the agent has a
        structured output schema — the schema is what makes the output matchable.
        """
        if agent.chained_action is None or not agent.structured_output_schema:
            self._record("maybe_chain", "brief §4", "no chained action")
            return
        payload = {
            "run_id": str(run.id),
            "session_id": str(run.session_id) if run.session_id else None,
            "agent": agent.name,
            # Why the run happened, not just where: a target that writes
            # something session-scoped has to be able to refuse when its agent
            # was merely somebody's delegate (schema.sql, agentic.apply_summary).
            "trigger_kind": run.trigger_kind,
            "output": execution.output
            if isinstance(execution.output, dict)
            else {"text": execution.text},
        }
        result = await fire_chained_action(
            self.repo, run, agent.chained_action, payload, self._headers
        )
        from .runtime.chained_action import rows_for

        await self.persistence.persist_turn(rows_for(run, agent.chained_action, payload, result))
        self.chained_action_failed = result.is_error
        self._record(
            "maybe_chain",
            "brief §4",
            f"{agent.chained_action.target}{' FAILED' if result.is_error else ''}",
        )

    async def maybe_summarize(
        self,
        session: Session | None,
        agent: AgentSpec,
        execution: ExecutionResult | None = None,
    ) -> None:
        """Step 12 — dispatch ``summarize_session_window`` when the threshold trips.

        Dispatch, never compute: "that summary doesn't get computed inline,
        synchronously, inside a request" (``brief.md`` §3). What this issues is an
        ordinary ``start_workflow`` call, and the run it eventually produces is an
        ordinary scheduled agent run.

        NEVER RAISES. This runs after the answer is persisted and streamed, and
        it ran inside the turn's `try`, so a dispatch that raised marked an
        answered turn `failed`, sent a RUN_ERROR after the answer, and failed a
        scheduled turn's task. On a stock install it always raised: the
        definition is seeded only in `dev/seed.sql`, and every run in a session
        past the threshold failed, delegated children included. A session that
        cannot be summarized keeps its window and loses only the summary slot
        (brief.md §3), so the verdict is "not summarized", recorded on the
        trace and logged with the reason, and the turn keeps its status.
        """
        if session is None:
            return
        try:
            used = execution.context_window_used if execution else None
            if not await self.persistence.needs_summarization(session.id, agent, used):
                self._record("maybe_summarize", "brief §3", "below threshold")
                return

            summarizer = (
                await self.repo.get_agent_by_id(agent.summarizer_agent_id)
                if agent.summarizer_agent_id
                else None
            )
            run_id = await self.repo.start_workflow(
                SUMMARY_WORKFLOW,
                {
                    "session_id": str(session.id),
                    "agent": (summarizer.name if summarizer else self.settings.default_summarizer),
                    "for_agent": agent.name,
                },
                trace_id=self.trace_id,
            )
        except Exception as exc:  # noqa: BLE001 - a side effect of an answered turn
            detail = f"{SUMMARY_WORKFLOW} not dispatched: {type(exc).__name__}: {exc}"
            log.warning("session %s is not summarized: %s", session.id, detail)
            self._record("maybe_summarize", "brief §3", detail)
            return
        self._record("maybe_summarize", "brief §3", f"dispatched workflow run {run_id}")

    async def finish(self, run: Run, session: Session | None, *, status: str) -> TurnResult:
        """Step 13 — one terminal status, one RUN_FINISHED event.

        ``quota_exceeded``, ``failed`` and ``succeeded`` all arrive here the same
        way, which is what keeps a quota cutoff an outcome rather than a crash.
        """
        run = await self.repo.update_run(run.id, status=status)  # type: ignore[arg-type]
        await self.sink.emit(
            RunFinished(run_id=run.id, thread_id=run.session_id, status=status)
        )
        if self.workflow_task_id is not None:
            # brief.md §3: the runtime completes its own triggering task, once
            # the run AND any chained action have finished — which is why this
            # is here and not in maybe_chain.
            if status == "quota_exceeded":
                # COMPLETED, which it was: a step whose run did no work reported
                # success, and the next step ran on nothing. Terminal, because a
                # retry inside the engine's backoff asks the same quota gate --
                # the verdict core/provider_errors gives an account out of credit.
                await self.fail_workflow_task(
                    run, "quota_exceeded: no quota remaining for this caller", terminal=True)
            elif self.chained_action_failed:
                # The task is not done. It used to be LEFT for the engine's retry,
                # which only the reaper delivered; failing it retryable delivers
                # the same retry without waiting for a lease to go stale.
                await self.fail_workflow_task(run, "the chained action failed", terminal=False)
            else:
                await self.repo.complete_task(
                    self.workflow_task_id,
                    {"run_id": str(run.id), "status": status},
                )
                self._record("finish", "brief §3", f"completed task {self.workflow_task_id}")
        self._record("finish", "brief §5.1", status)
        return TurnResult(run=run, session=session, trace=list(self.trace))

    async def fail_workflow_task(self, run: Run, message: str, *, terminal: bool) -> None:
        """Fail a scheduled run's triggering task; nothing for any other run.

        `terminal` comes from `task_outcome.failure_is_terminal` or from the
        exit path's own rule, never from a default: a retryable failure is
        re-dispatched by the engine, and a terminal one fails the workflow run.
        """
        if self.workflow_task_id is None:
            return
        error: dict[str, Any] = {"error": message, "run_id": str(run.id), "status": run.status}
        if terminal:
            error["terminal"] = True
        await self.repo.fail_task(self.workflow_task_id, error, terminal)
        self._record("finish", "brief §3",
                     f"failed task {self.workflow_task_id} ({'terminal' if terminal else 'retryable'})")
