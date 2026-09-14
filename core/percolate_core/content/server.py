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

import json
import os
from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, FastAPI, Header, HTTPException, Request, Response
from fastapi.responses import JSONResponse

from .. import __version__
from ..core import as_caller, claims_from_jwt, optional
from ..core.refusal import STATUS as REFUSED_STATUS, refusal
from . import storage

routes = APIRouter()


async def caller(authorization: str | None = Header(default=None)) -> dict[str, Any] | None:
    """The verified caller, or None for anonymous.

    Anonymous is a real state, not an error: an unauthenticated request sees
    public rows and the shared tier (org_id = rbac.shared_org_id()) and nothing
    else, which RLS enforces without this function needing an opinion. The
    shared tier stopped being `org_id is null` when identity/spec.md §4 made it
    a row and the column NOT NULL.
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


@routes.post("/files", status_code=201)
async def upload(request: Request,
                 claims: dict | None = Depends(caller),
                 x_p8_channel: str = Header(default="uploads"),
                 x_p8_title: str | None = Header(default=None),
                 x_p8_title_utf8: str | None = Header(default=None),
                 x_p8_org: str | None = Header(default=None),
                 traceparent: str | None = Header(default=None)):
    """Store bytes, register them, and start the ingestion workflow.

    All three in one transaction, so a committed resource always has a run and
    a rolled-back upload leaves neither.
    """
    if not claims:
        raise HTTPException(401, "Sign in before uploading a file")
    if x_p8_title_utf8 is not None:
        from urllib.parse import unquote
        try:
            x_p8_title = unquote(x_p8_title_utf8, encoding="utf-8", errors="strict")
        except UnicodeError:
            raise HTTPException(400, "X-P8-Title-Utf8 must contain percent-encoded UTF-8") from None
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
        # A REFUSAL IS NOT A BAD REQUEST. `content.register_upload` raises
        # "not authorized to upload content", hint "needs resources:create",
        # and the request that got it was well formed -- the caller may not
        # make it. One rule for that, shared with the agent runtime and the
        # CLI (core/refusal.py); everything else the database says is still a
        # 400, because its message is the useful one (an unknown channel names
        # itself) and passing it through beats a generic 500.
        refused = refusal(e)
        if refused is not None:
            return JSONResponse(refused.body(), status_code=REFUSED_STATUS)
        raise HTTPException(400, str(e).split("\n")[0])

    return {"resource_id": str(resource_id), "checksum": checksum, "bytes": len(data)}


@routes.get("/files/{resource_id}")
async def fetch(resource_id: UUID, claims: dict | None = Depends(caller)):
    async with as_caller(claims) as conn:
        row = await conn.fetchrow("select * from content.resolve_file($1)", resource_id)

    # resolve_file is SECURITY INVOKER, so RLS already decided this. No row
    # means "not yours or not there" -- deliberately one answer, because
    # distinguishing them tells an unauthorized caller the resource exists.
    if not row:
        raise HTTPException(404, "no such file, or not yours")

    body = storage.get(row["bucket"], row["object_key"])
    # NEVER INLINE, WHATEVER THE TYPE SAYS. `content_type` is the uploader's own
    # `Content-Type` header, kept verbatim from the upload above, and the bytes
    # are theirs too. Served inline it executes on this origin -- the same origin
    # as this file API -- so an uploaded `text/html` reads every file the viewer
    # can read. The delivery is already built: an agent answer containing a link
    # to `/files/<id>` passes the chat renderer's scheme allowlist
    # (`ui/static/md.js`), because a same-origin path is exactly what that
    # allowlist is for.
    #
    # This is CWE-80, which 2026 model evaluations fail about 85% of the time
    # against 82% passed for SQL injection -- and it is invisible to the 1,506
    # SQL assertions in the collection, which is why the SQL here is clean and
    # this was not. `attachment` carries no filename deliberately: the name is
    # attacker-supplied too and quoting it into a header is a second bug.
    return Response(
        body,
        media_type=row["content_type"] or "application/octet-stream",
        headers={
            "Content-Disposition": "attachment",
            "X-Content-Type-Options": "nosniff",
            "Content-Security-Policy": "sandbox; default-src 'none'",
        },
    )


@routes.post("/probe")
async def probe_source(request: Request, claims: dict | None = Depends(caller)):
    """Read one endpoint once and describe what came back.

    THE SAME OUTBOUND-HTTP RESPONSIBILITY this module already has, not a fourth
    one: the scraper pulls a channel and `http_call` steps execute here for the
    same reason, which is that this is the process allowed to make a request to
    somewhere else. A probe route on the UI server would have been a second
    place with that permission, and the UI server's whole claim is that it has
    none (`ui/server.py`).

    Signed in, always. Not because the report is sensitive -- it is the
    operator's own endpoint -- but because an unauthenticated URL fetcher on an
    internal network is a request forwarder for whoever finds it. The URL rules
    (`core/credentials.origin`), the byte and time caps, and the credential
    binding are in `probe.py` beside this file, and come from `core.credentials`,
    the same parser `ingest/api.py` wraps for the puller.

    No row is read or written. The report is not persisted: it describes an
    endpoint at a moment, and a stored one would be a second, ageing account of
    a source's shape beside the source's own configuration.
    """
    if not claims:
        raise HTTPException(401, "Sign in before inspecting an endpoint")
    body = await request.json() if await request.body() else {}
    if not isinstance(body, dict) or not isinstance(body.get("url"), str):
        raise HTTPException(400, "send {\"url\": \"https://...\"}")
    from .probe import ProbeFailed, probe

    try:
        return await probe(
            body["url"],
            auth_type=str(body.get("auth_type") or "none"),
            credential_ref=str(body.get("credential_ref") or ""),
            auth_header=str(body.get("auth_header") or "X-API-Key"),
        )
    except ProbeFailed as e:
        # A refusal to probe is the answer, not a server error: the assistant
        # shows it to the operator and declines to invent paths, which is the
        # whole point of asking.
        raise HTTPException(400, str(e)) from None


@routes.post("/evidence", status_code=201)
async def save_evidence(request: Request, claims: dict | None = Depends(caller)):
    """Keep a copy of a public page as the caller's research evidence (REM-239).

    The same outbound request `/probe` makes, for the reason given there, and
    the bytes stored the way `/files` stores them -- then registered through
    `content.register_evidence`, which holds the policy: anybody who may write
    research, limited by the `evidence_bytes` budget (REM-242). A person's
    application calls this with that person's token.

    A PAGE THAT IS NOT KEPT IS AN ANSWER, NOT AN ERROR. Unreachable, refused by
    the egress guard, too large or empty comes back 422 with `saved: false` and
    the reason, so the caller can leave the source unverified and say why.

    THE BUDGET IS ASKED BEFORE THE BYTES ARE STORED, so a refused page leaves no
    object behind in the common case. The database asks again when it registers,
    and that answer is the one that counts; the window between the two can only
    leave an unreferenced content-addressed object, which storage may prune.
    """
    if not claims:
        raise HTTPException(401, "Sign in before saving evidence")
    body = await request.json() if await request.body() else {}
    if not isinstance(body, dict) or not isinstance(body.get("url"), str):
        raise HTTPException(400, "send {\"url\": \"https://...\"}")
    title = body.get("title") if isinstance(body.get("title"), str) else None
    from .evidence import EvidenceRefused, fetch

    try:
        data, content_type = await fetch(body["url"])
    except EvidenceRefused as e:
        return JSONResponse({"saved": False, "reason": str(e)}, status_code=422)

    try:
        async with as_caller(claims) as conn:
            state = await conn.fetchval(
                "select rbac.limit_state(rbac.current_user_id(), 'evidence_bytes')")
        state = state if isinstance(state, dict) else json.loads(state or "{}")
        if state.get("status") in ("finite", "exhausted") and int(state.get("remaining") or 0) < len(data):
            return JSONResponse({"saved": False, "reason": "Your allowance for saving evidence is used up for now.",
                                 "limit": state}, status_code=REFUSED_STATUS)

        checksum, key = storage.put(data, content_type)
        async with as_caller(claims) as conn:
            resource_id = await conn.fetchval(
                "select content.register_evidence($1,$2,$3,$4,$5,$6,$7)",
                body["url"], checksum, storage.bucket(), key, len(data), content_type, title)
    except Exception as e:
        refused = refusal(e)
        if refused is not None:
            return JSONResponse(refused.body(), status_code=REFUSED_STATUS)
        raise HTTPException(400, str(e).split("\n")[0])

    return {"saved": True, "resource_id": str(resource_id), "checksum": checksum,
            "bytes": len(data), "content_type": content_type}


@routes.get("/health")
async def health():
    return {"status": "ok", "bucket": storage.bucket()}


def build_app(cors_origins: tuple[str, ...] | None = None) -> FastAPI:
    from urllib.parse import urlsplit
    from fastapi.middleware.cors import CORSMiddleware

    origins = cors_origins if cors_origins is not None else tuple(
        o.strip() for o in os.environ.get("P8_CONTENT_CORS_ORIGINS", "").split(",") if o.strip())
    for origin in origins:
        parsed = urlsplit(origin)
        if ("*" in origin or parsed.scheme not in {"http", "https"}
                or not parsed.hostname or parsed.username or parsed.password
                or parsed.path or parsed.query or parsed.fragment
                or "\\" in origin or any(c.isspace() for c in origin)):
            raise ValueError("Content CORS requires explicit HTTP(S) origins without paths")
    application = FastAPI(title="percolate content", version=__version__)
    if origins:
        application.add_middleware(CORSMiddleware, allow_origins=list(origins),
            allow_methods=["GET", "POST"],
            allow_headers=["Authorization", "Content-Type", "X-P8-Channel", "X-P8-Title", "X-P8-Title-Utf8", "X-P8-Org", "Traceparent"],
            allow_credentials=False)
    application.include_router(routes)
    return application


app = build_app()


def serve(host: str = "0.0.0.0", port: int | None = None) -> None:
    import uvicorn

    # Before the socket, not on the first upload: a storage backend this
    # process cannot write to is a startup failure with a name, not a 500 with
    # a stack trace in it.
    print("[content] bucket " + storage.ensure_bucket(), flush=True)
    uvicorn.run(app, host=host, port=port or int(os.environ.get("P8_PORT", "8081")))
