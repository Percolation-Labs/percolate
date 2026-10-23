"""A small asyncpg client — connection, JSONB codecs, per-request identity, LISTEN.

Scope discipline: a client, not an
ORM. An earlier private service's database pool is the prior art for the
shape (pool + fetch/execute + a JSONB codec); two things here it did not have,
both structural to this collection rather than stylistic:

- ``as_user()`` — every statement runs inside a transaction that has assumed the
  ``authenticated`` role and set ``request.jwt.claims``, which is exactly what
  PostgREST does per request. The runtime is "just another client" only if it
  actually goes through the same role and the same RLS (``brief.md`` §5), and
  the only way to be sure of that is to never hold a connection that hasn't.
- ``listen()`` — AG-UI streaming is a NOTIFY relay (``brief.md`` §4).
"""

from __future__ import annotations

import asyncio
import json
from collections.abc import AsyncIterator, Mapping
from contextlib import asynccontextmanager
from typing import Any

from ...core import identity
from ...core.config import dsn
from ..settings import Settings


class PgClient:
    """Owns the pool. One per process."""

    def __init__(self, settings: Settings, owns_pool: bool = True) -> None:
        self.settings = settings
        # Whether closing this client closes the *process* pool. A service's
        # lifespan owns it; a short-lived helper borrows it. Getting this wrong
        # is not subtle in effect and is very subtle in cause: a helper that
        # closed on exit tore the pool out from under a turn that was still
        # streaming, which surfaced as `InterfaceError: pool is closing` from
        # code that had done nothing wrong.
        self.owns_pool = owns_pool
        self._pool: Any = None
        # Listeners hold a connection *outside* the pool for as long as a client
        # is streaming, so without a cap a burst of clients exhausts Postgres'
        # connection slots — which is how the outage this repo's own fixtures
        # describe actually happens.
        self._listeners = asyncio.Semaphore(settings.max_listeners)

    async def connect(self) -> None:
        """Open the process pool, through ``core.identity``.

        Not a pool of its own: one process holds one pool (see
        ``core.identity.open_pool``), and this service may be sharing that
        process with the Content Server.
        """
        opener = identity.open_pool if self.owns_pool else identity.pool
        # `dsn()` rather than the field: an unset database is refused HERE, by
        # name, which is the step that used to restart-loop against a localhost
        # default nobody had configured.
        self._pool = await opener(
            self.settings.database_url or dsn(),
            min_size=self.settings.pool_min,
            max_size=self.settings.pool_max,
        )

    async def close(self) -> None:
        if self.owns_pool:
            await identity.close_pool()
        self._pool = None

    def _require(self) -> Any:
        if self._pool is None:
            raise RuntimeError("PgClient.connect() has not been called")
        return self._pool

    @asynccontextmanager
    async def as_user(
        self, claims: Mapping[str, Any] | None, role: str = identity.ROLE
    ) -> AsyncIterator[Any]:
        """One transaction, as ``role``, carrying the caller's verified claims.

        Delegates to ``core.identity.as_caller`` rather than repeating it: that
        function is the collection's one implementation of "whose RLS applies",
        and a second copy here is how the two drift into authorising
        differently.

        ``claims`` is the verified token payload, passed through WHOLE. This
        took a ``user_id`` and rebuilt ``{"sub": ...}`` from it, which dropped
        every other claim -- and ``rbac.current_org_ids()`` reads a missing
        ``orgs`` claim as "every org this user belongs to". A token narrowed
        to one org was narrowed on the Content Server and widened to all of
        them here, by a wrapper whose only job was to change the shape.
        """
        _require_claims(claims)
        async with identity.as_caller(claims, role=role) as conn:
            yield conn

    @asynccontextmanager
    async def publisher(self, claims: Mapping[str, Any] | None) -> AsyncIterator[Any]:
        """One connection, held for a turn, for publishing AG-UI events.

        ``as_user`` is the right shape for a read or a write — one transaction,
        one identity — and the wrong shape entirely for a stream: it cost a
        connection acquire, a ``BEGIN``, two setup statements and a ``COMMIT``
        *per token delta*, so a sixty-word answer ran sixty transactions to say
        sixty words.

        A NOTIFY is not a row access, and it must not be batched either — a
        notification is delivered at COMMIT, so holding one long transaction
        would delay every event to the end of the turn and destroy the streaming
        it exists for. So: one connection, session-level identity set once,
        autocommit per event. Four statements and a transaction become one
        statement.

        The same claims ``as_user`` sets, whole, and in the same order: claims
        while the connection is still ``authenticator``, THEN the role, because
        ``authenticated`` may not call ``set_config`` (see
        ``core.identity.as_caller``).

        AND THE ROLE IS RESET BEFORE THE CONNECTION GOES BACK. This said asyncpg
        resets session state on release, and it does run ``RESET ALL`` -- which
        Postgres documents as leaving ``role`` alone. So every connection a turn
        had published on went back to the pool still ``authenticated``, and the
        next request to draw it failed its first statement with ``permission
        denied for function set_config``: one successful streamed turn, then
        500s. Found on a live database with ``set_config`` revoked; invisible
        where ``authenticated`` could still call it.
        """
        _require_claims(claims)
        pool = self._require()
        # Bounded, through the same helper as_caller uses: this is the acquire
        # that HOLDS a connection for the turn, so it is the first half of the
        # two-per-turn sum in `settings.pool_max`.
        async with identity.acquired(pool) as conn:
            await conn.execute(
                "select set_config('request.jwt.claims', $1, false)",
                json.dumps(dict(claims)) if claims else "{}",
            )
            await conn.execute(f"set role {identity.ROLE}")

            async def publish(channel: str, payload: str) -> None:
                await conn.execute("select pg_notify($1, $2)", channel, payload)

            try:
                yield publish
            finally:
                await _restore_login_role(conn)

    async def listen(self, channel: str, queue: asyncio.Queue) -> Any:
        """Hold a dedicated connection ``LISTEN``ing, pushing payloads onto ``queue``.

        Dedicated, not pooled, and returned rather than context-managed: a
        listener outlives any one transaction, and a pooled connection that goes
        back to the pool stops listening. The caller closes it.

        Payloads are JSON objects (``brief.md`` §4): AG-UI events published by
        the runtime, plus ``MESSAGE_PERSISTED`` checkpoints published by the
        ``messages`` trigger. Both arrive on the session's one channel, which is
        what makes a delegation tree multiplex itself.
        """
        import asyncpg

        if self._listeners.locked():
            raise RuntimeError(
                f"too many concurrent listeners (limit {self.settings.max_listeners}); "
                "a stream holds a connection outside the pool for its lifetime"
            )
        await self._listeners.acquire()
        try:
            conn = await asyncpg.connect(self.settings.database_url or dsn())
        except BaseException:
            self._listeners.release()
            raise

        def _on_notify(_conn: Any, _pid: int, _channel: str, payload: str) -> None:
            queue.put_nowait(json.loads(payload))

        await conn.add_listener(channel, _on_notify)
        # Wrapped rather than returned raw: the caller closes the listener, and
        # the slot has to come back when it does. Accounting that depends on
        # every call site remembering is accounting that leaks.
        return _Listener(conn, self._listeners)


async def _restore_login_role(conn: Any) -> None:
    """Put a publisher's connection back as its login role, with no claims.

    ``reset role`` first: any role may run it, and only the login role may
    then clear the claims. A connection that cannot be proven reset is
    terminated rather than returned, so the pool discards it instead of
    handing the next caller somebody else's role and identity.
    """
    try:
        await conn.execute("reset role")
        await conn.execute("select set_config('request.jwt.claims', '', false)")
    except Exception:
        # BEST EFFORT, because the failure this handles includes the case where
        # the connection is already gone -- and `terminate()` on a released
        # connection raises `InterfaceError: cannot call Connection.terminate():
        # connection has been released back to the pool`, which then REPLACES
        # the exception we are here to re-raise.
        #
        # The cost is not a tidy traceback. Found by the tour: two acts got a
        # 500 whose agent log named this InterfaceError, so the turn's actual
        # cause appeared nowhere -- and the tour, parsing an error body it
        # expected to be JSON, aborted the whole act on a Python TypeError. One
        # swallowed exception, three layers of wrong diagnosis.
        #
        # Swallowing is safe in exactly this direction: a connection that cannot
        # be terminated BECAUSE it is already released is one the pool has
        # already taken back, which is what terminate() was reaching for. What
        # must not be lost is the `raise`, which is what tells the caller the
        # reset failed -- so it stays outside the inner try.
        try:
            conn.terminate()
        except Exception:
            pass
        raise


def _require_claims(claims: Any) -> None:
    """Refuse a user id where the claims belong.

    Both methods took a ``UUID`` until the claims had to travel whole, and a
    caller still passing one would otherwise reach ``dict(claims)`` and fail
    with a message about UUIDs not being iterable.
    """
    if claims is not None and not isinstance(claims, Mapping):
        raise TypeError(
            "pass the verified token claims (a mapping with 'sub' and any "
            f"'orgs'), not {type(claims).__name__}"
        )


class _Listener:
    """A held listening connection, and the slot it occupies."""

    def __init__(self, conn: Any, slots: asyncio.Semaphore) -> None:
        self._conn = conn
        self._slots = slots
        self._closed = False

    async def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        try:
            await self._conn.close()
        finally:
            self._slots.release()
