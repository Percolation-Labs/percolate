"""Connecting to Postgres *as the caller*.

This is the security-critical seam of every service in the collection, and the
reason it lives here rather than in each of them: it decides **whose** RLS
applies.

A service connects as a low-privilege role and sets the request's claims per
transaction, exactly as PostgREST does. A service that queried as *itself*
would bypass every policy in the collection — not by exploiting anything, just
by never presenting an identity for the policies to filter on.

Before this module existed the same logic was written three times, on two
different database drivers (``p8agentic/db/client.py``, ``gateway.py``, and the
reference worker). Three implementations of one security boundary is two too
many.
"""

from __future__ import annotations

import json
import os
from contextlib import asynccontextmanager
from typing import Any, Mapping

import asyncpg

_POOL: asyncpg.Pool | None = None


async def pool(dsn: str | None = None, **kwargs: Any) -> asyncpg.Pool:
    """The process-wide connection pool.

    One pool per process. Services are stateless and horizontally scaled, so
    the pool is sized for a single replica's concurrency rather than the
    cluster's — a pool per replica multiplied by replicas is how a connection
    limit gets exhausted by a deployment that looked reasonable.
    """
    global _POOL
    if _POOL is None:
        _POOL = await asyncpg.create_pool(
            dsn or os.environ["P8_DSN"],
            min_size=kwargs.pop("min_size", 1),
            max_size=kwargs.pop("max_size", 10),
            **kwargs,
        )
    return _POOL


async def close_pool() -> None:
    global _POOL
    if _POOL is not None:
        await _POOL.close()
        _POOL = None


@asynccontextmanager
async def as_caller(claims: Mapping[str, Any] | None):
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
    """
    p = await pool()
    async with p.acquire() as conn:
        async with conn.transaction():
            if claims:
                await conn.execute(
                    "select set_config('request.jwt.claims', $1, true)",
                    json.dumps(dict(claims)),
                )
            yield conn


@asynccontextmanager
async def as_service():
    """A transaction with **no** caller identity.

    For work that is genuinely the service's own and has no user behind it —
    a scheduled poll, a reconciliation sweep. Deliberately a separate function
    rather than ``as_caller(None)`` so that "this query has no user" is a
    decision someone wrote down, not an argument that happened to be null.
    """
    p = await pool()
    async with p.acquire() as conn:
        async with conn.transaction():
            yield conn


def claims_from_jwt(token: str, secret: str) -> dict[str, Any]:
    """Verify a bearer token and return its claims.

    HS256 with the same secret PostgREST uses, so one token works against every
    surface in the deployment. Kept here rather than in each service because a
    service that verified tokens slightly differently from PostgREST would
    authorise slightly differently, and the difference would be invisible until
    it mattered.
    """
    import hashlib
    import hmac
    import base64
    import time

    def b64d(s: str) -> bytes:
        return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))

    try:
        header_b64, payload_b64, sig_b64 = token.split(".")
    except ValueError:
        raise ValueError("malformed token: expected three dot-separated segments")

    expected = hmac.new(
        secret.encode(), f"{header_b64}.{payload_b64}".encode(), hashlib.sha256
    ).digest()
    if not hmac.compare_digest(expected, b64d(sig_b64)):
        raise ValueError("bad signature")

    payload = json.loads(b64d(payload_b64))
    if "exp" in payload and payload["exp"] < time.time():
        raise ValueError("token expired")
    return payload
