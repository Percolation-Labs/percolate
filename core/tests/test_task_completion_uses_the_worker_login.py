"""complete_task and fail_task run on a login that can become `worker`.

The agent runtime completes or fails the workflow task a scheduled run was
dispatched by (`agentic/brief.md` §3), and both functions are granted to
`worker`. The runtime switched its own connection to `worker`. That connection
logs in as `authenticator`, which no install makes a member of `worker`, so the
switch was refused with `permission denied to set role "worker"`. The run ended
`failed`, the task was never told, and the dispatching worker held it for the
step's whole `wait_ms`. Measured on a stock compose stack with a gateway added.

`P8_WORKER_DSN` names the login instead. The alternative, granting `worker` to
`authenticator`, would let every PostgREST request's login become a worker.

No database: asserted at the pool and connection seams. The live proof is
get-percolate's `ci/coldstart.sh`, whose scheduled run must be failed by the
runtime itself within 30 seconds.
"""
import os
import unittest
from contextlib import asynccontextmanager
from unittest.mock import AsyncMock, patch
from uuid import uuid4

import asyncpg

from percolate_core.agentic.db.repository import PgRepository
from percolate_core.core import identity

TASK = uuid4()
USER = str(uuid4())


class FakeConn:
    def __init__(self, refuse_role=False):
        self.statements = []
        self.refuse_role = refuse_role

    def transaction(self):
        @asynccontextmanager
        async def tx():
            yield
        return tx()

    async def execute(self, sql, *args):
        if self.refuse_role and sql.startswith("set local role"):
            raise asyncpg.InsufficientPrivilegeError('permission denied to set role "worker"')
        self.statements.append(sql)


class TaskCompletionUsesTheWorkerLogin(unittest.IsolatedAsyncioTestCase):
    """complete_task and fail_task run on a login that can become `worker`."""

    def setUp(self):
        identity._TASK_WORKER_POOL = None
        self.addCleanup(setattr, identity, "_TASK_WORKER_POOL", None)
        self.conn = FakeConn()
        self.acquired_from = []

        @asynccontextmanager
        async def acquired(p):
            self.acquired_from.append(p)
            yield self.conn

        p = patch.object(identity, "acquired", acquired)
        p.start()
        self.addCleanup(p.stop)
        self.main_pool = AsyncMock(return_value="main pool")
        p = patch.object(identity, "pool", self.main_pool)
        p.start()
        self.addCleanup(p.stop)

    async def test_with_p8_worker_dsn_a_separate_pool_on_that_login_is_used(self):
        dsn = "postgres://worker:pw@db:5432/percolate"
        create = AsyncMock(return_value="worker pool")
        with patch.dict(os.environ, {"P8_WORKER_DSN": dsn}), \
             patch.object(identity.asyncpg, "create_pool", create):
            async with identity.as_task_worker():
                pass
            async with identity.as_task_worker():
                pass
        self.assertEqual(create.await_args.args, (dsn,))
        self.assertEqual(create.await_count, 1, "a pool per call is a connection leak")
        self.assertEqual(self.acquired_from, ["worker pool", "worker pool"])
        self.main_pool.assert_not_called()
        self.assertEqual(self.conn.statements, ["set local role worker"] * 2)

    async def test_without_it_the_process_login_is_switched_as_before(self):
        env = {k: v for k, v in os.environ.items() if k != "P8_WORKER_DSN"}
        with patch.dict(os.environ, env, clear=True):
            async with identity.as_task_worker():
                pass
        self.assertEqual(self.acquired_from, ["main pool"])
        self.assertEqual(self.conn.statements, ["set local role worker"])

    async def test_a_refused_switch_names_the_variable_not_just_the_role(self):
        self.conn.refuse_role = True
        env = {k: v for k, v in os.environ.items() if k != "P8_WORKER_DSN"}
        with patch.dict(os.environ, env, clear=True):
            with self.assertRaises(PermissionError) as refused:
                async with identity.as_task_worker():
                    self.fail("the body ran on a connection that is not a worker")
            problem = await identity.task_worker_problem()
        self.assertIn("P8_WORKER_DSN", str(refused.exception))
        self.assertIn("permission denied to set role", str(refused.exception))
        self.assertEqual(problem, str(refused.exception))

    async def test_the_repository_completes_and_fails_through_it(self):
        class CallerClient:
            @asynccontextmanager
            async def as_user(self, claims, role=None):
                raise AssertionError(f"task function ran on the caller's connection as {role}")
                yield

        repo = PgRepository(CallerClient(), {"sub": USER})
        await repo.fail_task(TASK, {"error": "x"}, True)
        await repo.complete_task(TASK, {"result": "y"})
        self.assertEqual(self.conn.statements, [
            "set local role worker", "select workflow.fail_task($1, $2::jsonb, $3)",
            "set local role worker", "select workflow.complete_task($1, $2::jsonb)",
        ])


if __name__ == "__main__":
    unittest.main()
