"""The one built-in handler: `http_call`.

An LLM call, an embedding request, a feed pull and a webhook are the same task
to this code -- they differ only in the JSON on the row.

WHY HTTP IS DONE HERE AND NOT INSIDE POSTGRES
pg_durable takes the other road: df.http() executed by a background worker in
the extension. Three reasons this collection does not, the third being decisive:

1. It needs an HTTP client in the database (pg_net or similar). Every extension
   tried beyond core has failed to build against PG19 beta3 -- pg_cron and
   pg_search both did. Betting the primary execution path on that is a poor
   trade this early.
2. It gives the database outbound egress. pg_durable ships an allow-list
   precisely because that is a real posture change.
3. It removes no process: a worker runs anyway for non-HTTP steps, so HTTP
   inside the DB means two execution paths, two failure modes, two retry
   stories.
"""

from __future__ import annotations

import json
from typing import Any

import httpx

from ..core import credential_for
# The egress guard is core's: the probe and the API puller call the same one.
from ..core.egress import refuse_internal_egress  # noqa: F401 -- re-exported
from ..core.provider_errors import raise_for
from .templates import TerminalError, dig, resolve_task
from .agent_auth import agent_authorization


def build_request(spec: dict, ctx: dict) -> tuple[dict, dict]:
    original = spec
    spec = resolve_task(spec, ctx)
    if not spec.get("url"):
        raise TerminalError("http_call task has no 'url'")

    # After resolve_task and before anything is attached to the request: the
    # templated url is the one that will be fetched, and the check has to see
    # that rather than the `{{...}}` the author wrote.
    refuse_internal_egress(spec["url"])

    headers = dict(spec.get("headers") or {})
    body = spec.get("body")
    content = None
    if body is not None:
        if isinstance(body, (dict, list)):
            content = json.dumps(body).encode()
            headers.setdefault("Content-Type", "application/json")
        else:
            content = str(body).encode()

    # credential_ref is a NAME resolved from this process's environment. The
    # database stores only the reference, so a dump of workflow.tasks never
    # contains a secret and a task stays inspectable and replayable.
    #
    # Resolved against the RESOLVED url, through credential_for: the row names
    # the credential and, separately, where to send it -- and the url can carry
    # {{run.*}} and {{steps.*}}, which are whatever started the run and
    # whatever the last step returned. Resolving the name alone let those pick
    # the destination of the worker's secret. The operator's
    # P8_CREDENTIAL_ORIGINS says where each one may go; nothing on the row can.
    if authorization := agent_authorization(original, spec, ctx.get("_agent_caller")):
        headers = {k: v for k, v in headers.items() if k.lower() != "authorization"}
        headers["Authorization"] = authorization
    elif ref := spec.get("credential_ref"):
        headers["Authorization"] = (
            f"{spec.get('auth_scheme', 'Bearer')} {credential_for(ref, spec['url'])}")

    return {
        "method": spec.get("method", "GET").upper(),
        "url": spec["url"],
        "headers": headers,
        "content": content,
        "timeout": spec.get("timeout_ms", 30000) / 1000,
    }, spec


DEFAULT_WAIT_MS = 15 * 60 * 1000
"""How long the worker holds an async step for its callee, absent `wait_ms`.

Fifteen minutes. A scheduled agent turn takes minutes -- REM-146 measured turns
of 23, 75 and 224 seconds -- so this is four times the longest one measured. It
is not longer because the hold occupies the worker (see `_hold_until_released`
in loop.py): `percolate worker` runs one task at a time, so a runtime that dies
without answering stalls that worker for this long. It is also how long a turn
that fails inside the sequencer takes to fail its task: that path records the
run as `failed` and neither completes nor fails the task, and
`gateway._dispatch` fails it only when `run_scheduled` raises.
"""


class Dispatched(dict):
    """An async step's request was accepted; the callee completes the task.

    A dict, so it reads like any other output in a log, and its own type, so
    the loop can tell "hold this, do not complete it" from a step whose result
    merely happens to look like a receipt.
    """

    def __init__(self, *, status: int, result: Any, wait_seconds: float) -> None:
        super().__init__(status=status, result=result)
        self.wait_seconds = wait_seconds


def _wait_seconds(spec: dict) -> float:
    """The step's `wait_ms` as seconds, refused before anything is sent.

    Checked before the request rather than after it, because a bad value found
    after dispatch would fail a task whose callee is already running.
    """
    value = spec.get("wait_ms", DEFAULT_WAIT_MS)
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise TerminalError(
            f"http_call wait_ms must be a positive whole number of milliseconds, got {value!r}")
    return value / 1000


async def http_call(spec: dict, ctx: dict) -> Any:
    req, spec = build_request(spec, ctx)
    wait_seconds = _wait_seconds(spec) if spec.get("mode") == "async" else None

    async with httpx.AsyncClient() as client:
        try:
            r = await client.request(**req)
        except httpx.RequestError as e:
            raise RuntimeError(f"connection failed: {e}")

    # 4xx is the caller's fault and fails identically forever, and so does an
    # account with no credit; 5xx and a plain 429 are worth retrying. The rule
    # is core.provider_errors', shared with every other provider call.
    raise_for(r.status_code, r.content, "http_call", r.text[:2000])

    try:
        parsed = r.json()
    except Exception:
        parsed = r.text

    if spec.get("mode") == "async":
        # DISPATCH, THEN LEAVE THE TASK TO THE CALLEE (workflow-engine/spec.md
        # §14, agentic/brief.md §3). This returned before the request above
        # was made, and the loop completed the task with the receipt -- so a
        # scheduled agent run completed without /internal/run ever being
        # called, and the seeded summarize_session_window did nothing at all.
        #
        # The loop then HOLDS the task until the callee moves it, rather than
        # completing it or parking it in `waiting_external` -- why, and what
        # the hold costs, is on `_hold_until_released` in loop.py.
        return Dispatched(status=r.status_code, result=parsed, wait_seconds=wait_seconds)

    # Optional extraction, so a step hands the NEXT step a clean value instead
    # of a provider envelope whose shape the next template must know.
    if spec.get("jsonpath") and isinstance(parsed, (dict, list)):
        got = dig(parsed, spec["jsonpath"])
        if got is None:
            raise TerminalError(
                f"jsonpath '{spec['jsonpath']}' matched nothing in the response")
        return {"status": r.status_code, "result": got}
    return {"status": r.status_code, "result": parsed}
