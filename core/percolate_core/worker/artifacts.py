"""Output class 4: what a step does when its result does not fit in a column.

`workflow.tasks.output` is capped (`workflow.max_payload_bytes`, 64KB by
default) because an unbounded JSONB column is how a task table becomes
unqueryable. Before this module the engine's answer was a terminal failure
naming a remedy that did not exist on this side: register the bytes in object
storage and return a ref beside the payload. This is that half.

    {"status": 200, "$artifact": "<resource uuid>"}

THE REF IS A SIBLING OF `result`, NOT A VALUE INSIDE IT. The engine's size
check uses the jsonb `?` operator, which is top-level only, while every step
nests its payload under `result` -- so a ref inside `result` is invisible to
the check and a ref at the top breaks every {{steps.<id>.result}} that reads
it. As a sibling there is nothing to reconcile, `output_schema` never sees the
engine's key, and {{steps.<id>.$artifact}} resolves with no change to the
template resolver. See p8-subsystems specs/workflow-engine/outputs.md.

AND NO `result` AT ALL when we offload. A value too large to carry is not a
value; the ref is. Leaving a summary behind under `result` would make
{{steps.<id>.result}} resolve to something that is not the data, which is a
quiet lie -- where resolving to nothing is a loud, locatable failure at the
step that actually wanted it.

A RESOURCE ID, NOT AN s3:// URI. register_artifact returns a row in
content.resources, so the artifact is RLS-scoped, checksum-deduped, servable
and visible to content.check_drift. A bucket path in a JSONB column is none of
those, and carries a bucket name into a row that is meant to stay inspectable.
"""

from __future__ import annotations

import json
import os
from typing import Any

from ..core.identity import jsonb_text
from .templates import TerminalError

DEFAULT_MAX_BYTES = 65536

# One probe per process. The cap is a database setting, so asking the database
# is the only way to be right about a deployment that raised it -- and asking
# once per task would be a round trip per task to learn a number that does not
# change.
_max_bytes: int | None = None


async def max_payload_bytes(conn: Any) -> int:
    """The engine's cap, read from the database it is enforced by.

    Not an env var with a matching default: two places to configure one limit
    is how a worker ends up confidently offloading at 64KB against a database
    that accepts 256KB, or worse, not offloading at 256KB against one that
    does not. P8_MAX_PAYLOAD_BYTES exists only as an override for a worker
    that cannot reach the setting.
    """
    global _max_bytes
    if _max_bytes is None:
        if override := os.environ.get("P8_MAX_PAYLOAD_BYTES"):
            _max_bytes = int(override)
        else:
            got = await conn.fetchval(
                "select current_setting('workflow.max_payload_bytes', true)")
            _max_bytes = int(got) if got else DEFAULT_MAX_BYTES
    return _max_bytes


async def stored_size(conn: Any, out: Any) -> int:
    """What the ENGINE will measure, asked of the thing that measures it.

    complete_task compares `pg_column_size(v_out)` against the cap -- the size
    of the value as jsonb -- and this used to compare `len(json.dumps(out))`,
    the size of the value as compact JSON text. Those are two different
    quantities and jsonb is the larger one for anything object- or array-heavy,
    because every element carries a 4-byte JEntry. Measured on a live database:

        select jsonb_build_object('result', <1500 small objects>)
        length(j::text) = 48798      pg_column_size(j) = 74029

    So a 48KB payload was under a 64KB cap by this side's arithmetic and 9KB
    over it by the engine's: the worker declined to offload and the task then
    failed terminally, with a message telling the operator to do the thing the
    worker had just decided was unnecessary. Between those two numbers is a
    band where the two halves of one limit disagree, and no fudge factor closes
    it -- the ratio is a property of the payload's shape, not a constant.

    One round trip per completed task, on a connection and inside a transaction
    that are already open for complete_task. That is the price of the cap
    having one definition instead of two, and it is the same argument
    max_payload_bytes() makes about the number itself.

    `$1::text::jsonb` AND NOT `$1::jsonb`, which is not a style choice. With the
    single cast Postgres infers the parameter's type as jsonb, and every pool
    this package opens installs a jsonb codec whose encoder is json.dumps
    (core/identity.py) -- so an already-dumped string is encoded a SECOND time
    and what the database measures is a jsonb *string* containing JSON rather
    than the object. Measured on the same 1,500-object payload: 74,044 bytes on
    a bare connection and 48,819 on a pooled one, for the same value. The
    double cast pins the parameter to text, so no codec applies on either.
    ingest/handler.py carries the same warning about the same codec; this is
    that defect in the one place a re-encode is invisible, because both answers
    are plausible integers.

    And the text is `jsonb_text`, the codec's own encoder, rather than
    `json.dumps`: the double cast bypasses the codec, so this was the one jsonb
    argument on the http_call path that still carried `\\u0000`, and a response
    with a NUL in it aborted here, before complete_task was reached (REM-146).
    Measuring the same text the codec sends is also what the engine stores.
    """
    return await conn.fetchval("select pg_column_size($1::text::jsonb)", jsonb_text(out))


def _bytes_of(out: Any) -> tuple[bytes, str, bool]:
    """The payload as bytes, the content type, and whether `result` held it.

    A step whose result is already text (an HTML page, a CSV, a model's prose)
    is stored as that text rather than as a JSON string containing it -- the
    artifact is meant to be openable by whatever eventually reads it, and
    "a .json file holding one giant quoted string" is not.

    A HANDLER NEED NOT HAVE NESTED ITS PAYLOAD UNDER `result`, and this read
    `out.get("result")` as though one always had. The @handler contract in
    loop.py's own docstring returns `{"duration": ...}` -- no `result` key at
    all -- so the get() returned None, `json.dumps(None)` stored the four bytes
    `null` as the artifact, and the oversized payload went to complete_task
    unchanged and failed there. Reproduced: 104,030 bytes in, 4 bytes stored,
    104,083 bytes still sent. The data was gone and the failure named the
    remedy that had just destroyed it.

    So the third element says which of the two shapes this was. With no
    `result` key there is no envelope to tell apart from the payload -- the
    whole object IS the payload -- and offload() keeps nothing beside the ref.
    """
    if not isinstance(out, dict) or "result" not in out:
        return json.dumps(out).encode(), "application/json", False
    result = out["result"]
    if isinstance(result, str):
        return result.encode(), "text/plain; charset=utf-8", True
    return json.dumps(result).encode(), "application/json", True


async def offload(conn: Any, task_id: str, out: Any) -> Any:
    """Return `out` unchanged, or a ref to it stored in object storage.

    Called between the handler returning and complete_task, so it applies to
    EVERY step kind rather than only to http_call: a `work` handler that
    returns five megabytes has exactly the same problem, and solving it in one
    handler would leave the others failing for a reason the docs say is fixed.
    """
    if not isinstance(out, dict):
        return out

    size = await stored_size(conn, out)
    cap = await max_payload_bytes(conn)
    if size <= cap:
        return out

    try:
        from ..content import storage
    except ImportError as e:
        # Honest degradation: without object storage this task fails exactly as
        # it did before, and the message names the one command that changes it.
        # The shipped image installs [all], so the documented path always has
        # this; only a hand-rolled minimal install lands here.
        raise TerminalError(
            f"output is {size} bytes, over the {cap} byte limit, and this "
            f"worker cannot offload it: object storage support is not installed. "
            f"Run `pip install 'percolate-core[content]'`, or raise "
            f"workflow.max_payload_bytes deliberately. ({e})") from None

    # NOT wrapped in TerminalError: object storage being unreachable is the
    # ordinary transient failure, and the retry the engine already does is the
    # right response. Only the missing-dependency case above is terminal,
    # because pip will not run itself between attempts.
    data, content_type, nested = _bytes_of(out)
    checksum, key = storage.put(data, content_type)

    # Casts are explicit: asyncpg sends a str as text, and register_artifact's
    # first argument is uuid and its fifth is bigint. Without them the call
    # fails as "function does not exist", which reads as a missing migration
    # rather than as a type it could have coerced.
    resource_id = await conn.fetchval(
        "select workflow.register_artifact("
        "$1::uuid, $2::text, $3::text, $4::text, $5::bigint, $6::text, $7::text)",
        task_id, checksum, storage.bucket(), key, len(data), content_type,
        # The title is what a human sees in v_artifacts; the step key alone is
        # ambiguous across runs, and register_artifact defaults to it anyway,
        # so say what this actually is.
        f"{len(data)} bytes offloaded from a step output",
    )

    # Everything except `result`, plus the ref. `status` and any other envelope
    # field a handler set stays -- those are small and are about the CALL, not
    # about the payload, so a downstream step can still branch on an HTTP
    # status without dereferencing anything.
    #
    # UNLESS THERE WAS NO `result`, in which case there is no envelope to keep:
    # every key was payload, all of it is in the artifact, and carrying any of
    # it back would put the bytes we just offloaded back over the cap. The ref
    # alone is what completes.
    if not nested:
        return {"$artifact": str(resource_id)}
    kept = {k: v for k, v in out.items() if k != "result"}
    kept["$artifact"] = str(resource_id)
    return kept
