"""A task that outlives the stale timeout finishes once (REM-109).

`workflow.heartbeat_task` shipped, was granted to `worker`, and was called by
nothing -- `heartbeat_at` was written once, at claim. The reaper takes a lease
after `stale_timeout` of silence, two minutes by default, while
`ingest/transcribe.py` waits 300 seconds on one HTTP call. So a long
transcription was failed and re-queued with the first copy still in flight, up
to `max_attempts` times: duplicate provider spend and duplicate writes.

The live proof is a fixture task that sleeps past the timeout, and it needs a
database, a worker and a minute of wall clock -- it lives in
`p8-subsystems/dev/tests/workflow/`. What runs here is the part that made that
failure possible and is pure logic: whether the loop beats at all while a
handler is running, whether it paces itself from the queue rather than from a
constant, and whether it stops before the terminal transition.

Every case asserts something that was false before the change, so the file
fails as a whole against the previous `loop.py`.
"""
import asyncio
import unittest
from contextlib import asynccontextmanager
from unittest.mock import patch

from percolate_core.worker import loop as loop_module

# Short enough that a test is not a coffee break, long enough that a handler
# sleeping for 3x it produces several beats.
STALE_SECONDS = 0.9


class _Conn:
    """The two questions the loop asks, and a record of the heartbeats."""

    def __init__(self, log: list, stale: float | None):
        self.log = log
        self.stale = stale

    async def execute(self, sql: str, *args):
        # complete_task / fail_task go through execute(), not fetchval -- which
        # this stub had wrong at first, and the two tests about ordering failed
        # for that reason rather than for the reason they are about.
        if "complete_task" in sql or "fail_task" in sql:
            self.log.append(("terminal",))
        return None

    async def fetchval(self, sql: str, *args):
        if "queue_stale_timeout" in sql:
            if self.stale is None:
                raise RuntimeError("no such function: workflow.queue_stale_timeout")
            return self.stale
        if "heartbeat_task" in sql:
            self.log.append(args)
            return True
        if "claim_task" in sql:
            return "11111111-1111-1111-1111-111111111111"
        if "get_task_context" in sql:
            return '{"kind": "slow", "step_key": "s1", "task_input": {}}'
        if "complete_task" in sql or "fail_task" in sql:
            self.log.append(("terminal",))
            return None
        return None


def _service(log, stale=STALE_SECONDS):
    @asynccontextmanager
    async def as_service(*a, **kw):
        yield _Conn(log, stale)

    return as_service


class WorkerHeartbeatTests(unittest.TestCase):
    def _run(self, handler_seconds: float, stale=STALE_SECONDS) -> list:
        log: list = []

        async def slow(spec, ctx):
            await asyncio.sleep(handler_seconds)
            return {"ok": True}

        with patch.object(loop_module, "as_service", _service(log, stale)), \
             patch.dict(loop_module.HANDLERS, {"slow": slow}, clear=False), \
             patch.object(loop_module, "offload", lambda conn, tid, out: _identity(out)):
            asyncio.run(loop_module.run_once("media", "w1"))
        return log

    def test_a_long_handler_is_heartbeated_while_it_runs(self):
        """The regression. Zero beats is what shipped."""
        log = self._run(handler_seconds=STALE_SECONDS * 3)
        beats = [e for e in log if e != ("terminal",)]
        self.assertGreaterEqual(
            len(beats), 2,
            "a handler running for 3x the stale timeout was not heartbeated -- "
            "the reaper will take its lease and the task will run again",
        )

    def test_the_beat_carries_the_task_and_the_worker(self):
        """heartbeat_task checks the lease, so it needs both, in order."""
        log = self._run(handler_seconds=STALE_SECONDS * 2)
        beats = [e for e in log if e != ("terminal",)]
        self.assertTrue(beats, "no heartbeat to inspect")
        self.assertEqual(beats[0][1], "w1")
        self.assertEqual(beats[0][0], "11111111-1111-1111-1111-111111111111")

    def test_a_short_handler_is_not_heartbeated(self):
        """The first beat is one period in, so a fast task pays nothing."""
        log = self._run(handler_seconds=0.01)
        beats = [e for e in log if e != ("terminal",)]
        self.assertEqual(beats, [], "a task shorter than one period beat anyway")

    def test_the_beat_stops_before_the_terminal_transition(self):
        """The last word on a task is complete_task, not a beat racing it."""
        log = self._run(handler_seconds=STALE_SECONDS * 2)
        self.assertIn(("terminal",), log)
        self.assertEqual(
            log[-1], ("terminal",),
            "a heartbeat landed after the task was completed -- the beat is not "
            "being cancelled before the terminal call",
        )

    def test_the_period_comes_from_the_queue_not_from_a_constant(self):
        """A queue with a longer timeout beats less often, without a code change."""
        fast = self._run(handler_seconds=1.8, stale=0.9)
        slow = self._run(handler_seconds=1.8, stale=9.0)
        fast_beats = len([e for e in fast if e != ("terminal",)])
        slow_beats = len([e for e in slow if e != ("terminal",)])
        self.assertGreater(
            fast_beats, slow_beats,
            "the heartbeat period is not derived from workflow.queue_stale_timeout, "
            "so raising a queue's stale_timeout leaves its workers pacing to the old one",
        )

    def test_an_older_database_still_runs_the_task(self):
        """No queue_stale_timeout is a fallback, never a failed task."""
        log = self._run(handler_seconds=0.05, stale=None)
        self.assertIn(("terminal",), log, "a database without the new function "
                                          "stopped the worker completing a task")


async def _identity(out):
    return out


if __name__ == "__main__":
    unittest.main()
