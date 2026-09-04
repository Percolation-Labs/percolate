# percolate-core

The processes that sit in front of the database. The database itself, and the
specs all of this is built against, live in
[p8-subsystems](https://github.com/Percolation-Labs/p8-subsystems); nothing
here is required to use it.

```bash
pip install percolate-core                 # the worker -- asyncpg, httpx, typer
pip install 'percolate-core[content]'      # + Content Server (boto3, fastapi)
pip install 'percolate-core[agent]'        # + Agent Runtime (pydantic-ai, mcp)
pip install 'percolate-core[all]'
```

```bash
percolate worker --queue http    # claim and execute tasks
percolate content serve          # uploads, scraping, ingestion
percolate agent serve            # agents, streaming, delegation
percolate agent --help           # the runtime's own operator commands
```

### Output too large to store

`workflow.tasks.output` is capped (`workflow.max_payload_bytes`, 64KB by
default), and an oversized result used to fail the task terminally. The worker
now stores it and completes:

```json
{"status": 200, "$artifact": "9f3c…-uuid"}
```

The ref is a **sibling** of `result`, not a value inside it — the engine's size
check reads top-level keys while every step nests its payload under `result`,
so a ref inside `result` is invisible to the check and a ref at the top breaks
every `{{steps.<id>.result}}` reading it. And there is no `result` left: a value
too large to carry is not a value, so the next step reads
`{{steps.<id>.$artifact}}`, or resolves it in-database with
`sql: {function: artifact, args: ['{{steps.<id>.$artifact}}']}`.

It is a **resource id**, not an `s3://` URI — a row in `content.resources`, so
the artifact is RLS-scoped, checksum-deduped, servable and visible to
`content.check_drift`. Needs `percolate-core[content]` for object storage; the
image installs `[all]`, so the shipped worker always has it, and a minimal
install fails with the one command that fixes it. Asserted end to end by
[`dev/offload.py`](dev/offload.py).

[`docs-sample.md`](docs-sample.md) is the one to read next: a real REST call to
the Agent Runtime, the events it streams back, the rows it leaves behind, and
every header and option a caller can send — captured output, not illustration.

---

## Layout

| Module | Extra | What it is |
|---|---|---|
| `percolate_core.core` | — | connecting **as the caller**, configuration, credential resolution |
| `percolate_core.worker` | — | the step loop, the `@handler` registry, and artifact offload |
| `percolate_core.content` | `content` | the Content Server |
| `percolate_core.ingest` | `ingest` | parsing, chunking and batched embedding for uploaded files |
| `percolate_core.agentic` | `agent` | the Agent Runtime |

The import package matches the distribution name exactly, so there is no mapping
to remember. (`p8` was taken on PyPI.)

**One distribution rather than three.** Three packages means a version matrix
(`percolate-content 0.3` requiring `percolate-core >=0.2,<0.3`) resolved forever, for services
that release together and are written by the same people. Splitting later is
mechanical; merging two that have drifted is not.

**The base install stays small on purpose.** The common case is someone writing
their own worker, and they should not pull boto3 and pydantic-ai to do it. The
root CLI mounts each subpackage's own command group and tolerates its absence,
so `percolate worker` runs with neither installed and `percolate content` says
which extra to install — naming the module that was actually missing, rather
than guessing.

---

## `percolate_core.ingest` — an uploaded file becomes answerable

    pip install 'percolate-core[ingest]'      # + [tabular] for CSV/Parquet
    percolate ingest serve --queue ingest

The ingestion workflow the Content Server starts has two steps and this runs
both: **parse** (bytes to markdown to chunks) and **embed** (every chunk of a
document in one batched call). One library per format and none of them carries
a model:

| | reader | |
|---|---|---|
| pdf | `pymupdf4llm` | the PDF's own structure, no OCR |
| docx | `python-docx` | headings, lists and tables, in document order |
| html | stdlib | tags out, block structure kept |
| audio | any OpenAI-shaped `/audio/transcriptions` | including a local one |
| csv / xlsx / parquet | `pyarrow` | to Parquet in object storage, never chunked |
| everything else | — | registered, retrievable, not pretended to be text |

Chunking is `semchunk` with a **700-token** default — generous on purpose,
because a chunk here is retrieved, shown to a model and cited, and a 250-token
chunk keeps the sentence that matched and loses the one that explains it.

**Embedding batches, and it is why that step is `work` rather than a
declarative `matrix:` of `embed:` children.** A step's output is capped at
`workflow.max_payload_bytes` (64KB) and one 1536-dimension vector is ~31KB of
JSON, so two vectors do not fit in one task output: any design that carries
corpus vectors through the engine is limited to batches of one. This writes
them itself (`aiq.record_embeddings`) and returns a receipt — measured, an
eight-chunk document went from eight requests to one.

Defaults live here; overrides live in the database, as a channel's or an
upload's `ingest_policy`, validated by a strict pydantic model so a misspelled
key is refused rather than ignored. To see what a policy does to a file without
a database, a stack or a key:

    percolate ingest file ./notice.pdf --policy '{"chunking":{"target_tokens":300}}'

The contract, the per-format argument and the six defects that running it
found are `specs/world-model-ingestion/ingestion.md` in
[p8-subsystems](https://github.com/Percolation-Labs/p8-subsystems).

---

## `percolate_core.core` — the one that matters

It decides **whose** RLS applies, and it exists because that logic was
previously written three times on two different database drivers.

```python
from percolate_core.core import as_caller

async with as_caller(claims) as conn:      # claims = the VERIFIED JWT payload
    rows = await conn.fetch("select * from content.resources")
```

Every service connects as a low-privilege role — set explicitly by `as_caller`,
not inherited from whatever the connection string happens to log in as — and
sets the caller's claims **per transaction**, exactly as PostgREST does. A service that queried as
*itself* would bypass every policy in the collection — not by exploiting
anything, just by never presenting an identity for the policies to filter on.

Transaction-local (`set_config(..., true)`) is not a detail: an unregistered
GUC left at session scope survives into the next transaction on a pooled
connection, so the following request would inherit the previous caller's
identity.

`as_service()` exists for work with genuinely no user behind it — a scheduled
poll, a reconciliation sweep. Deliberately a separate function rather than
`as_caller(None)`, so "this query has no user" is something someone wrote down.

**One pool per process, with explicit ownership.** A service's lifespan owns it
(`open_pool`/`close_pool`, reference-counted); every short-lived helper borrows
it (`pool()`). Several mounted services in one process share it, and the last
one out closes it — without that, one service's shutdown closes the pool another
is still streaming through.

---

## Writing your own worker

Most steps need no worker from you:

| kind | who runs it |
|---|---|
| `sql` / `p8ql` | **nobody** — executes inside Postgres |
| `http_call` | the built-in handler |
| `timer` / `signal` / `decision` / `sub_workflow` | the engine |
| `work` | **you** |

When you do need one, it is this loop with a handler registered — not a
different program:

```python
from percolate_core.worker import handler, run

@handler("transcode")
async def transcode(spec, ctx):
    return {"duration": await ffmpeg(ctx["run_input"]["file_key"])}

run(queue="media")
```

`ctx` comes from `workflow.get_task_context()`: `run_input`, the accumulated
`context` (so a later step reads an earlier step's output), `task_input`,
`step_key`, and `trace_id`/`span_id`.

**The worker holds no table grants.** Every interaction is a `SECURITY DEFINER`
function call — `claim_task`, `get_task_context`, `complete_task`, `fail_task`
— which is why "bring your own worker" is safe to offer: a compromised worker
can claim and complete tasks, and nothing else.

**Raise `TerminalError` for what will not get better.** A bad argument, a
missing credential, a 404. Anything else is retried with backoff. The worker is
the only thing that knows what a failure means, so it decides and the engine
honours the verdict.

---

## Configuration

Environment only. Credentials by **reference**, never by value:
`credential_ref: "LLM_API_KEY"` on a task names a variable this process
resolves, so `workflow.tasks` stays inspectable and replayable.

| | Used by |
|---|---|
| `P8_DSN` | all |
| `P8_JWT_SECRET` | services verifying bearer tokens (same secret PostgREST uses) |
| `P8_QUEUE`, `P8_WORKER_ID`, `P8_POLL_SECONDS` | worker |
| `P8_S3_ENDPOINT`, `P8_S3_KEY`, `P8_S3_SECRET`, `P8_BUCKET` | content |

---

## Deployment

One image, several entrypoints — they share `percolate_core.core`, so separate
images would be separate builds of the same base and separate tags to keep in
step. `ENTRYPOINT ["percolate"]`, and the command selects the service:

```yaml
content: { image: percolationlabs/percolate-core:0.1.1, command: ["content","serve"] }
agent:   { image: percolationlabs/percolate-core:0.1.1, command: ["agent","serve"] }
gateway: { image: percolationlabs/percolate-core:0.1.1, command: ["agent","gateway"] }
worker:  { image: percolationlabs/percolate-core:0.1.1, command: ["worker","--queue","http"] }
```

The agent gateway is its own entrypoint because delegation is an MCP call into
it: an agent that delegates references it as an ordinary `tool_servers` row.

For the packaging decision record see
[PACKAGING.md](https://github.com/Percolation-Labs/p8-subsystems/blob/main/PACKAGING.md);
for what packaging *requires of the design*, `specs/agentic/brief.md` §10.

---

## Status

- `core`, `worker`, `content` — built, and exercised against a live PG19
  instance with MinIO.
- `agentic` — built and verified under the new namespace: `tests/smoke.py` (6
  checks, no database or credentials) and `dev/verify.py` (38 assertions against
  a live model, covering streaming, what is and is not persisted, the delegation
  and span trees, the reload round trip, mounting, session resume, tenant
  isolation, and a scheduled run completing its own workflow task).
- Still open: no service-surface entries in the specs repo's `surface.sql`,
  which by `meta/skills/spec-driven-development` §7 should exist **before** the
  endpoints they describe; and no startup check that the deployed schema is the
  one this version expects (`specs/agentic/brief.md` §10.4).

## Development

```bash
. dev/env.sh          # DSN, test user, JWT, and the LLM key
./dev/db.sh up        # a PG19 cluster of its own, loaded from the specs repo
./dev/stack.sh up     # PostgREST, the retrieval service, the agent gateway
uv run --all-extras python dev/verify.py
```

`dev/db.sh` loads `specs/*/schema.sql` from a p8-subsystems checkout directly —
never a copy — so a schema that only works because a harness did something extra
fails here. Set `P8_SPECS` if your checkout is elsewhere.
