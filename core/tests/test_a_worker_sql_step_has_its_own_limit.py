"""A worker-mode `sql` step runs under its own statement_timeout (REM-1316).

An inline `sql` step runs inside the statement that made it ready, and Postgres arms statement_timeout only when a
top-level statement starts, so a step's `timeout_ms` bounded nothing: on extension 0.2.38 `run_sql('select
pg_sleep(3)', false, 1000)` ran its 3 s. percolate's YAML.md ("Where a `sql` step runs") gives a step `mode: worker`,
in which the step is a task this worker claims and runs as a top-level statement under its own limit.

Two halves:

* `SqlStepStatements` drives `sql_step` against a recording connection: the limit is set as a statement of its own,
  before the step's, in the transaction that then completes the task; a timeout and an error each raise, so the loop
  fails the task through fail_task; a refusal fails it terminally.
* `AgainstADatabase` runs `loop.run_once` -- the real worker loop, claim to completion -- against a percolate database
  of 0.2.39 or later, and is skipped unless `P8_SQL_STEP_TEST_DSN` names one, with a login that may `set role
  worker` (the `p8` superuser of a `dev/ci-database.sh` container does). A step with timeout_ms 1000 running
  pg_sleep(3) must fail at about 1 s with a statement-timeout reason. It changes nothing it does not create, and
  deletes what it created. Before this handler existed the loop failed the task terminally at once: "no handler
  registered for kind 'sql'".
"""

from __future__ import annotations

import asyncio
import json
import os
import time
import unittest
import uuid
from contextlib import asynccontextmanager
from unittest import mock

import asyncpg

from percolate_core.worker import loop
from percolate_core.worker.templates import TerminalError

TASK = "11111111-1111-1111-1111-111111111111"


class _Conn:
    def __init__(self, log: list, fail: BaseException | None = None) -> None:
        self.log = log
        self.fail = fail

    async def fetchval(self, sql: str, *args):
        self.log.append(sql)
        if "worker_sql_step_timeout" in sql:
            return 1000
        if "current_setting('statement_timeout')" in sql:
            return "0"
        if "execute_worker_sql_step" in sql:
            if self.fail is not None:
                raise self.fail
            return {"result": [{"n": 42}]}
        return None

    async def execute(self, sql: str, *args):
        self.log.append(sql)


class SqlStepStatements(unittest.IsolatedAsyncioTestCase):
    async def _run(self, fail=None):
        from percolate_core.worker import sql as sql_module

        log: list = []
        transactions: list = []

        @asynccontextmanager
        async def as_service(*a, **kw):
            transactions.append(len(log))
            yield _Conn(log, fail)

        async def offload(conn, task_id, out):
            return out

        with mock.patch.object(sql_module, "as_service", as_service), \
             mock.patch.object(sql_module, "offload", offload):
            out = await sql_module.sql_step({}, {"_task_id": TASK, "_worker_id": "w1"})
        return out, log, transactions

    async def test_the_limit_is_a_statement_of_its_own_before_the_step_in_the_completing_transaction(self):
        from percolate_core.worker.sql import Completed

        out, log, transactions = await self._run()
        self.assertEqual(len(transactions), 1, "the step and its completion must be one transaction")
        limit = next(i for i, s in enumerate(log) if s == "set local statement_timeout = 1000")
        step = next(i for i, s in enumerate(log) if "execute_worker_sql_step" in s)
        restore = next(i for i, s in enumerate(log) if "set_config('statement_timeout'" in s)
        done = next(i for i, s in enumerate(log) if "complete_task" in s)
        self.assertLess(limit, step, "statement_timeout must be set before the step's statement starts")
        self.assertLess(step, restore)
        self.assertLess(restore, done, "complete_task (and an inline successor) must not run under the step's limit")
        self.assertIsInstance(out, Completed)
        self.assertEqual(dict(out), {"result": [{"n": 42}]})

    async def test_a_timeout_raises_retryable_with_the_reason(self):
        e = asyncpg.QueryCanceledError("canceling statement due to statement timeout")
        with self.assertRaises(RuntimeError) as got:
            await self._run(fail=e)
        self.assertNotIsInstance(got.exception, TerminalError)
        self.assertIn("timeout_ms (1000 ms)", str(got.exception))
        self.assertIn("statement timeout", str(got.exception))

    async def test_a_statement_that_cannot_parse_fails_terminally_as_it_would_inline(self):
        e = asyncpg.PostgresSyntaxError("syntax error at or near \"selec\"")
        with self.assertRaises(TerminalError):
            await self._run(fail=e)

    async def test_the_loop_does_not_complete_a_step_twice(self):
        log: list = []

        class _LoopConn:
            async def fetchval(self, sql, *args):
                if "to_regprocedure" in sql:
                    return True
                if "claim_task" in sql:
                    return TASK
                if "get_task_context" in sql:
                    return json.dumps({"kind": "sql", "step_key": "s", "task_input": {"mode": "worker"}})
                if "queue_stale_timeout" in sql:
                    return 120
                return None

            async def execute(self, sql, *args):
                log.append(sql)

        @asynccontextmanager
        async def as_service(*a, **kw):
            yield _LoopConn()

        async def fake_sql_step(spec, ctx):
            from percolate_core.worker.sql import Completed
            return Completed({"result": 1})

        with mock.patch.object(loop, "as_service", as_service), \
             mock.patch.dict(loop.HANDLERS, {"sql": fake_sql_step}):
            self.assertTrue(await loop.run_once("http", "w1"))
        self.assertFalse([s for s in log if "complete_task" in s or "fail_task" in s],
                         "the loop completed or failed a step the handler had already completed")


DSN = os.environ.get("P8_SQL_STEP_TEST_DSN")


@unittest.skipUnless(DSN, "set P8_SQL_STEP_TEST_DSN to a percolate >= 0.2.39 database to run the live half")
class AgainstADatabase(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        from percolate_core.core import identity

        self.admin = await asyncpg.connect(DSN)
        await identity.open_pool(DSN, min_size=1, max_size=3)
        self.queue = f"t1316-{uuid.uuid4().hex[:8]}"
        self.worker = f"w-{self.queue}"
        self.defs: list = []

    async def asyncTearDown(self) -> None:
        from percolate_core.core import identity

        for name in self.defs:
            try:
                await self.admin.execute(
                    "delete from workflow.runs where workflow_def_id in"
                    " (select id from workflow.definitions where name = $1)", name)
                await self.admin.execute("delete from workflow.definitions where name = $1", name)
            except asyncpg.PostgresError as e:  # a fixture left behind is named, not fatal
                print(f"\n  could not remove fixture {name}: {e}")
        await self.admin.close()
        await identity.close_pool()

    async def _start(self, steps: list) -> str:
        name = f"t_{self.queue.replace('-', '_')}_{len(self.defs)}"
        self.defs.append(name)
        await self.admin.execute(
            "insert into workflow.definitions (name, spec) values ($1, $2::jsonb)",
            name, json.dumps({"mode": "worker", "steps": steps}))
        return str(await self.admin.fetchval("select workflow.start_workflow($1, '{}'::jsonb)", name))

    async def _task(self, run: str, key: str):
        return await self.admin.fetchrow(
            "select status, attempts, error::text as error, output::text as output from workflow.tasks"
            " where run_id = $1::uuid and step_key = $2", run, key)

    async def test_a_3s_step_under_timeout_ms_1000_fails_at_about_1s(self):
        run = await self._start([{"key": "nap", "kind": "sql", "queue": self.queue,
                                  "input": {"statement": "select pg_sleep(3) as s", "timeout_ms": 1000}}])
        t0 = time.monotonic()
        self.assertTrue(await loop.run_once(self.queue, self.worker), "the worker found nothing to claim")
        took = time.monotonic() - t0
        tk = await self._task(run, "nap")
        print(f"\n  REM-1316: run_once took {took:.3f}s; task {tk['status']} after {tk['attempts']} attempt(s): {tk['error']}")
        self.assertIn("statement timeout", tk["error"] or "", "the step did not fail on its statement timeout")
        self.assertEqual(tk["attempts"], 1)
        self.assertLess(took, 2.0, f"a 3 s step under timeout_ms 1000 took {took:.3f}s")
        self.assertGreater(took, 0.9)

    async def test_a_step_that_succeeds_readies_its_successor_without_running_it(self):
        run = await self._start([
            {"key": "a", "kind": "sql", "queue": self.queue, "input": {"statement": "select 41 + 1 as n"}},
            {"key": "b", "kind": "sql", "queue": self.queue, "depends_on": ["a"],
             "input": {"statement": "select {{steps.a.result.0.n}} as n"}}])
        self.assertTrue(await loop.run_once(self.queue, self.worker))
        a, b = await self._task(run, "a"), await self._task(run, "b")
        self.assertEqual(a["status"], "succeeded", a["error"])
        self.assertEqual(json.loads(a["output"])["result"], [{"n": 42}])
        self.assertEqual(b["status"], "ready", "complete_task ran the worker-mode successor itself")
        self.assertTrue(await loop.run_once(self.queue, self.worker))
        b = await self._task(run, "b")
        self.assertEqual(json.loads(b["output"])["result"], [{"n": 42}], b["error"])


if __name__ == "__main__":
    unittest.main()
