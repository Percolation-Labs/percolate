"""The second built-in handler: a `sql` step in `mode: worker` (REM-1316).

WHY A SQL STEP NEEDS A WORKER AT ALL
An inline `sql` step runs inside the statement that made it ready -- start_workflow, or the complete_task of the step
before it -- and Postgres arms `statement_timeout` only when a top-level statement starts. So a step's `timeout_ms`
bounded nothing: on extension 0.2.38 `run_sql('select pg_sleep(3)', false, 1000)` ran its 3 s. percolate's
specs/workflow-engine/YAML.md ("Where a `sql` step runs") gives a step two modes, and in `worker` the step is a task
of its own, claimed like an http_call. This handler is the worker's half:

    select workflow.worker_sql_step_timeout(task, worker)    -- the step's limit, N ms
    set local statement_timeout = N                          -- a statement of its own
    select workflow.execute_worker_sql_step(task, worker)    -- the limit is armed when this starts, so it is exact
    set local statement_timeout = <what it was>
    select workflow.complete_task(task, output, worker)

all in one transaction, so a write step's rows commit with its completion or not at all, and complete_task -- which
makes the successors ready, and runs an inline one in the same statement -- is not held to the step's limit. A timeout
or an error rolls the transaction back and is raised to the loop, which fails the task through fail_task in a
transaction of its own; the usual rules decide whether it retries.

The worker still holds no table grants: both engine functions are SECURITY DEFINER, granted to `worker`, and refuse a
task this worker does not hold.
"""

from __future__ import annotations

from typing import Any

import asyncpg

from ..core import as_service
from .artifacts import offload
from .templates import TerminalError

SQL_TERMINAL_STATES = frozenset({"42501", "42883", "42P01", "42601", "P0001"})
"""SQLSTATEs the engine already treats as terminal for a sql step it runs inline (execute_sql_step): a refusal, a
missing function or table, a statement that does not parse, an exception the step raised on purpose. Each fails the
same way on every attempt, so a worker-run step fails on the first, as an inline one does. The loop's own
PERMANENT_DB_ERRORS (integrity, data, privilege) still apply on top of these."""


class Completed(dict):
    """The step's output, already written by complete_task in the step's own transaction.

    A dict, so it logs like any other output, and its own type, so the loop can tell "already completed, do not
    complete it again" from a step whose output merely looks like this one.
    """


async def sql_step(spec: dict, ctx: dict) -> Completed:
    """Run a claimed worker-mode `sql` step under its own statement_timeout, and complete it."""
    task_id, worker_id = ctx["_task_id"], ctx["_worker_id"]
    async with as_service() as conn:
        limit = await conn.fetchval(
            "select workflow.worker_sql_step_timeout($1, $2)", task_id, worker_id)
        if limit is None:
            # The lease moved between the claim and now (the reaper, or a cancel). Not terminal: the fail_task the
            # loop sends carries this worker's id, and the lease fence refuses it if somebody else holds the task.
            raise RuntimeError(f"this worker no longer holds sql task {task_id}")
        before = await conn.fetchval("select current_setting('statement_timeout')")
        # Its own statement, and an integer the database returned, so the formatting cannot carry anything else.
        await conn.execute(f"set local statement_timeout = {int(limit)}")
        try:
            out = await conn.fetchval(
                "select workflow.execute_worker_sql_step($1, $2)", task_id, worker_id)
        except asyncpg.QueryCanceledError as e:
            raise RuntimeError(
                f"the step's timeout_ms ({int(limit)} ms) ran out: {e} (SQLSTATE {e.sqlstate})") from None
        except asyncpg.PostgresError as e:
            if e.sqlstate in SQL_TERMINAL_STATES:
                raise TerminalError(f"{e} (SQLSTATE {e.sqlstate})") from None
            raise
        await conn.execute("select set_config('statement_timeout', $1, true)", before)
        # As the loop does for every other kind, between the handler and complete_task.
        out = await offload(conn, task_id, out)
        await conn.execute(
            "select workflow.complete_task($1, $2::jsonb, $3)", task_id, out, worker_id)
    return Completed(out)

