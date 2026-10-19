"""Whether an outbound request may go where it was pointed.

ONE CHECK, CALLED BY EVERY PROCESS THAT FETCHES A URL SOMEBODY ELSE CHOSE. It
was written for the worker (REM-91 item 6) and lived in `worker/http.py`, called
from one line, while two other callers fetched caller-chosen URLs without it:
`POST /probe` on the Content Server, which GETs any http(s) URL for any
signed-in caller, follows redirects and returns what it read, and the API source
puller in `ingest/api.py`. Each sits on the compose network beside Postgres,
MinIO and PostgREST. `credentials.origin` checks a URL's scheme and userinfo and
never the address its host resolves to, so it was not this check, and nothing
about sharing that parser made the guard shared.

It lives here, beside `origin`, so that a new caller finds it in the place it
already imports the URL rules from.
"""

from __future__ import annotations

import ipaddress
import os
import socket

from .config import TerminalError
from .credentials import origin

TEMPLATE_ENV = ("P8_AGENT_URL", "LLM_URL")
"""The environment variables a template may read before ``P8_TEMPLATE_ENV``
adds to them: the two the compiler and the specs' own examples emit.

AN ALLOW-LIST, because {{env.X}} read ANY variable and could put it anywhere in
a request: `body: {k: "{{env.P8_S3_SECRET}}"}` beside a `url` on the author's
own host sent the storage secret there, and no origin binding could see it,
because it never went through a credential_ref. A secret is sent by
`credential_ref`, which `core.credentials.credential_for` binds to an origin; a
template says where to send, not what to send. A deployment that templates
another endpoint lists it in `P8_TEMPLATE_ENV` (comma-separated).

Defined here rather than in `worker/templates.py` because the same list is what
`refuse_internal_egress` reads as "endpoints this operator sanctions", and
`core` cannot import from `worker`.
"""


class EgressRefused(TerminalError):
    """An outbound request pointed at this deployment's own network.

    A `TerminalError`, so the worker fails the step for good exactly as before,
    and a caller with its own error type (`content.probe.ProbeFailed`) can catch
    this one and restate it. ``address`` is kept for a log line and deliberately
    left out of the message: the probe returns its message to whoever asked,
    and "minio resolves to 172.18.0.4" is a map of the network being protected.
    """

    def __init__(self, message: str, address: str | None = None) -> None:
        super().__init__(message)
        self.address = address


def sanctioned_origins() -> set[tuple[str, str, int]]:
    """The internal endpoints this deployment has named, as origins.

    NOT A NEW LIST. It is the one templates already read -- ``P8_AGENT_URL``,
    ``LLM_URL``, and whatever ``P8_TEMPLATE_ENV`` adds -- because that list
    already means "endpoints this operator sanctions", and a second list for the
    same fact is a second list to forget. A deployment that wants the worker or
    an API source to reach another internal service names it there and gets
    both. The probe and ``/evidence`` do not read it (REM-555): see
    ``refuse_internal_egress``'s ``sanctioned``.
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


def _internal(address: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bool:
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
        address = address.ipv4_mapped
    # `not is_global` as well as the named classes: Alibaba Cloud's metadata
    # service is 100.100.100.200, in the carrier-grade NAT block, which is
    # neither private nor public.
    return (address.is_private or address.is_loopback or address.is_link_local
            or address.is_reserved or address.is_multicast or address.is_unspecified
            or not address.is_global)


def refuse_internal_egress(url: str, *, sanctioned: bool = True) -> None:
    """Refuse a URL that points this process back at its own network.

    The worker's step ``url`` is resolved from ``{{run.*}}`` and ``{{steps.*}}``
    -- whatever started the run and whatever the last step returned, which on
    the ingestion path includes text taken out of an uploaded document. A probe
    URL is typed by a caller, and an API source's URL is a row a caller saved.
    So ``http://minio:9000/...`` or ``http://169.254.169.254/`` was a request
    any of the three would make, with the response landing somewhere a caller
    could read it.

    ``credential_for`` already stops a *named* secret travelling somewhere it
    was not bound to, and ``TEMPLATE_ENV`` already stops ``{{env.X}}`` putting a
    secret in a body. Neither says anything about an unauthenticated GET to a
    service that answers on this network because the caller is on it.

    Call it on EVERY URL that will be requested: after template resolution, and
    on each redirect hop and continuation page, since each is a new URL.

    ``sanctioned=False`` for a URL a person typed for this one request (the
    probe, and ``/evidence`` through it): the operator's endpoints are not
    exempt then (REM-555). ``LLM_URL`` names a model server this deployment
    trusts its workers to call; it does not make that server a page any
    signed-in caller may read. A worker step and a saved API source keep the
    exemption, because naming an endpoint in ``P8_TEMPLATE_ENV`` is how an
    operator lets those reach it.

    WHAT THIS DOES NOT DO: it resolves and checks, and does not pin the resolved
    address for the request that follows, so a name answering differently on a
    second lookup is not covered. That is DNS rebinding; it has no incident
    here, and closing it means a pinned-IP transport for every call. Named so
    the next reader knows it was considered rather than missed.
    """
    try:
        target = origin(url)
    except ValueError as exc:
        raise EgressRefused(f"url is not a usable HTTP(S) URL: {exc}") from None

    if sanctioned and target in sanctioned_origins():
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
        # A scoped IPv6 address comes back as `fe80::1%eth0`.
        address = ipaddress.ip_address(str(info[4][0]).split("%", 1)[0])
        if _internal(address):
            if not sanctioned:
                raise EgressRefused(
                    f"refusing {host}: it resolves to an address on this machine's "
                    "own network, and a URL typed for this request may only reach "
                    "the public internet.",
                    address=str(address))
            raise EgressRefused(
                f"refusing {host}: it resolves to an address on this machine's own "
                "network. The url may come from a run, an earlier step, a saved "
                "source or a caller, so it is not necessarily an address anybody "
                "chose. If this process is meant to reach it, name the endpoint in "
                "P8_TEMPLATE_ENV (or P8_AGENT_URL / LLM_URL).",
                address=str(address))
