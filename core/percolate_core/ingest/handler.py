"""The `work` handler that turns an uploaded file into chunks.

This is the one step in the ingestion pipeline that needs code, and the
world-model brief says why it is allowed to: `chunk:` was refused as a workflow
shorthand because "the strategy is a decision the author has to make". This
module is a DEFAULT for that decision, not a removal of it -- the step stays
`kind: work` on its own queue, so replacing it is running a different worker,
not patching this one.

    percolate ingest serve --queue ingest

WHAT THE STEP DOES, in order, and where each part can fail:

    content.ingest_target(resource)   one call, because the worker holds no
                                      table grants -- it cannot join resources
                                      to files to channels
    storage.get(bucket, key)          the bytes, from the same S3-compatible
                                      client the Content Server wrote them with
    policy.resolve(...)               family default <- channel <- upload
    parse.to_markdown(...)            one library per format
    chunk.chunk_markdown(...)         semchunk, with offsets
    content.record_ingest(...)        chunks, provenance and status, in one
                                      transaction

and for a tabular upload the middle three become one conversion to Parquet and
a `content.register_dataset` call, because a table is not prose.

FAILURE IS TERMINAL WHERE IT WILL RECUR. A policy that does not validate, a
parser that is not installed, a PDF with no text layer: none of these is
different on the fifth attempt, and retrying them five times turns a clear
failure into a slow one. A storage read and a transcription call are the
opposite and stay retryable.
"""

from __future__ import annotations

import json
from typing import Any

from ..core import as_service
from ..worker.loop import handler
from ..worker.templates import TerminalError
from . import chunk as chunker
from . import parse, tabular
from .embed import embed_resource
from .policy import PolicyError, resolve

__all__ = ["OPS", "ingest", "work"]


def _name_of(target: dict[str, Any]) -> str | None:
    """A filename to reason about, from whatever the upload actually carried.

    The Content Server does not take one -- `POST /files` is bytes plus a
    title -- so the extension usually rides in the title or the uri. Both are
    checked because a content type of application/octet-stream is common and
    means nothing.
    """
    for candidate in (target.get("title"), target.get("uri")):
        if candidate and "." in str(candidate).rsplit("/", 1)[-1]:
            return str(candidate).rsplit("/", 1)[-1]
    return None


async def ingest(spec: dict[str, Any], ctx: dict[str, Any]) -> dict[str, Any]:
    resource_id = spec.get("resource_id") or (ctx.get("run_input") or {}).get("resource_id")
    if not resource_id:
        raise TerminalError(
            "an ingest step needs a resource_id -- `input: {op: ingest, resource_id: "
            "'{{run.resource_id}}'}`. content.register_upload puts it in the run input.")

    from ..content import storage  # imported here: only this op needs boto3

    # EVERY jsonb ARGUMENT BELOW IS PASSED AS A PYTHON OBJECT, not as a string
    # of JSON. The pool installs a jsonb codec whose encoder is json.dumps, so
    # a pre-dumped string is encoded a second time and arrives as a jsonb
    # STRING -- `p_outcome ? 'chunks'` is then false, record_ingest writes no
    # chunks and marks the resource 'stored', and the step reports success.
    # Every text upload in the first end-to-end run landed that way: five
    # resources, zero chunks, no error anywhere.
    async with as_service() as conn:
        raw = await conn.fetchval(
            "select content.ingest_target($1::uuid)::text", str(resource_id))
    if not raw:
        raise TerminalError(
            f"resource {resource_id} does not exist, or this worker may not see it")
    target = json.loads(raw)

    if not target.get("object_key"):
        # A resource with no bytes is a pulled record, not an upload. Nothing
        # to parse, and saying so beats a null-dereference three frames down.
        raise TerminalError(
            f"resource {resource_id} has no file -- content.register_fetched creates "
            "resources without bytes, and there is nothing for a chunker to read")

    try:
        family, policy = resolve(target.get("content_type"), _name_of(target),
                                 target.get("policy") or {})
    except PolicyError as e:
        raise TerminalError(str(e)) from None

    if policy.mode == "skip":
        return {"result": {"resource_id": resource_id, "mode": "skip", "chunks": 0,
                           "detail": "policy says skip; the bytes stay registered"}}

    data = storage.get(target["bucket"], target["object_key"])
    name = _name_of(target)

    # ---------------------------------------------------------------- tabular
    if policy.mode == "tabular":
        try:
            parquet, columns, rows = tabular.to_parquet(data, policy, name)
        except tabular.MissingParser as e:
            raise TerminalError(str(e)) from None
        except Exception as e:  # noqa: BLE001 -- pyarrow raises a dozen types
            # for a malformed table and every one of them means the same thing
            # to the caller: this is not the table it said it was, and it will
            # not be on the next attempt either.
            raise TerminalError(
                f"this file could not be read as a table: {e}. Set "
                "`ingest_policy: {mode: text}` on the channel or the upload to "
                "chunk it as prose instead.") from None

        dataset = tabular.dataset_name_for(policy, name, target.get("title"))
        checksum, _ = storage.put(parquet, "application/vnd.apache.parquet")
        key = tabular.object_key_for(dataset, checksum)
        # Written a second time under the dataset prefix, and that is not a
        # duplicate by accident: `objects/<hash>` is the content-addressed
        # store every file lives in, and the dataset prefix is what the DuckDB
        # glob reads. One is storage, the other is a table.
        storage.put_at(key, parquet, "application/vnd.apache.parquet")

        async with as_service() as conn:
            receipt = json.loads(await conn.fetchval(
                "select content.register_dataset($1::uuid,$2,$3,$4,$5::jsonb,$6::bigint,$7,$8::text[])::text",
                str(resource_id), dataset, storage.bucket(), key,
                columns, rows, policy.table.mode,
                policy.table.partition_by))
            outcome = {"mode": "tabular", "parser": "arrow",
                       "detail": {**receipt, "rows": rows,
                                  "columns": [c["name"] for c in columns]}}
            landed = json.loads(await conn.fetchval(
                "select content.record_ingest($1::uuid, $2::jsonb)::text",
                str(resource_id), outcome))
        return {"result": {**landed, "dataset": dataset, "rows": rows}}

    # ------------------------------------------------------------------ store
    if policy.mode == "store":
        async with as_service() as conn:
            landed = json.loads(await conn.fetchval(
                "select content.record_ingest($1::uuid, $2::jsonb)::text",
                str(resource_id),
                {"mode": "store", "parser": None,
                 "detail": {"family": family,
                            "content_type": target.get("content_type")}}))
        return {"result": landed}

    # ------------------------------------------------------------------- text
    try:
        parsed = parse.to_markdown(data, policy, name)
    except (parse.MissingParser, parse.EmptyParse) as e:
        raise TerminalError(str(e)) from None

    chunks = chunker.chunk_markdown(parsed.markdown, policy.chunking)
    if not chunks:
        raise TerminalError(
            f"{parsed.parser} produced {len(parsed.markdown)} characters and the "
            "chunker produced nothing from it")

    markdown_ref = None
    if policy.keep_markdown:
        md_checksum, md_key = storage.put(
            parsed.markdown.encode(), "text/markdown; charset=utf-8")
        markdown_ref = {"bucket": storage.bucket(), "object_key": md_key,
                        "bytes": len(parsed.markdown.encode()),
                        "checksum": md_checksum}

    # THE CHUNKS ARE DOCUMENT TEXT, so they carry whatever the file carried and
    # whatever the parser made of it. `content.record_chunks` reads each one
    # with `c->>'content'`, and Postgres text cannot hold U+0000: one NUL in a
    # 777-byte upload took the ingest task terminal, cancelled the three tasks
    # after it, and wrote no chunks at all. Measured 2026-09-12 (REM-146). The
    # replacement happens in the pool's jsonb encoder (core/identity.py), which
    # every jsonb argument in this package passes through.
    async with as_service() as conn:
        landed = json.loads(await conn.fetchval(
            "select content.record_ingest($1::uuid, $2::jsonb)::text",
            str(resource_id),
            {"mode": "text", "parser": parsed.parser, "chunks": chunks,
             "markdown": markdown_ref,
             "detail": {**parsed.detail, "family": family,
                        "characters": len(parsed.markdown),
                        "target_tokens": policy.chunking.target_tokens}}))

    # A RECEIPT, not the chunks (workflow-engine/outputs.md §2): the rows have a
    # home, and returning them would copy every chunk into tasks.output and
    # again into runs.context.
    return {"result": {**landed, "parser": parsed.parser,
                       "characters": len(parsed.markdown)}}


from .api import api_pull

OPS = {"ingest": ingest, "embed": embed_resource, "api_pull": api_pull}


@handler("work")
async def work(spec: dict[str, Any], ctx: dict[str, Any]) -> dict[str, Any]:
    """Dispatch a `work` step by its `op`.

    The engine dispatches on step KIND, and `work` is the one kind that means
    "your code" -- so a worker that handles two kinds of work needs a second
    level, and this is it. Queues are the first level: this worker is meant to
    be run with `--queue ingest`, so an unknown op here is a workflow pointing
    the wrong step at the ingest pool, and the message says so.
    """
    op = spec.get("op")
    fn = OPS.get(op)
    if fn is None:
        raise TerminalError(
            f"this is the ingest worker and it has no op named {op!r} -- it knows "
            f"{', '.join(sorted(OPS))}. A `work:` step for your own code belongs on "
            "its own queue with your own @handler, not on this one.")
    return await fn(spec, ctx)
