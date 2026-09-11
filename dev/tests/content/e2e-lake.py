#!/usr/bin/env python3
"""The lake, run end to end: stage, refine in DuckDB, write Parquet and Iceberg,
land a few rows in Postgres -- and refuse what it must refuse. Executed.

    P8_LAKE_S3=http://localhost:19100 P8_LAKE_CATALOG_URL=http://localhost:19181/catalog \\
        percolate-core/.venv/bin/python dev/tests/content/e2e-lake.py

Needs: a database with the extension installed (`dev/reload.sh scratch_lake`),
an S3-compatible store, and an Iceberg REST catalog whose warehouse writes to
that store (lake.md §7 records the Lakekeeper + MinIO pair it was run with).
It starts a real `percolate lake serve` and a fake embedding endpoint itself,
because "a workflow step runs this" is the claim, not "this function works".

What it stages: 50,000 shipments as Parquet in object storage -- the raw feed
nobody wants in Postgres. What it expects in Postgres at the end: a handful of
landed rows, some registry rows, and the WAL that cost (§5 below).
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import asyncpg
import duckdb

HOST = os.environ.get("P8_HOST", "localhost")
PORT = os.environ.get("P8_PG_PORT", "5610")
DB = os.environ.get("P8_DB", "scratch_lake")
ADMIN_DSN = os.environ.get("P8_ADMIN_DSN", f"postgres://p8:p8@{HOST}:{PORT}/{DB}")
WORKER_DSN = os.environ.get("P8_WORKER_DSN", f"postgres://worker:workerpass@{HOST}:{PORT}/{DB}")
S3 = os.environ.get("P8_LAKE_S3", "http://localhost:19100")
S3_KEY = os.environ.get("P8_LAKE_S3_KEY", "probe")
S3_SECRET = os.environ.get("P8_LAKE_S3_SECRET", "probepass123")
BUCKET = os.environ.get("P8_LAKE_BUCKET", "lake")
CATALOG = os.environ.get("P8_LAKE_CATALOG_URL", "http://localhost:19181/catalog")
WAREHOUSE = os.environ.get("P8_LAKE_WAREHOUSE", "lake")
QUEUE = "lake-test"
EMBED_PORT = 18977

ALICE = "a1a1a1a1-0000-4000-8000-00000000a11c"
BOB = "b0b0b0b0-0000-4000-8000-0000000000b0"
ORG_A = "a0000000-0000-4000-8000-00000000000a"
ORG_B = "b0000000-0000-4000-8000-00000000000b"
STAGED = 50_000
CARRIERS = ["kestrel", "bellhaven", "ravensworth", "harbour", "tamsin"]

CHECKS: list[tuple[bool, str, str]] = []


def check(ok: bool, what: str, detail: str = "") -> bool:
    CHECKS.append((bool(ok), what, detail))
    print(f"  {'ok  ' if ok else 'FAIL'}  {what}" + (f"  -- {detail}" if detail else ""), flush=True)
    return bool(ok)


# --------------------------------------------------------------------------
# A fake OpenAI-shaped embedding endpoint: hashed bag of words into 8 dims, so
# "nearest" means something and a run is reproducible.
# --------------------------------------------------------------------------

def vec(text: str) -> list[float]:
    v = [0.0] * 8
    for w in str(text).lower().split():
        h = hashlib.sha256(w.encode()).digest()
        v[h[0] % 8] += 1.0 + h[1] / 255.0
    n = sum(x * x for x in v) ** 0.5 or 1.0
    return [x / n for x in v]


CALLS = {"requests": 0, "texts": 0}


class Embed(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        texts = body["input"] if isinstance(body["input"], list) else [body["input"]]
        CALLS["requests"] += 1
        CALLS["texts"] += len(texts)
        out = {"data": [{"index": i, "embedding": vec(t)} for i, t in enumerate(texts)]}
        raw = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, *a):  # noqa: D401
        pass


# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------

def stage_raw() -> None:
    """50,000 shipments and one tenant-B secret, written straight to the store.

    Written with DuckDB rather than through the Content Server:
    this is what a connector's staged tier (sources.md §16.2) looks like, and
    the lake is the thing under test, not the upload path.
    """
    con = duckdb.connect()
    con.execute("load httpfs")
    con.execute(f"create secret s (type s3, key_id '{S3_KEY}', secret '{S3_SECRET}', "
                f"endpoint '{S3.split('://')[1]}', use_ssl false, url_style 'path')")
    con.execute(f"""
        copy (
          select i as id,
                 ['kestrel','bellhaven','ravensworth','harbour','tamsin'][1 + i % 5] as carrier,
                 -3.0 + (i % 1000) / 200.0 as lon,
                 50.0 + (i % 777) / 150.0 as lat,
                 timestamp '2026-08-01' + to_seconds(i * 60) as shipped_at,
                 case when i % 97 = 0 then 'damaged pallet crushed corner'
                      when i % 13 = 0 then 'late arrival customs hold'
                      else 'delivered on time' end as note
          from range({STAGED}) t(i)
        ) to 's3://{BUCKET}/datasets/shipments_raw/part-0.parquet' (format parquet)""")
    con.execute(f"copy (select 1 as id, 'tenant b payroll' as secret) "
                f"to 's3://{BUCKET}/datasets/b_secret/part-0.parquet' (format parquet)")


FIXTURE_SQL = f"""
set role app_owner;
insert into rbac.users(id,email) values ('{ALICE}','alice-lake@test.invalid'),('{BOB}','bob-lake@test.invalid')
  on conflict (id) do nothing;
insert into rbac.user_roles(user_id,role) values ('{ALICE}','admin'),('{BOB}','admin') on conflict do nothing;
insert into rbac.orgs(id,slug,name) values ('{ORG_A}','lake-a','Lake A'),('{ORG_B}','lake-b','Lake B')
  on conflict (id) do nothing;
insert into rbac.org_members(org_id,user_id,role) values ('{ORG_A}','{ALICE}','admin'),('{ORG_B}','{BOB}','admin')
  on conflict do nothing;

delete from content.datasets where org_id in ('{ORG_A}','{ORG_B}');
insert into content.datasets(name, org_id, owner_id, visibility, bucket, prefix, columns, row_count, file_count)
values ('shipments_raw','{ORG_A}','{ALICE}','org','{BUCKET}','datasets/shipments_raw',
        '[{{"name":"id","type":"BIGINT"}}]', {STAGED}, 1),
       ('b_secret','{ORG_B}','{BOB}','private','{BUCKET}','datasets/b_secret',
        '[{{"name":"id","type":"INTEGER"}}]', 1, 1);

insert into aiq.embedding_models(name, dim, provider, endpoint, credential_ref)
values ('lake-test-embed', 8, 'openai', 'http://localhost:{EMBED_PORT}/v1/embeddings', 'FAKE_EMBED_KEY'),
       ('lake-test-embed-b', 8, 'openai', 'http://localhost:{EMBED_PORT}/v1/embeddings', 'FAKE_EMBED_KEY')
on conflict (name) do update set endpoint = excluded.endpoint;

-- A landing function, as a package would ship one: it asks task_owner() whose
-- rows these are and upserts, so a retried step lands the same rows once.
create schema if not exists lake_test;
drop table if exists lake_test.sites;
create table lake_test.sites (
    id bigint primary key, carrier text, geom jsonb, distance real,
    owner_id uuid not null, task uuid not null);
create or replace function lake_test.land_sites(p_task uuid, p_worker text, p_rows jsonb)
returns int language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_owner uuid := workflow.task_owner(p_task, p_worker); n int;
begin
  insert into lake_test.sites(id, carrier, geom, distance, owner_id, task)
  select (r->>'id')::bigint, r->>'carrier', r->'geom', (r->>'_distance')::real, v_owner, p_task
    from jsonb_array_elements(p_rows) r
  on conflict (id) do update set carrier = excluded.carrier, geom = excluded.geom,
                                 distance = excluded.distance, task = excluded.task;
  get diagnostics n = row_count;
  return n;
end $$;
select workflow.register_step_function('land_sites', 'lake_test.land_sites',
                                       array['uuid','text','jsonb'], 30000, 'e2e-lake landing');
reset role;
"""


def refine_workflow(name: str, step_input: dict) -> str:
    return json.dumps({"name": name, "steps": [
        {"id": "refine", "work": True, "queue": QUEUE, "input": {"op": "refine", **step_input}}]})


async def start(conn, name: str, step_input: dict, run_input: dict | None = None) -> str:
    """Define and start a one-step workflow as Alice, in org A.

    The org is set by hand after the start: a run takes its owner from the
    caller's claims and its org defaults to the shared tier, and nothing yet
    starts a run in a named org (lake.md §8). Setting it here is the test
    standing in for that, and it is the one shim in this file.
    """
    async with conn.transaction():
        await conn.execute("set local role authenticated")
        await conn.execute(f"set local request.jwt.claims = '{{\"sub\":\"{ALICE}\"}}'")
        await conn.execute("select workflow.define_yaml($1)", refine_workflow(name, step_input))
        run = await conn.fetchval("select workflow.start_workflow($1, $2::jsonb)::text",
                                  name, json.dumps(run_input or {}))
    await conn.execute("update workflow.runs set org_id = $1 where id = $2::uuid", ORG_A, run)
    return run


async def wait(conn, run: str, seconds: int = 180) -> tuple[str, dict]:
    deadline = time.time() + seconds
    while time.time() < deadline:
        # Terminal by the vocabulary, not by a list written here (REM-52).
        status, done = await conn.fetchrow(
            "select status, workflow.is_terminal(status) from workflow.runs where id = $1::uuid", run)
        if done:
            row = await conn.fetchrow(
                "select output::text, error from workflow.tasks where run_id = $1::uuid "
                "order by created_at desc limit 1", run)
            out = json.loads(row["output"]) if row and row["output"] else {}
            if row and row["error"]:
                out["_error"] = row["error"]
            return status, out
        await asyncio.sleep(0.5)
    return "timeout", {}


async def wal(conn) -> int:
    return int(await conn.fetchval("select pg_current_wal_lsn() - '0/0'::pg_lsn"))


# --------------------------------------------------------------------------

async def main() -> int:
    server = HTTPServer(("localhost", EMBED_PORT), Embed)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    print("=== fixtures: 50,000 staged shipments in object storage, two tenants", flush=True)
    stage_raw()
    conn = await asyncpg.connect(ADMIN_DSN)
    await conn.execute(FIXTURE_SQL)

    logdir = pathlib.Path(tempfile.mkdtemp(prefix="p8-lake-"))
    env = {**os.environ, "P8_DSN": WORKER_DSN, "P8_S3_ENDPOINT": S3, "P8_S3_KEY": S3_KEY,
           "P8_S3_SECRET": S3_SECRET, "P8_LAKE_BUCKET": BUCKET, "P8_BUCKET": BUCKET,
           "P8_LAKE_CATALOG_URL": CATALOG, "P8_LAKE_WAREHOUSE": WAREHOUSE,
           "FAKE_EMBED_KEY": "unused", "P8_WORKER_ID": "lake-e2e"}
    exe = pathlib.Path(sys.executable).parent / "percolate"
    log = (logdir / "lake-worker.log").open("w")
    worker = subprocess.Popen([str(exe), "lake", "serve", "--queue", QUEUE],
                              env=env, stdout=log, stderr=log)
    print(f"  started lake worker (log {log.name})", flush=True)

    try:
        wal_before = await wal(conn)

        # ------------------------------------------------------------------
        print("\n=== 1. refine Parquet -> Parquet: filter, join the small side, geocode, embed", flush=True)
        run = await start(conn, "lake_e2e_parquet", {
            "inputs": {"raw": {"dataset": "shipments_raw"},
                       "watch": {"rows": "{{run.watch}}"}},
            "sql": ("select r.id, r.carrier, ST_Point(r.lon, r.lat) as geom, r.note, r.shipped_at "
                    "from raw r join watch w using (carrier) "
                    "where r.shipped_at >= $since::timestamp and r.note <> 'delivered on time'"),
            "params": {"since": "{{run.since}}"},
            "embed": {"column": "note", "into": "note_emb", "model": "lake-test-embed",
                      "max_rows": 20000},
            "output": {"dataset": "watched", "format": "parquet", "mode": "replace",
                       "visibility": "org", "geometry": {"geom": {"crs": "OGC:CRS84"}}}},
            {"watch": [{"carrier": "kestrel"}, {"carrier": "bellhaven"}],
             "since": "2026-08-10 00:00:00"})
        status, out = await wait(conn, run)
        res = out.get("result") or {}
        check(status == "succeeded", "the parquet refine step completed", out.get("_error", ""))

        truth = duckdb.connect()
        truth.execute("load httpfs")
        truth.execute(f"create secret s (type s3, key_id '{S3_KEY}', secret '{S3_SECRET}', "
                      f"endpoint '{S3.split('://')[1]}', use_ssl false, url_style 'path')")
        expected = truth.execute(f"""
            select count(*) from 's3://{BUCKET}/datasets/shipments_raw/*.parquet'
            where carrier in ('kestrel','bellhaven') and shipped_at >= timestamp '2026-08-10'
              and note <> 'delivered on time'""").fetchone()[0]
        check(res.get("rows") == expected,
              "the result has exactly the rows an independent DuckDB count finds",
              f"{res.get('rows')} vs {expected}")
        ds = await conn.fetchrow("select * from content.datasets where org_id = $1 and name = 'watched'", ORG_A)
        check(ds is not None and ds["row_count"] == expected, "registered in content.datasets with its row count")
        if ds:
            geo = json.loads(ds["geometry"])
            emb = json.loads(ds["embeddings"])
            check(geo.get("geom", {}).get("crs") == "OGC:CRS84" and geo["geom"]["encoding"] == "native",
                  "geometry registered with the CRS the step declared", json.dumps(geo))
            typ = truth.execute(f"select typeof(geom) from read_parquet('s3://{BUCKET}/{ds['prefix']}/*.parquet') limit 1").fetchone()[0]
            check(typ == "GEOMETRY('OGC:CRS84')", "and the Parquet file carries that CRS on the column", typ)
            check(emb.get("note_emb") == {"model": "lake-test-embed", "dims": 8},
                  "the embedding column registered in its model's space", json.dumps(emb))
            check(ds["prefix"].startswith(f"lake/{ORG_A}/watched/v-"),
                  "a replace wrote a fresh prefix under the org's own", ds["prefix"])
        check(CALLS["texts"] == expected and CALLS["requests"] >= 1,
              "every non-null note embedded, in batches", f"{CALLS['texts']} texts in {CALLS['requests']} requests")

        # ------------------------------------------------------------------
        print("\n=== 2. refine Parquet -> Iceberg, merge on id, twice", flush=True)
        merge_input = {
            "inputs": {"w": {"dataset": "watched"}},
            "sql": "select id, upper(carrier) as carrier, geom, note, note_emb from w where id % $m = 0",
            "params": {"m": 1},
            "output": {"dataset": "watched_ice", "format": "iceberg", "mode": "merge",
                       "key": ["id"], "visibility": "org"}}
        run = await start(conn, "lake_e2e_iceberg", merge_input)
        status, out = await wait(conn, run)
        check(status == "succeeded", "the iceberg merge step completed", out.get("_error", ""))
        ds = await conn.fetchrow("select * from content.datasets where org_id = $1 and name = 'watched_ice'", ORG_A)
        ns = "o_" + ORG_A.replace("-", "")
        check(ds is not None and ds["table_ref"] == f"{ns}.watched_ice" and ds["format"] == "iceberg",
              "registered as an iceberg dataset in the org's namespace", ds and ds["table_ref"])
        first = ds["row_count"] if ds else None
        if ds:
            check(json.loads(ds["geometry"]).get("geom", {}).get("encoding") == "wkb",
                  "geometry recorded as WKB, the only form the catalog accepted")
            check(json.loads(ds["embeddings"]).get("note_emb", {}).get("model") == "lake-test-embed",
                  "the embedding column's model carried forward from the input")
        run = await start(conn, "lake_e2e_iceberg", merge_input)
        status, out = await wait(conn, run)
        ds = await conn.fetchrow("select row_count from content.datasets where org_id = $1 and name = 'watched_ice'", ORG_A)
        check(status == "succeeded" and ds and ds["row_count"] == first == expected,
              "a second merge of the same rows leaves the count unchanged", f"{first} -> {ds and ds['row_count']}")

        # ------------------------------------------------------------------
        print("\n=== 3. read Iceberg back, nearest-neighbour, land five rows in Postgres", flush=True)
        run = await start(conn, "lake_e2e_land", {
            "inputs": {"near": {"nearest": {"dataset": "watched_ice", "column": "note_emb",
                                            "vector": vec("damaged pallet"),
                                            "model": "lake-test-embed", "k": 5}}},
            "sql": "select id, carrier, geom, _distance from near where ST_Y(geom) > 49",
            "land": {"function": "land_sites", "max_rows": 100}})
        status, out = await wait(conn, run)
        res = out.get("result") or {}
        check(status == "succeeded" and (res.get("landed") or {}).get("rows") == 5,
              "five nearest rows landed through the allow-listed function", out.get("_error", ""))
        rows = await conn.fetch("select * from lake_test.sites order by distance")
        check(len(rows) == 5 and all(str(r["owner_id"]) == ALICE for r in rows),
              "the landing function attributed every row to the run owner")
        check(len(rows) == 5 and all(json.loads(r["geom"]).get("type") == "Point" for r in rows),
              "geometry crossed into Postgres as GeoJSON")
        notes = truth.execute(f"""
            select count(*) from 's3://{BUCKET}/datasets/shipments_raw/*.parquet'
            where id in ({','.join(str(r['id']) for r in rows) or '0'}) and note like 'damaged%'""").fetchone()[0]
        check(len(rows) == 5 and notes == 5, "every nearest row really is a damaged-pallet note", f"{notes}/5")

        wal_lake = await wal(conn) - wal_before

        # ------------------------------------------------------------------
        print("\n=== 4. what it refuses, and that a refusal writes nothing", flush=True)
        before = await conn.fetchval("select count(*) from lake_test.sites")
        cases = [
            ("a write smuggled in as authored SQL", {
                "inputs": {"raw": {"dataset": "shipments_raw"}},
                "sql": "copy (select * from raw) to 's3://elsewhere/x.parquet'",
                "land": {"function": "land_sites", "max_rows": 10}}, "exactly one SELECT"),
            ("a second statement after a SELECT", {
                "inputs": {"raw": {"dataset": "shipments_raw"}},
                "sql": "select 1; create secret s2 (type s3, key_id 'x', secret 'y')",
                "land": {"function": "land_sites", "max_rows": 10}}, "exactly one SELECT"),
            ("another tenant's dataset, by name", {
                "inputs": {"b": {"dataset": "b_secret"}},
                "sql": "select * from b", "land": {"function": "land_sites", "max_rows": 10}},
             "may not read it"),
            ("more rows than land.max_rows", {
                "inputs": {"raw": {"dataset": "shipments_raw"}},
                "sql": "select id, carrier from raw",
                "output": {"dataset": "never_written", "format": "parquet", "mode": "replace"},
                "land": {"function": "land_sites", "max_rows": 10}}, "land.max_rows is 10"),
            ("a query vector from another model", {
                "inputs": {"near": {"nearest": {"dataset": "watched_ice", "column": "note_emb",
                                                "vector": vec("damaged"), "model": "lake-test-embed-b"}}},
                "sql": "select id from near", "land": {"function": "land_sites", "max_rows": 10}},
             "embed the query with the column's model"),
            ("a template spliced into the SQL", {
                "inputs": {"raw": {"dataset": "shipments_raw"}},
                "sql": "select id from raw where carrier = '{{run.c}}'",
                "land": {"function": "land_sites", "max_rows": 10}}, "{{template}}"),
            ("geometry with no CRS on its type and none declared", {
                "inputs": {"raw": {"dataset": "shipments_raw"}},
                "sql": "select id, ST_Point(lon * 100000, lat * 100000) as geom from raw limit 3",
                "output": {"dataset": "never_written", "format": "parquet", "mode": "replace"}},
             "Declare it"),
            ("a declared CRS that contradicts the type", {
                "inputs": {"raw": {"dataset": "shipments_raw"}},
                "sql": "select id, ST_Point(lon, lat)::GEOMETRY('OGC:CRS84') as geom from raw limit 3",
                "output": {"dataset": "never_written", "format": "parquet", "mode": "replace",
                           "geometry": {"geom": {"crs": "EPSG:27700"}}}},
             "declares crs"),
            ("a landing function that is not registered", {
                "inputs": {"raw": {"dataset": "shipments_raw"}},
                "sql": "select id from raw limit 1",
                "land": {"function": "lake_test.land_sites", "max_rows": 10}}, "no step function named"),
        ]
        for i, (what, spec, needle) in enumerate(cases):
            run = await start(conn, f"lake_e2e_refuse_{i}", spec, {"c": "kestrel"})
            status, out = await wait(conn, run)
            err = out.get("_error", "")
            check(status == "failed" and needle in err, f"refused: {what}", err[:140])
        attempts = await conn.fetchval("""
            select max(t.attempts) from workflow.tasks t join workflow.runs r on r.id = t.run_id
             join workflow.definitions d on d.id = r.workflow_def_id where d.name like 'lake_e2e_refuse_%'""")
        check(attempts == 1, "every refusal was terminal: one attempt, not five", f"max attempts {attempts}")
        check(await conn.fetchval("select count(*) from lake_test.sites") == before,
              "no refused step landed a row")
        check(await conn.fetchval("select count(*) from content.datasets where name = 'never_written'") == 0,
              "the over-limit step registered no output")
        leaked = truth.execute(f"select count(*) from glob('s3://{BUCKET}/lake/{ORG_A}/never_written/**')").fetchone()[0]
        check(leaked == 0, "and wrote no object for it either", f"{leaked} objects")

        # ------------------------------------------------------------------
        print("\n=== 5. the registry refuses a location outside the writer's org", flush=True)
        run = await start(conn, "lake_e2e_sql", {"sql": "select 1", "land": {"function": "land_sites", "max_rows": 1}})
        # Nobody serves this queue: the task is claimed here, by hand, as a worker.
        await conn.execute("update workflow.tasks set queue = 'lake-sql-check' where run_id = $1::uuid", run)
        w = await asyncpg.connect(WORKER_DSN)
        try:
            async with w.transaction():
                await w.execute("set local role worker")
                task = await w.fetchval("select (workflow.claim_task('lake-sql-check', 'sql-check')).id::text")
            bad = [
                ("a parquet prefix in another org", {"name": "x", "format": "parquet", "bucket": BUCKET,
                                                      "prefix": f"lake/{ORG_B}/x"}),
                ("a dot segment climbing out of the org", {"name": "x", "format": "parquet", "bucket": BUCKET,
                                                           "prefix": f"lake/{ORG_A}/x/../../{ORG_B}/x"}),
                ("an iceberg table in another org's namespace", {"name": "x", "format": "iceberg", "bucket": BUCKET,
                                                                 "prefix": "iceberg/x",
                                                                 "table_ref": "o_" + ORG_B.replace('-', '') + ".x"}),
                ("an embedding column claiming the wrong width", {"name": "x", "format": "parquet", "bucket": BUCKET,
                                                                  "prefix": f"lake/{ORG_A}/x",
                                                                  "embeddings": {"e": {"model": "lake-test-embed", "dims": 1536}}}),
                ("merge on parquet", {"name": "x", "format": "parquet", "mode": "merge", "bucket": BUCKET,
                                      "prefix": f"lake/{ORG_A}/x"}),
            ]
            for what, payload in bad:
                try:
                    async with w.transaction():
                        await w.execute("set local role worker")
                        await w.fetchval("select content.register_lake_output($1::uuid, 'sql-check', $2::jsonb)",
                                         task, json.dumps(payload))
                    check(False, f"refused: {what}", "it was accepted")
                except asyncpg.PostgresError as e:
                    check(True, f"refused: {what}", str(e).splitlines()[0][:110])
            try:
                async with w.transaction():
                    await w.execute("set local role worker")
                    await w.fetchval("select content.lake_resolve($1::uuid, 'someone-else', array['shipments_raw'])", task)
                check(False, "refused: resolving under a task another worker holds")
            except asyncpg.PostgresError as e:
                check(True, "refused: resolving under a task another worker holds", str(e).splitlines()[0][:80])
        finally:
            await w.close()

        # ------------------------------------------------------------------
        print("\n=== 5b. a retry, and a worker with no object storage -- the op, in-process", flush=True)
        # A work step is retried when a worker dies mid-step, so the same task
        # runs the op twice. Forced here by calling it twice under one claim.
        os.environ.update({k: v for k, v in env.items() if k.startswith(("P8_", "FAKE_"))})
        from percolate_core.core import close_pool, open_pool
        from percolate_core.lake.refine import refine
        from percolate_core.worker.templates import TerminalError as Terminal
        pool = await open_pool(WORKER_DSN)   # the worker's own pool, and its jsonb codec

        async def claimed(queue: str) -> str:
            run = await start(conn, f"lake_e2e_{queue.replace('-', '_')}",
                              {"sql": "select 1", "land": {"function": "land_sites", "max_rows": 1}})
            await conn.execute("update workflow.tasks set queue = $1 where run_id = $2::uuid", queue, run)
            async with pool.acquire() as c, c.transaction():
                await c.execute("set local role worker")
                return await c.fetchval(f"select (workflow.claim_task('{queue}', 'inproc')).id::text")

        task = await claimed("lake-retry")
        append = {"op": "refine", "inputs": {"raw": {"dataset": "shipments_raw"}},
                  "sql": "select id, carrier from raw where id < 100",
                  "output": {"dataset": "appended", "format": "iceberg", "mode": "append"}}
        ctx = {"_task_id": task, "_worker_id": "inproc", "task_input": append}
        first = (await refine(append, ctx))["result"]["output"]["row_count"]
        second = (await refine(append, ctx))["result"]["output"]["row_count"]
        # first == second, not == 100: the catalog outlives a database reload,
        # so a rerun appends onto the last run's table (lake.md §8).
        check(first == second and first >= 100,
              "an Iceberg append retried under one task lands its rows once", f"{first} then {second}")

        task = await claimed("lake-noobj")
        for k in ("P8_S3_KEY", "P8_S3_SECRET"):
            os.environ.pop(k, None)
        inline = {"op": "refine", "inputs": {"r": {"rows": [{"id": 900001, "carrier": "inline"}]}},
                  "sql": "select id, carrier, ST_Point(0, 51.5) as geom from r",
                  "land": {"function": "land_sites", "max_rows": 5}}
        got = (await refine(inline, {"_task_id": task, "_worker_id": "inproc", "task_input": inline}))["result"]
        check((got.get("landed") or {}).get("rows") == 1,
              "with no object storage, inline rows still refine and land", json.dumps(got.get("landed")))
        try:
            await refine({**inline, "output": {"dataset": "nowhere"}},
                         {"_task_id": task, "_worker_id": "inproc", "task_input": inline})
            check(False, "with no object storage, a dataset output is refused")
        except Terminal as e:
            check("no object storage" in str(e), "with no object storage, a dataset output is refused by name",
                  str(e)[:90])
        os.environ.update({"P8_S3_KEY": S3_KEY, "P8_S3_SECRET": S3_SECRET})
        await close_pool()

        # ------------------------------------------------------------------
        print("\n=== 7. p8ql LAKE as a workflow step, and a successor reading its rows", flush=True)
        yaml = json.dumps({"name": "lake_e2e_p8ql", "steps": [
            {"id": "totals",
             "p8ql": ("LAKE FROM watched, watched_ice "
                      "select w.carrier, count(*) as n, "
                      "round(avg(ST_Y(i.geom)), 3) as mean_lat "
                      "from watched w join watched_ice i using (id) "
                      "where w.note like 'damaged%' group by 1 order by 1")},
            {"id": "echo", "needs": ["totals"],
             "sql": "select jsonb_array_length({{steps.totals.result.rows}}::jsonb) as carriers"}]})
        async with conn.transaction():
            await conn.execute("set local role authenticated")
            await conn.execute(f"set local request.jwt.claims = '{{\"sub\":\"{ALICE}\"}}'")
            await conn.execute("select workflow.define_yaml($1)", yaml)
            run = await conn.fetchval("select workflow.start_workflow('lake_e2e_p8ql', '{}')::text")
        await conn.execute("update workflow.runs set org_id = $1 where id = $2::uuid", ORG_A, run)
        spec = json.loads(await conn.fetchval(
            "select spec::text from workflow.definitions where name = 'lake_e2e_p8ql' "
            "order by version desc limit 1"))
        step = next(s for s in spec["steps"] if s["key"] == "totals")
        check(step["kind"] == "work" and step["queue"] == "lake" and step["input"]["op"] == "query",
              "the p8ql LAKE step is stored as lake work", json.dumps(step)[:120])
        # The stored step names queue `lake`; this test's worker serves its own.
        await conn.execute("update workflow.tasks set queue = $1 where run_id = $2::uuid and step_key = 'totals'",
                           QUEUE, run)
        deadline = time.time() + 120
        while time.time() < deadline:
            # Including cancelled, which this loop used to wait out in full.
            if await conn.fetchval(
                    "select workflow.is_terminal(status) from workflow.runs where id = $1::uuid", run):
                break
            await asyncio.sleep(0.5)
        rows = await conn.fetch("select step_key, status, output::text, error::text from workflow.tasks "
                                "where run_id = $1::uuid order by created_at", run)
        by = {r["step_key"]: r for r in rows}
        got = json.loads(by["totals"]["output"] or "{}").get("result") or {}
        want = truth.execute(f"""
            select carrier, count(*) from 's3://{BUCKET}/datasets/shipments_raw/*.parquet'
            where carrier in ('kestrel','bellhaven') and shipped_at >= timestamp '2026-08-10'
              and note like 'damaged%' group by 1 order by 1""").fetchall()
        check(by["totals"]["status"] == "succeeded"
              and [(r["carrier"].lower(), r["n"]) for r in got.get("rows", [])] == [(c, n) for c, n in want],
              "the LAKE step joined Parquet to Iceberg and counted what DuckDB counts directly",
              json.dumps(got.get("rows"))[:160] + f" vs {want}" + (by["totals"]["error"] or ""))
        check(all(isinstance(r.get("mean_lat"), float) and 50 < r["mean_lat"] < 56 for r in got.get("rows", [])) and got.get("rows"),
              "geometry read back from Iceberg WKB answered ST_Y in the lake")
        echo = json.loads(by.get("echo", {}).get("output") or "{}") if "echo" in by else {}
        check(by.get("echo") is not None and by["echo"]["status"] == "succeeded"
              and (echo.get("result") or [{}])[0].get("carriers") == len(want),
              "a successor step read {{steps.totals.result.rows}}", json.dumps(echo)[:120])

        # Bob asks for Alice's dataset by name, in a run of his own.
        async with conn.transaction():
            await conn.execute("set local role authenticated")
            await conn.execute(f"set local request.jwt.claims = '{{\"sub\":\"{BOB}\"}}'")
            await conn.execute("select workflow.define_yaml($1)", json.dumps({
                "name": "lake_e2e_p8ql_bob", "steps": [
                    {"id": "peek", "p8ql": "LAKE FROM watched select count(*) from watched"}]}))
            run = await conn.fetchval("select workflow.start_workflow('lake_e2e_p8ql_bob', '{}')::text")
        await conn.execute("update workflow.runs set org_id = $1 where id = $2::uuid", ORG_B, run)
        await conn.execute("update workflow.tasks set queue = $1 where run_id = $2::uuid", QUEUE, run)
        status, out = await wait(conn, run)
        check(status == "failed" and "may not read it" in out.get("_error", ""),
              "another tenant's LAKE step is refused at resolution", out.get("_error", "")[:100])

        # ------------------------------------------------------------------
        print("\n=== 6. what it cost Postgres, against the same records as rows", flush=True)
        await conn.execute("drop table if exists lake_test.as_rows")
        await conn.execute("create table lake_test.as_rows (source_id uuid, external_id text, "
                           "watermark text, raw jsonb, data jsonb, created_at timestamptz default now(), "
                           "updated_at timestamptz default now(), primary key (source_id, external_id))")
        records = truth.execute(f"select to_json(r)::varchar from 's3://{BUCKET}/datasets/shipments_raw/*.parquet' r").fetchall()
        w0 = await wal(conn)
        src = "11111111-2222-4333-8444-555555555555"
        for i in range(0, len(records), 10_000):
            page = [json.loads(r[0]) for r in records[i:i + 10_000]]
            await conn.execute("""
                insert into lake_test.as_rows(source_id, external_id, watermark, raw, data)
                select $1::uuid, r->>'id', r->>'shipped_at', r, r from jsonb_array_elements($2::jsonb) r""",
                               src, json.dumps(page))
        wal_rows = await wal(conn) - w0
        size_rows = await conn.fetchval("select pg_total_relation_size('lake_test.as_rows')")
        print(f"  staged in object storage:   {STAGED:,} records", flush=True)
        print(f"  WAL, the three lake runs:   {wal_lake / 1e6:8.2f} MB  (registry rows, 5 landed rows, run bookkeeping)", flush=True)
        print(f"  WAL, the same records as    {wal_rows / 1e6:8.2f} MB  (content.source_records' shape, jsonb raw+data)", flush=True)
        print(f"  table size, as rows:        {size_rows / 1e6:8.2f} MB", flush=True)
        check(wal_lake < wal_rows, "the lake path wrote less WAL than landing the feed as rows",
              f"{wal_lake / 1e6:.2f} MB vs {wal_rows / 1e6:.2f} MB")
        await conn.execute("drop table lake_test.as_rows")
    finally:
        worker.terminate()
        worker.wait(10)
        server.shutdown()
        await conn.close()

    failed = [c for c in CHECKS if not c[0]]
    print(f"\n{len(CHECKS) - len(failed)}/{len(CHECKS)} checks passed; worker log {logdir}", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
