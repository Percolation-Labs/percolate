"""The step loop. There is one, and you extend it rather than replace it.

    from p8.worker import handler, run

    @handler("transcode")
    async def transcode(spec, ctx):
        return {"duration": await ffmpeg(ctx["run_input"]["file_key"])}

    run(queue="media")

WHAT NEEDS A PROCESS AT ALL
Only two step kinds. `http_call` performs network I/O; `work` runs code we do
not have. Everything else -- indexing, projection, a query, a rollup -- is
`kind = 'sql'` and executes inside Postgres with nothing running anywhere
(workflow-engine/schema.sql §17). Reaching for a worker is usually a sign the
step should have been `sql`.

The worker holds NO table grants. Every interaction is a SECURITY DEFINER
function call -- claim_task, get_task_context, complete_task, fail_task --
which is why "bring your own worker" is safe to offer: a compromised worker can
claim and complete tasks, and nothing else.
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
from collections.abc import Awaitable, Callable
from typing import Any

import asyncpg

from ..core import as_service
from .artifacts import offload
from .http import http_call
from .agent_auth import uses_run_identity
from .templates import TerminalError, resolve_task

PERMANENT_DB_ERRORS = (
    # 23xxx -- unique, foreign key, check, not-null. The row is wrong.
    asyncpg.exceptions.IntegrityConstraintViolationError,
    # 22xxx -- bad literal, numeric overflow, invalid json. The value is wrong.
    asyncpg.exceptions.DataError,
)
"""Database errors a retry cannot fix, so the task fails on the first attempt.

Everything NOT here stays retryable, and the omissions are the design: a
serialization failure, a deadlock and a connection drop are all "the database
was busy", which is the case the retry budget was bought for.
"""

Handler = Callable[[dict, dict], Awaitable[Any]]
HANDLERS: dict[str, Handler] = {"http_call": http_call}


def handler(kind: str) -> Callable[[Handler], Handler]:
    """Register a handler for a step kind. This is the whole extension API."""
    def deco(fn: Handler) -> Handler:
        HANDLERS[kind] = fn
        return fn
    return deco


async def run_once(queue: str, worker_id: str) -> bool:
    """Claim one task and run it. True if work was done."""
    async with as_service() as conn:
        row = await conn.fetchval(
            "select (workflow.claim_task($1, $2)).id", queue, worker_id)
    if not row:
        return False
    task_id = str(row)

    async with as_service() as conn:
        ctx = json.loads(await conn.fetchval(
            "select workflow.get_task_context($1, $2)::text", task_id, worker_id))

    kind = ctx["kind"]
    fn = HANDLERS.get(kind)
    print(f"[{worker_id}] {ctx.get('step_key')} ({kind})", flush=True)

    try:
        if fn is None:
            raise TerminalError(
                f"no handler registered for kind '{kind}' -- register one with "
                f"@handler({kind!r}), or point this worker at a different queue")

        spec = ctx.get("task_input") or {}
        if kind == "http_call" and uses_run_identity(spec):
            try:
                async with as_service() as conn:
                    owner = await conn.fetchval("select workflow.task_owner($1, $2)", task_id, worker_id)
            except asyncpg.InsufficientPrivilegeError as e:
                raise TerminalError(str(e)) from None
            except asyncpg.UndefinedFunctionError:
                raise TerminalError("The database needs workflow.task_owner; apply the workflow-engine RBAC integration before running agent steps") from None
            ctx["_agent_caller"] = str(owner)
        # `work` steps get their templates resolved HERE, and http_call ones do
        # not, and the asymmetry is deliberate rather than left over.
        #
        # YAML.md promises that {{run.x}} / {{steps.x.y}} / {{env.X}} resolve at
        # dispatch. For http_call that happens inside build_request, on the
        # nested request spec. For `work` it happened NOWHERE: a step written as
        # `input: {resource_id: '{{run.resource_id}}'}` reached the handler with
        # the braces intact, and every handler would have had to know to call
        # resolve() itself -- which the first one written against this engine
        # did not, and the failure was a UUID parse error nineteen characters
        # long, retried five times.
        #
        # It is not done for every kind because http_call's payload can legally
        # CONTAIN braces (a chunk of text on its way to a model), and resolving
        # an already-resolved value would turn that data into a missing
        # reference. One pass, at the layer that owns the shape.
        if kind == "work":
            spec = resolve_task(spec, ctx)

        ctx["_task_id"] = task_id
        ctx["_worker_id"] = worker_id
        out = await fn(spec, ctx)
        async with as_service() as conn:
            # Between the handler and complete_task, so it covers every step
            # kind rather than only http_call. An oversized output used to be a
            # terminal failure naming a remedy that had no implementation on
            # this side; now the bytes go to object storage and the task
            # completes carrying a "$artifact" ref instead of a "result".
            out = await offload(conn, task_id, out)
            # THE OBJECT, NOT ITS TEXT. `$2` is inferred as jsonb, and every
            # pool this package opens installs a jsonb codec whose encoder is
            # json.dumps -- so a pre-dumped string was encoded a SECOND time
            # and every task this worker has ever completed arrived as a jsonb
            # STRING containing a document. It was invisible because the engine
            # repairs it: workflow.normalize_output unwraps the one unambiguous
            # case and files a task_events row saying "the producer should pass
            # the object to complete_task/fail_task(uuid, jsonb), not its
            # text". This worker was that producer. Measured on the dogfood
            # stack before this line changed -- workflow.encoding_drift()
            # reported 10 repairs from ingest-1 and 2 from worker-1.
            await conn.execute(
                "select workflow.complete_task($1, $2::jsonb)", task_id, out)
        if isinstance(out, dict) and "$artifact" in out:
            print(f"[{worker_id}]   ok -- offloaded to {out['$artifact']}", flush=True)
        else:
            print(f"[{worker_id}]   ok", flush=True)
    except TerminalError as e:
        print(f"[{worker_id}]   terminal: {e}", flush=True)
        async with as_service() as conn:
            await conn.execute(
                "select workflow.fail_task($1, $2::jsonb, true)",
                # The object, for the reason complete_task above carries.
                task_id, {"error": str(e), "terminal": True})
    except Exception as e:
        # A CONSTRAINT VIOLATION IS NOT A TRANSIENT FAULT, and treating every
        # non-TerminalError as one meant the same row was re-inserted against
        # the same unique index five times, with a backoff between each:
        #
        #   retryable: duplicate key value violates unique constraint
        #   "idx_node_keys_canonical" -- Key (org_id, key, entity_type)=
        #   (null, rotterdam psc report, document) already exists.
        #
        # Nothing about the second attempt differs from the first. The retry
        # budget exists for the network and for a busy database; spending it on
        # a deterministic refusal delays the failure without changing it, and
        # buries the real message under four identical copies.
        #
        # Deliberately narrow. Integrity and data errors say "what you sent is
        # wrong"; serialization failures and deadlocks say "try again" and are
        # NOT in here, because those are exactly what the retry budget is for.
        terminal = isinstance(e, PERMANENT_DB_ERRORS)
        label = "terminal" if terminal else "retryable"
        print(f"[{worker_id}]   {label}: {e}", flush=True)
        payload = {"error": str(e)}
        if terminal:
            payload["terminal"] = True
        async with as_service() as conn:
            await conn.execute(
                "select workflow.fail_task($1, $2::jsonb, $3)",
                # Same: normalize_output is reached from fail_task's error
                # too, which is why its event name covers both.
                task_id, payload, terminal)
    return True


async def serve(queue: str | None = None, worker_id: str | None = None,
                poll_seconds: float | None = None) -> None:
    queue = queue or os.environ.get("P8_QUEUE", "default")
    worker_id = worker_id or os.environ.get("P8_WORKER_ID", f"worker-{os.getpid()}")
    poll = poll_seconds or float(os.environ.get("P8_POLL_SECONDS", "2"))
    print(f"[{worker_id}] queue '{queue}', handlers: {sorted(HANDLERS)}", flush=True)
    while True:
        try:
            if not await run_once(queue, worker_id):
                await asyncio.sleep(poll)
        except asyncio.CancelledError:
            return
        except Exception as e:
            # One bad task must never kill the loop -- a crashlooping worker
            # stops draining the whole queue.
            print(f"[{worker_id}] loop error: {e}", file=sys.stderr, flush=True)
            await asyncio.sleep(poll)


def run(queue: str | None = None, **kw: Any) -> None:
    """Blocking entry point, for a `if __name__ == '__main__'` worker."""
    asyncio.run(serve(queue, **kw))
