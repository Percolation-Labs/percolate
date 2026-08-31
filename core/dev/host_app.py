"""A stand-in for the bigger thing this module gets mounted into.

`specs/agentic/brief.md` §10.1 says `percolate-core` ships as a pip module in one
`p8` image alongside the Content Server. This file is what that image's process
looks like from this module's side: a host app that owns the lifespan, mounts
the agentic router under a prefix of its choosing, and mounts the agent gateway
as a sub-application.

It exists to be *run*, not read: if mounting ever stops behaving identically to
standalone mode, this fails and `dev/verify.py` does not.

    uv run uvicorn dev.host_app:app --port 8090
"""

from __future__ import annotations

import sys
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from percolate_core.agentic import api
from percolate_core.agentic.gateway import build_server
from percolate_core.agentic.settings import Settings

settings = Settings.from_env()
gateway = build_server(settings)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """The host composes each module's lifespan; it does not reimplement them.

    Two here: the agentic pool, and the MCP session manager the gateway's
    streamable-HTTP transport needs. A module that could not be composed this
    way — one that opened its pool at import, or on first request — would be
    mountable in name only.
    """
    async with api.lifespan(app, settings), gateway.session_manager.run():
        yield


app = FastAPI(title="p8 (host)", lifespan=lifespan)

# The prefix is the host's choice, not the module's.
app.include_router(api.router(), prefix="/agents")
app.mount("/agents/gateway", gateway.streamable_http_app())


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    """The host's own surface, sharing a process with a mounted subsystem."""
    return {"status": "ok", "mounted": "percolate_core.agentic"}
