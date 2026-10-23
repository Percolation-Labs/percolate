# What a step leaves behind

A step finishing is not the same as a step producing something. This file is
about the second half: where the thing a step made actually lives, who owns it
afterwards, and what the next step is allowed to read.

There are **four** answers, and only four. They are not interchangeable, and
picking the wrong one is how a workflow ends up with its real state in a JSONB
column nobody can query.

| Class | The output is | It lives in | What the next step reads |
|---|---|---|---|
| **1. Payload** | a small JSON value | `tasks.output`, copied into `runs.context` | `{{steps.<id>.result}}` |
| **2. State** | rows | your tables | ids and counts — a receipt |
| **3. Shape** | a validated structured answer from a model | `agentic.messages` | the value, plus the message it came from |
| **4. Bytes** | a file | object storage, registered in `content` | `{{steps.<id>.$artifact}}` |

Class 1 is the one everything else is defined against, so it goes first even
though it is the least interesting. The other three exist because a payload
column is the wrong home for rows, for a conversation turn, and for a megabyte.

---

## 1. The inline payload — small, copied, and read by templates

`{{steps.<id>.result}}` is the one idiom the engine teaches, and it is a
*value*, interpolated into the next task's input at dispatch. That has a cost
that is easy to miss: every byte a step returns is copied into another task
row, and again into `runs.context`, and stays there for the life of the run.

So the payload class is deliberately bounded — `workflow.max_payload_bytes`,
64KB by default, a hard limit rather than a warning. It is sized for what it is
*for*: a status code, a count, a document id, a 768-dimension embedding on its
way from an embed step to a search step (~10KB as JSON, and the reason the
limit was raised from 8KB). Anything bigger is one of the other three classes
wearing the wrong hat.

The limit is checked twice, in `complete_task` and again by a trigger on the
table, and the two are not redundant: the first classifies the failure
(terminal, because the same response is the same size on every attempt), the
second catches a writer that never went through `complete_task` at all.

---

## 2. The database is the state

This is the easy case and it is already the whole design. A `sql` or `p8ql`
step writes rows — through a registered function, or with its own
`sql: {statement: ..., write: true}` — and the rows *are* the result. The
load-bearing registered functions all have this shape — one projects a fetched
series into a typed table, another lands one year of a dataset,
`content.record_chunks` stores chunks and marks the resource ready.

**The rule this file adds: a class-2 step's `output` is a receipt, not the
result.** Ids and counts, bounded by construction — `{"result": {"resource_id":
"…", "chunks": 412}}`. The next step re-reads by key. It does not receive the
rows through `runs.context`.

That is not a style preference; it is class 1's cost, paid by data that already
has a home. A step that returns its rows has quietly made the task table the
storage layer for them — with no index, no type, and no RLS policy of its own.

Nothing enforces this today. A registered function returning a 40KB result set
is accepted, lands in `runs.context`, and works. It is the failure that reports
success: the pipeline is correct and the state is in the wrong place, which is
only discovered when someone tries to query it.

**Not built:** the receipt discipline is a convention here, not a check. The
honest place for one is `register_step_function` — a registered function could
declare whether it returns a receipt or a value, and the engine could refuse an
oversized result from a function that claimed the former. That is a real design
decision (some `sql` steps legitimately return a value — a list of currencies,
say, that a matrix then fans out over), so it is named
rather than assumed.

---

## 3. A model produced a shape, so it is a message

An `agent:` step with `output_schema` is the only step kind whose output is
both *authored by something outside this system* and *contractually shaped*.
Both halves matter, and today only one of them is honoured.

**What is built.** `complete_task` validates the answer against the declared
shape before storing it, parses the JSON-in-a-string a model actually returns,
and treats a violation as **retryable** — the one place in this engine where
retry is the right remedy, because the same prompt genuinely can conform on the
next attempt. That is correct and stays.

**What is missing: the answer never becomes an assistant message.** It is
validated by `workflow`, stored in `workflow.tasks.output`, and copied into
`runs.context`. On the `agentic` side, if the runtime persists anything at all,
it is text in `messages.content`:

- `agentic.messages` has no JSON column. Columns are `content:text`,
  `tool_calls:jsonb`, `citations:jsonb` — a structured answer is stored as a
  string and has to be re-parsed by every reader.
- When this was measured (September 2026), assistant rows on a development
  instance already held a JSON object as text in `content`, and others only
  *looked* like it because the runtime's step-cap message opens with `[`. The
  case is not hypothetical, and it is ambiguous to detect after the fact.

So a structured answer is validated in one system and stored in another, with
no column saying it was structured, no link to the schema it satisfied, and no
link back to the task that asked for it.

### The rule

**A structured answer from a model is an assistant message row, and the
workflow's copy is a reference to it.**

Both halves are needed. The value must stay inline in `tasks.output` because
`{{steps.classify.result.verdict}}` is the whole point — a fan-in that has to
join to `agentic.messages` to count verdicts is not the thing that was built.
But inline-and-only-inline makes the conversation plane a lossy sink: the model
said something contractual and the system of record for what models say does
not have it.

So: inline the value, **and** name where it came from.

```json
{"result": {"verdict": "SAFETY", "confidence": 0.91},
 "message_id": "…", "run_id": "…"}
```

One side is authoritative (the message row), the other is a working copy with a
pointer home. That is a copy made deliberately, which is a different thing from
a copy made by accident — and it is the same discipline class 4 uses, where the
`$artifact` id points at the row that owns the bytes.

### The schema must live in one place

Today the contract is written twice — once as `agents.structured_output_schema`
on the agent row, once as `output_schema` in the YAML — and they will drift.
The failure mode when they do is a **passing shape check against a stale
schema**, which is the worst available outcome: green run, wrong contract.

The fix has been proposed elsewhere:
`output_schema: {$ref: 'agent'}`, resolved from the agent row at dispatch. This
file seconds it, for a second reason: once the answer is a message on a run
against that agent, the schema it satisfied has to be the agent's, or the
message row is annotated with a contract the agent does not have.

### Follow-on steps read the state, as usual

Once the answer is a row, a later step reads it the way it reads any other
state — a registered function over `agentic.messages`, scoped by `run_id` or
`session_id`. That is class 2, and it is the reason class 3 has to land in the
database rather than staying in `runs.context`: **a workflow can only build on
what is queryable.** `runs.context` is a blob keyed by step id. A table of
validated structured answers is something you can aggregate, score, and
re-extract from three months later.

**Not built, and each of these is small on its own:**

1. `agentic.messages.structured_output jsonb`, constrained to assistant rows,
   the way `citations` already is.
2. The runtime writing it, and validating against the agent's schema, on the
   `/internal/run` path.
3. `complete_task` carrying `message_id`/`run_id` through for an agent step.
4. `output_schema: {$ref: 'agent'}`.

(4) is the one that stops the contract drifting; (1) is the one that stops the
answer being a string.

---

## 4. Everything else is bytes, and bytes are a resource

Anything that is neither a small value, nor rows, nor a validated shape is a
file: a rendered report, a scraped page kept verbatim, a model response too
large to inline, a chart. It goes to object storage and comes back as a ref.

```json
{"status": 200, "result": {"pages": 12}, "$artifact": "9f3c…-uuid"}
```

**The ref is a sibling of `result`, not a value inside it**, and that placement
is the design. Three things fall out of it:

1. `{{steps.<id>.result}}` is untouched, and `{{steps.<id>.$artifact}}`
   resolves the ref — `resolve_args`' template character class already admitted
   `$`, so this needed no resolver change.
2. `output_schema` validates `result` and never sees the engine's key, so a
   contract with `additionalProperties: false` stays writable.
3. A step that produced *only* bytes writes no `result` at all, and
   `{{steps.<id>.result}}` then fails loudly — correct, because there is no
   value.

### A resource id, not an `s3://` URI

`workflow.register_artifact(task_id, checksum, bucket, object_key, size_bytes,
…)` returns a row in `content.resources`. That is what makes an artifact
RLS-scoped, checksum-deduped, servable, and visible to `content.check_drift`.
A bucket path in a JSONB column is a string with no owner: none of those
things, and it drags a bucket name into a row that is supposed to stay
inspectable and replayable — the same argument that makes `credential_ref` a
*name* rather than a secret.

Nothing new is stored to make the link. The task's output holds the resource id
(forward) and the resource's metadata holds the task id (back), each on the row
that owns it; `workflow.v_artifacts` is the join, read from either end. A link
table would be a third copy of a fact two rows already carry.

`external_id` is the **task** id, so a retry converges on one resource instead
of leaving a trail of orphans — the same idempotency `tasks.idempotency_key`
already gives the engine. Bytes dedupe independently by checksum, so two tasks
writing identical output share one `content.files` row and still get a resource
each.

### `stored` is a fourth resource status, and it closes two collisions

An artifact is retrievable the moment it lands and is **not corpus**. Under
`ready` it would have been both of these, permanently:

- `content.check_drift()` reports resources that are `ready` with no chunks.
  Every artifact ever produced would be permanent noise in that report.
- `world-model-ingestion/integration.sql` projects resources into the graph as `document` nodes where
  `status = 'ready'`. Machine-generated step output is exactly the data-plane
  volume `ai-query-layer/graph-identity.md`'s inclusion policy keeps out of the node registry —
  the same argument that excludes chunks.

A status of its own excludes it from both **by construction**, rather than by
adding a predicate to each and hoping the next one remembers. Asserted:
`08-artifacts.sql` §3e fails if an artifact appears in either.

### `$ref` was the old spelling, and it never worked

The spec said return `{"$ref": "s3://…"}` and the size check would let it
through. Two things were wrong with that, both verified on the live instance.

**It collided with the `result` idiom.** The check uses the jsonb `?` operator,
which is top-level only, while `YAML.md` says every step nests its payload
under `result`. Probed at a 64KB limit:

```
A: oversized, {"$ref": …} at the top level        -> accepted
B: oversized, {"status":200,"result":{"$ref": …}} -> REFUSED as oversized
```

Shape B is the only form that keeps `{{steps.<id>.result}}` resolving. Shape A
passes the check and breaks every template that reads it. No shape satisfied
both — a better account of "the worker does not implement `$ref`" than "it was
not written yet". The same top-level assumption sat in `complete_task`, where
it compounded: shape validation runs on `coalesce(v_out->'result', v_out)`, so
a ref'd result could never satisfy a declared `output_schema` either.

**The bypass admitted exactly what the rule exists to reject.** A
`{"$ref": "s3://b/k"}` payload is about thirty bytes and was never going to
trip a 64KB limit, so `not (output ? '$ref')` only ever fired on a payload that
was *both* oversized and carried a ref — one that offloaded its data and then
inlined it anyway. It had no legitimate caller. The limit is unconditional now.

Both mistakes fail terminally and name the fix: the old `$ref` key, and a
`$artifact` holding a bucket path rather than a resource id. Neither is
retryable, for the same reason an oversized payload is not — the same string
arrives on every attempt.

### What is built, and what is not

**Built and asserted** (`dev/tests/workflow/08-artifacts.sql`, green on the dev
instance and on a fresh `CREATE EXTENSION`): the ref shape and its extractor,
the unconditional limit, both terminal refusals, `register_artifact`, the
`stored` status and the two exclusions it buys, `workflow.artifact` as a
registered step function, and `v_artifacts`. The end-to-end assertion runs
against a real 1.2 MB object in MinIO — four hundred times the wire limit and
incompressible, so nothing about it fits by accident.

**The worker side is built too.** The database cannot do this half — it has no
outbound egress by design — so the shipped worker does the `PUT` to object
storage and the `register_artifact` call after it, when a step's output is over
the cap (`core/percolate_core/worker/artifacts.py`). `register_artifact` takes
exactly the arguments a worker holds after a `PUT`.

Also unbuilt: presigned upload URLs, which are the Content Server's job and
not the database's.

---

## Why four and not five

The test for another class is whether it has a different *owner* after the step
ends. A payload is owned by the run; rows are owned by the schema that defines
them; a structured answer is owned by the conversation plane; bytes are owned
by object storage with a Postgres pointer. Everything else proposed as an
output type — a metric, an event, a summary, a decision — is rows, and belongs
to whichever table already models it.

The one genuinely open question is class 3's boundary: an agent step *without*
`output_schema` returns prose, and prose is a message but not a shape. It
should still land as an assistant row for the same provenance reason; it simply
has nothing to validate. That is a smaller change than the shaped case and is
covered by (2) above.

---

## Verified, and two things found on the way

Everything above marked *verified* was run against the dev instance on
2026-09-01: the `$ref` nesting probe, the message-column inventory, the zero
`workflow_task_id` count, the registered-function list, and the full artifact
path against MinIO.

Two findings are not about output classes at all, and are recorded because both
were invisible until something was actually run:

**`CREATE EXTENSION percolate` on an empty database was broken**, at HEAD and
independently of this work. `workflow-engine/schema.sql` §24 keeps every tool
description together in one set, reasoning — correctly — that `cancel_run` can
be commented before `integration-rbac.sql` redefines it, because
`pg_description` is keyed on an oid that `CREATE OR REPLACE` does not change.
That argument does not extend to **views**: `runs_api` and `tasks_api` do not
exist yet, have no oid to key on, and the install died on
`relation "workflow.runs_api" does not exist`. The two view comments now live
beside the views. Confirmed pre-existing by building HEAD's spec files into
their own extension script and installing that too.

**The dev database has `workflow.max_payload_bytes = 262144`** set at the
database level — an `ALTER DATABASE` that appears nowhere in `dev/init`, so it
is not reproducible from the repo. It is not unknown: `04-matrix.sql` says "this
database has it raised" and sets the value locally before asserting on it, which
is the right pattern and is why the payload tests were never wrong.
`08-artifacts.sql` does the same. The drift is that a fresh stack and this one
disagree, with nothing in the repo saying so.
