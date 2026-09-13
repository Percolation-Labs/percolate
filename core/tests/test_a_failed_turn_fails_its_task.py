"""A scheduled turn that fails, fails the workflow task that started it.

A scheduled run reaches the runtime through `/internal/run` and completes its
own triggering task when the run is done (brief.md §3). Every other ending said
nothing to the task. An exception inside the turn recorded the run as `failed`
and returned; a quota cutoff COMPLETED the task, so the next step ran on
nothing; a failed chained action left it for a retry only the reaper delivered.
And what did reach the task, through the gateway, was failed retryable whatever
the cause -- an agent nobody registered was dispatched `max_attempts` times.

Once the dispatching worker holds the task (percolate-core #46), a turn that
says nothing costs the step's whole `wait_ms`. So each exit path is pinned here
with the verdict it should carry, and every case asserts the task was NOT
completed, because "failed and also completed" is its own defect.
"""
import asyncio
import unittest
from contextlib import asynccontextmanager
from unittest.mock import patch
from uuid import uuid4

import asyncpg
from pydantic_ai.exceptions import ModelHTTPError, UsageLimitExceeded

from percolate_core.agentic import gateway
from percolate_core.agentic.contracts import AgentSpec, ChatRequest, InboundMessage, RequestContext
from percolate_core.agentic.sequencer import TurnSequencer
from percolate_core.agentic.settings import Settings
from percolate_core.agentic.testing import MemoryRepository
from percolate_core.core.config import TerminalError

TASK = uuid4()
NO_CREDIT = {"error": {"type": "insufficient_quota", "code": "insufficient_quota"}}
RATE_LIMITED = {"error": {"type": "requests", "code": "rate_limit_exceeded"}}


def refused():
    return asyncpg.InsufficientPrivilegeError.new(
        {"C": "42501", "M": "not authorized to invoke agent summarizer"})


class RecordingRepository(MemoryRepository):
    """The in-memory repository, recording every way a task gets failed.

    `fail_task`, and also the raw `workflow.fail_task` statement the gateway
    ran on a borrowed worker connection before the repository had that method
    -- so against older code these tests fail on the verdict it reached, not on
    a missing attribute.
    """

    def __init__(self) -> None:
        super().__init__()
        self.failed_tasks = []
        repo = self

        class Conn:
            async def execute(self, sql, *args):
                if "fail_task" in sql:
                    repo.failed_tasks.append(
                        (args[0], args[1], bool(args[2]) if len(args) > 2 else False))

        class Client:
            @asynccontextmanager
            async def as_user(self, claims, role=None):
                yield Conn()

        self.client = Client()

    async def fail_task(self, task_id, error, terminal):
        self.failed_tasks.append((task_id, error, terminal))


class ScheduledTurn(unittest.IsolatedAsyncioTestCase):
    async def turn(self, *, raises=None, quota=True, chained_failed=False, scheduled=True):
        repo = RecordingRepository()
        repo.agents["summarizer"] = AgentSpec(name="summarizer", system_prompt="summarize")
        repo.quota_allowed = quota
        sequencer = TurnSequencer(repo, Settings(default_model="test"))
        if scheduled:
            sequencer.workflow_task_id = TASK

        async def failing_model(*a, **kw):
            raise raises

        async def failed_chain(self, *a, **kw):
            self.chained_action_failed = True

        with patch.object(TurnSequencer, "invoke_model", failing_model) if raises else _nothing(), \
             patch.object(TurnSequencer, "maybe_chain", failed_chain) if chained_failed else _nothing():
            result = await sequencer.run_turn(
                ChatRequest(model="summarizer",
                            messages=[InboundMessage(role="user", content="the window")]),
                RequestContext())
        return repo, result

    def assertFailedOnce(self, repo, *, terminal):
        self.assertEqual(repo.completed_tasks, [], "a failed turn completed its task")
        self.assertEqual(len(repo.failed_tasks), 1, repo.failed_tasks)
        task, error, was_terminal = repo.failed_tasks[0]
        self.assertEqual(task, TASK)
        self.assertEqual(was_terminal, terminal, error)
        self.assertEqual(error.get("terminal", False), terminal)
        return error

    async def test_a_successful_turn_still_completes_and_fails_nothing(self):
        repo, result = await self.turn()
        self.assertEqual(result.run.status, "succeeded")
        self.assertEqual(len(repo.completed_tasks), 1)
        self.assertEqual(repo.failed_tasks, [])

    async def test_an_exception_inside_the_turn_fails_the_task(self):
        for label, error, terminal in (
            ("provider 5xx", ModelHTTPError(503, "m", {"error": "overloaded"}), False),
            ("plain rate limit", ModelHTTPError(429, "m", RATE_LIMITED), False),
            ("account out of credit", ModelHTTPError(429, "m", NO_CREDIT), True),
            ("refused credential", ModelHTTPError(401, "m", {"error": "bad key"}), True),
            ("database refusal", refused(), True),
            ("usage limit spent", UsageLimitExceeded("request_limit of 3 exceeded"), True),
            ("a TerminalError", TerminalError("bad request shape"), True),
            ("a dropped connection", ConnectionError("reset by peer"), False),
        ):
            with self.subTest(label):
                repo, result = await self.turn(raises=error)
                self.assertEqual(result.run.status, "failed")
                failed = self.assertFailedOnce(repo, terminal=terminal)
                self.assertEqual(failed["run_id"], str(result.run.id))

    async def test_a_quota_cutoff_fails_the_task_terminally_instead_of_completing_it(self):
        repo, result = await self.turn(quota=False)
        self.assertEqual(result.run.status, "quota_exceeded")
        self.assertIn("quota_exceeded", self.assertFailedOnce(repo, terminal=True)["error"])

    async def test_a_failed_chained_action_fails_the_task_for_a_retry(self):
        repo, _ = await self.turn(chained_failed=True)
        self.assertFailedOnce(repo, terminal=False)

    async def test_an_interactive_turn_touches_no_task(self):
        repo, _ = await self.turn(raises=ConnectionError("x"), scheduled=False)
        self.assertEqual((repo.completed_tasks, repo.failed_tasks), ([], []))


class TheGatewayDispatch(unittest.IsolatedAsyncioTestCase):
    """What escapes the sequencer, and cancellation of the background turn."""

    async def dispatch(self, error):
        repo = RecordingRepository()

        @asynccontextmanager
        async def connected(settings, claims):
            yield repo

        async def run_scheduled(settings, **kwargs):
            raise error

        with patch.object(gateway, "connected", connected), \
             patch.object(gateway, "run_scheduled", run_scheduled), \
             patch("traceback.print_exc"):
            try:
                await gateway._dispatch(Settings(), task_id=TASK, agent_name="summarizer",
                                        session_id=None, prompt="", headers={})
            except asyncio.CancelledError:
                repo.reraised = True
        return repo

    async def test_each_escaping_failure_carries_its_own_verdict(self):
        for label, error, terminal in (
            ("no agent by that name", LookupError("no agent row named 'summarizr'"), True),
            ("no verified caller", PermissionError("a verified caller is required"), True),
            ("start_run refused", refused(), True),
            ("database unreachable", ConnectionRefusedError("connect call failed"), False),
        ):
            with self.subTest(label):
                repo = await self.dispatch(error)
                self.assertEqual([(t, terminal) for t, _, terminal in repo.failed_tasks],
                                 [(TASK, terminal)])

    async def test_a_cancelled_turn_is_handed_back_for_retry_and_still_cancels(self):
        repo = await self.dispatch(asyncio.CancelledError())
        self.assertEqual([(t, terminal) for t, _, terminal in repo.failed_tasks], [(TASK, False)])
        self.assertTrue(getattr(repo, "reraised", False), "the cancellation was swallowed")


class _nothing:
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


if __name__ == "__main__":
    unittest.main()
