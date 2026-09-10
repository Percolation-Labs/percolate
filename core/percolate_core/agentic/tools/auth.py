"""Request credentials stay in transport scope, never in prompts or rows."""
from contextlib import contextmanager
from contextvars import ContextVar
from urllib.parse import urlsplit

from .provider import resolve_credential

_CALLER = ContextVar("tool_caller_credentials", default=None)


def origin(url: str) -> tuple[str, str, int]:
    parsed = urlsplit(url)
    if (parsed.scheme not in {"http", "https"} or not parsed.hostname
            or parsed.username or parsed.password or "\\" in url
            or any(c.isspace() for c in url)):
        raise ValueError("expected an HTTP(S) URL without user information")
    return parsed.scheme, parsed.hostname.lower(), parsed.port or (443 if parsed.scheme == "https" else 80)


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
    credential. Other services keep their own credential_ref. An agent row or
    model-authored argument cannot opt a destination into this policy.
    """
    outbound = {k: v for k, v in (headers or {}).items() if k.lower() != "authorization"}
    caller = _CALLER.get()
    if caller and caller[0] and origin(server.url) in caller[1] and origin(url or server.url) == origin(server.url):
        outbound["Authorization"] = caller[0]
    else:
        credential = await resolve_credential(server.credential_ref)
        if credential:
            outbound["Authorization"] = f"Bearer {credential}"
    return outbound
