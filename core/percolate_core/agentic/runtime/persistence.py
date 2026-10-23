"""Component 1 — the Postgres persistence adapter (``brief.md`` §5.1).

pydantic-ai's conversation model is a ``message_history`` list passed into
``Agent.run()``. This module maps that onto ``sessions``/``runs``/``messages`` in
both directions, and owns the one part that "needs an actual opinion, not just a
mapping": **what gets reloaded**.

The opinion, stated by the spec and implemented here: *windowing, with a reserved
slot for a rolling summary*. Never "everything ever said in this session."
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

from ..contracts import AgentSpec, Message, Run, ToolResult
from ..db import Repository
from ..settings import Settings


# THE DELIMITER HAS ONE HOME, because the test asserts it and a test agreeing
# with its own copy of a string is a test that passes while the code drifts --
# the axis this collection spent a whole postmortem on
# (2026-09-11-fixed-at-the-copy-that-failed.md).
SUMMARY_OPEN = "<conversation-summary>"
SUMMARY_CLOSE = "</conversation-summary>"


def frame_summary(content: str | None) -> str:
    """Wrap a summary in the marker that says it is background, not instruction.

    A summary is replayed as USER text (see ``to_model_messages``), and an
    undelimited user part is indistinguishable from something the user actually
    said -- a different confusion with the same root as replaying it as a
    system part.
    """
    return f"{SUMMARY_OPEN}\n{content or ''}\n{SUMMARY_CLOSE}"


class PersistenceAdapter:
    """Reads and writes the conversation plane. Owns the context policy."""

    def __init__(self, repo: Repository, settings: Settings) -> None:
        self.repo = repo
        self.settings = settings

    # -- reload ------------------------------------------------------------

    def window_size(self, agent: AgentSpec) -> int:
        """Per-agent override, else the process default.

        OPEN (``brief.md`` §9): message count vs. token estimate, and what
        number. Count is implemented because it is the honest minimum; a token
        estimate changes this one method, not the shape around it.
        """
        return agent.context_policy.window_messages or self.settings.window_messages

    async def reload_window(
        self, session_id: UUID, agent: AgentSpec, run: Run | None = None
    ) -> list[Message]:
        """Build the bounded history for the next turn.

        **Scoped to this run's branch of the delegation tree, not to the whole
        session** — which is ``brief.md`` §9's "where is the line between this
        session's history and this run's history for a delegation tree", and it
        stopped being an open question the moment a sub-run was actually run: a
        session-wide window handed the delegated agent the *parent's* rows,
        including the ``tool_call`` row representing its own invocation.

        The rule: a run reloads the messages of the runs that share its parent —
        null for a top-level run, so successive turns of the conversation are
        one history; the parent run id for a delegated one, so a sub-agent sees
        its own turns and nothing of the conversation that called it. The parent
        still sees the delegation, because the ``tool_call``/``tool_response``
        pair lives on the *parent's* run (§2's slow path), which is what those
        rows are for.

        Shape (``brief.md`` §3): ``[summary?] + [the most recent N messages]``,
        where the summary row is injected **at the tail of the reloaded history
        — the oldest position in what's actually sent to the model, immediately
        before the windowed recent messages**. It is absent until the window has
        ever needed one.

        Two things this deliberately does not do:

        - It does not compute the summary. That is a scheduled run
          (``summarize_session_window``), not inline work in a request path.
        - It does not include ambient context (date, tenant). That arrives as
          headers and is injected separately, precisely so the context policy
          can never accidentally drop it (``brief.md`` §5.1 item 4).

        A scheduled run reloads *nothing*: its context is the input it was
        dispatched with (§3 -- "an ordinary scheduled agent run over the
        messages about to fall out of the window"), not the conversation it
        happens to be about. Giving it the conversation would both duplicate its
        own prompt and make a background job's history depend on live chat.
        """
        if run is not None and run.trigger_kind == "scheduled":
            return []
        # A superset of the policy bound: tool_call/tool_response rows sit
        # between turns, so asking the database for exactly `window_messages`
        # rows could return a window with no turns in it at all.
        window = self.window_size(agent)
        recent = await self.repo.branch_messages(
            session_id, run.parent_run_id if run else None, limit=window * 4 + 8
        )
        summary = next((m for m in recent if m.role == "summary"), None)
        turns = [m for m in recent if m.role != "summary"]
        return ([summary] if summary else []) + turns[-window:]

    def to_model_messages(self, messages: list[Message]) -> list[Any]:
        """Map ``messages`` rows onto pydantic-ai ``ModelMessage`` objects.

        The mapping is where the fast path / slow path distinction stops
        mattering: both shapes have to produce the same ``message_history``, or
        an agent's behaviour would depend on how its previous turns happened to
        be persisted, which would make the two granularities semantically
        different rather than just structurally different (``brief.md`` §2).

        A ``role='summary'`` row maps to a **user**-role message inside an
        explicit ``<conversation-summary>`` delimiter, not a system one. It is
        derived text: the summarizer is an ordinary agent run over the window,
        so a summary of untrusted content is still untrusted content and must
        not acquire authority by being summarised (``specs/agentic/brief.md``,
        "What a summary is allowed to do to the next turn").

        A delegation round-trips as a real ``ToolCallPart``/``ToolReturnPart``
        pair, never as prose: a delegated turn the model sees as "text
        describing a tool call" is a turn it will cheerfully repeat.
        """
        from pydantic_ai.messages import (
            ModelRequest,
            ModelResponse,
            SystemPromptPart,
            TextPart,
            ToolCallPart,
            ToolReturnPart,
            UserPromptPart,
        )

        from .chained_action import CHAINED_CALL_ID

        history: list[Any] = []
        for message in messages:
            if message.tool_call_id == CHAINED_CALL_ID:
                # A chained action is a record of something the *runtime* did
                # after the model finished, not a turn the model is continuing.
                # Replaying it is wrong on two counts: the model never asked for
                # it, and a Postgres function name is not a legal tool name
                # (OpenAI rejects the dot in `agentic.apply_summary` outright --
                # found by running it). The rows stay for audit; the history
                # skips them.
                continue
            if message.role == "summary":
                # A SUMMARY IS DERIVED TEXT AND CARRIES NO MORE AUTHORITY THAN
                # THE WINDOW IT REPLACED. It used to be replayed as a
                # ``SystemPromptPart``, on the reasonable-sounding argument that
                # a summary should carry the weight of what it stands in for.
                # It should not, and the reason is what produces it: the
                # summarizer is an ordinary agent run over the conversation
                # window, so anything an attacker put in a retrieved chunk, a
                # tool result or a delegated answer got restated by us and then
                # replayed with SYSTEM authority on every later turn --
                # outliving the window that would otherwise have aged it out.
                # OWASP ASI06, with the poisoning step performed by our own
                # summarizer. specs/agentic/brief.md has the decision.
                #
                # So: a user part, inside an explicit delimiter. The delimiter
                # is not decoration -- without it the model cannot tell the
                # summary from something the user said, which is a different
                # confusion with the same cause.
                history.append(
                    ModelRequest(parts=[UserPromptPart(content=frame_summary(message.content))])
                )
            elif message.role == "user":
                history.append(
                    ModelRequest(parts=[UserPromptPart(content=message.content or "")])
                )
            elif message.role == "assistant":
                history.append(ModelResponse(parts=[TextPart(content=message.content or "")]))
            elif message.role == "system":
                history.append(
                    ModelRequest(parts=[SystemPromptPart(content=message.content or "")])
                )
            elif message.role == "tool_call":
                # The slow path round-trips as a real tool call, not as prose:
                # a delegated turn the model sees as "text describing a tool
                # call" is a turn it will happily repeat.
                call = (message.tool_calls or [{}])[0]
                history.append(
                    ModelResponse(
                        parts=[
                            ToolCallPart(
                                tool_name=call.get("tool_name", message.content or "tool"),
                                args=call.get("arguments", {}),
                                tool_call_id=message.tool_call_id or str(message.id),
                            )
                        ]
                    )
                )
            elif message.role == "tool_response":
                history.append(
                    ModelRequest(
                        parts=[
                            ToolReturnPart(
                                tool_name=_paired_tool_name(messages, message),
                                content=message.content or "",
                                tool_call_id=message.tool_call_id or str(message.id),
                            )
                        ]
                    )
                )
        return history

    # -- persist -----------------------------------------------------------

    def user_row(self, run: Run, text: str) -> Message:
        """The user's turn, written before the quota gate.

        ``brief.md`` §5.1's ordering rule, learned by building this: check-then-
        persist reads as the natural order, but it silently loses the user's
        message when a quota denial lands on the first turn of a session —
        contradicting the same paragraph's promise that a cutoff preserves what
        already exists. Persist what the user said, *then* decide whether the
        model may be called.
        """
        return Message(run_id=run.id, session_id=run.session_id, role="user", content=text)

    def build_turn_rows(
        self,
        run: Run,
        user_text: str | None,
        assistant_text: str | None,
        tool_results: list[ToolResult],
        slow_path: bool,
        citations: list[Any] | None = None,
        assistant_message_id: Any = None,
    ) -> list[Message]:
        """Lay out the rows for one turn, in either granularity.

        Fast path (default, ``brief.md`` §2): two rows — the user turn and the
        assistant turn, with tool calls riding along as ``tool_calls`` JSONB.

        Slow path: ``user → tool_call → tool_response → ... → assistant``, one
        row each. **Mandatory whenever a tool call is itself a delegation**,
        because the sub-agent's run must be independently queryable rather than
        buried in a JSONB blob.

        Shell: real, because the row layout *is* the thing under review.
        """
        rows: list[Message] = []
        if user_text is not None:
            rows.append(
                Message(run_id=run.id, session_id=run.session_id, role="user", content=user_text)
            )

        if slow_path:
            for result in tool_results:
                rows.append(
                    Message(
                        run_id=run.id,
                        session_id=run.session_id,
                        role="tool_call",
                        content=result.tool_name,
                        tool_call_id=result.call_id,
                    )
                )
                rows.append(
                    Message(
                        run_id=run.id,
                        session_id=run.session_id,
                        role="tool_response",
                        content=str(result.content),
                        tool_call_id=result.call_id,
                        is_error=result.is_error,
                        error_kind=result.error_kind,
                    )
                )
            tool_calls_jsonb: list[dict[str, Any]] = []
        else:
            tool_calls_jsonb = [
                {
                    "call_id": r.call_id,
                    "tool_name": r.tool_name,
                    "content": r.content,
                    "is_error": r.is_error,
                    "error_kind": r.error_kind,
                }
                for r in tool_results
            ]

        assistant = Message(
                run_id=run.id,
                session_id=run.session_id,
                role="assistant",
                content=assistant_text,
                tool_calls=tool_calls_jsonb,
                citations=citations or [],
        )
        if assistant_message_id is not None:
            assistant.id = assistant_message_id
        rows.append(assistant)
        return rows

    async def persist_turn(self, rows: list[Message]) -> list[Message]:
        """One RPC, one transaction (phase gate 2, ``phases.py``)."""
        return await self.repo.append_messages(rows)

    # -- quota -------------------------------------------------------------

    async def check_quota(self, user_id: UUID | None) -> bool:
        """Called before *every* LLM call, not once per run (``brief.md`` §5.1).

        Lives on the persistence adapter rather than in the engine because the
        spec puts it here, and because the adapter is the component that already
        holds the user identity a quota is scoped to.

        Denial is not an exception: the caller transitions the run to the
        terminal status ``quota_exceeded`` so partial output stays inspectable.
        """
        return await self.repo.has_quota_remaining(user_id, "llm_tokens")

    # -- summarization trigger --------------------------------------------

    async def needs_summarization(
        self,
        session_id: UUID,
        agent: AgentSpec,
        context_window_used: float | None = None,
    ) -> bool:
        """Has this session crossed the threshold that fires the summarizer?

        ``brief.md`` §3: once a session's message count or token estimate crosses
        a configurable threshold, ``start_workflow('summarize_session_window',
        ...)`` fires — "most naturally from a trigger on ``messages`` insert".

        **The token estimate is no longer owed.** §9 left "message count vs.
        token estimate" open, and count shipped as the honest minimum because
        the alternative was a token count of our own -- a tokenizer per provider,
        kept in step with models nobody here controls. pydantic-ai 2.38 added
        ``RunContext.context_window_used``: the fraction of *this model's
        declared* window the response occupied, computed by the library that
        already knows both numbers. The estimate now arrives
        correct-by-construction, and it is the better of the two triggers
        because message count was only ever a proxy for it.

        **Either fires it, rather than one replacing the other.** The estimate is
        ``None`` for a model that declares no context window, and a session can
        equally fill up on many small messages without ever filling a context.
        The two fail in opposite directions, so this is a disjunction -- and the
        cheap count is still evaluated first.

        OPEN (§9) still: trigger-in-Postgres vs. here. If it becomes a database
        trigger this method is deleted rather than kept as a second, drifting
        copy of the rule -- which is why the new input arrives as an argument
        rather than as state this object reads for itself.
        """
        threshold = (
            agent.context_policy.summarize_after_messages
            or self.settings.summarize_after_messages
        )
        if await self.repo.message_count(session_id) >= threshold:
            return True
        if context_window_used is None:
            return False
        return context_window_used >= self.settings.summarize_at_context_fraction


def _paired_tool_name(messages: list[Message], response: Message) -> str:
    """Find the ``tool_call`` row a ``tool_response`` row answers.

    pydantic-ai correlates a return to its call by ``tool_call_id`` *and*
    ``tool_name``; the row only carries the id, so the name comes from its pair.
    Falling back to a placeholder rather than raising, because a history that
    lost one row should degrade, not make the whole session unloadable.
    """
    for message in messages:
        if message.role == "tool_call" and message.tool_call_id == response.tool_call_id:
            return (message.tool_calls or [{}])[0].get("tool_name") or message.content or "tool"
    return "tool"
