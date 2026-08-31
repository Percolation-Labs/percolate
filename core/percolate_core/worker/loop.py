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
from typing import Any, Awaitable, Callable

from ..core import as_service
from .http import http_call
from .templates import TerminalError

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
        out = await fn(ctx.get("task_input") or {}, ctx)
        async with as_service() as conn:
            await conn.execute(
                "select workflow.complete_task($1, $2::jsonb)", task_id, json.dumps(out))
        print(f"[{worker_id}]   ok", flush=True)
    except TerminalError as e:
        print(f"[{worker_id}]   terminal: {e}", flush=True)
        async with as_service() as conn:
            await conn.execute(
                "select workflow.fail_task($1, $2::jsonb, true)",
                task_id, json.dumps({"error": str(e), "terminal": True}))
    except Exception as e:
        print(f"[{worker_id}]   retryable: {e}", flush=True)
        async with as_service() as conn:
            await conn.execute(
                "select workflow.fail_task($1, $2::jsonb, false)",
                task_id, json.dumps({"error": str(e)}))
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
