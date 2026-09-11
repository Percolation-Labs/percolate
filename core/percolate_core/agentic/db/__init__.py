"""Postgres access: a small client, and the single repository seam over it."""

from collections.abc import AsyncIterator, Mapping
from contextlib import asynccontextmanager
from typing import Any

from ..settings import Settings
from .client import PgClient
from .repository import PgRepository, Repository


@asynccontextmanager
async def connected(
    settings: Settings, claims: Mapping[str, Any] | None = None
) -> AsyncIterator[PgRepository]:
    """A pool, a repository scoped to one caller's verified claims, and a
    guaranteed close.

    Every short-lived caller (the CLI, the gateway's request handlers) wants
    exactly this, and each of them growing its own ten-line version is how a
    connection leak ends up in one of them and not the others. The HTTP app is
    the deliberate exception: it holds a pool for its whole lifetime rather than
    one per request.
    """
    # Borrows the process pool rather than owning it: this helper wraps a single
    # short operation, and the pool outlives it.
    client = PgClient(settings, owns_pool=False)
    await client.connect()
    try:
        yield PgRepository(client, claims)
    finally:
        await client.close()


__all__ = ["PgClient", "PgRepository", "Repository", "connected"]
