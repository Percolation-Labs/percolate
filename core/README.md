# p8

The processes that sit in front of the database. `../../INSTALL.md` covers the
database itself; nothing here is required to use it.

```bash
pip install p8                 # the worker -- asyncpg, httpx, typer
pip install 'p8[content]'      # + Content Server (boto3, fastapi)
pip install 'p8[agent]'        # + Agent Runtime (pydantic-ai, mcp)
pip install 'p8[all]'
```

```bash
p8 worker --queue http    # claim and execute tasks
p8 content serve          # uploads, scraping, http_call execution
p8 agent serve            # agents, streaming, delegation
```

---

## Layout

| Module | Extra | What it is |
|---|---|---|
| `p8.core` | — | connecting **as the caller**, configuration, credential resolution |
| `p8.worker` | — | the step loop and the `@handler` registry |
| `p8.content` | `content` | the Content Server |
| `p8.agentic` | `agent` | the Agent Runtime |

**One distribution rather than three.** Three packages means a version matrix
(`p8content 0.3` requiring `p8core >=0.2,<0.3`) resolved forever, for services
that release together and are written by the same people. Splitting later is
mechanical; merging two that have drifted is not.

**The base install stays small on purpose.** The common case is someone writing
their own worker, and they should not pull boto3 and pydantic-ai to do it. The
CLI imports each subpackage lazily, so `p8 worker` runs without either
installed and `p8 content serve` fails with the extra to install rather than an
`ImportError`.

---

## `p8.core` — the one that matters

It decides **whose** RLS applies, and it exists because that logic was
previously written three times on two different database drivers.

```python
from p8.core import as_caller

async with as_caller(claims) as conn:      # claims = the VERIFIED JWT payload
    rows = await conn.fetch("select * from content.resources")
```

Every service connects as a low-privilege role and sets the caller's claims
**per transaction**, exactly as PostgREST does. A service that queried as
*itself* would bypass every policy in the collection — not by exploiting
anything, just by never presenting an identity for the policies to filter on.

Transaction-local (`set_config(..., true)`) is not a detail: an unregistered
GUC left at session scope survives into the next transaction on a pooled
connection, so the following request would inherit the previous caller's
identity.

`as_service()` exists for work with genuinely no user behind it — a scheduled
poll, a reconciliation sweep. Deliberately a separate function rather than
`as_caller(None)`, so "this query has no user" is something someone wrote down.

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
from p8.worker import handler, run

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

One image, three entrypoints — they share `p8.core`, so three images would be
three builds of the same base and three tags to keep in step.

```yaml
content: { image: p8/runtime:0.1, command: ["p8","content","serve"] }
agent:   { image: p8/runtime:0.1, command: ["p8","agent","serve"] }
worker:  { image: p8/runtime:0.1, command: ["p8","worker","--queue","http"] }
```

See [`../../PACKAGING.md`](../../PACKAGING.md) for the reasoning and the
remaining work.

---

## Status

- `p8.core`, `p8.worker`, `p8.content` — built, and exercised against a live
  PG19 instance with MinIO.
- `p8.agentic` — moved from `experiments/agentic-runtime` unchanged (it uses
  relative imports throughout, so the move needed no edits). Its own tests have
  not been re-run under the new namespace.
- No Dockerfile yet. No service-surface entries in `../../surface.sql`, which
  by `meta/skills/spec-driven-development` §7 should exist **before** the
  endpoints they describe.
