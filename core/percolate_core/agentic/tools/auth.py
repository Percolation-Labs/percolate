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
    """
    outbound = {k: v for k, v in (headers or {}).items() if k.lower() != "authorization"}
    same_origin = origin(url or server.url) == origin(server.url)
    caller = _CALLER.get()
    if caller and caller[0] and origin(server.url) in caller[1] and same_origin:
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
