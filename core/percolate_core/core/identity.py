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

import asyncio
import json
import os
from collections.abc import Mapping
from contextlib import asynccontextmanager
from typing import Any

import asyncpg

from .config import dsn as config_dsn
from .text import without_nul


def _acquire_seconds() -> float:
    """How long to wait for a pooled connection before saying why.

    Read per call rather than at import, so a host or a test can change it
    without reimporting the module.
    """
    return float(os.getenv("P8_POOL_ACQUIRE_SECONDS", "10"))


@asynccontextmanager
async def acquired(p: asyncpg.Pool) -> Any:
    """A pooled connection, or an error that explains the arithmetic.

    BOUNDED, because the unbounded version deadlocks instead of failing. An
    agent turn holds one connection for its whole lifetime -- ``publisher()``
    keeps it so that a sixty-word answer is not sixty transactions -- and every
    repository call *inside* that turn takes a second one. So a turn needs TWO
    connections at once, and with ``P8_POOL_MAX`` at its old default of 8, eight
    concurrent turns each held one and then waited forever for the other. Not
    under load: by construction, at exactly the concurrency the pool size looks
    like it supports.

    A bare ``asyncio.TimeoutError`` would not tell anybody that, so it is caught
    here and replaced with the sum. A deadlock becoming a timeout is an
    improvement; the timeout becoming a sentence that names the two connections
    is the part that saves the next person the afternoon.
    """
    try:
        async with p.acquire(timeout=_acquire_seconds()) as conn:
            yield conn
    except asyncio.TimeoutError:
        raise RuntimeError(
            f"no pooled connection in {_acquire_seconds():g}s. An agent turn holds one "
            "connection for its whole life and takes a second for every query inside "
            "it, so the pool has to be about TWICE the number of turns you want at "
            "once -- P8_POOL_MAX=16 supports eight. Raise it, or raise "
            "P8_POOL_ACQUIRE_SECONDS if the wait is legitimate."
        ) from None


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

    AND U+0000 IS REPLACED ON THE WAY IN, for jsonb (REM-146). jsonb cannot
    hold `\\u0000`, so one NUL anywhere in a bound payload aborts the whole
    statement. That rule was first applied at two call sites, and at least
    three more wrote a foreign string into a jsonb argument without it: an
    http_call response (`complete_task`), an API source's page
    (`commit_api_page`) and a tool server's catalogue (`upsert_tool_server`).
    Every jsonb argument this package binds passes through this encoder, so
    the rule lives here once rather than at each call site. `json` is left
    alone: it stores the escape verbatim and nothing here reads it as text.
    """
    await conn.set_type_codec(
        "json", encoder=json.dumps, decoder=json.loads, schema="pg_catalog"
    )
    await conn.set_type_codec(
        "jsonb", encoder=jsonb_text, decoder=json.loads, schema="pg_catalog"
    )


def jsonb_text(value: Any) -> str:
    """The text of a jsonb argument: `json.dumps`, with no U+0000 in it."""
    return json.dumps(without_nul(value))


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
        _POOL = await _new_pool(dsn or config_dsn(), **kwargs)
    _REFS += 1
    return _POOL


async def _new_pool(dsn: str, **kwargs: Any) -> asyncpg.Pool:
    """Every pool this package opens, with the jsonb encoder on its connections.

    One call site for both the process pool and ``as_task_worker``'s pool, so
    no connection this package opens escapes ``_init_connection``
    (``tests/test_nul_at_the_boundary.py`` counts the call sites).
    """
    return await asyncpg.create_pool(
        dsn,
        min_size=kwargs.pop("min_size", 1),
        max_size=kwargs.pop("max_size", 10),
        init=kwargs.pop("init", _init_connection),
        **kwargs,
    )


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
        await _close_task_worker_pool()


@asynccontextmanager
async def as_caller(claims: Mapping[str, Any] | None, role: str = ROLE):
    """A transaction with the caller's identity applied.

    ``claims`` is the verified JWT payload — ``sub`` and any ``orgs`` — not
    anything a client asserted in a header. Passing ``None`` means anonymous,
    which is a real state: the caller then sees only ``public`` rows and the
    shared tier — ``org_id = rbac.shared_org_id()`` — which is what an
    unauthenticated request should get. This said ``org_id is null``, which was
    the spelling until ``identity/spec.md`` §4 ruled that the shared tier is a
    row rather than the absence of one and made the column NOT NULL everywhere.

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

    **Claims first, then the role**, and the order is the point. ``set_config``
    is not executable by ``authenticated``, ``web_anon`` or ``api_viewer``
    (``user-rbac/roles.sql``): while it was, any signed-in user could write
    somebody else's ``sub`` into ``request.jwt.claims`` from inside
    ``aiq.sql_passthrough`` and read as them. So the claims are written while
    the connection is still its login role (``authenticator`` here, ``worker``
    for the worker), and only then does the transaction become the caller.
    That is the order PostgREST uses; the reverse is a permission error.
    """
    p = await pool()
    async with acquired(p) as conn, conn.transaction():
        await conn.execute(
            "select set_config('request.jwt.claims', $1, true)",
            json.dumps(dict(claims)) if claims else "{}",
        )
        await conn.execute(f"set local role {role}")
        yield conn


# The remedy, as a sentence rather than a stack trace, because the person who
# sees this is deploying rather than debugging.
CANNOT_OPEN_A_SESSION = (
    "this runtime cannot open a session as `{role}` against this database, so "
    "every turn would fail after reporting healthy. Postgres said: {err}\n"
    "  * If the database is newer than the runtime, upgrade the runtime -- a "
    "database at extension 0.2.0 or later refuses `set_config` to `{role}`, "
    "and a runtime older than 0.1.9 writes the role before the claims, which "
    "is the reverse of the order that works (see as_caller above).\n"
    "  * If the runtime is newer than the database, upgrade the extension "
    "(`alter extension percolate update`).\n"
    "  * If neither, the connection's login role is not a member of `{role}`: "
    "check P8_DSN's user and P8_ROLE."
)


async def verify_can_open_a_session(role: str = ROLE) -> None:
    """Refuse at startup if a turn could not open a session at all.

    THE PROBE IS THE THING ITSELF, not a proxy for it. It runs the two
    statements `as_caller` runs, in the order it runs them, and throws the
    transaction away -- so what it answers is "would a turn get a session",
    which is the question, rather than "do these version numbers look
    compatible", which is a different question that has been wrong before.
    `core/agent_document.py` settled this shape for the same reason and says
    so: a catalogue probe survives a database upgraded in place, where
    `pg_extension.extversion` has been known to lag what is installed.
    Comparing versions would also need a table of which pairs work, which is a
    second home for a fact the database already enforces.

    Called from the agent runtime's `lifespan` after the pool opens, so the
    process exits instead of serving. WHY STARTUP AND NOT THE FIRST TURN: the
    first turn reports in band. AG-UI answers HTTP 200 with a well-formed
    stream carrying one `RUN_ERROR`, `docker compose ps` says healthy, and the
    deployment looks fine to everything that watches it. REM-10 found the live
    instance of this only by asserting on the events inside the stream.

    WHAT THIS DOES NOT DO, and it is the first thing to say because the issue
    that produced it is about a pair this cannot catch. A check that ships in
    0.1.9 does not run in 0.1.8, so the REM-135 pairing -- published 0.1.8
    against a 0.2.0 database -- is not detected by this and never will be. The
    only cure for an already-published runtime is not to pair it (REM-135's
    `PACKAGING.md` row). What this buys is the NEXT one: from here on, a
    runtime that cannot serve the database it is pointed at says so at startup,
    in one sentence, instead of once per turn inside a 200.

    Anonymous claims rather than an invented `sub`: the two statements and
    their order are what is under test, and inventing a user id would put a
    value in `request.jwt.claims` that names nobody for no gain.
    """
    try:
        async with as_caller(None, role):
            pass
    except asyncpg.InsufficientPrivilegeError as exc:
        # The specific one, because it is the one with a remedy worth naming.
        # Anything else -- the database is down, the pool is exhausted, the DSN
        # is wrong -- is not a compatibility answer and is left to propagate as
        # itself rather than be reported as a version mismatch.
        raise RuntimeError(
            CANNOT_OPEN_A_SESSION.format(role=role, err=exc)
        ) from exc


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
    async with acquired(p) as conn, conn.transaction():
        await conn.execute(f"set local role {role}")
        yield conn


WORKER_DSN_VAR = "P8_WORKER_DSN"
"""The login a process that is NOT a worker uses to complete or fail a task."""

_TASK_WORKER_POOL: asyncpg.Pool | None = None

CANNOT_ACT_AS_WORKER = (
    "this process cannot complete or fail a workflow task: its login cannot "
    "become `{role}`, so a scheduled run it accepts would never report back and "
    "its step would wait out the whole `wait_ms`. Postgres said: {err}\n"
    "  * Set " + WORKER_DSN_VAR + " to a DSN whose login is a member of `{role}` "
    "-- the `worker` login the workers already use. It is used for "
    "complete_task and fail_task and nothing else.\n"
    "  * Do not grant `{role}` to `authenticator`: every PostgREST request "
    "arrives on that login, and each could then become a worker."
)


async def _close_task_worker_pool() -> None:
    global _TASK_WORKER_POOL
    if _TASK_WORKER_POOL is not None:
        await _TASK_WORKER_POOL.close()
        _TASK_WORKER_POOL = None


@asynccontextmanager
async def as_task_worker(role: str = SERVICE_ROLE):
    """A transaction as ``worker``, for completing or failing a workflow task.

    For the agent runtime, whose connection logs in as ``authenticator``. A
    scheduled run completes the task that dispatched it (``agentic/brief.md``
    §3), and ``complete_task``/``fail_task`` are granted to ``worker``, not to
    ``authenticated``. The runtime used to ``set local role worker`` on its own
    connection. ``authenticator`` is not a member of ``worker`` in any install
    (the image's ``00-superuser.sql``, get-percolate's ``bootstrap.sql``), so
    that statement failed with ``permission denied to set role "worker"``. The
    run ended ``failed``, the task was never told, and the dispatching worker
    held it for the step's whole ``wait_ms``.

    SO THE LOGIN IS A SECOND DSN, NOT A SECOND GRANT. ``P8_WORKER_DSN`` names a
    login that is a member of ``worker``, which in every install is the
    ``worker`` login the workers already use: it holds no table privileges, only
    EXECUTE on the task functions. The alternative, ``grant worker to
    authenticator``, lets every PostgREST request's login become a worker. That
    is the separation ``open_pool``'s one-DSN rule protects, and a pool that only
    ever runs task functions as ``worker`` does not weaken it.

    No caller claims: completing a task is the service's own act, as in
    ``as_service``, and the task functions are SECURITY DEFINER.

    Unset, this switches the process's own login to ``worker``. That is right for
    a process whose login is already a member of ``worker``, such as a worker, or a
    development stack connected as the schema's superuser. Where the switch is refused,
    the error names the variable rather than the role.
    """
    worker_dsn = os.getenv(WORKER_DSN_VAR)
    if worker_dsn:
        global _TASK_WORKER_POOL
        if _TASK_WORKER_POOL is None:
            _TASK_WORKER_POOL = await _new_pool(worker_dsn, min_size=0, max_size=2)
        p = _TASK_WORKER_POOL
    else:
        p = await pool()
    async with acquired(p) as conn, conn.transaction():
        try:
            await conn.execute(f"set local role {role}")
        except asyncpg.InsufficientPrivilegeError as exc:
            raise PermissionError(CANNOT_ACT_AS_WORKER.format(role=role, err=exc)) from exc
        yield conn


async def task_worker_problem(role: str = SERVICE_ROLE) -> str | None:
    """Why this process could not complete a task, or None if it could.

    Asked before a scheduled run is ACCEPTED, because the answer cannot be given
    afterwards: a runtime that cannot call ``fail_task`` cannot report that it
    cannot call ``fail_task`` either. It runs the statement ``as_task_worker``
    runs, in a transaction it throws away.
    """
    try:
        async with as_task_worker(role):
            pass
    except PermissionError as exc:
        return str(exc)
    return None


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
