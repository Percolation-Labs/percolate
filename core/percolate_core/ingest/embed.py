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
"""

from __future__ import annotations

import json
from typing import Any

import httpx

from ..core import as_service, credential_for
from ..core.provider_errors import raise_for
from ..worker.templates import TerminalError

__all__ = ["embed_resource", "embed_texts"]

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
    """The `op: embed` step: every chunk of one resource, into one space."""
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

    vectors, requests = embed_texts(call, [r["content"] for r in rows], batch_size)

    payload = [{"chunk_id": r["chunk_id"], "embedding": v}
               for r, v in zip(rows, vectors)]
    async with as_service() as conn:
        landed = await conn.fetchval(
            "select aiq.record_embeddings($1, $2::jsonb)", call["model"], payload)

    return {"result": {"resource_id": resource_id, "model": call["model"],
                       "embedded": landed, "chunks": len(rows),
                       "requests": requests, "batch_size": batch_size}}
