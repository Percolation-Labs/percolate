"""Stand-in for workflow-engine's generic `http_call` executor.

`workflow-engine/spec.md` §14 is explicit that this worker is *that* system's
to build — "infrastructure, not per-consumer code ... No workflow author ever
writes worker code for an `http_call` step". It does not exist yet, so this is
the smallest faithful stand-in that lets `agentic`'s scheduled-run path be
exercised end to end. It is ~60 lines and lives in `dev/` for that reason: when
the real executor lands, this is deleted, not promoted.

Faithful to the spec where it matters:

  * claims `kind = 'http_call'` tasks from a queue, as the `worker` role
  * reads the call spec from `tasks.input` ({"url", "method", "mode"})
  * `mode: "async"` -> dispatch only, then park the task in `waiting_external`
    and stop; the callee completes it later through `complete_task`
  * includes `workflow_task_id` in the dispatch body, which is precisely what
    lets the agent runtime complete its own triggering task

One thing it cannot do faithfully: **there is no granted function for parking a
task in `waiting_external`.** `claim_task` sets `running`, `complete_task` and
`fail_task` end it, `start_child_workflow` parks a sub-workflow task — but an
`http_call` executor has nothing to call, so this script updates the row
directly as a superuser and flags it. That is a real gap between
workflow-engine's §14 and its schema, not a shortcut chosen here.

Usage: uv run python dev/worker.py [--queue http] [--once]
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from percolate_core.agentic.db import PgClient
from percolate_core.agentic.settings import Settings


async def run_once(client: PgClient, queue: str) -> bool:
    async with client.as_user(None, role="worker") as conn:
        task = await conn.fetchrow("select * from workflow.claim_task($1, $2)", queue, "dev-worker")
        if task is None or task["id"] is None:
            return False
        # get_task_context, not a select on workflow.runs: the `worker` role
        # holds NO table grants by design (user-rbac/roles.sql), so reading the
        # run's input directly is denied -- correctly. This function is the
        # granted way in, and it hands back task input and run input together.
        ctx = await conn.fetchval(
            "select workflow.get_task_context($1, $2)", task["id"], "dev-worker"
        )

    spec = ctx["task_input"] or {}
    body = {"workflow_task_id": str(task["id"]), "input": ctx["run_input"] or {}}
    print(f"  dispatch {spec.get('method', 'POST')} {spec.get('url')} task={task['id']}")

    headers = {"Content-Type": "application/json"}
    if token := os.getenv("P8_REST_TOKEN"):
        headers["Authorization"] = f"Bearer {token}"

    async with httpx.AsyncClient(timeout=spec.get("timeout_ms", 120000) / 1000) as http:
        response = await http.request(
            spec.get("method", "POST"), spec["url"], json=body, headers=headers
        )

    if response.is_error:
        # A dispatch that the callee rejected is a failed task, not a parked
        # one -- otherwise a bad request sits in waiting_external forever and
        # workflow-engine's retry never sees it.
        async with client.as_user(None, role="worker") as conn:
            await conn.execute(
                "select workflow.fail_task($1, $2::jsonb)",
                task["id"],
                json.dumps({"status": response.status_code, "body": response.text[:500]}),
            )
        print(f"  dispatch rejected -> {response.status_code}, task failed")
        return True

    if spec.get("mode") == "async":
        # See module docstring: no granted function parks a task here, so this
        # is a direct write as the superuser the dev harness connects as.
        async with client.as_user(None, role="app_owner") as conn:
            await conn.execute(
                "update workflow.tasks set status = 'waiting_external' where id = $1", task["id"]
            )
        print(f"  dispatched (async), task parked in waiting_external -> {response.status_code}")
    else:
        async with client.as_user(None, role="worker") as conn:
            await conn.execute(
                "select workflow.complete_task($1, $2::jsonb)",
                task["id"],
                json.dumps({"status": response.status_code, "body": response.text[:2000]}),
            )
        print(f"  completed (sync) -> {response.status_code}")
    return True


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--queue", default="http")
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()

    client = PgClient(Settings.from_env())
    await client.connect()
    try:
        while True:
            worked = await run_once(client, args.queue)
            if args.once and not worked:
                print("  no http_call tasks queued")
            if args.once:
                return
            if not worked:
                await asyncio.sleep(1)
    finally:
        await client.close()


if __name__ == "__main__":
    asyncio.run(main())
