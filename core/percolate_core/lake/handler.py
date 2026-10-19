"""The lake worker's `work` handler: `refine` writes, `query` reads.

Its own queue and its own process, for the reason the ingest worker has one: a
DuckDB scan wants memory and spill disk sized for the largest input a
deployment has, and a pool sized for that is the wrong pool for parsing PDFs.

    percolate lake serve --queue lake
"""

from __future__ import annotations

from typing import Any

from ..worker.loop import handler
from ..worker.templates import TerminalError
from .query import query
from .refine import refine

__all__ = ["OPS", "work"]

OPS = {"refine": refine, "query": query}


@handler("work")
async def work(spec: dict[str, Any], ctx: dict[str, Any]) -> dict[str, Any]:
    op = spec.get("op")
    fn = OPS.get(op)
    if fn is None:
        raise TerminalError(
            f"this is the lake worker and it has no op named {op!r} -- it knows "
            f"{', '.join(sorted(OPS))}. Parsing and embedding uploads is the ingest "
            "worker's (`percolate ingest serve`), on its own queue.")
    return await fn(spec, ctx)
