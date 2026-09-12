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

import ipaddress
import json
import os
import socket
from typing import Any

import httpx

from ..core import credential_for
from ..core.credentials import origin
from ..core.provider_errors import raise_for
from .templates import TEMPLATE_ENV, TerminalError, dig, resolve_task
from .agent_auth import agent_authorization


def _sanctioned_origins() -> set[tuple[str, str, int]]:
    """The internal endpoints this deployment has named, as origins.

    NOT A NEW LIST. It is the one templates already read -- ``P8_AGENT_URL``,
    ``LLM_URL``, and whatever ``P8_TEMPLATE_ENV`` adds -- because that list
    already means "endpoints this operator sanctions", and a second list for the
    same fact is a second list to forget. A deployment that wants the worker to
    reach another internal service names it there and gets both at once.
    """
    names = set(TEMPLATE_ENV) | {
        n.strip() for n in os.environ.get("P8_TEMPLATE_ENV", "").split(",") if n.strip()}
    out: set[tuple[str, str, int]] = set()
    for name in names:
        value = os.environ.get(name)
        if not value:
            continue
        try:
            out.add(origin(value))
        except ValueError:
            continue
    return out


def refuse_internal_egress(url: str) -> None:
    """Refuse a step that points the worker back at its own network.

    The docstring at the top of this file argues that giving *the database*
    outbound egress is "a real posture change", and notes that pg_durable ships
    an allow-list "precisely because" it is. The worker had none, and the worker
    is the process that actually makes the calls.

    It sits on the compose network beside Postgres, MinIO and PostgREST with
    ``P8_S3_KEY`` in its environment, and a step's ``url`` is resolved from
    ``{{run.*}}`` and ``{{steps.*}}`` -- whatever started the run and whatever
    the last step returned, which on the ingestion path includes text taken out
    of an uploaded document. So ``http://minio:9000/...`` or
    ``http://169.254.169.254/`` was a request the worker would make, with the
    response landing in ``tasks.output`` and from there into the next step's
    context.

    ``credential_for`` already stops a *named* secret travelling somewhere it
    was not bound to, and ``TEMPLATE_ENV`` already stops ``{{env.X}}`` putting a
    secret in a body. Neither says anything about an unauthenticated GET to a
    service that answers on this network because the caller is on it.

    WHAT THIS DOES NOT DO: it resolves and checks, and does not pin the resolved
    address for the request that follows, so a name answering differently on a
    second lookup is not covered. That is DNS rebinding; it has no incident
    here, and closing it means a pinned-IP transport for every call. Named so
    the next reader knows it was considered rather than missed.
    """
    try:
        target = origin(url)
    except ValueError as exc:
        raise TerminalError(f"http_call url is not a usable HTTP(S) URL: {exc}") from None

    if target in _sanctioned_origins():
        return

    _, host, port = target
    try:
        infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
    except socket.gaierror:
        # A NAME THAT DOES NOT RESOLVE REACHES NOTHING, so there is nothing here
        # to refuse: let the request proceed and fail as it always did, with
        # httpx's own retryable "connection failed". The first version of this
        # raised instead, and fourteen existing tests went red -- they drive the
        # worker with hostnames like `model.example` and a mocked transport, and
        # a check that resolves for real turned "this test never touches the
        # network" into "this test needs DNS". That is the check changing what
        # the code under it means, which is worse than the gap it closes: the
        # gap is a host that cannot be connected to either.
        return

    for info in infos:
        address = ipaddress.ip_address(info[4][0])
        if (address.is_private or address.is_loopback or address.is_link_local
                or address.is_reserved or address.is_multicast
                or address.is_unspecified):
            raise TerminalError(
                f"http_call refuses {host}: it resolves to {address}, which is on "
                "this machine's own network. A step's url is resolved from the run "
                "and from earlier steps, so it is not necessarily an address anybody "
                "chose. If the worker is meant to reach it, name the endpoint in "
                "P8_TEMPLATE_ENV (or P8_AGENT_URL / LLM_URL).")


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

    # 4xx is the caller's fault and fails identically forever, and so does an
    # account with no credit; 5xx and a plain 429 are worth retrying. The rule
    # is core.provider_errors', shared with every other provider call.
    raise_for(r.status_code, r.content, "http_call", r.text[:2000])

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
