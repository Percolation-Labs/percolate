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

from ..core import credential
from .templates import TerminalError, dig, resolve
from .agent_auth import agent_authorization


def build_request(spec: dict, ctx: dict) -> tuple[dict, dict]:
    original = spec
    spec = resolve(spec, ctx)
    if not spec.get("url"):
        raise TerminalError("http_call task has no 'url'")

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
    if authorization := agent_authorization(original, spec, ctx.get("_agent_caller")):
        headers = {k: v for k, v in headers.items() if k.lower() != "authorization"}
        headers["Authorization"] = authorization
    elif ref := spec.get("credential_ref"):
        headers["Authorization"] = f"{spec.get('auth_scheme', 'Bearer')} {credential(ref)}"

    return {
        "method": spec.get("method", "GET").upper(),
        "url": spec["url"],
        "headers": headers,
        "content": content,
        "timeout": spec.get("timeout_ms", 30000) / 1000,
    }, spec


async def http_call(spec: dict, ctx: dict) -> Any:
    req, spec = build_request(spec, ctx)

    if spec.get("mode") == "async":
        # Fire and park: the task stays in waiting_external until something
        # calls signal_task. Reuses that status rather than inventing an
        # "in flight externally" one -- the semantics are identical.
        return {"dispatched": True, "mode": "async"}

    async with httpx.AsyncClient() as client:
        try:
            r = await client.request(**req)
        except httpx.RequestError as e:
            raise RuntimeError(f"connection failed: {e}")

    if r.status_code >= 400:
        detail = r.text[:2000]
        # 4xx is the caller's fault and fails identically forever; 5xx/429 are
        # the server's and are worth retrying. Collapsing these into one "it
        # failed" turns a fast failure into five slow ones.
        if 400 <= r.status_code < 500 and r.status_code not in (408, 429):
            raise TerminalError(
                f"HTTP {r.status_code} (client error, not retryable): {detail}")
        raise RuntimeError(f"HTTP {r.status_code}: {detail}")

    try:
        parsed = r.json()
    except Exception:
        parsed = r.text

    # Optional extraction, so a step hands the NEXT step a clean value instead
    # of a provider envelope whose shape the next template must know.
    if spec.get("jsonpath") and isinstance(parsed, (dict, list)):
        got = dig(parsed, spec["jsonpath"])
        if got is None:
            raise TerminalError(
                f"jsonpath '{spec['jsonpath']}' matched nothing in the response")
        return {"status": r.status_code, "result": got}
    return {"status": r.status_code, "result": parsed}
