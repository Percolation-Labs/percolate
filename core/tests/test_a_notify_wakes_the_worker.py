"""A notify wakes the worker; the poll is only the fallback (REM-1319).

The engine notifies `task_ready` with the queue as payload whenever a task becomes ready, and the worker did not
listen: on 0.2.38 a step that became ready while the worker was idle waited a median 1.18 s of its 1.20 s for the
2 s poll. These drive `serve` against a fake pool, with a 30 s poll, so anything that happens in well under a second
was the notify or the reconnect sweep and not the poll.

Also here, the two round trips the claim path dropped: the task's context is read in the claim's transaction behind
a savepoint, so a context that fails still leaves the claim committed, and a queue's stale timeout is asked once
rather than for every task.
"""

from __future__ import annotations

import asyncio
import json
import unittest
from contextlib import asynccontextmanager
from unittest import mock

from percolate_core.worker import loop

POLL = 30.0
SOON = 1.0


class _ListenConn:
    def __init__(self) -> None:
        self.listeners: dict = {}
        self.on_terminate = None

    def add_termination_listener(self, cb) -> None:
        self.on_terminate = cb

    async def add_listener(self, channel, cb) -> None:
        self.listeners[channel] = cb

    async def execute(self, sql, *args):
        return None

    def notify(self, payload: str) -> None:
        self.listeners[loop.READY_CHANNEL](self, 1, loop.READY_CHANNEL, payload)

    def die(self) -> None:
        self.on_terminate(self)


class _Pool:
    def __init__(self) -> None:
        self.conns: list[_ListenConn] = []

    async def acquire(self) -> _ListenConn:
        c = _ListenConn()
        self.conns.append(c)
        return c

    async def release(self, conn) -> None:
        return None


async def _until(cond, timeout=SOON) -> bool:
    deadline = asyncio.get_running_loop().time() + timeout
    while asyncio.get_running_loop().time() < deadline:
        if cond():
            return True
        await asyncio.sleep(0.005)
    return cond()


class ANotifyWakesTheWorker(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.pool = _Pool()
        self.claims: list[float] = []

        async def fake_pool(*a, **kw):
            return self.pool

        async def fake_run_once(queue, worker_id):
            self.claims.append(asyncio.get_running_loop().time())
            return False  # an empty queue: the loop waits

        self.patches = [
            mock.patch.object(loop, "pool", fake_pool),
            mock.patch.object(loop, "run_once", fake_run_once),
            mock.patch.object(loop, "RECONNECT_SECONDS", 0.01),
        ]
        for p in self.patches:
            p.start()
        self.worker = asyncio.create_task(loop.serve("http", "w-listen", poll_seconds=POLL))
        # Started: listening, and the first claims (the loop's own, and the sweep the LISTEN asks for) are done.
        self.assertTrue(await _until(lambda: self.pool.conns and self.pool.conns[0].listeners))
        await asyncio.sleep(0.05)

    async def asyncTearDown(self) -> None:
        self.worker.cancel()
        try:
            await self.worker
        except asyncio.CancelledError:
            pass
        for p in self.patches:
            p.stop()

    async def test_a_notify_for_its_queue_claims_without_waiting_for_the_poll(self):
        before = len(self.claims)
        self.pool.conns[0].notify("http")
        self.assertTrue(await _until(lambda: len(self.claims) > before),
                        f"a notify for the worker's queue did not wake it within {SOON}s; the poll is {POLL}s")

    async def test_a_notify_for_another_queue_does_not(self):
        before = len(self.claims)
        self.pool.conns[0].notify("media")
        await asyncio.sleep(0.2)
        self.assertEqual(len(self.claims), before, "a notify for another queue woke this worker")

    async def test_a_lost_connection_is_listened_on_again_and_swept(self):
        before = len(self.claims)
        self.pool.conns[0].die()
        self.assertTrue(await _until(lambda: len(self.pool.conns) == 2 and self.pool.conns[1].listeners),
                        "the worker did not LISTEN again after its connection was lost")
        self.assertTrue(await _until(lambda: len(self.claims) > before),
                        "no claim sweep after reconnecting, so a task made ready while nobody listened waits for the poll")
        # and the new connection's notifies wake it
        before = len(self.claims)
        self.pool.conns[1].notify("http")
        self.assertTrue(await _until(lambda: len(self.claims) > before))


TASK = "22222222-2222-2222-2222-222222222222"


class _ClaimConn:
    def __init__(self, log: list, context_fails: bool) -> None:
        self.log = log
        self.context_fails = context_fails

    async def execute(self, sql, *args):
        self.log.append(sql)

    async def fetchval(self, sql, *args):
        if "to_regprocedure" in sql:
            return True
        if "claim_task" in sql:
            self.log.append("claim")
            return TASK
        if "get_task_context" in sql:
            self.log.append("context")
            if self.context_fails:
                raise RuntimeError("context refused")
            return json.dumps({"kind": "quick", "step_key": "s", "task_input": {}})
        if "queue_stale_timeout" in sql:
            self.log.append("stale")
            return 120
        return None


class TheClaimPathTakesFewerTransactions(unittest.TestCase):
    def _run(self, context_fails=False, tasks=1):
        log: list = []
        transactions = [0]

        @asynccontextmanager
        async def as_service(*a, **kw):
            transactions[0] += 1
            yield _ClaimConn(log, context_fails)

        async def quick(spec, ctx):
            return {"ok": True}

        async def offload(conn, tid, out):
            return out

        loop._STALE_PERIODS.clear()

        async def go():
            for _ in range(tasks):
                await loop.run_once("q-1319", "w1")

        with mock.patch.object(loop, "as_service", as_service), \
             mock.patch.dict(loop.HANDLERS, {"quick": quick}), \
             mock.patch.object(loop, "offload", offload):
            asyncio.run(go())
        return log, transactions[0]

    def test_the_context_is_read_in_the_claims_transaction(self):
        log, transactions = self._run()
        self.assertEqual(log[:4], ["claim", "savepoint task_context", "context", "release savepoint task_context"])
        # claim + context, the stale timeout, complete: three, where it was four
        self.assertEqual(transactions, 3)

    def test_a_failed_context_is_rolled_back_to_the_savepoint_not_with_the_claim(self):
        log: list = []

        @asynccontextmanager
        async def as_service(*a, **kw):
            yield _ClaimConn(log, True)

        with mock.patch.object(loop, "as_service", as_service), self.assertRaises(RuntimeError):
            asyncio.run(loop.run_once("q-1319", "w1"))
        self.assertEqual(log, ["claim", "savepoint task_context", "context", "rollback to savepoint task_context"])

    def test_the_stale_timeout_is_asked_once_for_many_tasks(self):
        log, transactions = self._run(tasks=5)
        self.assertEqual(log.count("stale"), 1, "the queue's stale timeout was asked for every task")
        self.assertEqual(transactions, 1 + 5 * 2)


if __name__ == "__main__":
    unittest.main()
