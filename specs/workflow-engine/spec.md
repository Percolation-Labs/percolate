# DB-Native Workflow Engine — Final Spec

## 1. Goal

Postgres owns all orchestration state: queueing, locking (`SKIP LOCKED`), dependency
resolution, retries, scheduling, and now saga compensation. No separate control-plane
service. Workflow definitions are data (JSON), not SDK-specific code. The client "SDK"
is a small set of SQL functions, callable directly or via PostgREST — any HTTP-capable
language is a full client, with no generated per-language SDK.

## 2. Non-goals (deliberate scope cuts)

- **Full event-sourced replay** (Temporal's model). Instead: `decision` tasks are
  contractually pure functions of a recorded input snapshot, with a runtime hash check
  that catches non-determinism loudly rather than requiring a full replay engine.
- **A human authoring/inspection UI.** Status dashboards only (Grafana on SQL views).
  The entire management surface — trigger, signal, cancel, inspect — is the same small
  RPC set a worker uses, exposed via PostgREST. An AI agent and a human with `psql` use
  the identical interface; there is nothing else to build for either.
- **Multi-tenant platform fairness.** This is a workflow engine for one team's use, not
  a shared platform serving other teams with SLAs against each other.
- **General cyclic OR-joins.** Provably undecidable territory (van der Aalst et al. on
  EPC "vicious circles"). The spec validator rejects graphs with no valid entry point;
  acyclic/free-choice structures are the supported executable class.

## 3. Core data model

Five core tables (in the `workflow` schema): `workflow.definitions`, `workflow.runs`, `workflow.tasks`, `workflow.task_dependencies`, `workflow.task_events`,
plus `queue_config` and `rate_limits` for operational tuning. Full DDL in
[`schema.sql`](schema.sql) (single canonical file — nothing else to merge).

Key design decisions:

| Decision | Why |
|---|---|
| `workflow.task_dependencies` edge table + `pending_deps` counter, not an array | O(1) dependency resolution at scale; avoids array-scan cost per completion |
| Dependency rows locked (`FOR UPDATE`) before a new task's `pending_deps` is decided | Closes a real race: a dependency completing between a new task's insert and its edge being recorded would otherwise leave the new task permanently stuck |
| One unified cascade trigger for `done`/`cancelled`/`failed` | A prior version only cascaded cancellation one hop; grandchildren of a failed task could stall forever. One trigger, firing recursively per row, cascades to any depth |
| `queue` encodes affinity: `{step-group}:{resource-class}:{zone}` | The only signal both `claim_task` and KEDA see; one K8s Deployment per queue |
| `kind` ∈ `work / decision / timer / signal / sub_workflow / http_call / sql / matrix` | Distinguishes execution model without separate tables |
| `matrix` tasks expand in the transaction that completes them, and rewire their successors onto the children | Fan-out with no controller process and no window in which the parent is done and the children do not exist — §13 |
| A matrix declares its granularity: `batch_size` rows per child, `partition_by` columns that keep rows together | One row per task is right for an HTTP call and wrong for a cheap write — a hundred four-millisecond rows would otherwise cost a hundred claims, heartbeats and cascades. §15b |
| `decision` tasks are contractually pure; output hash checked on any re-execution | Enables lightweight, targeted replay (re-run a decision against its recorded input) without full event sourcing — and catches purity violations that would otherwise fail silently |
| Payloads are capped by a trigger (`workflow.max_payload_bytes`, 64KB); anything larger is registered in object storage and named by a `$artifact` resource id **beside** the payload | Avoids TOAST bloat and replication/backup blow-up; schema-enforced, not just convention. The ref is a sibling of `result` rather than a value inside it, and it is a resource id rather than an `s3://` URI — see [`outputs.md`](outputs.md) for both, and for the earlier `{"$ref": "s3://..."}` spelling that could not be written in a shape the templates and the size check both accepted |
| `saga_group` + `compensation_task_key` + `begin_compensation()` | The single largest capability gap found against DBOS/River/Temporal — compensations run as ordinary tasks (retries, backoff, audit trail all inherited) in strict reverse order on failure |
| `validate_spec()` trigger on `workflow.definitions` | Lightweight WF-net-style soundness check (duplicate keys, unknown dependencies, unreachable steps, cycles with no entry point) rejected at registration, not discovered as a stalled run in production |

## 4. Client API (the whole "SDK")

```
start_workflow(name, input, external_id)     -- bootstrap: expand a registered spec into
                                                  a run + its initial task graph. Idempotent
                                                  via external_id, and the key is YOURS --
                                                  see "Whose runs an external_id matches"
claim_task(queue, worker_id)                 -- SETOF: one row, or NO rows when
                                                  the queue is empty. Rate-limited
                                                  already; claim_tasks() batched;
                                                  claim_task_rate_limited() is a
                                                  superseded alias -- §23
heartbeat_task(task_id, worker_id)  -> bool     -- false = STOP. Three reasons now:
                                                  cancel requested, task terminal,
                                                  or your lease was reaped
complete_task(task_id, output, worker_id)
fail_task(task_id, error, terminal, worker_id)  -- terminal=true stops retrying; false
                                                  re-queues with backoff. 4xx is
                                                  terminal, 5xx is not.
complete_decision_task(task_id, output, new_tasks, worker_id)  -- atomic branch +
                                                        complete; the replay primitive
add_task(run_id, step_key, queue, depends_on, kind, input, rate_key)  -- runtime fan-out
expand_matrix(task_id)                          -- a `matrix` step: expand a row set into
                                                    N children, rewire the successors onto
                                                    them, and complete -- one transaction.
                                                    Called by a trigger, not by a worker.
matrix_rows(task_id)                            -- the recorded row set, read back off the
                                                    children in expansion order
signal_task(run_id, signal_name, payload)       -- resolves a waiting_external task
cancel_run(run_id)                              -- cascades into child sub-workflow runs
start_child_workflow(task_id, workflow_name, input)
begin_compensation(run_id, saga_group)          -- enqueues compensating tasks in
                                                    reverse-completion order
```

Exposed 1:1 over PostgREST RPC endpoints for non-DB-native clients. No generated
per-language client.

### Whose runs an `external_id` matches

`external_id` is an idempotency key the CALLER chooses — a ticket reference, a
document id, a date — so two people will pick the same string, and the
idempotence contract has to say which runs it is idempotent *against*. It is
the runs that caller may see: their own, or one their permissions reach, the
same rule `assert_run_access` applies to cancelling and signalling.
Anything else it matches nothing, and a new run
starts.

Stated because for a while it was not: the match was on the key alone, so
naming a value somebody else had used returned **their** run's id, or named it
in the error. The rows stayed refused — `runs_api` and `tasks_api` are
RLS-filtered — and what the caller got was the id, the knowledge that a run
under that key exists, and whatever their next step did with a run id handed
back to it (REM-77).

The key is therefore unique **per owner** rather than installation-wide, which
is a property of the index and not of the function: a match narrowed without
the constraint narrowing with it turns another tenant's row from a returned id
into a unique violation — the same existence oracle, plus a write that
legitimately should have succeeded. `integration-rbac.sql` §(e) holds both
halves side by side for that reason.

**The engine is not a tenant.** `tick()` fires a schedule with no identity at
all and depends on this key for its own idempotence (§12b), so an operator's
session matches every run with the key, as it always did; its authorization is
the grant, which is the same exemption the worker-facing functions carry.

### What `get_task_context` returns

Named in the block above but, for a long time, never described — which made
"bring your own worker" an incomplete offer. A third-party worker is handed a
task id and must know what it can read from it. This is the contract:

```
{
  "run_id":     uuid,      "step_key":  text,      -- which step of which run
  "kind":       text,      -- dispatch on THIS, never on the shape of the input
  "task_input": {…},       -- the step's own arguments, templates unresolved
  "run_input":  {…},       -- what start_workflow was called with -> {{run.*}}
  "context":    {…},       -- every completed step's output, keyed by step_key
                           --   -> {{steps.<key>.result}}
  "attempt":    int,       -- 0 on the first try; the retry count, for backoff
  "trace_id":   text,      "span_id": text         -- W3C trace propagation
}
```

Two of these are load-bearing in a way that is easy to miss. **`kind`** is what
a worker dispatches on; it was omitted at first, which forced the worker to
infer the handler from the input's shape — inference that silently does the
wrong thing on a malformed task. And **`context`** is why template resolution
happens at dispatch rather than at author time: `{{steps.embed.result}}` cannot
be resolved when the workflow is written, because the step has not run.

**`worker_id` on the three completion paths is the lease fence (§23), and the
shipped worker passes it.** A worker that is slow is indistinguishable from one
that is dead, so the reaper can revoke a lease from a worker that is still alive
and about to report. Passing the `claimed_by` that `get_task_context` hands back
is what lets the engine tell the current holder from a previous one. A caller
that omits it still has completions refused against terminal tasks and revoked
leases, and only the two-live-workers case degrades to first-writer-wins.

`claim_task` in particular is a more general primitive than "a worker pod claims a
job" — it's the same shape as a person claiming a piece of work in a
marketplace, such as a writer claiming a detected event as a gig. Reuse this instead of building bespoke
claim/expiry/idempotency logic for that kind of flow when it's built.

## 5. Python harness (user-facing DX)

**This section described a design that was replaced, and the replacement is
smaller.** It is rewritten rather than deleted because what it got wrong is the
recurring temptation in this collection: it put the workflow's *definition* in
Python, where a definition in Python is a deploy.

It used to specify a decorator pair — `@workflow("send_invoice")` on a class,
`@step(queue=…, retries=…)` on its methods — walked at container startup to
build the spec JSON, hash it, and upsert `workflow.definitions` on change. That
made the authoring surface a Python import, so a step added to a DAG was a new
image, and it made the harness the thing that decides what a workflow *is*.
Authoring is now YAML compiled by the database (`define_yaml()`, `YAML.md`), and
a definition changes with a REST call.

What is left for a process to do is the claim loop and nothing else, which is
the whole extension API:

```python
from percolate_core.worker import handler, run

@handler("transcode")
async def transcode(spec, ctx):
    return {"duration": await ffmpeg(ctx["run_input"]["file_key"])}

run(queue="media")
```

Two differences from what was specified, both consequences of the move:

- **A handler is registered against a step KIND, not a step key.** There is no
  `step_key -> function` dispatch table, because the step keys belong to a
  definition the worker never reads. `work` steps name their handler in the
  spec; every other kind the worker serves (`http_call`) it ships with.
- **No decorator walk, no spec upsert, no startup registration of any kind.**
  A worker that has never seen a definition can serve every queue in it.

Built in `percolate-core`: the claim loop scoped to declared queues, and
artifact offload and registration (`PUT` the bytes, then
`workflow.register_artifact` — both halves, now; this section said the worker
half was missing and it has since landed), and the heartbeat: the worker calls
`workflow.heartbeat_task` while a long task runs, so the lease is held alive by
a running worker rather than recovered by `reap_stale_tasks` on expiry.
**Still not built:** OTel span creation as a child of `workflow.runs.trace_id`.

Registering scheduled workflows is explicitly **not** on that list either.
This section used to end "register scheduled workflows with `pg_cron`", which
put scheduling in the harness and one `cron.job` row per schedule. §12b below
replaces both halves: a schedule is a row in `workflow.schedules`, created by
an ordinary REST call, and `pg_cron` runs one job for the whole system.

**Decision task contract (enforced by convention + runtime hash check, not by the DB
sandboxing the function):** a function registered as `kind='decision'` may only read its
recorded input and return branch/fan-out instructions. No network calls, no wall-clock
reads, no fresh random IDs — all such values must come from the recorded input snapshot.
Violating this doesn't fail immediately; it fails the first time the decision
re-executes and produces a different output hash than what was recorded.

## 6. Saga / compensation

Each work task may declare a `saga_group` and a `compensation_task_key`. On a terminal
failure within that saga group, `begin_compensation(run_id, saga_group)`:
1. Finds every `done` task in the group with an undone compensation, ordered by
   `completed_at DESC` (reverse/LIFO — the saga-theory default).
2. Enqueues each as an ordinary `work` task, chained via `depends_on` so they execute
   strictly in sequence even though the underlying queue is concurrent.
3. Compensation task functions **must be idempotent** — they may be retried, and (by
   saga semantics) may run even when there's nothing to undo, so they must no-op safely
   in that case.

This is deliberately the differentiator versus the closest prior art: DBOS and River
both leave compensation as hand-rolled application code; there is essentially no
established open-source pattern for first-class saga compensation on a `SKIP LOCKED`
Postgres queue. Compensations get retries, backoff, and audit trail for free because
they're ordinary tasks, not a separate mechanism.

## 7. Scaling design (assumed worst case, not deferred)

Target: tens of thousands of task completions/sec, millions of live tasks, thousands of
KEDA-scaled pods.

- **Partitioning**: `tasks` partitioned by `created_at` (`pg_partman`); `done`/`failed`
  rows rotated to cold partitions continuously.
- **Audit log off the hot path**: plan to move `task_events` from synchronous
  trigger-insert to WAL-based CDC once write volume makes doubling writes matter.
- **Batch claiming**: `claim_tasks(queue, worker_id, batch_size)` — one round trip
  for up to `batch_size` tasks, and it consumes `rate_key` per task exactly as
  `claim_task` does. It did not, for as long as both existed: §21b moved the
  token bucket into the singular claim so throttling stopped being opt-in, and
  left the batch claim a bare `UPDATE`, so the throughput path handed out every
  throttled task at once. Recipe 1 below combines the bucket, lookahead-skip
  claiming and batching in one pipeline, so they were always meant to compose.
- **Connection pooling (PgBouncer/pgcat)**: mandatory at this target, not deferrable.
- **NOTIFY fan-out**: a single relay process holds the one `LISTEN` connection and fans
  out over a broker, so thousands of pods never hold raw idle DB connections.
- **Single-primary ceiling**: if worst-case write volume exceeds one Postgres primary,
  the fork is Citus, sharded by `run_id`/tenant, queues pinned to shard-zones. Decide
  this explicitly before it's discovered under load.

## 8. Kubernetes / KEDA / affinity

**Specified in full in `pools.md`, with DDL in `pools.sql`.** This section stated the intent — one Deployment + ScaledObject per
queue, YAML generated rather than hand-authored — but named neither where
queues are declared nor what does the generating. Both now have an answer, and
it is worth stating here because it changed the shape of this section rather
than merely filling it in:

**A worker pool is a row.** A consumer declares an image, a resource shape and
scale bounds in `workflow.pools`; a manager process (`percolate-core`'s
`manager` subpackage) reconciles those rows into Deployments and
`ScaledObject`s in one namespace; KEDA scales each between 0 and N on that
pool's queue depth. Deleting the row — or setting `enabled = false` — removes
the Deployment. Nobody gets cluster credentials to do any of it. That makes the
deployment surface the same surface as everything else in this collection —
rows, RLS-scoped, reachable over PostgREST — rather than a second control plane
in YAML.

Two consequences for what this section previously said:

- **Affinity is declared, not parsed.** `pools.node_class` produces the
  `nodeAffinity` + toleration, rather than the manager splitting a
  resource-class segment out of a queue name. The
  `{step-group}:{resource-class}:{zone}` convention (§3) is unchanged and still
  a convention; it is no longer load-bearing for scheduling.
- **The queue is still the unit of routing, but the pool is the unit of
  deployment.** `workflow.pool_queues` binds them, with a primary key on
  `queue` so that at most one pool serves a queue — enforced in the database,
  because two ScaledObjects each computing a replica count from a depth the
  other is draining oscillates.

Unchanged and still true: data-locality affinity (if Citus) pins pods to the
zone their shard lives in with a startup healthcheck refusing to serve on
mismatch; spreading a queue's pods across nodes for blast-radius protection;
and pooler locality (a zone-local PgBouncer/pgcat per shard-zone) matching
worker affinity, since otherwise the cross-AZ hop just moves from worker→DB to
worker→pooler.

## 9. Observability

Two separate pillars, not one — metrics and traces answer different questions and
use different infra, and the rule is to emit OpenTelemetry rather than a bespoke
format:

- **Metrics**: `postgres_exporter` custom queries against
  `v_queue_depth`/`v_run_progress` → Prometheus → Grafana, no custom code.
  `v_stuck_tasks` (age-based, per-queue timeout aware via `queue_config`) feeds
  Alertmanager. `v_compensation_status` and `v_decision_history` are the saga and
  replay observability surfaces, respectively — both just SQL, no new tooling.
- **Traces**: `workflow_runs.trace_id` (W3C format, one per run, propagated from an
  already-traced caller via `start_workflow`'s `p_trace_id` param when one exists)
  and `tasks.span_id`/`parent_span_id` (W3C format, one span per task, wired at
  creation time) link a run's steps into one real distributed trace across pods
  that never talk to each other directly — not just a shared free-text ID for
  humans to `WHERE trace_id = ...` by, but data actually shaped to export as OTel
  spans without translation. The export step itself is a real, separate piece of
  infra (an OTel Collector, or a worker in the same KEDA-scaled pool, reading
  `tasks`/`task_events` and emitting OTLP) — Postgres can't speak OTLP itself.

## 10. Minimum infra footprint

Must have: Postgres, PgBouncer/pgcat, KEDA + postgres scaler, S3,
`postgres_exporter` + Prometheus/Grafana.
Deferred until needed: NOTIFY→broker relay, PostgREST, Citus.

`pg_cron` has moved off the "must have" line, and the demotion is the point of
§12b: it drives one job, so anything that calls `workflow.tick()` once a minute
substitutes for it exactly — an operator, a KEDA-scaled pod, a `while sleep
60`. It is what this deployment happens to use (and it does now build on PG19,
via `dev/patches/pg_cron-pg19.patch`), not something the design requires.

Consumer-declared pools (§8, `pools.md`) add nothing to that list: the manager
is the image already deployed under a different command, and KEDA + the postgres
scaler were already required. They add no Kubernetes version floor either —
deploying every pool into one known namespace keeps the manager's access to an
ordinary namespaced `Role`, with no admission-policy machinery and so no
dependency on a recent API (`pools.md` §7.1).

## 11. Test recipes (validate the design against)

1. **Rate-limited scraping/ingestion** — token-bucket rate limiter
   (`try_consume_rate_limit`), lookahead-skip claiming so one throttled source doesn't
   head-of-line-block a queue, batching sub-second I/O to keep round-trips proportional.
2. **GPU-bound AI pipeline** — resource-class + zone affinity, per-queue reaper timeout
   (`queue_config.stale_timeout`), cooperative cancel inside long steps via
   `heartbeat_task`'s boolean return.
3. **Complex dynamic DAG** — document processing with runtime-discovered fan-out
   (`add_task`), conditional branching via `decision`/`complete_decision_task`, fan-in
   via `pending_deps`, human-in-the-loop via `signal`/`signal_task`.

Worked code for all three landed in the suite rather than in the companion
`workflow_recipes.sql` this section used to promise: rate limiting in
`dev/tests/workflow/05-faults.sql` and `11-plan-graph.sql`, the cooperative
cancel and `decision`/`signal` halves in `06-recovery.sql`, runtime fan-out in
`04-matrix.sql`, and the human-in-the-loop shape end to end as a readable
walkthrough in `dev/examples/08-wait.sql`. Executed recipes beat a companion
file nobody runs, which is why the file was never written.

## 12. Known, deliberately deferred gaps

Not fixed in this version, called out so they're a decision rather than a surprise:

- **Generalized joins** (Discriminator, N-of-M, acyclic OR-join, Multi-Merge) — the
  current model is pure AND-join. Adding `join_type`/`join_threshold`/`join_arrivals`
  closes this in one change when a concrete use case needs it (second tier).
- **Cancel Region / Deferred Choice** — no cancellation-group primitive or
  first-to-claim race resolution yet. Needed once a use case requires "race two
  branches, cancel the loser" or "withdraw a whole cancelled region."
- ~~**Partial-failure tolerance over a fan-out**~~ — built: `continue_on:
  failed` and `min_success` on a `matrix` step (`schema.sql` §21e). Without
  them a `matrix` step's successors are cancelled when any one child fails
  terminally, which is the pure AND-join above behaving as specified and wrong
  for the case fan-out exists to serve.
- **Aggregation over a fan-out** (`{{items.<step>}}` — the cross-step namespace,
  not §15b's per-child `{{items}}`, which is one task's own batch) — deliberately absent
  while the answer is "children write to a table, the successor is a `sql` step
  over it". Promote it on the second consumer that cannot be expressed that
  way.
- **Milestone pattern** (state-conditional enablement) and **exception-type coverage
  beyond work-item-failure/deadline-expiry** (external-trigger, constraint-violation
  exceptions with compensate/rollback recovery actions) — third tier; add only
  if scope expands to need them.

These are intentionally not implemented now — they were sequenced
into "ship now" (folded into this schema) vs. "add on demand" vs. "add only if scope
expands," and the two deferred tiers stay deferred until a real recipe needs them.

**This list is decisions, not a backlog.** Recursion, the reduce half of
map-reduce, token budgets in and out, and the run-scoped ceilings the same
argument produces are wants that no sentence in this spec commits to, and they
are kept apart so that neither list can be read as the other.

## 13. Usage metering — this module records the event, policy lives elsewhere

Every metered action in this stack (an LLM call, an external API hit, a storage
write) happens *inside a task*, and this module already appends an immutable
event per state transition (`workflow.task_events`), so a task's cost belongs
beside the task rather than on a second instrumentation path. Measured model
usage from a scheduled agent run is recorded by the runtime through
`claims.record_execution_result`, against the verified task, lease holder and
attempt (`core/README.md`). This module never enforces a quota, the same way it
never enforces a permission. A rollup by owner over `workflow.runs.owner_id`,
and any quota check that would read it, are not built.

## 14. Precedent check: Microsoft's `pg_durable` — build our own for now, documented as a possible future swap-in

Real overlap of intent (durable execution as a Postgres-native primitive, checkpointed
steps, fan-out, timers) is worth checking against seriously, not dismissed on
vibes — checked directly against its actual README and architecture doc, across
several rounds of being challenged and corrected on the details, not a single
surface-level pass. Verdict: **build this module on its own foundation, learn
its real issues firsthand, keep `pg_durable` as a named, documented candidate to
swap in or converge toward later, not adopted now.**

**The principles are genuinely, independently convergent — not superficially.**
`pg_durable`'s README states its philosophy directly:

- *"No external infrastructure... no Redis, no Temporal, no external
  services"* / *"Compute close to data"* — the same instinct as this whole
  collection's "can this be a SQL function?" default (`specs/README.md`) and
  this module's own "No separate control-plane service" (§1).
- *"Durable — Function state persists to PostgreSQL. Survives crashes,
  restarts, and failovers"* — the same property this module's checkpointed
  `tasks`/`task_events`/`SKIP LOCKED` claiming model exists to guarantee.
- *"If a step needs arbitrary code... expose it behind an HTTP endpoint for
  `df.http()`"* — the same idea as this module's `http_call` task kind below:
  anything that isn't native SQL logic gets dispatched out to an HTTP-callable
  service, not hand-rolled inside the orchestrator. Two systems reasoning from
  the same constraint (Postgres can't run arbitrary code or call out itself)
  landed on the same answer independently.

And the shape of *this* collection's actual usage matches `pg_durable`'s own
intended pattern more closely than an earlier pass here concluded, not less: in
this collection, an LLM/agent call is a single `http_call` step dispatched from
a workflow whose steps, dependencies, and state all live entirely in
Postgres — exactly the "declaratively define agents and flows in data"
shape `pg_durable`'s own `df.http()` targets, and matching one of `pg_durable`'s
own named use cases (chunk data, call an embedding API, upsert into `pgvector`)
almost exactly. An earlier draft of this section read `pg_durable`'s own
"when NOT to use this" line — *"the workflow mostly lives outside Postgres and
spans many heterogeneous systems"* — as excluding this module's own use case.
That was wrong, corrected directly: that line describes a workflow whose
*orchestration* lives outside Postgres and merely touches it, not a
Postgres-native, data-defined workflow that dispatches individual steps out via
HTTP. This module is the latter. Retracted rather than left standing.

**What actually still supports building our own, once the wrong argument is
removed:**

- **Concrete missing primitives**, not a vague capability gap: no
  saga/compensation (this schema's own history calls it "the single largest
  capability gap found versus DBOS/River/Temporal" — the product of this
  module's own workflow-theory research pass; `pg_durable` doesn't have it at
  all), no queue/affinity routing, no rate limiting, no human-in-the-loop
  signals, no static spec validation. These are specific, already-researched
  gaps, not a hand-wave.
- **Preview status, no committed roadmap.** Explicitly "do not use it in
  production" (stated in `pg_durable`'s own Docker image); no GA date or
  stability timeline found anywhere for `pg_durable` itself (only that PG19
  targets GA ~Sept–Oct 2026, a different project). Plausible to mature given
  real product motivation (Azure HorizonDB uses it) — not something to plan a
  6-month build around without a source to point to.
- **The execution-model question is genuinely open, not resolved either way.**
  `pg_durable` runs one Postgres background worker *process* — but that
  process is async (`duroxide` on `tokio`), so many activities including its
  built-in `execute-http` can be concurrently in-flight within it, not strictly
  sequential the way an earlier pass here first assumed. If real compute is
  dispatched out via HTTP to an already-horizontally-scaled fleet (exactly
  this module's `http_call` pattern), a single async orchestrator dispatching
  and checkpointing is a legitimate, ordinary pattern, not an obvious
  bottleneck. What's still missing either way: no published concurrency limit
  or throughput number for that process, from `pg_durable` or from this
  module's own KEDA-pod design — neither side of this comparison is
  benchmarked, so this stays a real open question, not a settled point in
  either direction.

**Worth taking as inspiration, unrelated to the adopt/don't-adopt question**:
`pg_durable`'s underlying runtime (`duroxide`) does genuine **deterministic
replay** for its decision/branching steps — a stronger correctness guarantee
than this module's own `decision`-task determinism guard (schema §1b/§3, a
hash-comparison check on re-execution, deliberately chosen *to avoid* needing a
full replay engine). Worth a real future evaluation of whether hash-comparison
catches everything a true replay engine would, now that a concrete example of
"the more rigorous version" exists to compare against — an open question to
track, not an action to take now.

This section states where the evaluation landed after being built, challenged,
and corrected across several rounds against `pg_durable`'s actual documentation
— not a first-draft take.

**So: take the pattern, not the dependency — designed now, needed now, not
deferred.** `http_call` is a real `tasks.kind` (schema §3), and needs no new
SQL functions at all: `claim_task` already claims by `queue` regardless of
`kind`, and `complete_task`/`fail_task` already do exactly what a callback
needs. The whole design is a data convention on columns that already exist:

- **`input`** carries the call spec: `{"url", "method", "headers"?,
  "credential_ref"?, "body"?, "timeout_ms"?, "mode": "sync" | "async"}`.
  `credential_ref` names a credential the executor resolves from *its own*
  environment/secret store — never a literal secret stored in the row, same
  "Postgres never holds outbound-call secrets" boundary `user-rbac`'s OAuth
  exchange and `agentic`'s LLM credentials already respect.
- **A built-in `http_call` handler on the standard worker** — infrastructure,
  not per-consumer code, and deliberately NOT a separate process. `percolate
  worker` (`percolate_core.worker`) is the one worker a deployment runs; `http_call` is a handler
  registered on it, and a user adds their own step kinds with a
  `@handler("kind")` decorator on the same loop rather than deploying a second
  service. No workflow author ever writes worker code for an `http_call` step
  — that's the entire point. (pg_durable makes the opposite choice, executing
  `df.http()` inside a Postgres background worker. We don't, because doing so
  needs an HTTP client extension in the database, grants the database outbound
  egress, and removes no process since a worker is running anyway.)
- **`mode: "sync"`** (the common case: a quick call, response needed
  immediately) — the executor awaits the response within `input.timeout_ms`,
  writes it to `output`, and calls `complete_task`/`fail_task` itself,
  exactly like any other task kind's worker would.
- **`mode: "async"`** — for calls that kick off real work rather than
  returning a result directly (an agent run that takes many LLM round trips).
  The executor makes the *dispatch* call (still retried, and bounded by
  `timeout_ms`, like a sync call) and does not complete the task. The callee —
  typically `agentic`'s runtime, since a `workflow_task_id` is included in the
  dispatch body so it can — calls `complete_task(task_id, output)` or
  `fail_task` itself once the work is done, on a login that is a member of
  `worker`, the only role those two functions are granted to. `agentic`'s
  runtime holds that login as `P8_WORKER_DSN` (`core/README.md`). No
  new "async HTTP" concept: dispatch is a task like any other, completion is a
  callback like any other.

  **What is built: the worker holds the lease while it waits.** After a 2xx
  dispatch the task stays `running` under the dispatching worker, which keeps
  calling `heartbeat_task` at a third of the queue's stale timeout, so the
  reaper does not re-dispatch work that outlasts `stale_timeout`. On extension
  0.2.0 `worker` cannot read that timeout: `queue_stale_timeout` is not
  `security definer`, and as `worker` it fails with "permission denied for
  function stale_timeout_default". The worker falls back to a third of the
  2-minute default, so a queue configured below about 80 seconds is reaped
  during the hold — as is any long handler on such a queue. Extension 0.2.1
  makes `queue_stale_timeout` `security definer`, so `worker` can call it and
  the heartbeat paces from the queue's own `stale_timeout`. It stops, and
  writes nothing, when `heartbeat_task` returns false: the callee finished the
  task, the reaper took the lease, or the run was cancelled. The wait is
  bounded by the step's `wait_ms` (15 minutes by default); past it the worker
  fails the task terminally, so a callee that never answers cannot hold the
  worker forever. The cost is a worker slot for the length of the external
  work, and a `percolate worker` process runs one task at a time.

  **Not yet built: parking in `waiting_external`.** Measured on extension
  0.2.0: no function granted to `worker` parks an `http_call` task, and once a
  claimed task is `waiting_external` the lease fence (§23 of `schema.sql`)
  refuses the callee's `complete_task` — "the lease was revoked -- task is
  waiting_external after 1 attempt(s)" — and the run stays `running`. The
  requirement stands, and it is the reason to build parking: an external wait
  should not occupy a worker slot. Building it needs a lease-checked park that
  `worker` may call, and a fence that admits completion of a parked task.

**This also settles how a scheduled agent run starts.** `agentic.runs.workflow_task_id`
is the link back to the triggering task; the start is: `workflow-engine`
dispatches a `mode: "async"` `http_call` task targeting the agent runtime's
internal trigger endpoint (not the public AG-UI surface), the runtime creates
the `runs` row and executes, and calls `complete_task` on the originating task
once the run (and any `chained_action` it triggers) finishes. Consolidation,
a knowledge-base refresh, and an iterated deep-research pattern all use the
exact same mechanism —
none of them needed a bespoke integration, because dispatch is a row and
completion is the `complete_task` call every worker makes. The end-to-end
check this section first recorded (dispatch → `waiting_external` →
`complete_task` → run completion) predates the lease fence and no longer
holds; see "Not yet built" above. The worker is `percolate-core`'s
`worker/http.py` and `worker/loop.py`.


## 12b. Scheduling — a scheduled workflow is a row

*Numbered 12b, not 12: this section was appended after §12 above and took its
number, so for a while the file had two §12s and the cross-references stopped
saying which. Sub-lettering is what `schema.sql` already does (§21c, §21g) for
a section that arrives after its neighbours are numbered.*

Implemented in `schema.sql` §19; tested in `dev/tests/workflow/02-schedules.sql`
(the logic, with the clock driven by the test) and `03-cron-tick.sql` (that
something is really calling it, against a running stack).

§7 above said "register scheduled workflows with `pg_cron`" and left the shape
open. Filling it in changed the shape rather than confirming it, so the
reasoning is recorded here rather than in a comment.

**One `pg_cron` job, not one per schedule.**

```sql
select cron.schedule('workflow-tick', '* * * * *', $$select workflow.tick()$$);
```

Registering a cron job per schedule was the obvious design and is the wrong
one here, for three reasons that only appear once you try it:

- `cron.job` is a catalogue table belonging to another extension. It has no
  `org_id` and no owner, so a scheduled workflow could not be RLS-scoped, and
  "list my schedules" would mean reading a table every tenant shares.
- Creating one needs rights on the `cron` schema, so adding a schedule could
  never be an ordinary authenticated REST call — which is exactly what a user
  wants it to be.
- It is a second copy of state. `cron.job` plus whatever row we kept beside it
  is precisely the drift this collection keeps paying for.

**The REST surface**, reached through PostgREST with `Content-Profile:
workflow`, is three functions:

```bash
curl -X POST localhost:3000/rpc/schedule_workflow \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Profile: workflow' \
  -H 'Content-Type: application/json' \
  -d '{"p_name":"nightly-reconcile","p_workflow":"content_reconcile",
       "p_cron":"0 3 * * *","p_timezone":"America/New_York"}'
```

plus `set_schedule_enabled` (reversible) and `unschedule_workflow`
(destructive). Reads are `GET /schedules_api`, RLS-scoped like every other
read path. All three are `SECURITY DEFINER` and therefore do their own
authorization — the rule §16's header states and that `cancel_run` was
confirmed exploitable for. A user may create their own schedules and touch
only their own; the check is asserted from a simulated PostgREST connection in
`02-schedules.sql`, because a test that merely `SET ROLE`s passes while
checking nothing.

**Matching, not next-run computation.** `cron_matches(expr, ts, tz)` answers
"does this instant match?", and `tick()` asks once a minute — which is what
cron itself does. A `next_run_at` column would be a cached derivation that
every path editing a schedule has to recompute correctly, and that a DST
boundary or a timezone edit silently invalidates. There is nothing to keep in
sync here.

Two details worth knowing because they are surprising and deliberate:

- **Vixie cron's day rule is reproduced, not fixed.** When *both* day-of-month
  and day-of-week are restricted, either matching fires: `0 0 13 * 5` is the
  13th **or** any Friday. Implementing the intuitive AND would make every
  expression copied out of a crontab mean something different here.
- **The timezone is the schedule's.** "Every weekday at 09:00" is a statement
  about somebody's morning, and a scheduler that silently means 09:00 UTC is
  wrong in a way nobody notices until a report lands at 4am.
- **An appointment survives daylight saving; a poll rides it.** Two mornings a
  year, local time is not a function of the UTC minute, and matching on the
  UTC minute alone gets both of them wrong. Measured on a live database before
  this rule existed: `30 1 * * *` in `America/New_York` started **two** runs on
  2026-11-01, because 05:30Z and 06:30Z are both 01:30 local and the
  `external_id` carries the UTC minute; `30 2 * * *` started **none** on
  2026-03-08, because 01:59 local is followed by 03:00 local and 02:30 never
  happens. Neither raised anything.

  The rule is Vixie cron's own distinction, and
  `workflow.cron_is_wall_clock()` carries it. A **poll** — `*` or `*/n` in the
  hour field — rides the transition unchanged: a repeated hour is an extra
  hour of polling and a skipped one is an hour less, which is what "every five
  minutes" means. An **appointment** — any other hour field — fires exactly
  once per local wall-clock minute, and a minute the clock jumped over fires
  at the first tick after the jump. A ticker that was merely *down* is not the
  same event and is deliberately not caught up: local and UTC advance
  together across an outage, and they do not across a transition, which is how
  `tick()` tells them apart. Driven a minute at a time across both real
  transitions in `02-schedules.sql`.

**What a schedule does *not* get is a second execution engine.** `tick()`
calls `start_workflow()` like any other caller, so retry, backoff, the reaper,
saga compensation, cancellation and tracing all apply unchanged. The fire is
made idempotent by the engine's own `external_id` — `schedule:<name>:<minute>`
— rather than by a new mechanism, so two overlapping tickers cannot
double-start a run. That survives the key being scoped to its caller (§4)
because the ticker has no identity to be scoped by: it runs as `scheduler`
with no JWT, matches every run under the key, and is authorized by the grant.
It has to — §21j stamps the *schedule's* owner onto the run after the fire, so
by the next tick the run belongs to a person the ticker is not, and a ticker
held to that person's scope would start the second run for the same minute
that this key exists to prevent. `overlap_policy = 'skip'` (the default) additionally
refuses to start a run while the schedule's previous one is still running,
which is the overlapping-poll problem solved once here rather than per
pipeline.

A schedule that cannot fire says so on its own row: a missing definition or a
bad input leaves `last_error`/`last_error_at` set and does not stop the other
schedules in the same tick. `last_tick_at` (evaluated) and `last_fired_at`
(started a run) are separate columns, because "the ticker is dead" and "this
schedule is being skipped every minute" are different problems that a single
column makes identical.

## 15. Matrix fan-out — the work to do is a query result

Implemented in `schema.sql` §20; tested in `dev/tests/workflow/04-matrix.sql`,
which drives every assertion below against a live database.

This is the Argo Workflows `withParam` shape, and the reason to state it as a
design decision rather than a feature is that **the difference is a transaction
boundary, not syntax.** Argo expands a matrix by having a controller pod read a
JSON array out of a previous step's output and template one pod per element:
three processes and a serialisation round trip before any real work starts, and
a window in which the emitting step is `done` and its children do not exist, so
a controller crash strands the fan-out.

Both halves of the alternative were already here. `schema.sql` §17's `sql` steps run a query
with no process; §4's `complete_decision_task` atomically completes a task and
inserts the tasks it decided on. `workflow.expand_matrix` is those two facts in
one function, and the invariant it buys is the one Argo cannot state: **the
parent cannot be `done` while its children are missing, because they are
inserted by the statement that completes it.**

Authoring syntax and the full rationale are in `YAML.md`. What belongs here is
the four things that changed the engine, each of which was found by running it.

**1. The AND-join is not free.** The design note this was built from claimed
`pending_deps` already handled fan-in. It does not: a successor declares
`depends_on: [fan]`, so its one edge points at the *matrix* task, which
completes at expansion time. An aggregate would fire instantly over nothing and
the run would report `completed` — this collection's worst failure shape.
Expansion therefore rewires every successor onto the children (edge each,
`pending_deps` incremented) *before* completing the parent; the cascade then
decrements the original edge, leaving exactly N. Zero children leaves zero,
which correctly releases the successor — a polling pipeline finding nothing new
is the normal case, not an incident.

**2. The row set is recorded on the children, not in the parent's output.** A
matrix is a `decision` task in §3's sense — pure with respect to a recorded
snapshot — and a query over live tables is not pure. The resolution is that the
row set *is* the snapshot; the correction is where it lives. Five thousand rows
do not fit under §7's payload cap, so the parent records a digest (count and
hash) and each row is stored on the child it produced, individually inside the
cap by construction. `matrix_rows()` reads them back. Re-expansion against a
changed row set is refused by name, reusing `decision_output_hash` unchanged;
an identical re-expansion is a no-op.

**3. Fan-out children stay out of `runs.context`.** `complete_task` merges
every output into one JSONB column on the run, rewritten in full per
completion. At N children that is N rewrites of a value that grows to N
outputs — quadratic write amplification on the hottest path in this schema —
and nothing could read it usefully anyway, since `fan[0]`, `fan[1]` … are not
names an author writes. The consequence is deliberate and limiting: there is no
aggregation namespace, and a successor that needs the results reads the
children's rows, typically as a `sql` step over a domain table they wrote to.

**4. A task that completes twice must not decrement twice.** Not a matrix bug;
found by the matrix re-expansion test. `pending_deps` is decremented on the
transition *into* `done`, and the `done → ready` transition never re-increments
it, so a second decrement is always wrong — it would release a successor early,
over an incomplete fan-out, in a run reporting success.
`cascade_task_status` now keys off `completed_at`, which is null only on a
first completion. This was reachable before matrix steps existed; nothing took
the path.

### The guard rails, and why there are three

`max_fanout` is mandatory. A three-way cross join with a forgotten `WHERE`
inserts the cartesian product as task rows, and the ceiling has to fail the
task rather than the database. It is checked in the compiler (authoring time,
with the step id in the message), in `validate_matrix_steps` (registration
time, because a spec can arrive as JSON without passing through the compiler),
and at expansion time before a single child exists — terminally, since it will
fail identically on every retry.

Rows come from a **query or a registered function**. This section used to say
*never inline SQL*, on the reasoning that expansion is `SECURITY DEFINER` and a
step supplying a statement is a privilege-escalation primitive with a YAML front
end. That describes what happens and is no longer the rule: `percolate.sql_policy`
defaults to `open`, a step may carry its own SQL, and a matrix may fan out over
`rows: "select id from documents where processed_at is null"` — the most natural
thing anyone writes here. A row source is always read-only whatever the step
says, `rows: {function, args}` remains and is what `sql_policy = 'registered'`
restricts you to, and `items: [...]` still covers the static case. See
[YAML.md](YAML.md#a-step-may-carry-its-own-sql) for the trade.

Nested fan-out is **rejected**, not supported-but-buggy: a child has no static
successors to rewire, so grandchildren would never be joined to anything and
the run would complete before they finished.

### What running it changed

The four points above were written from the design. Then the worked example was
run for real — three filers × two XBRL concepts against `data.sec.gov`, through
the live worker — and three of them were wrong. They are corrected above rather
than annotated, and recorded here because the corrections are the useful part.

**`{{item.*}}` moved from dispatch to expansion.** The design deferred it, on
the Templates rule that author-time resolution makes a recorded input a lie.
All six children then failed with `unknown template namespace 'item' --
expected steps, run or env`, which is the **worker's** error: deferring had put
`item` into the contract of a shipped image that knows three namespaces, so the
headline case did not work and only `sql` children had ever been exercised. The
rule was also misapplied — it governs a stored *definition*, shared across
runs; a fan-out child exists for one row, so substituting it makes the recorded
input say exactly what will be sent. Now a worker never learns a task was
fanned out.

**The fan-in was unreachable, and the note explaining why it was fine was
false.** The matrix output was a bare object, so `{{steps.fan.result}}` — the
idiom every other kind teaches — resolved to nothing. And it carried no way to
find the children. The claim that no aggregation was needed because "children
write to a domain table and the successor is a `sql` step over it" holds for
`work` children and not for `rest` ones, which are the entire worked example: a
generic worker records a response and knows no domain. The output is now
`{"result": {task_id, fanout, rows_hash, source}}`, and `matrix_outputs()` —
allow-listed, scoped to the executing run — pairs each child's row with its
output.

**An unstorable output was retried.** One ordinary XBRL response came back at
69,248 bytes against the 64KB cap and was retried four times with exponential
backoff, re-fetching a public API each time, on a failure byte-identical every
attempt. The worker cannot classify it — the HTTP call succeeded — so the
engine now does, terminally, with the remedy in the message.

### Batching — the granularity had to be declarable (§15b)

`schema.sql` §20j; tested in `dev/tests/workflow/10-batching.sql`.

The map half shipped with exactly one granularity — one row, one task — and
that is a property of the *work*, not of fan-out. A row that is an HTTP call to
someone else's API is a concurrency unit and should be a task. A row that is a
four-millisecond database write is not: a hundred of them become a hundred
claims, heartbeats, completions and cascade cycles, and the engine costs more
than the job. The only way to express "ten workers, ten rows each" was to make
the row function return chunks, which moves a scheduling decision into a domain
query where no reader of either can see it.

So the step declares it: `batch_size` caps rows per child, `partition_by` names
columns whose rows must not be split across children, and together they
partition first and cap within each partition. Four things this had to get
right, and each is an assertion in the test:

1. **The child's shape says how many rows it owns** — `items` and `batch`
   instead of `item`. Always emitting an array, one element wide when
   unbatched, would be the smaller rule and would make every existing handler
   and fan-in unwrap something to find a row that used to be right there.
2. **`{{items}}` binds at expansion**, beside `{{item.*}}` and for the reason
   §15's reversal established: a batched `rest` child POSTing ten records as a
   body is the headline case, and resolving it at dispatch would put a fourth
   namespace into the contract of a worker image that knows three.
3. **`{{item.<col>}}` survives on a batch only for a column constant across
   it** — which is exactly what `partition_by` manufactures, and is why it is a
   partition rather than a sort. A varying column fails the step before any
   child exists; substituting the first row's value would produce a task that
   processes fifty rows and addresses one of them, and would pass every test
   written at a batch size of one.
4. **`max_fanout` still counts rows.** Counting children instead would let
   `batch_size: 1000` walk a five-million-row cross join past a ceiling of
   5,000.

What it costs is stated rather than discovered: `continue_on`/`min_success`
count children, so a batch is now the unit of blast radius as well as of work;
retries re-do a whole batch, making idempotence a precondition; and `batch_size`
is the one number in a spec that directly multiplies a stored payload, so
expansion checks the cap itself and names that number as the remedy.

### The known sharp edge, now measured

**One failed child cancelled the successors**, until `continue_on: failed` and
`min_success` were built. This was not a hypothetical about the fourth thousand: the
*first* realistic run, six children wide, lost one to a 404 because Amazon does
not tag `us-gaap:Revenues`, and the aggregate was cancelled. A matrix over real
registries will hit an absent concept, a rate limit or an oversized response on
essentially every run, so partial-failure tolerance is not a refinement of this
feature — it is the difference between having it and not.

Two other gaps the same run exposed, both real and both outside this section:
§7's offload to object storage had no database half at all, so a large response
had no path but a bigger cap — both halves are now built (`register_artifact`,
the `$artifact` ref, the worker's `PUT`; `outputs.md`); and the worker stored its `http_call`
output as a **JSON string containing JSON** rather than an object, so
`{{steps.<id>.result}}` resolves to nothing against any REST step and every SQL
consumer must decode it first. That one is a worker-contract defect — this
schema's `complete_task(uuid, jsonb)` and the whole `{{steps.*}}` design assume
an object — and it is worth an engine-side guard, because an output nothing can
navigate produces an empty answer in a run that reports success.

## 16. Twelve faults, and what closing them changed

`schema.sql` §21; asserted in `dev/tests/workflow/05-faults.sql`. §15 recorded
what running the matrix design changed. This records what running *five more*
pipelines changed — and the pattern is sharper than any individual fault.

**Every one of the twelve sat outside the transaction.** The task graph never
misbehaved under 256 tasks of live traffic. What failed was the authoring
surface, the worker contract, saga, and the authorization model — the parts
furthest from the one place this system is strong. That is worth stating as a
design finding rather than a tally: the transactional core earns its keep, and
the things bolted to its edges had been specified and never exercised.

**The most expensive fault was a contract written in prose.** The worker stored
its `http_call` output as a JSON string containing JSON. Nothing enforced
otherwise, so `{{steps.<id>.result}}` — the one idiom every step kind teaches —
resolved to nothing against every REST step, and chaining anything to a fetch
was impossible as documented. It also raised the question of whether
`http_call` should become fire-and-forget async. It should not: the invariant
that matters is that the *database* never blocks on someone else's latency, and
the worker blocking satisfies it while keeping retry, backoff, the reaper and
saga applicable because the call is an ordinary task. A callback model would
need a correlation key and a policy for the callback that never arrives — a
second execution path re-earning each of those. The defect was never
sync-versus-async; it was that the contract was enforced nowhere. It is
enforced now: a double-encoded output is repaired, and the repair is *recorded*
(`workflow.encoding_drift()`), because silent leniency is how a contract rots.

**Three features read as configured and were not.** `rate_key` was compiled,
stored on every task, and consumed by nothing — a fan-out ran at 12.9 req/s
against a published 10/s ceiling believing it was throttled. Saga compensation,
this file's stated differentiator, was broken in five independent ways and had
never been run through the compiler. `signal`, `timer` and `sub_workflow` were
legal engine kinds unreachable from YAML, and `sub_workflow` had never executed
at all. A capability that reads as done is worse than a missing one, because
nobody goes looking.

**`min_success` is a transport floor, not a content one.** A 200 carrying an
empty body counts as a success. The engine cannot know what useful means;
`matrix_outputs` returns every child's status so the aggregate can say so
itself. Stated because it is exactly the kind of thing that looks like a
guarantee and is not.

**What a capability document must be derived from.** `SCHEMA "workflow"`
derived its `step_kinds` from the engine's check constraint — true about the
engine, false about what anyone can write. Deriving from the catalog protects
against drift; it does not protect against describing the wrong layer. It now
reports `authorable_in_yaml` alongside `step_kinds`, with anything in the
difference named as reachable only by inserting JSON.

### Testing failures on purpose

A fault-injection service belongs in the dev stack: every failure this
collection hit in real traffic, on demand, at a URL. A workflow that
handles a 429 correctly is untested until something returns a 429, and getting
one from a real API is unreliable, slow and rude. Each route reproduces an
observed failure and says which — that is the selection rule, not a catalogue
of everything HTTP can do.

### Reported by someone building on it

`schema.sql` §22. An 18-task brief generator ran end to end and needed three
workarounds, which is the most useful kind of report: the workarounds *are* the
findings. All three are closed, and one of them was closed twice.

**The run could not see itself.** `{{run.*}} `read only the run input, so
`runs.id` was unreachable from a template — and could not be passed in either,
because the caller does not know it until `start_workflow` returns. Eight of
eighteen tasks failed. Engine fields now live under a reserved `$` prefix, and
`{{run.id}}` says what to write instead.

**The fix worked in half the engine, silently.** Probing rather than assuming
showed the worker's template pattern does not admit `$` — so `{{run.$id}}`
resolved in `sql` steps and was sent as a literal string in `rest` and `agent`
ones. A session threaded that way looks exactly like success. `{{run.$*}}` is
now bound before dispatch, on the same principle as `{{item.*}}`: if the worker
cannot know a namespace, the engine binds it.

**Registration checked the wrong role.** `to_regprocedure` resolves with the
*caller's* privileges while `execute_sql_step` runs as the *definer's*, so
registering as a superuser always succeeded and every invocation failed with
`permission denied for schema …` — naming the schema, not the registration.

**The halves can ship out of step.** A `matrix:` step that `YAML.md` documents
in full failed with a syntax complaint, because the SQL half had shipped and
the compiled parser had not. `workflow.compiler_capabilities()` now probes the
installed compiler with a canary per feature, and `define_yaml` names a version
skew as one. Worth noting that "it compiled" is not evidence a feature exists —
a deserialiser silently drops keys it does not know — so the probe checks the
emitted spec, not the absence of an error.

**And the version-skew fix was itself half-blind.** The first version checked
only the *failure* branch, which catches every missing step kind — those fail
loudly — and misses the one that matters. `output_schema` is not a kind, so
serde drops it, the document compiles clean, and the contract is absent at
runtime with a green run to reassure you. The reporter quoted this file's own
comment back at it: *compiling is not evidence — the emitted spec is*. The check
now runs on success too, `deny_unknown_fields` makes an unknown step key a
compile error, and agent-only keys are refused on other kinds.

That is the third instance in this collection of the same failure: **a thing
that is silently dropped rather than refused.** `{{item.*}}` sent unresolved,
`rate_key` stored and never consumed, a contract compiled away. It is worth
naming as the house rule it implies — *if you cannot honour it, refuse it* — and
`failure-modes.md` §1 collects the class.

`failure-modes.md` collects the classes all of this belongs to, for the next
person.

### A note on this file's shape

`schema.sql` is append-only by convention: later definitions supersede earlier
ones, and the last definition of a name is the live one. That keeps each fix
next to the failure that motivated it, which is the point — but seventeen
functions are now defined more than once (`complete_task` five times), and a
reader fixing a bug has to know which copy is live. The clean-install check is
what keeps this honest, and consolidating the superseded definitions is real
debt, not a stylistic preference.

## 17. Who may start a workflow, and which org the run belongs to

**(a), (b) and (d) are built. (c) is half built and the other half is declined
on a measurement — see its section.** Written as a decision first,
because the build issue was blocked on it — and two of the four questions have
answers already implied by mechanisms this collection has and did not apply
here. What landed is in `integration-rbac.sql` section (e) and
`dev/tests/workflow/20-a-definition-is-somebodys.sql`; **(b), which org a run
belongs to, is REM-42** — whose remaining Done-when clauses are exactly (b) and
(c).

Two things in this section were wrong when it was written, and both are
corrected in place below rather than left for a reader to trip over: the
mechanism in (a), and the backfill in (d).

### What was true before this was built, measured

On the database `dev/ci-database.sh` builds, 2026-09-12, before the change:

- a plain `member` who owns nothing called `workflow.start_workflow` on a
  definition somebody else wrote, and it **succeeded**. `integration-rbac.sql`
  gates `define_yaml` (`may_define()`), `cancel_run` and `signal_task`
  (`assert_run_access`) — not `start_workflow`. Every definition is startable
  by every signed-in caller in every org, including the per-user
  `source_<id>` workflows `save_api_source` compiles.
- the resulting run was stamped `org = shared`, `visibility = private`,
  `owner_id` = the caller. The owner is right; the org is the deployment's
  shared tier regardless of which orgs the caller belongs to, which is why lake
  output from a run cannot be made org-visible.

`workflow.definitions` carries no `owner_id`, no `org_id` and no `visibility`.
That is the root: there is nothing on the row for an authorization check to
read, so no check can be written until the columns exist.

### (a) Who may start one

**Visibility on the definition, through `rbac.add_scope_columns`, not a new
permission.** The collection already has the primitive — one call adds
`org_id`, `visibility` and the trigger, and `rbac.add_scope_policy` generates
the row predicate from `rbac.scope_predicate()` so it cannot drift from the
fourteen tables already using it. A `workflows:start` permission was the
alternative and is worse: a permission answers *may this kind of caller start
workflows*, and the question here is *may this caller start THIS workflow*,
which is a row question. Permissions gate verbs; scope gates rows.

So: a caller may start a definition they can SELECT.

**But the policy cannot be what decides it, and the first version of this
paragraph said it was.** `start_workflow`, `start_child_workflow` and
`schedule_workflow` are all SECURITY DEFINER, and a definer function owned by
the table's owner does not see the table's policies at all. Measured on a
three-line reproduction, 2026-09-12: of two rows where a policy admits one, a
direct `select` returned 1, a SECURITY INVOKER function returned 1, and a
SECURITY DEFINER function returned **2**. `force row level security` brings it
back to 1 and is the wrong lever here — the engine's own definer paths
legitimately read every definition, including `define_yaml`'s `max(version)+1`
allocation and `seed_load`'s probe, so forcing the table would break the writer
to gate the reader.

What is built instead keeps the sentence true without a second *rule*:
`workflow.current_definition()` — which REM-58 already made the single answer
to "which version does this name mean" — filters by `workflow.may_start(d)`,
and that predicate is `rbac.is_operator() or rbac.may_read(owner_id, org_id,
visibility)`. `may_read()` is the policy's own expression as a function, and
its header says it exists for exactly this caller: "what a SECURITY DEFINER
function calls, once, about one row it has already fetched". So there is one
rule with two spellings that cannot drift, rather than two rules.

Three consequences worth stating, because each is a way a working-looking
version of this gets it wrong:

- **The filter goes inside the version resolution, not after it.** Filter after
  `order by version desc` and a caller who reuses somebody's workflow name
  takes the higher version, and the original author is handed that row and then
  refused it — their own workflow disappears because somebody else reused the
  name.
- **`is_operator()` is load-bearing, not defensive.** `worker` and `scheduler`
  hold no JWT, so `may_read()` alone answers false for anything not public —
  and `start_child_workflow` resolves as `worker` while the clock resolves as
  `scheduler`. Without that arm, marking a workflow private silently stops its
  own sub-workflows and its own schedule, and for a scheduler a job that
  resolves nothing is indistinguishable from nothing being due.
- **Authoring is still a separate authority.** `may_define()` asks for
  `workflows:update`; this section is only about starting. The seeded role set
  has no role that may author without also holding the new
  `workflow_definitions:select` override, which is correct for `admin` and is
  why the test defines a role of its own.

**The refusal says which of the two it is**, because "no such workflow" and
"not yours" are different problems for the caller and the same SQL:

```
ERROR:  no workflow definition named 'x' is visible to you
HINT:   it may not exist, or it may belong to an org you are not a member of
```

Deliberately one message for both. Distinguishing them tells an unauthorised
caller that a name exists, which is the probe `may_invoke` closed for agents,
and the same reasoning applies here.

### (b) Which org the run belongs to

**Built — REM-42.** `workflow.set_run_owner()` derives it, and
`dev/tests/workflow/21-a-run-belongs-to-its-definitions-org.sql` asserts the
five claims that make it a tenancy rule rather than a copied column.

Two things the implementation added that this section did not say, both because
a version without them looks correct:

- **Only when the run is still on the shared tier**, so an org supplied
  explicitly survives. `rbac.is_shared_org()` is the test rather than `is
  null`, because the column is NOT NULL with the shared sentinel as its
  default — "the caller did not choose" reads as the sentinel.
- **`visibility` is not touched.** Belonging to an org and being readable by
  everyone in it are different claims, and the run stays `private` to its
  owner. There is a mechanical reason as well: `trg_runs_visibility` sorts
  before `trg_set_run_owner` and Postgres fires BEFORE triggers in name order,
  so `rbac.enforce_visibility()` has already validated the row by the time the
  org is derived. Setting `visibility` there would set it behind its own check.

**Derived from the definition, not from the caller.** A run of an org's
workflow is that org's run, which makes the org unambiguous when the caller is
in several — and it is what makes lake output from a run org-visible without
a second decision.

A `p_org_id` argument checked against `rbac.current_org_ids()` was the
alternative. It is rejected: it puts the choice in the caller's hands for no
gain, and every caller would then have to pass the value the definition already
carries. The one case it would serve — a definition on the shared tier, started
by a member of two orgs, whose output should land in one of them — is better
served by that person having an org-scoped copy of the definition, which (c)
makes cheap.

Shared-tier definitions keep today's behaviour: the run is `shared`. That is
correct rather than a fallback — a workflow nobody owns produces a run nobody
owns.

### (c) Seeded and package-installed definitions

**Half built, and the other half is declined rather than pending.** The
shared-tier default is built and enforced by `trg_set_definition_owner` (see
(d)). `apply_package` gaining an optional org is **not built and should not be
until something asks for it**, which is a reversal of the paragraph below and
is recorded here rather than quietly left undone.

The measurement: `percolate.apply_package` has **no caller anywhere** —
`grep -rn apply_package` across `percolate-core` and `get-percolate` returns
one line, and it is the function's own entry in `contract.json`. So an optional
org argument would be an unused parameter on an uncalled function, and in
Postgres it is not free: adding a defaulted parameter defines a *second*
function rather than replacing the first, so it costs
`drop function percolate.apply_package(jsonb)`, a re-grant, a re-comment and an
upgrade hop — the cost `workflow.reap_stale_tasks()` paid and wrote down beside
it in `schema.sql`, where the ambiguity was measured as a hard error rather
than guessed at.

When a caller appears, the paragraph below is still the right design and the
work is small. Until then the shared tier is the correct answer for a package
installed into a deployment, which is what the paragraph already says.

`percolate.apply_package` passes no org today, and its definitions are
therefore shared-tier. That stays the default: a package is installed for the
deployment, and the shared tier is exactly what "for the deployment" means.

`apply_package` gains an optional org, and when it is given, the definitions it
installs are that org's. The permission to do so is the one already required to
apply a package; no new grant.

The `source_<id>` workflows `save_api_source` compiles are the case that
matters most here, because they are per-user by construction: they take the org
of the source they were compiled from, so a private data source's workflow is
as private as the source. Today they are startable by anyone.

### (d) What upgrading does

Every existing definition becomes shared-tier, visibility **`public`** —
`rbac.add_scope_columns('workflow.definitions', 'public')`. So an upgraded
database keeps working exactly as it does now — every definition startable by
every signed-in caller — and **the change is opt-in per definition**. That is
deliberate: an upgrade that silently made running workflows unstartable would
be a worse failure than the gap it closes.

**This paragraph said `private`, and that would have caused precisely the
failure the sentence above calls worse than the gap.** `add_scope_columns`
backfills `visibility` on the call that adds the column, and `private` over a
table whose rows have no `owner_id` yet satisfies `rbac.may_read()` for nobody
at all — not the author, not an org, not the operator. Every existing workflow
would have become unstartable by everyone. `public` is the same answer
`agentic.agents`, `skills`, `tool_servers` and `plugins` took, for the same
reason: the policy being replaced was effectively `using (true)`.

The asymmetry is the whole of the fix, and it is worth saying in one line:
**existing rows are backfilled `public`, and the column default is `private`**,
so nothing that works stops working and everything authored from now on is
private to its author.

One case the default gets wrong on its own, and a trigger handles it.
`apply_package` is SECURITY DEFINER and runs with no JWT, so `owner_id` stays
null — and an ownerless row at `private` is readable by nobody, so every
package workflow would install successfully and then be startable by no
signed-in caller, with nothing to say so. `trg_set_definition_owner` therefore
promotes ownerless-and-private to `public`, which is (c) above applied at the
row: a definition nobody owns is the deployment's. There is no explicit-private
case to protect, because ownerless *and* private is a row no caller can ever
read and so cannot be what anybody meant.

The migration a deployment runs afterwards is a normal `update` on
`workflow.definitions` setting `org_id`, and it is theirs to write because only
they know which workflows belong to which org.

### What this does not decide

**Publishing** — a definition readable by every org, startable by every org,
writable by one. `rbac.visibilities` already carries a `public` scope and
`requires_org`, so the vocabulary exists; whether a workflow may use it is a
product question about whether one tenant may run another's code, and that is
not a question this section should answer quietly. It is left open
deliberately.

## `workflow.lifecycle_states`

The closed vocabulary every run and task state is checked against: the state
name, whether it is terminal, whether it counts as success, and a note. One
table rather than a `CHECK` list repeated on each table, so a client can read
the vocabulary instead of being told it, and `percolate.enums()` can publish it.

`succeeded` rather than `completed` or `done`, which is a correctness argument
and not a preference: a failed run also completed, also finished, is also done.
Only `succeeded` is the opposite of `failed`, so only that pair is exclusive in
meaning rather than merely by constraint — and it is what Kubernetes, Argo and
Step Functions call it.
