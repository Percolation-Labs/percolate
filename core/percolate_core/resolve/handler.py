"""The `work` handler for the resolve queue. Imported by `serve` only."""

from __future__ import annotations

from ..worker import TerminalError, handler
from . import resolve


@handler("work")
async def work(spec: dict, ctx: dict) -> dict:
    """Dispatch a `work` step on the resolve queue by its `op`."""
    if spec.get("op") != "resolve":
        raise TerminalError(
            f"this is the resolve worker and it has one op, 'resolve', not {spec.get('op')!r}. "
            "A `work:` step for other code belongs on its own queue.")
    return await resolve(spec, ctx)
