"""The Content Server: a server AND a scraper.

Two jobs that are the same job differing only in who initiates -- a push
arrives as an upload, a pull is a channel we poll. Both get bytes, store them,
write the rows, and start the ingestion workflow.

It is also where `http_call` steps execute, which is not a fourth
responsibility but the same outbound-HTTP capability the scraper already needs.

WHY READS ARE PROXIED RATHER THAN PRESIGNED
A presigned URL is a second, independent authorization mechanism with its own
scoping and expiry, to be gotten right IN ADDITION to Postgres RLS. Proxying
keeps exactly one authorization path for file bytes -- the same one governing
every other read in the collection. The cost is bandwidth through this process,
acceptable because it is stateless and scales horizontally.
"""

from __future__ import annotations

import os
from typing import Any
from uuid import UUID

from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response

from .. import __version__
from ..core import as_caller, claims_from_jwt, optional
from . import storage

app = FastAPI(title="percolate content", version=__version__)


async def caller(authorization: str | None = Header(default=None)) -> dict[str, Any] | None:
    """The verified caller, or None for anonymous.

    Anonymous is a real state, not an error: an unauthenticated request sees
    globally-shared rows (org_id is null) and nothing else, which RLS enforces
    without this function needing an opinion.
    """
    if not authorization:
        return None
    if not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "Authorization must be 'Bearer <token>'")
    secret = optional("P8_JWT_SECRET")
    if not secret:
        raise HTTPException(500, "P8_JWT_SECRET is not set -- tokens cannot be verified")
    try:
        return claims_from_jwt(authorization[7:], secret)
    except ValueError as e:
        raise HTTPException(401, str(e))


@app.post("/files", status_code=201)
async def upload(request: Request,
                 claims: dict | None = Depends(caller),
                 x_p8_channel: str = Header(default="uploads"),
                 x_p8_title: str | None = Header(default=None),
                 x_p8_org: str | None = Header(default=None),
                 traceparent: str | None = Header(default=None)):
    """Store bytes, register them, and start the ingestion workflow.

    All three in one transaction, so a committed resource always has a run and
    a rolled-back upload leaves neither.
    """
    data = await request.body()
    if not data:
        raise HTTPException(400, "empty body -- send the file bytes")

    content_type = request.headers.get("content-type")
    checksum, key = storage.put(data, content_type)

    # W3C traceparent: take its trace-id field so an upload and everything it
    # causes share one trace rather than three disconnected ones.
    trace_id = None
    if traceparent and len(traceparent.split("-")) > 2:
        trace_id = traceparent.split("-")[1]

    try:
        async with as_caller(claims) as conn:
            resource_id = await conn.fetchval(
                "select content.register_upload($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)",
                x_p8_channel, checksum, storage.bucket(), key, len(data),
                content_type, x_p8_title, f"s3://{storage.bucket()}/{key}",
                UUID(x_p8_org) if x_p8_org else None, "{}", None, trace_id)
    except Exception as e:
        # The database's message is the useful one (an unknown channel names
        # itself); passing it through beats a generic 500.
        raise HTTPException(400, str(e).split("\n")[0])

    return {"resource_id": str(resource_id), "checksum": checksum, "bytes": len(data)}


@app.get("/files/{resource_id}")
async def fetch(resource_id: UUID, claims: dict | None = Depends(caller)):
    async with as_caller(claims) as conn:
        row = await conn.fetchrow("select * from content.resolve_file($1)", resource_id)

    # resolve_file is SECURITY INVOKER, so RLS already decided this. No row
    # means "not yours or not there" -- deliberately one answer, because
    # distinguishing them tells an unauthorized caller the resource exists.
    if not row:
        raise HTTPException(404, "no such file, or not yours")

    body = storage.get(row["bucket"], row["object_key"])
    return Response(body, media_type=row["content_type"] or "application/octet-stream")


@app.get("/health")
async def health():
    return {"status": "ok", "bucket": storage.bucket()}


def serve(host: str = "0.0.0.0", port: int | None = None) -> None:
    import uvicorn

    # Before the socket, not on the first upload: a storage backend this
    # process cannot write to is a startup failure with a name, not a 500 with
    # a stack trace in it.
    print("[content] bucket " + storage.ensure_bucket(), flush=True)
    uvicorn.run(app, host=host, port=port or int(os.environ.get("P8_PORT", "8081")))
