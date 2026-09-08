"""End to end: an oversized step output becomes a registered artifact.

Output class 4, asserted rather than described. Run against the p8-subsystems
dev stack (`p8-subsystems/dev/stacks.sh up dev`), which brings up PG19 on :5610
and MinIO on :5614:

    P8_OFFLOAD_DSN=postgres://p8:p8@localhost:5610/p8dev \
    uv run --with asyncpg --with boto3 python dev/offload.py

Seven checks, each one a sentence the specs make: a small payload is untouched;
an oversized one becomes a "$artifact" ref with no "result"; the task COMPLETES
where it used to fail terminally; the ref resolves to a real object; the bytes
read back byte-identical to what the step produced; a handler that did not nest
its payload under "result" is offloaded rather than destroyed; and the size this
side measures is the size the engine enforces.

THE LAST TWO ARE REGRESSIONS, and both were defects this file could not have
found in the shape it had. Its one fixture was `{"status": 200, "result": ...}`
-- a payload nested under `result`, whose JSON text and jsonb sizes happen to
agree closely -- which is the one shape in which neither defect can occur. That
is `meta/postmortems/README.md`'s "verified in a world where the defect could
not appear", arriving inside the harness that exists to assert this module.
"""
import asyncio, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ.setdefault("P8_S3_ENDPOINT", "http://localhost:5614")
os.environ.setdefault("P8_S3_KEY", "p8admin")
os.environ.setdefault("P8_S3_SECRET", "p8password")
os.environ.setdefault("P8_BUCKET", "p8-content")

# NOT a literal. This said `localhost:5499/p8experiment`, which was the old
# single experiment container; `dev/stacks.sh` replaced it with four named
# instances and the dev one is :5610/p8dev. A harness pointed at a stack that
# no longer exists cannot fail, and README.md cites this file as the assertion
# behind the whole artifact path.
DSN = os.environ.get("P8_OFFLOAD_DSN", "postgres://p8:p8@localhost:5610/p8dev")

import asyncpg
from percolate_core.core.identity import _init_connection
from percolate_core.worker.artifacts import offload, stored_size


async def fresh_task(conn):
    """A run and its one task. Each completion needs its own -- complete_task
    is not idempotent and a second call on a succeeded task is a different
    assertion from the one being made here."""
    run_id = await conn.fetchval("select workflow.start_workflow('t_offload','{}'::jsonb)")
    task_id = await conn.fetchval(
        "select id from workflow.tasks where run_id=$1 and step_key='fetch'", run_id)
    return run_id, task_id


async def main():
    conn = await asyncpg.connect(DSN)
    # THE CONNECTION THE WORKER ACTUALLY HAS, which a bare asyncpg.connect() is
    # not. Every pool this package opens installs a json/jsonb codec, and a
    # codec changes how a parameter is encoded -- so a size measured on a bare
    # connection and the same size measured in production were two different
    # numbers, and this file would have agreed with the wrong one. Same reason
    # check 6 exists: a harness whose fixture is not the production shape is
    # measuring something else.
    await _init_connection(conn)
    await conn.execute("set role app_owner")
    # The engine cap on this box may be raised; pin it so the test tests the engine.
    await conn.execute("set workflow.max_payload_bytes = '65536'")

    await conn.execute("""
        insert into workflow.definitions (name, spec) values
        ('t_offload', '{"steps":[{"key":"fetch","kind":"http_call","queue":"t"}]}')
        on conflict do nothing""")
    runs = []
    run_id, task_id = await fresh_task(conn)
    runs.append(run_id)

    # 1. A small payload is untouched.
    small = {"status": 200, "result": {"rates": {"GBP": 0.79}}}
    assert await offload(conn, str(task_id), small) == small, "a small payload was altered"
    print("small payload: unchanged")

    # 2. An oversized one becomes a ref.
    big = {"status": 200, "result": {"rows": [{"i": i, "pad": "x" * 200} for i in range(600)]}}
    n = len(json.dumps(big).encode())
    out = await offload(conn, str(task_id), big)
    print(f"oversized payload: {n} bytes -> {out}")
    assert "result" not in out, "result survived an offload"
    assert out["status"] == 200, "the envelope was dropped along with the payload"
    rid = out["$artifact"]

    # 3. It completes -- the whole point, since this used to be terminal.
    await conn.execute("select workflow.complete_task($1,$2::jsonb)", task_id, json.dumps(out))
    status = await conn.fetchval("select status from workflow.tasks where id=$1", task_id)
    # `succeeded`, not `done`. workflow.tasks' CHECK admits pending / ready /
    # running / waiting_external / succeeded / failed / cancelled, and this
    # asserted a value the constraint forbids -- so the harness could never
    # report success, whatever the code did.
    assert status == "succeeded", f"task did not complete: {status}"
    print(f"task status: {status}")

    # 4. And the ref resolves to the real object, with the real byte count.
    got = json.loads(await conn.fetchval("select workflow.artifact($1::uuid)::text", rid))
    print(f"resolved: {got}")
    assert got["bucket"] == "p8-content" and got["size_bytes"] > 60000, got

    row = await conn.fetchrow(
        "select step_key, checksum, object_key, size_bytes from workflow.v_artifacts "
        "where task_id=$1", task_id)
    print(f"v_artifacts: {dict(row)}")
    assert row["step_key"] == "fetch"

    # 5. The bytes are actually in the bucket and are byte-identical.
    from percolate_core.content import storage
    fetched = storage.get(got["bucket"], got["object_key"])
    assert fetched == json.dumps(big["result"]).encode(), "stored bytes differ from the payload"
    print(f"round trip: {len(fetched)} bytes read back identical")

    # 6. A handler that nested nothing. loop.py's own @handler example returns
    #    `{"duration": ...}` with no `result` key at all, and _bytes_of read
    #    out["result"] as though one were always there: it stored the four
    #    bytes `null` and passed the oversized payload through unchanged, so
    #    the task failed terminally with its data destroyed and the error
    #    naming the remedy that had just destroyed it.
    run_id, task_id = await fresh_task(conn)
    runs.append(run_id)
    flat = {"duration": 12.5, "frames": ["f" * 100 for _ in range(1200)]}
    out = await offload(conn, str(task_id), flat)
    print(f"unnested payload: {len(json.dumps(flat).encode())} bytes -> {out}")
    assert set(out) == {"$artifact"}, f"an unnested payload kept payload keys: {sorted(out)}"
    await conn.execute("select workflow.complete_task($1,$2::jsonb)", task_id, json.dumps(out))
    status = await conn.fetchval("select status from workflow.tasks where id=$1", task_id)
    assert status == "succeeded", f"unnested payload did not complete: {status}"
    got = json.loads(await conn.fetchval(
        "select workflow.artifact($1::uuid)::text", out["$artifact"]))
    fetched = storage.get(got["bucket"], got["object_key"])
    assert fetched == json.dumps(flat).encode(), "the whole output was not what got stored"
    print(f"unnested round trip: {len(fetched)} bytes read back identical")

    # 7. The band where the two measures disagree. jsonb carries a 4-byte
    #    JEntry per element, so an object-heavy payload is larger stored than
    #    it is as JSON text -- under the cap by this side's old arithmetic and
    #    over it by the engine's, which is a terminal failure the worker had
    #    decided was unnecessary.
    run_id, task_id = await fresh_task(conn)
    runs.append(run_id)
    band = {"status": 200,
            "result": [{"i": i, "name": f"item {i}"} for i in range(1500)]}
    as_text = len(json.dumps(band).encode())
    as_jsonb = await stored_size(conn, band)
    print(f"band payload: {as_text} bytes as JSON text, {as_jsonb} as jsonb")
    assert as_text <= 65536 < as_jsonb, (
        "this fixture no longer straddles the cap, so it asserts nothing: "
        f"text={as_text} jsonb={as_jsonb}")
    out = await offload(conn, str(task_id), band)
    assert "$artifact" in out, "a payload the engine would refuse was not offloaded"
    await conn.execute("select workflow.complete_task($1,$2::jsonb)", task_id, json.dumps(out))
    status = await conn.fetchval("select status from workflow.tasks where id=$1", task_id)
    assert status == "succeeded", f"the straddling payload did not complete: {status}"
    print("band payload: offloaded and completed")

    for r in runs:
        await conn.execute("delete from workflow.runs where id=$1", r)
    await conn.close()
    print("\nOFFLOAD OK")

asyncio.run(main())
