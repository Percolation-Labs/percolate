"""A small asyncpg client — connection, JSONB codecs, per-request identity, LISTEN.

Scope discipline (``meta/skills/spec-driven-development`` §5): a client, not an
ORM. ``../p8k8``'s ``p8/services/database/pool.py`` is the prior art for the
shape (pool + fetch/execute + a JSONB codec); two things here it does not have,
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
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any
from uuid import UUID

from ..settings import Settings


class PgClient:
    """Owns the pool. One per process."""

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self._pool: Any = None
        # Listeners hold a connection *outside* the pool for as long as a client
        # is streaming, so without a cap a burst of clients exhausts Postgres'
        # connection slots — which is how the outage this repo's own fixtures
        # describe actually happens.
        self._listeners = asyncio.Semaphore(settings.max_listeners)

    async def connect(self) -> None:
        import asyncpg

        async def _init(conn: Any) -> None:
            for typ in ("json", "jsonb"):
                await conn.set_type_codec(
                    typ, encoder=json.dumps, decoder=json.loads, schema="pg_catalog"
                )

        self._pool = await asyncpg.create_pool(
            self.settings.database_url,
            min_size=self.settings.pool_min,
            max_size=self.settings.pool_max,
            init=_init,
        )

    async def close(self) -> None:
        if self._pool is not None:
            await self._pool.close()
            self._pool = None

    def _require(self) -> Any:
        if self._pool is None:
            raise RuntimeError("PgClient.connect() has not been called")
        return self._pool

    @asynccontextmanager
    async def as_user(
        self, user_id: UUID | None, role: str = "authenticated"
    ) -> AsyncIterator[Any]:
        """One transaction, running as ``role`` with the user's claims.

        ``role`` is almost always ``authenticated``. The exception is
        ``workflow-engine``'s ``worker`` role, which is what
        ``complete_task``/``claim_task`` are granted to — when this runtime
        finishes a scheduled run it *is* a worker, and borrowing that role for
        exactly those calls is using that system's role model rather than
        widening this one's (``brief.md`` §3).

        ``set local`` rather than ``set``: the settings must not survive the
        connection going back to the pool, or the next borrower inherits an
        identity — the exact failure mode that makes pooled RLS dangerous.

        A null ``user_id`` is a real case (an unauthenticated request), and it
        deliberately does *not* fall back to a privileged role: the statements
        simply see nothing, which is the correct answer.
        """
        pool = self._require()
        async with pool.acquire() as conn, conn.transaction():
            await conn.execute(f"set local role {role}")
            claims = json.dumps({"sub": str(user_id)}) if user_id else "{}"
            await conn.execute("select set_config('request.jwt.claims', $1, true)", claims)
            yield conn

    @asynccontextmanager
    async def publisher(self, user_id: UUID | None) -> AsyncIterator[Any]:
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
        statement. asyncpg resets session state when the connection returns to
        the pool, which is what makes the session-level ``set role`` safe.
        """
        pool = self._require()
        async with pool.acquire() as conn:
            await conn.execute("set role authenticated")
            claims = json.dumps({"sub": str(user_id)}) if user_id else "{}"
            await conn.execute("select set_config('request.jwt.claims', $1, false)", claims)

            async def publish(channel: str, payload: str) -> None:
                await conn.execute("select pg_notify($1, $2)", channel, payload)

            yield publish

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
            conn = await asyncpg.connect(self.settings.database_url)
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
