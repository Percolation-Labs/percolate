"""Request credentials stay in transport scope, never in prompts or rows."""
from contextlib import contextmanager
from contextvars import ContextVar

# The one origin parser (core.credentials), re-exported under the name
# openapi.py imports. This module kept its own copy beside ingest/api.py's; two
# parsers of one boundary disagree about exactly the inputs an attacker picks.
from ...core.credentials import origin
from .provider import resolve_credential

__all__ = ["caller_credentials", "origin", "outbound_headers"]

_CALLER = ContextVar("tool_caller_credentials", default=None)


@contextmanager
def caller_credentials(authorization: str | None, allowed_origins: tuple[str, ...]):
    """Only enter after authenticating the inbound caller. Async tasks isolate it."""
    marker = _CALLER.set((authorization, frozenset(origin(o) for o in allowed_origins)))
    try:
        yield
    finally:
        _CALLER.reset(marker)


async def outbound_headers(server, headers=None, *, url=None):
    """Trust both the registration origin and actual destination; never follow redirects.

    On trusted first-party services the verified caller wins over a static
    credential. Other services keep their own credential_ref -- and only on
    their own origin: the row binds the credential to its ``url``, so a
    destination elsewhere gets neither. An agent row or model-authored argument
    cannot opt a destination into this policy.

    THE CALLER'S CONTEXT STOPS WHERE THEIR TOKEN STOPS, and it is one list
    deciding both (REM-148). `X-P8-User-Id`, `X-P8-Session-Id` and the rest of
    the ambient `X-P8-*` block name the person asking, their conversation and
    the run it belongs to. They were forwarded to every destination, so on
    2026-09-12 a registered third party -- `httpbin.org`, deliberately outside
    `P8_TOOL_AUTH_ORIGINS` -- echoed back a real user id and session id from a
    live stack while the `Authorization` rule six lines above was correctly
    refusing it the token. Half of an identity boundary is not one.

    `traceparent` is exempt because it is not ours and carries no identity: W3C
    trace propagation across a third party is the point of the standard.

    The alternative -- a per-server column saying what context it may receive --
    is a shipped extension change, and it would put a second list beside
    `P8_TOOL_AUTH_ORIGINS` for one boundary. An operator who wants a tool server
    to know the tenant binds its origin, which is the sentence that already
    exists.
    """
    outbound = {k: v for k, v in (headers or {}).items() if k.lower() != "authorization"}
    same_origin = origin(url or server.url) == origin(server.url)
    caller = _CALLER.get()
    # Membership is read off `caller[1]` rather than `caller[0]`: a call with no
    # inbound token still has a configured origin list, and an anonymous caller
    # leaks less, not more.
    bound = bool(caller) and origin(server.url) in caller[1] and same_origin
    if not bound:
        outbound = {k: v for k, v in outbound.items()
                    if not k.lower().startswith("x-p8-")}
    if caller and caller[0] and bound:
        outbound["Authorization"] = caller[0]
    elif same_origin:
        # The DESTINATION, not the registration -- they coincide here only
        # because same_origin already holds. resolve_credential now asks
        # core.credentials whether this origin is bound to that variable, which
        # the same-origin test above cannot answer: a server somebody registered
        # at their own host IS its own registration origin, so same_origin was
        # true for exactly the case worth refusing.
        credential = await resolve_credential(server.credential_ref, url or server.url)
        if credential:
            outbound["Authorization"] = f"Bearer {credential}"
    return outbound
