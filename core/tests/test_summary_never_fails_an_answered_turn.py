"""A turn that has answered is not failed by the summary it asks for afterwards.

Step 12 of `TurnSequencer.run_turn` dispatches `summarize_session_window` once a
session passes its threshold (brief.md §3). It ran inside the turn's `try`, after
the answer was persisted and streamed, so a `start_workflow` that raised sent the
whole turn to the `except`: the run was marked `failed`, a RUN_ERROR followed the
answer, and a scheduled turn failed its task.

On a stock get-percolate install it always raised, because the definition is
seeded only in percolate-core's `dev/seed.sql`. Every run in a session past 40
messages failed after answering, and a delegated child's failure reached its
parent as a failed tool call. One session on the gpx stack produced 52 runs.

Summarization is a side effect of a finished turn. When it cannot be dispatched,
the session is not summarized, the trace says why, and the turn keeps its
status.
"""
import unittest
from uuid import uuid4

import asyncpg

from percolate_core.agentic.contracts import AgentSpec, ChatRequest, InboundMessage, RequestContext
from percolate_core.agentic.contracts.agents import ContextPolicy
from percolate_core.agentic.sequencer import TurnSequencer
from percolate_core.agentic.settings import Settings
from percolate_core.agentic.testing import MemoryRepository

TASK = uuid4()


def not_installed():
    # The refusal workflow.start_workflow raises for a name it cannot see.
    return asyncpg.RaiseError.new({
        "C": "P0001",
        "M": "no workflow definition named 'summarize_session_window' is visible to you",
    })


class NoSummaryWorkflow(MemoryRepository):
    def __init__(self, error: BaseException | None) -> None:
        super().__init__()
        self.error = error
        self.failed_tasks = []

    async def start_workflow(self, name, payload, trace_id=None):
        if self.error is not None:
            raise self.error
        return await super().start_workflow(name, payload, trace_id)

    async def fail_task(self, task_id, error, terminal):
        self.failed_tasks.append((task_id, error, terminal))


class SummaryDispatch(unittest.IsolatedAsyncioTestCase):
    async def turn(self, error, *, scheduled=False):
        repo = NoSummaryWorkflow(error)
        # Threshold 1: the user's own row trips it, so every turn dispatches.
        repo.agents["chat"] = AgentSpec(
            name="chat", system_prompt="answer",
            context_policy=ContextPolicy(summarize_after_messages=1))
        sequencer = TurnSequencer(repo, Settings(default_model="test"))
        if scheduled:
            sequencer.workflow_task_id = TASK
        result = await sequencer.run_turn(
            ChatRequest(model="chat", messages=[InboundMessage(role="user", content="hello")]),
            RequestContext())
        return repo, result

    def summarize_record(self, result):
        return [r.detail for r in result.trace if r.name == "maybe_summarize"]

    async def test_a_missing_summary_workflow_leaves_the_answered_turn_succeeded(self):
        repo, result = await self.turn(not_installed())
        self.assertIsNone(result.error, result.error)
        self.assertEqual(result.run.status, "succeeded")
        self.assertEqual(repo.runs[result.run.id].status, "succeeded")
        answers = [m for m in repo.messages if m.run_id == result.run.id and m.role == "assistant"]
        self.assertEqual(len(answers), 1, "the turn did not persist its answer")
        # Not silent: the trace names what was missing.
        detail = " ".join(self.summarize_record(result))
        self.assertIn("not dispatched", detail)
        self.assertIn("summarize_session_window", detail)

    async def test_any_dispatch_failure_is_the_same_verdict(self):
        for label, error in (
            ("dropped connection", ConnectionError("reset by peer")),
            ("refused", asyncpg.InsufficientPrivilegeError.new({"C": "42501", "M": "denied"})),
        ):
            with self.subTest(label):
                _, result = await self.turn(error)
                self.assertEqual(result.run.status, "succeeded", result.error)

    async def test_a_scheduled_turn_still_completes_its_task(self):
        # A summarizer's own run is scheduled, and its session is over the
        # threshold by definition. Failing its task would retry a run that
        # already wrote the summary.
        repo, result = await self.turn(not_installed(), scheduled=True)
        self.assertEqual(result.run.status, "succeeded")
        self.assertEqual(repo.failed_tasks, [])
        self.assertEqual([t for t, _ in repo.completed_tasks], [TASK])

    async def test_control_an_installed_workflow_is_still_dispatched(self):
        repo, result = await self.turn(None)
        self.assertEqual(result.run.status, "succeeded")
        self.assertEqual([name for name, _ in repo.workflows], ["summarize_session_window"])
        self.assertTrue(any("dispatched" in d for d in self.summarize_record(result)))


class StartupSaysWhatIsMissing(unittest.IsolatedAsyncioTestCase):
    """The same absence, named once at startup rather than discovered per turn."""

    async def probe(self, row=None, raises=None):
        from contextlib import asynccontextmanager
        from unittest.mock import patch

        from percolate_core.agentic import api

        class Conn:
            async def fetchrow(self, sql, *args):
                if raises is not None:
                    raise raises
                return row

        @asynccontextmanager
        async def as_caller(claims, role=None):
            yield Conn()

        with patch.object(api.identity, "as_caller", as_caller):
            return await api.warn_if_sessions_cannot_be_summarized(
                Settings(default_model="test", default_summarizer="summarizer"))

    async def test_a_stock_install_is_warned_about_both(self):
        with self.assertLogs("percolate_core.agentic.api", "WARNING") as logs:
            missing = await self.probe((False, False))
        self.assertEqual(len(missing), 2, missing)
        self.assertIn("summarize_session_window", logs.output[0])
        self.assertIn("'summarizer'", logs.output[0])

    async def test_an_install_with_both_is_silent(self):
        with self.assertNoLogs("percolate_core.agentic.api", "WARNING"):
            self.assertEqual(await self.probe((True, True)), [])

    async def test_a_failed_check_warns_and_does_not_stop_startup(self):
        with self.assertLogs("percolate_core.agentic.api", "WARNING"):
            self.assertEqual(await self.probe(raises=ConnectionError("down")), [])


if __name__ == "__main__":
    unittest.main()
