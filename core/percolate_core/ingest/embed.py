"""Embedding a corpus, in batches, from the registry.

ONE REQUEST PER CHUNK IS THE WRONG UNIT BY TWO ORDERS OF MAGNITUDE. A
300-chunk document embedded as a `matrix:` of `embed:` children is 300 HTTP
requests, 300 task rows and 300 round trips to a provider that accepts 2048
inputs in one call. Measured on this collection's own fixtures, the fan-out
spent about a second per chunk in latency alone.

WHY THE FAN-OUT CANNOT SIMPLY BE BATCHED. A step's output is capped
(`workflow.max_payload_bytes`, 64KB) and one 1536-dimension vector is ~31KB of
JSON -- two do not fit. Any design that carries corpus vectors through
`tasks.output` is limited to batches of one or two whatever else it does. So
the process that receives the vectors has to be the one that writes them, and
what goes back to the engine is a receipt: `{"embedded": 412, "requests": 5}`.

WHAT STAYS IN THE DATABASE. Everything about the model: which one, its url, the
shape of its request body, where the vectors are in the response, and the NAME
of the credential. `aiq.embed_batch_call()` hands all of that back from
`aiq.embedding_models` + `aiq.embedding_providers`, so this file contains no
provider knowledge and a second provider is a row rather than a branch.

ONE PROVIDER IS A BRANCH, AND ONLY ONE (REM-628). `in_process` providers -- a
small ONNX model loaded in this worker -- have no url, no body and no
credential, so there is no request for the registry to describe. The registry
still chooses the model, its id and its dimension; what the branch buys is that
a deployment gets vectors with no key, no bill and no egress. It is a branch on
one boolean column, and everything after it is the HTTP path unchanged.
"""

from __future__ import annotations

import asyncio
import json
from typing import Any

import httpx

from ..core import as_service, credential_for
from ..core.provider_errors import raise_for
from ..worker.templates import TerminalError

__all__ = ["embed_resource", "embed_source", "embed_texts"]

# Two ceilings, and a request stops at whichever comes first. Counts are what
# providers document; characters are what actually breaks -- a batch of 96
# chunks at 700 tokens is ~270KB of request body, which is fine, and a batch of
# 96 pathological chunks is not.
DEFAULT_BATCH = 96
DEFAULT_MAX_CHARS = 400_000


def _batches(texts: list[str], size: int, max_chars: int) -> list[list[int]]:
    """Indices, grouped. Indices rather than texts, so the caller keeps the
    mapping back to chunk ids without a second parallel list to get wrong."""
    out: list[list[int]] = []
    current: list[int] = []
    chars = 0
    for i, text in enumerate(texts):
        if current and (len(current) >= size or chars + len(text) > max_chars):
            out.append(current)
            current, chars = [], 0
        current.append(i)
        chars += len(text)
    if current:
        out.append(current)
    return out


def _vectors_from(body: Any, path: str, expected: int) -> list[list[float]]:
    """The vectors, in input order, from wherever this provider puts them.

    ORDER IS THE WHOLE CORRECTNESS ARGUMENT of a batch: the response is matched
    to chunk ids positionally, so a provider that reordered would attach every
    vector to the wrong chunk and nothing downstream could tell. OpenAI returns
    an `index` on each element for exactly this reason, and it is used when it
    is there rather than trusted to be redundant.
    """
    node: Any = body
    for part in path.split("."):
        if part and isinstance(node, dict):
            node = node.get(part)
    if not isinstance(node, list):
        raise TerminalError(
            f"the embedding response has no list at {path!r} -- the provider's "
            f"batch_response_path in aiq.embedding_providers does not match what it "
            f"actually returned: {json.dumps(body)[:300]}")

    items = list(node)
    if items and isinstance(items[0], dict) and "index" in items[0]:
        items.sort(key=lambda e: e.get("index", 0))
    vectors = [e.get("embedding") if isinstance(e, dict) else e for e in items]

    if len(vectors) != expected:
        raise TerminalError(
            f"asked for {expected} embeddings and got {len(vectors)} -- a batch whose "
            "response is a different length cannot be matched to its inputs by "
            "position, and matching it wrongly would attach every vector to the "
            "wrong chunk")
    return vectors


def embed_texts(spec: dict[str, Any], texts: list[str],
                batch_size: int = DEFAULT_BATCH,
                max_chars: int = DEFAULT_MAX_CHARS) -> tuple[list[list[float]], int]:
    """(vectors in input order, requests made). `spec` is aiq.embed_batch_call's."""
    # A provider that runs here rather than over HTTP (REM-628). The registry
    # still decides everything -- which model, which id, which dimension -- so
    # this stays one branch on one column rather than provider knowledge: the
    # spec says `in_process` and the rest of this function has nothing to do.
    # "requests" is 0 and means it: a receipt of {"embedded": 412, "requests":
    # 0} is how a reader tells a local run from a hosted one.
    if spec.get("in_process"):
        from .local_embed import DEFAULT_LOCAL_BATCH, embed_local
        size = batch_size if batch_size != DEFAULT_BATCH else DEFAULT_LOCAL_BATCH
        return embed_local(spec["model_id"], texts, size, spec.get("dim")), 0

    url, method = spec["url"], spec.get("method", "POST")
    # The url and the credential NAME are two columns of the registry, written
    # separately; the binding between them is the operator's, not the row's.
    token = (credential_for(spec["credential_ref"], url)
             if spec.get("credential_ref") else None)
    headers = {"Authorization": "Bearer " + token} if token else {}
    vectors: list[list[float] | None] = [None] * len(texts)
    requests = 0

    with httpx.Client(timeout=120.0) as client:
        if spec.get("batch"):
            template = spec.get("body") or {}
            # The body came back with the FIRST batch's texts substituted (the
            # database has no loop); the key holding them is the one whose value
            # is a list, and each request replaces it.
            key = next((k for k, v in template.items() if isinstance(v, list)), "input")
            for group in _batches(texts, batch_size, max_chars):
                body = dict(template)
                body[key] = [texts[i] for i in group]
                r = client.request(method, url, headers=headers, json=body)
                requests += 1
                raise_for(r.status_code, r.content, "embedding endpoint", r.text[:500])
                got = _vectors_from(r.json(), spec.get("jsonpath", "data"), len(group))
                for slot, vector in zip(group, got):
                    vectors[slot] = vector
        else:
            # A provider with no batch template is called once per text -- by
            # this same function, so a deployment on Ollama gets the same
            # receipt, the same retry and the same code path, just slower.
            template = spec.get("single_template") or {}
            path = spec.get("single_path") or "embedding"
            for i, text in enumerate(texts):
                body = {k: (text if v == "{{text}}" else
                            spec["model"] if v == "{{model}}" else v)
                        for k, v in template.items()}
                r = client.request(method, url, headers=headers, json=body)
                requests += 1
                raise_for(r.status_code, r.content, "embedding endpoint", r.text[:500])
                node: Any = r.json()
                for part in path.split("."):
                    if isinstance(node, list):
                        node = node[int(part)]
                    elif isinstance(node, dict):
                        node = node.get(part)
                vectors[i] = node

    missing = [i for i, v in enumerate(vectors) if v is None]
    if missing:
        raise TerminalError(f"{len(missing)} of {len(texts)} texts came back with no vector")
    return vectors, requests  # type: ignore[return-value]


async def embed_resource(spec: dict[str, Any], ctx: dict[str, Any]) -> dict[str, Any]:
    """The `op: embed` step: every chunk of one resource, into one space.

    With `source` instead of a resource id it embeds a registered semantic
    source by name (`embed_source`), which is how claims and questions get
    their vectors (REM-662)."""
    if spec.get("source"):
        return await embed_source(spec, ctx)
    resource_id = spec.get("resource_id") or (ctx.get("run_input") or {}).get("resource_id")
    if not resource_id:
        raise TerminalError("an embed step needs a resource_id")
    model = spec.get("model")
    batch_size = int(spec.get("batch_size") or DEFAULT_BATCH)

    async with as_service() as conn:
        rows = json.loads(await conn.fetchval(
            "select content.chunks_to_embed($1::uuid)::text", str(resource_id)))
        if not rows:
            # Not an error: a tabular or stored resource has no chunks, and the
            # pipeline is the same one for every upload.
            return {"result": {"resource_id": resource_id, "embedded": 0,
                               "requests": 0, "detail": "no chunks to embed"}}
        call = json.loads(await conn.fetchval(
            "select aiq.embed_batch_call($1, $2::jsonb)::text",
            model, [r["content"] for r in rows[:1]]))

    # OFF THE EVENT LOOP. `embed_texts` is a synchronous `httpx.Client` loop,
    # and called directly from this coroutine it blocked everything else in the
    # process for the whole corpus: every concurrent agent turn, every SSE
    # stream, every other task. Worst on a provider with no `batch` template,
    # where it is one request per chunk -- a 300-chunk document is 300 blocking
    # round trips -- but the batched path blocks too, just in fewer pieces.
    #
    # A thread rather than a rewrite to httpx.AsyncClient: the function is one
    # code path shared by both providers on purpose ("a deployment on Ollama
    # gets the same receipt, the same retry and the same code path, just
    # slower"), and making it async would either duplicate it or make the
    # synchronous callers async too. One line here keeps that property.
    vectors, requests = await asyncio.to_thread(
        embed_texts, call, [r["content"] for r in rows], batch_size)

    payload = [{"chunk_id": r["chunk_id"], "embedding": v}
               for r, v in zip(rows, vectors)]
    async with as_service() as conn:
        landed = await conn.fetchval(
            "select aiq.record_embeddings($1, $2::jsonb)", call["model"], payload)

    return {"result": {"resource_id": resource_id, "model": call["model"],
                       "embedded": landed, "chunks": len(rows),
                       "requests": requests, "batch_size": batch_size}}


# A page of rows per round trip. Small enough that one page's texts and vectors
# are a few hundred KB in memory, large enough that a page is a handful of
# batched provider calls rather than one.
SOURCE_PAGE = 256
# The most rows one task embeds. A backfill of a large corpus is several tasks
# rather than one that holds a core for an hour; the next run picks up where
# this one stopped, because what a space lacks is all the state there is.
SOURCE_MAX_ROWS = 20_000


async def embed_source(spec: dict[str, Any], ctx: dict[str, Any]) -> dict[str, Any]:
    """The `op: embed` step over a registered semantic source, by name (REM-662).

    WHY THIS EXISTS. `embed_resource` embeds one resource's chunks, and a claim
    or a question is not a resource. The `embed:` matrix that installs for them
    compiles to one HTTP call per row, so a deployment whose model runs here
    (fastembed, REM-628) -- production -- had no way to give a claim a vector,
    and `claims.candidates` refused every claim by name. This is the same loop
    as `embed_resource` with the row set asked of `aiq.texts_to_embed(source,
    model, limit)`, which reads any registered source and returns the rows the
    model's space has no vector for.

    WHAT IS LEFT TO EMBED IS THE ONLY STATE. Each page is the rows still
    missing, so a page that landed is gone from the next one, a task that dies
    halfway loses nothing, and two tasks racing write the same vector twice
    (record_embeddings upserts). The model is resolved once, before the first
    page, so a default moved mid-run cannot split one run across two spaces.
    """
    source = str(spec["source"])
    model = spec.get("model") or None
    batch_size = int(spec.get("batch_size") or DEFAULT_BATCH)
    page = max(1, int(spec.get("page") or SOURCE_PAGE))
    cap = max(1, int(spec.get("max_rows") or SOURCE_MAX_ROWS))

    async with as_service() as conn:
        # An empty batch resolves the model, its provider and its request shape
        # without embedding anything -- the probe content.install_ingest_workflow
        # uses. Its body holds an empty list where the texts go, and embed_texts
        # replaces that list per request, so one call serves every page.
        call = json.loads(await conn.fetchval(
            "select aiq.embed_batch_call($1, $2::jsonb)::text", model, []))
    name = call["model"]

    embedded = requests = pages = 0
    more = False
    while True:
        if embedded >= cap:
            more = True
            break
        async with as_service() as conn:
            rows = json.loads(await conn.fetchval(
                "select aiq.texts_to_embed($1, $2, $3)::text",
                source, name, min(page, cap - embedded)))
        if not rows:
            break
        texts = [r["content"] for r in rows]
        vectors, n = await asyncio.to_thread(embed_texts, call, texts, batch_size)
        payload = [{"chunk_id": r["chunk_id"], "embedding": v}
                   for r, v in zip(rows, vectors)]
        async with as_service() as conn:
            landed = await conn.fetchval(
                "select aiq.record_embeddings($1, $2::jsonb)", name, payload)
        if not landed:
            # Rows that come back and do not land would come back forever.
            raise TerminalError(
                f"{len(rows)} rows of source {source!r} were embedded and none landed in "
                f"the {name} space, so the next page would be the same rows")
        embedded += int(landed)
        requests += n
        pages += 1

    return {"result": {"source": source, "model": name, "embedded": embedded,
                       "pages": pages, "requests": requests, "more": more}}
