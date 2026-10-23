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
from .http import Dispatched, http_call
from .agent_auth import uses_run_identity
from .templates import TerminalError, resolve_task

PERMANENT_DB_ERRORS = (
    # 23xxx -- unique, foreign key, check, not-null. The row is wrong.
    asyncpg.exceptions.IntegrityConstraintViolationError,
    # 22xxx -- bad literal, numeric overflow, invalid json. The value is wrong.
    asyncpg.exceptions.DataError,
    # 42501 -- the database refused this caller: a missing permission, a may_*
    # predicate, or a policy that admits no row to write. The CALLER is wrong,
    # and the fourth attempt asks the same question of the same grants. The
    # engine's own SQL retry lists already treat 42501 as terminal
    # (workflow-engine execute_sql_step and run_ready_sql_steps), so a `work:`
    # step refused out here was the one path still spending its whole budget on
    # it -- the inbound half of the class an exhausted provider account is.
    asyncpg.exceptions.InsufficientPrivilegeError,
)
"""Database errors a retry cannot fix, so the task fails on the first attempt.

Everything NOT here stays retryable, and the omissions are the design: a
serialization failure, a deadlock and a connection drop are all "the database
was busy", which is the case the retry budget was bought for.
"""

Handler = Callable[[dict, dict], Awaitable[Any]]
HANDLERS: dict[str, Handler] = {"http_call": http_call}

HEARTBEAT_FRACTION = 3
"""Heartbeat this many times per stale timeout (REM-109).

Not an interval, because an interval on this side is a copy of a fact that
lives on the queue: `workflow.queue_stale_timeout` is asked at claim time and
the period is derived from it, so raising a queue's `stale_timeout` cannot
leave the workers pacing to the old one. Three rather than two so a single
dropped beat -- one slow round trip, one restarted connection -- does not cost
the lease.
"""


async def _heartbeat_until_done(task_id: str, worker_id: str, period: float) -> None:
    """Say the lease is still held, until cancelled.

    WHY THIS EXISTS. `workflow.heartbeat_task` shipped, was granted to `worker`,
    and was called by nothing: `heartbeat_at` was written once, at claim. The
    reaper takes a lease after `stale_timeout` of silence -- two minutes by
    default -- while `ingest/transcribe.py` waits 300 seconds on one HTTP call
    and `ingest/embed.py` waits 120. So a transcription task was failed and
    re-queued with the first copy still in flight, up to `max_attempts` times:
    duplicate provider spend and duplicate writes, on the ingestion path, with
    every copy eventually succeeding and the last one winning.

    Raising the timeout instead would have made it a number on the queue that
    has to stay above the largest timeout any handler might ever use -- which
    nothing checks, and which the next handler breaks. A heartbeat makes the
    bound one on SILENCE rather than on duration, which is what the reaper is
    actually for: distinguishing a long task from a dead worker.

    A false return means the database says this lease is no longer ours to
    extend -- the lease moved, or cancellation was requested (the function
    returns `not cancel_requested`). Either way there is nothing further to
    say, so the beating stops and the handler is left to finish; the existing
    `complete_task` / `fail_task` path already handles arriving late, because
    `lease_violation` is checked there too. Cancelling the handler from here
    would be inventing cancellation semantics this issue did not buy.

    Never fails the task. A heartbeat that cannot reach the database is the
    same situation as no heartbeat at all, which is the behaviour that existed
    before this function -- so it logs and keeps trying rather than turning a
    transient blip into a failed task.
    """
    while True:
        await asyncio.sleep(period)
        try:
            async with as_service() as conn:
                alive = await conn.fetchval(
                    "select workflow.heartbeat_task($1, $2)", task_id, worker_id)
        except asyncio.CancelledError:
            raise
        except asyncpg.UndefinedFunctionError:
            # An older database: the lease behaves exactly as it did before
            # this, so say so once and stop rather than logging every period.
            print(f"[{worker_id}] no workflow.heartbeat_task in this database; "
                  f"long tasks are bounded by stale_timeout alone", flush=True)
            return
        except Exception as e:  # noqa: BLE001 -- see the docstring
            print(f"[{worker_id}] heartbeat failed ({type(e).__name__}: {e}); "
                  f"retrying in {period:.0f}s", flush=True)
            continue
        if not alive:
            print(f"[{worker_id}] heartbeat refused -- the lease moved or "
                  f"cancellation was requested; no longer extending it", flush=True)
            return


async def _hold_until_released(task_id: str, worker_id: str, period: float,
                               wait_seconds: float) -> None:
    """Hold an async step's lease until its callee completes or fails the task.

    WHY A HOLD. An async http_call's callee -- the agent runtime, for a
    scheduled turn -- completes the task itself when the work is done
    (agentic/brief.md §3). Returning without a heartbeat left the task
    `running` and silent, so the reaper took it after `stale_timeout` (two
    minutes by default) and a second worker dispatched the same turn again,
    while turns take minutes. Parking it in `waiting_external`, as
    workflow-engine/spec.md §14 describes, is not possible on extension 0.2.0:
    no function granted to `worker` parks an http_call task, and the lease
    fence refuses `complete_task` on a claimed task that is no longer `running`
    ("the lease was revoked -- task is waiting_external after 1 attempt(s)").
    So the worker keeps the lease the way any long handler does -- heartbeats,
    paced from the queue -- and writes nothing. (On extension 0.2.0 the pace is
    not the queue's: `queue_stale_timeout` fails for `worker` with "permission
    denied for function stale_timeout_default", run_once falls back to 40s,
    and a queue whose stale_timeout is under about 80s is reaped mid-hold.)

    WHAT IT COSTS: one worker slot for the length of the external work.
    `percolate worker` runs one task at a time, so while a scheduled turn runs
    that worker process claims nothing else. Parking would free the slot, and
    that is the reason to build it in the engine.

    WHEN IT STOPS. `heartbeat_task` returns false once the task is not
    `running` under this worker: the callee completed or failed it, the reaper
    took the lease, or the run was cancelled. Every one of those gets the same
    answer -- write nothing and return -- so they are not told apart, and no
    function `worker` may call could tell them apart: heartbeat_task, task_owner
    and get_task_context each report only "not held by you". The engine
    records the false return as a `lease_violation` task event (op
    `heartbeat`), so a dispatch the callee completed leaves one such row.

    WHEN IT GIVES UP. Past `wait_seconds` (the step's `wait_ms`) with the lease
    still held, the task is failed TERMINALLY -- a retry would dispatch a turn
    the callee may still be running, which is the duplicate this exists to
    prevent -- and with this worker's id, so the fence refuses the write if the
    lease moved after the last beat.

    Never raises (short of cancellation): the caller's generic handler would
    otherwise fail the task as retryable and without the worker id.
    """
    clock = asyncio.get_running_loop()
    deadline = clock.time() + wait_seconds
    while True:
        await asyncio.sleep(max(0.0, min(period, deadline - clock.time())))
        try:
            async with as_service() as conn:
                alive = await conn.fetchval(
                    "select workflow.heartbeat_task($1, $2)", task_id, worker_id)
        except asyncio.CancelledError:
            raise
        except asyncpg.UndefinedFunctionError:
            print(f"[{worker_id}] no workflow.heartbeat_task in this database; cannot "
                  f"hold the lease, so the task is left to the callee", flush=True)
            return
        except Exception as e:  # noqa: BLE001 -- a blip is not a release
            print(f"[{worker_id}] heartbeat failed ({type(e).__name__}: {e}); "
                  f"still holding", flush=True)
            alive = True
        if not alive:
            print(f"[{worker_id}]   released -- the task is no longer running "
                  f"under this worker", flush=True)
            return
        if clock.time() >= deadline:
            reason = (f"the callee did not complete or fail this task within "
                      f"{wait_seconds:g}s of a successful dispatch (wait_ms)")
            print(f"[{worker_id}]   terminal: {reason}", flush=True)
            try:
                async with as_service() as conn:
                    await conn.execute(
                        "select workflow.fail_task($1, $2::jsonb, true, $3)",
                        task_id, {"error": reason, "terminal": True}, worker_id)
            except asyncio.CancelledError:
                raise
            except Exception as e:  # noqa: BLE001 -- see the docstring
                print(f"[{worker_id}] could not fail the held task "
                      f"({type(e).__name__}: {e})", flush=True)
            return


CAPABILITIES: tuple[str, ...] = ("dry_run",)
"""What this worker tells claim_task it can run safely. See run_once."""


def handler(kind: str) -> Callable[[Handler], Handler]:
    """Register a handler for a step kind. This is the whole extension API."""
    def deco(fn: Handler) -> Handler:
        HANDLERS[kind] = fn
        return fn
    return deco


async def run_once(queue: str, worker_id: str) -> bool:
    """Claim one task and run it. True if work was done."""
    async with as_service() as conn:
        # A DRY RUN'S TASK GOES ONLY TO A WORKER THAT DECLARES IT (REM-1125). Its agent call is flagged `dry_run`,
        # and a runtime that predates the flag would make the real call, so claim_task hands it out only to a caller
        # that lists 'dry_run'. This worker may list it because the runtime it calls ships in the same image and
        # answers that flag on a stand-in model with no tools (sequencer.dry_run_overrides). A database from before
        # the capabilities argument has no dry runs to hand out, and is asked the two-argument form.
        if await conn.fetchval("select to_regprocedure('workflow.claim_task(text,text,text[])') is not null"):
            row = await conn.fetchval(
                "select (workflow.claim_task($1, $2, $3::text[])).id", queue, worker_id, list(CAPABILITIES))
        else:
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
            # THE RUN'S STARTER TRAVELS WITH ITS OWNER (REM-247): workflow.task_principal where the database has it,
            # asked for by name first because this is one transaction and a failed call would abort it. A database
            # from before it answers task_owner alone, and the step's token stays owner-only, as it always was.
            starter = None
            try:
                async with as_service() as conn:
                    if await conn.fetchval("select to_regprocedure('workflow.task_principal(uuid,text)') is not null"):
                        row = await conn.fetchrow(
                            "select owner_id, started_actor, started_credential_id"
                            "  from workflow.task_principal($1, $2)", task_id, worker_id)
                        owner = row["owner_id"]
                        starter = {"actor": row["started_actor"], "credential_id": row["started_credential_id"]}
                    else:
                        owner = await conn.fetchval("select workflow.task_owner($1, $2)", task_id, worker_id)
            except asyncpg.InsufficientPrivilegeError as e:
                raise TerminalError(str(e)) from None
            except asyncpg.UndefinedFunctionError:
                raise TerminalError("The database needs workflow.task_owner; apply the workflow-engine RBAC integration before running agent steps") from None
            ctx["_agent_caller"] = str(owner)
            ctx["_agent_starter"] = starter
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
        # BEFORE the resolution below, not after it, because `{{task.id}}` is
        # resolvable now (REM-126) and `work` resolves HERE while `http_call`
        # resolves inside its own handler. Set after, a `work` step asking for
        # `{{task.id}}` got `template {{task.id}} resolved to nothing` while the
        # identical reference in an `http_call` step worked -- one namespace
        # behaving differently by step kind, which is the asymmetry the comment
        # above is at pains to say is deliberate about resolution TIMING and is
        # not deliberate about what is resolvable.
        ctx["_task_id"] = task_id
        ctx["_worker_id"] = worker_id

        if kind == "work":
            spec = resolve_task(spec, ctx)

        # The handler runs with a heartbeat beside it, so a task that takes
        # longer than the queue's stale_timeout finishes once instead of being
        # reaped and re-run with the first copy still in flight (REM-109). The
        # period comes from the database rather than from a constant here --
        # see HEARTBEAT_FRACTION.
        try:
            async with as_service() as conn:
                stale = await conn.fetchval(
                    "select extract(epoch from workflow.queue_stale_timeout($1))", queue)
            period = max(float(stale) / HEARTBEAT_FRACTION, 1.0)
        except Exception as e:  # noqa: BLE001
            # An older database with no queue_stale_timeout, or a blip. Fall
            # back to the default the schema ships (2 minutes) rather than
            # skipping the heartbeat: a wrong-but-frequent beat is safe, and
            # no beat at all is the defect.
            period = 120.0 / HEARTBEAT_FRACTION
            print(f"[{worker_id}] could not read the queue's stale timeout "
                  f"({type(e).__name__}); heartbeating every {period:.0f}s", flush=True)

        beat = asyncio.create_task(_heartbeat_until_done(task_id, worker_id, period))
        try:
            out = await fn(spec, ctx)
        finally:
            # Stop before complete_task/fail_task, so the last word on this
            # task is the terminal transition rather than a beat racing it.
            beat.cancel()
            try:
                await beat
            except asyncio.CancelledError:
                pass
        if isinstance(out, Dispatched):
            # An async http_call was accepted by its callee, which completes
            # or fails this task itself. Completing it here is what made every
            # scheduled run finish before it began; returning without a
            # heartbeat let the reaper hand it to a second dispatch. So this
            # worker HOLDS it -- and is occupied for the length of the external
            # work, which is the cost; see _hold_until_released.
            print(f"[{worker_id}]   dispatched (HTTP {out['status']}) -- holding "
                  f"until the callee completes it, at most {out.wait_seconds:g}s", flush=True)
            await _hold_until_released(task_id, worker_id, period, out.wait_seconds)
            return True
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
            #
            # WITH THE WORKER ID (REM-553). lease_violation compares holders
            # only when one is passed, so a worker whose lease was reaped and
            # handed to another could complete that other worker's task.
            await conn.execute(
                "select workflow.complete_task($1, $2::jsonb, $3)", task_id, out, worker_id)
        if isinstance(out, dict) and "$artifact" in out:
            print(f"[{worker_id}]   ok -- offloaded to {out['$artifact']}", flush=True)
        else:
            print(f"[{worker_id}]   ok", flush=True)
    except TerminalError as e:
        print(f"[{worker_id}]   terminal: {e}", flush=True)
        async with as_service() as conn:
            await conn.execute(
                "select workflow.fail_task($1, $2::jsonb, true, $3)",
                # The object, for the reason complete_task above carries, and
                # the worker id for the lease fence (REM-553).
                task_id, {"error": str(e), "terminal": True}, worker_id)
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
        # wrong" and a refusal says "who you are is wrong"; serialization
        # failures and deadlocks say "try again" and are NOT in here, because
        # those are exactly what the retry budget is for.
        terminal = isinstance(e, PERMANENT_DB_ERRORS)
        label = "terminal" if terminal else "retryable"
        print(f"[{worker_id}]   {label}: {e}", flush=True)
        payload = {"error": str(e)}
        if terminal:
            payload["terminal"] = True
        async with as_service() as conn:
            await conn.execute(
                "select workflow.fail_task($1, $2::jsonb, $3, $4)",
                # Same: normalize_output is reached from fail_task's error
                # too, which is why its event name covers both. The worker id
                # matters most here: without it a reaped worker's retryable
                # failure set the live holder's task back to ready (REM-553).
                task_id, payload, terminal, worker_id)
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
