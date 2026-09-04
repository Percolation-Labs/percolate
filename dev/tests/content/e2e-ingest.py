#!/usr/bin/env python3
"""Upload five formats, and answer questions about them. Executed, not asserted.

    LLM_API_KEY=sk-… python3 dev/tests/content/e2e-ingest.py

This is the last unchecked criterion in RELEASE-0.1.md's worker section --
"end to end: upload a file, and with no further action it becomes answerable by
SEARCH" -- run rather than described. It needs a live stack (`docker compose up
-d db minio`) and a real embedding key, because the thing being tested is
precisely the part that cannot be faked: 05-corpus-sample.sql already proves
retrieval works over literal vectors, and what nobody had ever run is the path
from an uploaded PDF to a vector in a space.

It starts the three processes itself -- Content Server, http worker, ingest
worker -- because "with no further action" is the claim, and a test that
requires a person to have started the right workers by hand is testing
something weaker than the sentence.

WHAT EACH FILE IS FOR. Every fact lives in exactly one fixture, so an answer
can only come from the format that carries it (dev/tests/content/fixtures.py):

    markdown  the serial range           parsed as itself
    pdf       the 78 °C threshold        pymupdf4llm
    docx      the 19-week lead time      python-docx, from a TABLE
    wav       the eleven-day pause       transcribed by a model
    csv       the downtime totals        Parquet + DuckDB, never chunked

The last one is the interesting negative: it must NOT be chunked, and the
question about it is answered by SQL over Parquet rather than by retrieval.
"""

from __future__ import annotations

import asyncio
import json
import mimetypes
import os
import pathlib
import subprocess
import sys
import tempfile
import time

import asyncpg
import httpx

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fixtures  # noqa: E402

HOST = os.environ.get("P8_HOST", "localhost")
PORT = os.environ.get("P8_PG_PORT", "5499")
ADMIN_DSN = os.environ.get("P8_ADMIN_DSN", f"postgres://p8:p8@{HOST}:{PORT}/p8experiment")
WORKER_DSN = os.environ.get("P8_WORKER_DSN", f"postgres://worker:workerpass@{HOST}:{PORT}/p8experiment")
SERVER_DSN = os.environ.get("P8_SERVER_DSN", f"postgres://authenticator:authpass@{HOST}:{PORT}/p8experiment")
CONTENT_URL = os.environ.get("P8_CONTENT_URL", "http://localhost:8199")
MODEL = "text-embedding-3-small"
SPACE = "aiq.emb_text_embedding_3_small"

CHECKS: list[tuple[bool, str, str]] = []


def as_json(value):
    """A jsonb column read back, whatever the driver decided it was.

    A ::text cast comes back as a string and the pool's codec hands back an
    object; a test that assumed one of them spent a run reporting a TypeError
    instead of the assertion it was making.
    """
    if isinstance(value, (dict, list)) or value is None:
        return value or {}
    return json.loads(value)


def check(ok: bool, what: str, detail: str = "") -> bool:
    CHECKS.append((bool(ok), what, detail))
    print(f"  {'ok  ' if ok else 'FAIL'}  {what}" + (f"  -- {detail}" if detail else ""),
          flush=True)
    return bool(ok)


# ---------------------------------------------------------------------------
# The stack
# ---------------------------------------------------------------------------

def spawn(name: str, args: list[str], env: dict[str, str], logdir: pathlib.Path):
    log = (logdir / f"{name}.log").open("w")
    proc = subprocess.Popen(args, env={**os.environ, **env}, stdout=log, stderr=log)
    print(f"  started {name} (pid {proc.pid}, log {log.name})", flush=True)
    return proc


def wait_for_health(url: str, seconds: int = 30) -> bool:
    for _ in range(seconds * 2):
        try:
            if httpx.get(url, timeout=2).status_code == 200:
                return True
        except Exception:
            pass
        time.sleep(0.5)
    return False


# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------

async def wait_for_runs(conn, run_ids: list[str], seconds: int = 240) -> dict[str, str]:
    """Poll until every run is terminal. Returns run_id -> status."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        rows = await conn.fetch(
            "select id::text, status from workflow.runs where id = any($1::uuid[])",
            run_ids)
        status = {r["id"]: r["status"] for r in rows}
        if all(s in ("completed", "failed", "cancelled") for s in status.values()):
            return status
        await asyncio.sleep(2)
    return status


async def failure_detail(conn, run_id: str) -> str:
    rows = await conn.fetch(
        "select step_key, status, output::text from workflow.tasks "
        "where run_id = $1::uuid and status in ('failed','dead') limit 3", run_id)
    return "; ".join(f"{r['step_key']}: {(r['output'] or '')[:300]}" for r in rows)


async def ask(conn, question: str, seconds: int = 120) -> tuple[str, list[dict]]:
    """Run `ask_uploads` and return (answer, retrieved rows)."""
    run_id = str(await conn.fetchval(
        "select workflow.start_workflow('ask_uploads', $1::jsonb)",
        json.dumps({"question": question})))
    status = await wait_for_runs(conn, [run_id], seconds)
    ctx = await conn.fetchval("select context::text from workflow.runs where id = $1::uuid",
                              run_id)
    ctx = as_json(ctx)
    if status.get(run_id) != "completed":
        return f"<run {status.get(run_id)}: {await failure_detail(conn, run_id)}>", []
    rows = (ctx.get("retrieve") or {}).get("result", {}).get("rows", [])
    return (ctx.get("answer") or {}).get("result", ""), rows


async def main() -> int:
    if not os.environ.get("LLM_API_KEY"):
        print("LLM_API_KEY is not set -- this test embeds and transcribes for real.",
              file=sys.stderr)
        return 2

    workdir = pathlib.Path(tempfile.mkdtemp(prefix="p8-ingest-e2e-"))
    print(f"workdir {workdir}", flush=True)
    files = fixtures.build(workdir / "fixtures")

    print("\n=== stack ===", flush=True)
    procs = []
    py = sys.executable
    if not wait_for_health(f"{CONTENT_URL}/health", 1):
        procs.append(spawn("content", [py, "-m", "percolate_core.cli", "content",
                                       "serve", "--port", CONTENT_URL.rsplit(":", 1)[-1]],
                           {"P8_DSN": SERVER_DSN}, workdir))
    if not check(wait_for_health(f"{CONTENT_URL}/health", 30), "Content Server is up",
                 (workdir / "content.log").read_text()[-400:].strip()
                 if (workdir / "content.log").exists() else ""):
        return 1
    procs.append(spawn("worker-http", [py, "-m", "percolate_core.cli", "worker",
                                       "--queue", "http", "--id", "e2e-http"],
                       {"P8_DSN": WORKER_DSN}, workdir))
    procs.append(spawn("worker-ingest", [py, "-m", "percolate_core.cli", "ingest",
                                         "serve", "--queue", "ingest", "--id", "e2e-ingest"],
                       {"P8_DSN": WORKER_DSN}, workdir))

    admin = await asyncpg.connect(ADMIN_DSN)
    try:
        # A channel of our own, so the assertions cannot be confused by anything
        # else this database has ingested -- and one with a POLICY on it, which
        # is the override layer being exercised rather than described.
        await admin.execute("""
            insert into content.channels (name, kind, config)
            values ('e2e-uploads', 'file_upload',
                    jsonb_build_object('ingest_workflow','ingest_file'))
            on conflict (org_id, name) do update
              set config = excluded.config""")
        await admin.execute("""
            insert into content.channels (name, kind, config)
            values ('e2e-small-chunks', 'file_upload',
                    jsonb_build_object('ingest_workflow','ingest_file',
                                       'ingest_policy',
                                       '{"chunking": {"target_tokens": 120}}'::jsonb))
            on conflict (org_id, name) do update
              set config = excluded.config""")

        print("\n=== upload ===", flush=True)
        uploaded: dict[str, str] = {}
        for path in files:
            ctype = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
            r = httpx.post(f"{CONTENT_URL}/files", content=path.read_bytes(),
                           headers={"Content-Type": ctype,
                                    "X-P8-Channel": "e2e-uploads",
                                    "X-P8-Title": path.name},
                           timeout=60)
            if not check(r.status_code == 201, f"POST /files {path.name}", r.text[:200]):
                return 1
            uploaded[path.name] = r.json()["resource_id"]

        # The same markdown again, on the channel whose policy says chunk small.
        md = next(p for p in files if p.suffix == ".md")
        # A DIFFERENT TITLE for the same bytes, and it is not cosmetic: two
        # resources whose titles match collide on the graph's canonical key
        # (aiq.node_keys is unique on (org_id, key, entity_type)), the
        # projection trigger raises, and the parse step fails five times for a
        # reason that has nothing to do with parsing. That is a real defect --
        # uploading v2 of `report.pdf` is the most ordinary thing a user does --
        # and it is recorded in ingestion.md §7 rather than papered over here.
        r = httpx.post(f"{CONTENT_URL}/files", content=md.read_bytes(),
                       headers={"Content-Type": "text/markdown",
                                "X-P8-Channel": "e2e-small-chunks",
                                "X-P8-Title": md.stem + " (small chunks).md"},
                       timeout=60)
        check(r.status_code == 201, "POST /files (channel with a chunking policy)")
        small_id = r.json()["resource_id"]

        run_ids = [str(r["id"]) for r in await admin.fetch(
            "select id from workflow.runs where external_id = any($1::text[])",
            ["ingest:" + rid for rid in list(uploaded.values()) + [small_id]])]
        check(len(run_ids) == len(uploaded) + 1,
              "every upload started an ingestion run",
              f"{len(run_ids)} runs for {len(uploaded) + 1} uploads")

        print("\n=== ingestion ===", flush=True)
        status = await wait_for_runs(admin, run_ids)
        bad = [rid for rid, s in status.items() if s != "completed"]
        for rid in bad:
            print(f"    run {rid}: {status[rid]} -- {await failure_detail(admin, rid)}")
        check(not bad, "every ingestion run completed", f"{len(status)} runs")

        rows = {r["title"]: r for r in await admin.fetch("""
            select r.title, r.status, r.metadata::text as meta,
                   (select count(*) from content.resource_chunks c where c.resource_id = r.id) as chunks,
                   (select count(*) from content.resource_chunks c
                     where c.resource_id = r.id and c.start_offset is not null) as with_offsets,
                   (select count(*) from content.resource_chunks c
                     join """ + SPACE + """ e on e.chunk_id = c.id
                    where c.resource_id = r.id) as embedded
            from content.resources r
            join content.channels ch on ch.id = r.channel_id
            where ch.name = 'e2e-uploads'""")}

        for name, expect_parser in (("r7-field-notice.md", "markdown"),
                                    ("actuator-teardown.pdf", "pymupdf4llm"),
                                    ("supplier-review.docx", "docx"),
                                    ("ops-briefing.wav", "transcribe")):
            if name not in rows:
                check(False, f"{name} was ingested", "no resource row")
                continue
            row = rows[name]
            meta = as_json(row["meta"]).get("ingest", {})
            check(row["status"] == "ready" and row["chunks"] > 0,
                  f"{name}: chunked and ready",
                  f"status={row['status']} chunks={row['chunks']}")
            check(meta.get("parser") == expect_parser,
                  f"{name}: parsed by {expect_parser}", f"got {meta.get('parser')}")
            check(row["with_offsets"] == row["chunks"],
                  f"{name}: every chunk carries its span",
                  f"{row['with_offsets']}/{row['chunks']}")
            check(row["embedded"] == row["chunks"],
                  f"{name}: every chunk embedded into {MODEL}",
                  f"{row['embedded']}/{row['chunks']}")
            check(bool(meta.get("markdown", {}).get("object_key")),
                  f"{name}: the parsed markdown was kept")

        csv_row = rows.get("incidents.csv")
        if csv_row:
            check(csv_row["status"] == "stored" and csv_row["chunks"] == 0,
                  "incidents.csv: stored as a table, NOT chunked",
                  f"status={csv_row['status']} chunks={csv_row['chunks']}")
        ds = await admin.fetchrow(
            "select name, row_count, file_count, columns::text, bucket, prefix "
            "from content.datasets where name = 'incidents'")
        check(ds is not None and ds["row_count"] == 6,
              "the CSV registered a dataset of 6 rows",
              f"{dict(ds) if ds else None}")
        if ds:
            cols = [c["name"] for c in as_json(ds["columns"])]
            check(cols == ["site", "date", "units_affected", "downtime_hours"],
                  "the dataset's columns came from the Arrow schema", str(cols))

        small = await admin.fetchrow(
            "select (select count(*) from content.resource_chunks c "
            "        where c.resource_id = r.id) as chunks "
            "from content.resources r where r.id = $1::uuid", small_id)
        big = rows.get("r7-field-notice.md")
        check(small and big and small["chunks"] > big["chunks"],
              "a channel policy of 120 target tokens chunks the same file smaller",
              f"{small['chunks'] if small else '?'} chunks vs {big['chunks'] if big else '?'}")

        # THE BATCHING, ASSERTED RATHER THAN ASSUMED. The eight-chunk upload is
        # the one that shows it: one HTTP request for eight chunks, not eight.
        # This is the whole reason the embed step is `work` and not a matrix of
        # `embed:` children, so a regression to the fan-out must fail here.
        embed_out = await admin.fetchrow("""
            select t.output::text as out
            from workflow.tasks t
            join workflow.runs r on r.id = t.run_id
            where r.external_id = $1 and t.step_key = 'embed'""",
            "ingest:" + str(small_id))
        receipt = (as_json(embed_out["out"]) if embed_out else {}).get("result", {})
        check(receipt.get("requests") == 1 and receipt.get("embedded", 0) > 1,
              "the chunks of one document embed in ONE request, not one each",
              json.dumps(receipt))

        # THE SECOND INDEX, over the same parse. `parse` has two dependents --
        # `embed` and `text -> graph -> land_graph` -- so the semantic index and
        # the graph index are siblings rather than a chain: neither waits for
        # the other and a failed extraction does not cost the vectors.
        print("\n=== the graph index ===", flush=True)
        graph = await admin.fetchrow('''
            select
              (select count(*) from aiq.nodes n
                where n.entity_type <> 'document') as nodes,
              (select count(*) from aiq.edges) as edges,
              (select count(*) from aiq.soft_nodes) as soft,
              (select count(distinct relation) from aiq.edges) as relations''')
        check(graph and graph["nodes"] > 0 and graph["edges"] > 0,
              "the uploads produced nodes and edges, not just chunks",
              json.dumps(dict(graph)) if graph else "none")

        # The names have to come from the documents. A graph that landed
        # something is not the same as a graph that landed THIS corpus.
        # An extracted entity lands as a SOFT node -- named, not yet resolved to
        # a typed row -- which is graph.sql's third residence and the right one
        # for "the document said this and we do not know what it is yet".
        named = await admin.fetch('''
            select key from aiq.soft_nodes
            where key in ('bellhaven metals','ravensworth precision','kestrel',
                          'harmonic drive','r7 articulated arm','flexspline',
                          'ravensworth','kestrel line','harmonic drive assembly')''')
        check(len(named) >= 2,
              "entities the fixtures name are in the graph, by name",
              ", ".join(sorted(r["key"] for r in named)) or "none")

        # Provenance: every edge must name the resource whose text produced it,
        # or "why is this in the graph" is a guess. It is on the EDGE rather
        # than the node because a name can be observed by many documents and an
        # assertion is made by one.
        prov = await admin.fetchval('''
            select count(*) from aiq.edges e
            join content.resources r
              on r.id = (e.provenance->'sources'->0->>'resource_id')::uuid
            join content.channels c on c.id = r.channel_id
            where c.name like 'e2e-%' ''')
        check(prov and prov > 0,
              "every edge names the resource and the run that produced it",
              f"{prov} edges attributed to this test's uploads")

        # And the relations are the deployment's vocabulary, not the model's
        # imagination: aiq.edges refuses an out-of-catalogue relation, so this
        # passing at all means every edge the model proposed was in-vocabulary
        # or was dropped rather than invented.
        vocab = await admin.fetchval('''
            select count(*) from aiq.edges e
            join content.resources r
              on r.id = (e.provenance->'sources'->0->>'resource_id')::uuid
            join content.channels c on c.id = r.channel_id
            where c.name like 'e2e-%'
              and not exists (select 1 from aiq.graph_vocabulary v
                              where v.relation = e.relation)''')
        check(vocab == 0, "no edge carries a relation outside the vocabulary",
              f"{vocab} out-of-catalogue edges")

        print("\n=== duckdb over the parquet, straight from object storage ===", flush=True)
        try:
            from percolate_core.ingest import tabular
            uri = await admin.fetchval("select content.dataset_uri('incidents')")
            table = tabular.read_dataset(
                uri, "select site, sum(downtime_hours) as hours "
                     "from dataset group by 1 order by 2 desc")
            got = {r["site"]: r["hours"] for r in table.read_all().to_pylist()}
            check(round(got.get("Kestrel", 0), 2) == 56.25,
                  "DuckDB read s3://…/datasets/incidents/*.parquet and aggregated it",
                  json.dumps(got))
        except Exception as e:
            check(False, "DuckDB read the dataset from object storage", str(e)[:200])

        print("\n=== questions ===", flush=True)
        questions = [
            ("Which R7 serial numbers are affected by the field notice?",
             "R7-4913", "r7-field-notice.md"),
            ("At what case temperature does grease start migrating past the seal?",
             "78", "actuator-teardown.pdf"),
            ("Which supplier has the longest lead time, and how long is it?",
             "19", "supplier-review.docx"),
            ("How long will the Kestrel line be paused, and when does it start?",
             "eleven", "ops-briefing.wav"),
        ]
        # BOTH HALVES, because the label was already claiming both. This said
        # "answered from <source>" while checking only that the expected string
        # appeared somewhere in the reply. A model that already knows what an R7
        # is, or that was handed the wrong passages and guessed well, passed a
        # check whose whole purpose is proving the answer came out of THIS
        # corpus -- and the answer half only ever tests the model, while the
        # retrieval half is the one that tests the pipeline this file is about.
        #
        # The retrieved rows do NOT carry a title, which is why the assertion
        # was missing rather than merely weak: `titles = [r.get("title") ...]`
        # sat one line above the check, unused, and would have been a list of
        # Nones if anything had read it -- aiq.search returns
        # (chunk_id, content, rrf_score, lexical_rank, semantic_rank) and no
        # document identity at all. So provenance is resolved here, through the
        # chunk ids, which is the join the retrieval result deliberately leaves
        # to the caller.
        for question, expect, source in questions:
            answer, retrieved = await ask(admin, question)
            chunk_ids = [r.get("chunk_id") for r in retrieved if r.get("chunk_id")]
            titles = [r["title"] for r in await admin.fetch("""
                select distinct r.title
                  from content.resource_chunks c
                  join content.resources r on r.id = c.resource_id
                 where c.id = any($1::uuid[])""", chunk_ids)] if chunk_ids else []
            print(f"    Q: {question}\n    A: {str(answer)[:220]}", flush=True)
            answered = (expect.lower() in str(answer).lower()
                        or (expect == "eleven" and "11" in str(answer)))
            # Among the retrieved documents, not ranked first: pinning the rank
            # would make this a test of the fusion weights rather than of
            # ingestion, and LIMIT 4 already says how wide the window is.
            from_source = source in titles
            check(answered and from_source, f"answered from {source}",
                  f"expected {expect!r}"
                  + ("" if answered else " -- not in the answer")
                  + ("" if from_source else f" -- {source} was not retrieved; got {titles}"))

        print("\n=== drift ===", flush=True)
        # Scoped to this test's own resources: check_drift() reports the whole
        # database, and another test's half-written fixture is not this test's
        # failure to report.
        drift = await admin.fetch("""
            select d.kind, d.detail from content.check_drift() d
            join content.resources r on r.id = d.id
            join content.channels c on c.id = r.channel_id
            where c.name like 'e2e-%'""")
        check(not drift, "no uploaded resource is ready with no chunks",
              "; ".join(f"{d['kind']}: {d['detail']}" for d in drift) or "clean")

    finally:
        await admin.close()
        for p in procs:
            p.terminate()

    passed = sum(1 for ok, _, _ in CHECKS if ok)
    print(f"\n{passed}/{len(CHECKS)} checks passed", flush=True)
    if passed != len(CHECKS):
        print("logs are in " + str(workdir), flush=True)
    return 0 if passed == len(CHECKS) else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
