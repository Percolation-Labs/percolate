"""End to end: an oversized step output becomes a registered artifact.

Output class 4, asserted rather than described. Run against the p8-subsystems
compose stack (`cd p8-subsystems/dev && docker compose up -d`), which brings up
PG19 on :5499 and MinIO on :9000:

    uv run --with asyncpg --with boto3 python dev/offload.py

Five checks, each one a sentence the specs make: a small payload is untouched;
an oversized one becomes a "$artifact" ref with no "result"; the task COMPLETES
where it used to fail terminally; the ref resolves to a real object; and the
bytes read back byte-identical to what the step produced.
"""
import asyncio, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ.setdefault("P8_S3_ENDPOINT", "http://localhost:9000")
os.environ.setdefault("P8_S3_KEY", "p8admin")
os.environ.setdefault("P8_S3_SECRET", "p8password")
os.environ.setdefault("P8_BUCKET", "p8-content")

import asyncpg
from percolate_core.worker.artifacts import offload
from percolate_core.worker.templates import TerminalError


async def main():
    conn = await asyncpg.connect("postgres://p8:p8@localhost:5499/p8experiment")
    await conn.execute("set role app_owner")
    # The engine cap on this box is raised; pin it so the test tests the engine.
    await conn.execute("set workflow.max_payload_bytes = '65536'")

    await conn.execute("""
        insert into workflow.definitions (name, spec) values
        ('t_offload', '{"steps":[{"key":"fetch","kind":"http_call","queue":"t"}]}')
        on conflict do nothing""")
    run_id = await conn.fetchval("select workflow.start_workflow('t_offload','{}'::jsonb)")
    task_id = await conn.fetchval(
        "select id from workflow.tasks where run_id=$1 and step_key='fetch'", run_id)

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
    assert status == "done", f"task did not complete: {status}"
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

    await conn.execute("delete from workflow.runs where id=$1", run_id)
    await conn.close()
    print("\nOFFLOAD OK")

asyncio.run(main())
