"""Connecting to Postgres *as the caller*.

This is the security-critical seam of every service in the collection, and the
reason it lives here rather than in each of them: it decides **whose** RLS
applies.

A service connects as a low-privilege role and sets the request's claims per
transaction, exactly as PostgREST does. A service that queried as *itself*
would bypass every policy in the collection — not by exploiting anything, just
by never presenting an identity for the policies to filter on.

Before this module existed the same logic was written three times, on two
different database drivers (the agent runtime's client, its gateway, and the
reference worker). Three implementations of one security boundary is two too
many — so every service goes through ``as_caller``/``as_service`` here, the
agent runtime included; its ``PgClient`` is a thin adapter over these, not a
second implementation.
"""

from __future__ import annotations

import json
import os
from collections.abc import Mapping
from contextlib import asynccontextmanager
from typing import Any

import asyncpg

ROLE = os.getenv("P8_ROLE", "authenticated")
"""The role a request-scoped transaction assumes. `user-rbac/roles.sql` names it."""

LEEWAY_SECONDS = 30
"""Clock-skew tolerance on `exp`/`nbf`. Thirty seconds, not thirty minutes: this
absorbs drift, it is not a grace period for expired sessions."""

SERVICE_ROLE = os.getenv("P8_SERVICE_ROLE", "worker")
"""The role for the service's own work. `workflow-engine` grants task claiming
and completion to `worker`, and no table privileges to anything."""

_POOL: asyncpg.Pool | None = None
_REFS = 0
"""How many lifespans currently hold the pool open.

One pool per process and several services mounted in it means several owners
with independent lifespans. Without counting, the first one to shut down closes
the pool the others are still using — observed as `InterfaceError: pool is
closed` from a service that had done nothing wrong. Last one out closes it.
"""


async def _init_connection(conn: asyncpg.Connection) -> None:
    """JSON/JSONB come back as dicts, on every connection this process opens.

    Installed here rather than by whichever service happens to open the pool
    first: with one pool per process, a codec set up by one subpackage and not
    another is a difference in behaviour that depends on import order.
    """
    for typ in ("json", "jsonb"):
        await conn.set_type_codec(
            typ, encoder=json.dumps, decoder=json.loads, schema="pg_catalog"
        )


async def open_pool(dsn: str | None = None, **kwargs: Any) -> asyncpg.Pool:
    """Open the process pool. Call this from a service's lifespan, not on import.

    One pool per process, and therefore one DSN per process. That is not a
    limitation being papered over: the services that share an image share a
    database, and a second DSN in one process would mean two identities' worth
    of RLS in one connection pool.

    ``meta/module-composition.md`` requires a module to own nothing at import
    time so a host can compose it. A host that mounts several of these services
    opens the pool once in its own lifespan and closes it there; ``pool()``
    below is the convenience for a process that *is* the service.
    """
    global _POOL, _REFS
    if _POOL is None:
        _POOL = await asyncpg.create_pool(
            dsn or os.environ.get("P8_DSN") or os.environ["P8_DATABASE_URL"],
            min_size=kwargs.pop("min_size", 1),
            max_size=kwargs.pop("max_size", 10),
            init=kwargs.pop("init", _init_connection),
            **kwargs,
        )
    _REFS += 1
    return _POOL


def set_pool(existing: asyncpg.Pool | None) -> None:
    """Install a pool this module did not create — a host's, or a test's."""
    global _POOL, _REFS
    _POOL = existing
    _REFS = 0


async def pool(dsn: str | None = None, **kwargs: Any) -> asyncpg.Pool:
    """The process pool, opening it on first use.

    Kept lazy for the worker, which is a process that owns itself and should
    not need ceremony. A mounted service should call ``open_pool`` in its
    lifespan instead, so that shutdown has something to close.

    A *borrow*, not an acquire: it does not take a reference, because there is
    no matching release. ``open_pool``/``close_pool`` are the paired ones.
    """
    global _REFS
    if _POOL is None:
        await open_pool(dsn, **kwargs)
        _REFS -= 1  # a borrow takes no hold: there is no matching release
    return _POOL  # type: ignore[return-value]


async def close_pool() -> None:
    """Release one hold; close the pool when the last one goes."""
    global _POOL, _REFS
    if _REFS > 0:
        _REFS -= 1
    if _POOL is not None and _REFS == 0:
        await _POOL.close()
        _POOL = None


@asynccontextmanager
async def as_caller(claims: Mapping[str, Any] | None, role: str = ROLE):
    """A transaction with the caller's identity applied.

    ``claims`` is the verified JWT payload — ``sub`` and any ``orgs`` — not
    anything a client asserted in a header. Passing ``None`` means anonymous,
    which is a real state: the caller then sees only globally-shared rows
    (``org_id is null``), which is what an unauthenticated request should get.

    The claims are set **transaction-local** (``set_config(..., true)``). That
    is not a detail: an unregistered GUC left at session scope survives into
    the next transaction on a pooled connection, so the following request would
    inherit the previous caller's identity. Transaction scope makes that
    impossible rather than unlikely.

    The **role** is set too, and explicitly. Claims alone are not enough: a
    policy filters on ``rbac.current_user_id()``, but a connection whose login
    role is the schema owner — or worse, a superuser — bypasses RLS entirely
    before any policy is consulted, and then the claims decide nothing.
    Depending on the DSN's user being the right one makes this seam's safety a
    property of somebody's connection string. ``specs/README.md`` calls that
    exact configuration out as the way RLS silently does nothing.
    """
    p = await pool()
    async with p.acquire() as conn, conn.transaction():
        await conn.execute(f"set local role {role}")
        await conn.execute(
            "select set_config('request.jwt.claims', $1, true)",
            json.dumps(dict(claims)) if claims else "{}",
        )
        yield conn


@asynccontextmanager
async def as_service(role: str = SERVICE_ROLE):
    """A transaction with **no** caller identity.

    For work that is genuinely the service's own and has no user behind it —
    a scheduled poll, a reconciliation sweep. Deliberately a separate function
    rather than ``as_caller(None)`` so that "this query has no user" is a
    decision someone wrote down, not an argument that happened to be null.

    ``role`` still applies: "no user" means no *caller*, not "whatever the
    connection string happens to grant". A worker uses ``workflow-engine``'s
    ``worker`` role, which holds no table privileges at all.
    """
    p = await pool()
    async with p.acquire() as conn, conn.transaction():
        await conn.execute(f"set local role {role}")
        yield conn


def mint_jwt(
    sub: str,
    secret: str,
    *,
    role: str = ROLE,
    ttl_seconds: int = 3600,
    extra: Mapping[str, Any] | None = None,
) -> str:
    """Sign a bearer token that every surface in the deployment accepts.

    The counterpart of ``claims_from_jwt`` and deliberately beside it: a minter
    that disagreed with the verifier about the algorithm or the claim names
    would produce tokens this collection rejects, and the two drifting apart is
    exactly the failure that having one file prevents.

    Two claims are load-bearing and neither is optional. ``sub`` is the user id
    every policy reads through ``rbac.current_user_id()``, so a token without
    it authenticates nobody. ``role`` is the Postgres role PostgREST switches
    to, so a token without it lands on the anonymous role and reads nothing --
    which looks like an empty database rather than like a permissions problem.

    There is no ``kid`` and no asymmetric option, because PostgREST beside us
    is verifying HS256 with one shared secret; offering more here would mean
    minting tokens that work against this runtime and fail against the REST
    interface in the same stack.
    """
    import base64
    import hmac
    import hashlib
    import time

    def b64(raw: bytes) -> str:
        return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()

    now = int(time.time())
    claims: dict[str, Any] = {"sub": str(sub), "role": role, "iat": now}
    if ttl_seconds:
        claims["exp"] = now + int(ttl_seconds)
    if extra:
        claims.update(extra)

    head = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    body = b64(json.dumps(claims, separators=(",", ":"), sort_keys=True).encode())
    sig = b64(
        hmac.new(secret.encode(), f"{head}.{body}".encode(), hashlib.sha256).digest()
    )
    return f"{head}.{body}.{sig}"


def claims_from_jwt(token: str, secret: str) -> dict[str, Any]:
    """Verify a bearer token and return its claims.

    HS256 with the same secret PostgREST uses, so one token works against every
    surface in the deployment. Kept here rather than in each service because a
    service that verified tokens slightly differently from PostgREST would
    authorise slightly differently, and the difference would be invisible until
    it mattered.

    Three checks, and all three are load-bearing:

    * the **signature**, obviously;
    * **`exp`/`nbf`**, because a valid signature is not a valid token — a
      runtime that skips them makes every token it ever issued permanent, and
      is then strictly weaker than the PostgREST beside it, which rejects the
      same token. That is worse than being obviously unprotected;
    * the **algorithm**, pinned by this verifier rather than read from the
      token's own header, which is the classic JWT confusion bug.

    A small leeway absorbs clock skew between whoever minted the token and
    whoever is checking it; without one, ordinary drift rejects valid tokens.
    """
    import base64
    import hashlib
    import hmac
    import time

    def b64d(s: str) -> bytes:
        return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))

    try:
        header_b64, payload_b64, sig_b64 = token.split(".")
    except ValueError:
        raise ValueError("malformed token: expected three dot-separated segments")

    if json.loads(b64d(header_b64)).get("alg") != "HS256":
        raise ValueError("unsupported algorithm: this verifier accepts HS256 only")

    expected = hmac.new(
        secret.encode(), f"{header_b64}.{payload_b64}".encode(), hashlib.sha256
    ).digest()
    if not hmac.compare_digest(expected, b64d(sig_b64)):
        raise ValueError("bad signature")

    payload = json.loads(b64d(payload_b64))
    now = time.time()
    if "exp" in payload and now >= float(payload["exp"]) + LEEWAY_SECONDS:
        raise ValueError("token expired")
    if "nbf" in payload and now < float(payload["nbf"]) - LEEWAY_SECONDS:
        raise ValueError("token is not valid yet")
    return payload
