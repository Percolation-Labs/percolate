# Scale — measured, and the two things it found

**Every number in this file was produced by running it**, and every one is
reproducible with [`dev/scale/run.sh`](../../dev/scale/README.md). That is the
rule for this document specifically: a scaling claim with no measurement behind
it does not belong here, because the failure class this file exists to catch is
*designs that are correct in reasoning and wrong under load*.

It found two defects, cleared one suspicion, and refuted one of my own
hypotheses. The defects had been in the schema since it shipped, neither is
visible on a fixture, and one of them cost two orders of magnitude.

## The environment, because a number without one is not a number

| | |
|---|---|
| PostgreSQL | 19beta3, `percolate 0.1.0`, `percolate_parser 0.1.0` (measured at 0.1.0) |
| Host | 10 cores, Docker Desktop on macOS (container-local storage) |
| `shared_buffers` | 128 MB (the image default) |
| `work_mem` | 4 MB (the image default) |
| Workers | `pgbench` as the `worker` role, calling `workflow.claim_task` |

`work_mem` matters more than it looks: it is why finding 1 spills to disk rather
than merely being slow, and a deployment that has raised it will see a smaller
version of the same defect rather than none of it.

**Storage here is slow**, and that is worth stating because it shaped the work.
Bulk deletes on this container stall on `IO:AioIoCompletion` — a single-statement
delete of 1M task rows was still running after 22 minutes. That is an artefact of
the environment rather than a property of the design, and it is why `--clean`
batches and why the harness README says a volume reset beats a large delete.

## Finding 1 — the claim index did not match the claim

**The claim path is the hottest query in the engine.** Every worker runs it on
every task, and it is the one query whose cost is multiplied by both worker count
and backlog depth.

`idx_tasks_claimable` was `(queue, priority, run_after)`. `claim_task` orders by
`priority desc, created_at`. **`created_at` was not in the index at all.**

While a queue is shallow this costs nothing, because the planner reads a handful
of rows whichever way it goes. Once a queue is deep it is catastrophic: every row
matches `status = 'ready'`, so the index offers no selectivity, and the planner
correctly abandons it for a sequential scan plus a sort of the entire ready set —
in order to return twenty rows.

Two runs of `dev/scale/run.sh` against a freshly created database, changing
nothing but the index:

```
200,000 ready tasks, 8 concurrent workers, 10s

  (queue, priority, run_after)              78.7 claims/s   101.7 ms mean
  (queue, priority desc, created_at)    13,965.3 claims/s     0.57 ms mean
```

A single claim, same two runs:

```
before:  Seq Scan on tasks (rows=200000) -> Sort (external merge Disk: 38800kB)
         Buffers: shared hit=5381, temp read=492 written=4861
         Execution Time: 73.269 ms

after:   Index Scan using idx_tasks_claimable (rows=20)
         Buffers: shared hit=22 read=2
         Execution Time: 0.069 ms
```

**Thirty-eight megabytes of temp I/O, per claim, per worker.** Eight workers
doing that concurrently is why the throughput number is 78 and not 2,000. And it
degrades with depth: at 1M ready tasks the same eight workers managed **7.6
claims/s at a mean latency of 1,050 ms.**

The fix is one line, and it is now in `schema.sql`: index
`(queue, priority desc, created_at) where status = 'ready'`, matching the
`ORDER BY` exactly. `priority desc` is written out rather than left to a reverse
scan, because a mixed direction (`desc, asc`) cannot be served by scanning one
index backwards — that reverses both keys.

Verified flat in the backlog: **0.069 ms at 200k ready, 0.044 ms at 1M.**

### Why nothing caught it

Two reasons, and both are worth fixing rather than noting.

**Every task in this system has `priority = 100`.** Nothing writes the column —
`start_workflow` does not set it and the compiler has no key for it — so the
first sort key is constant, `ORDER BY priority desc, created_at` degenerates to
`ORDER BY created_at` over the whole ready set, and the index's second column is
dead weight. The unwritten `priority` had been listed as the cheapest open item;
this is the same gap seen from the other side, and it is no longer cheap.

**No test in this repo had ever made a queue deep.** The `dev/tests/` fixtures
are tens of rows, which is right for asserting behaviour and exactly wrong for
finding this. That is what `dev/scale/` is for, and why its README says a probe
that passes on a hundred rows will pass on the day it should have failed.

## Finding 2 — the autoscaler's probe has no index of its own

`workflow.queue_depth(queue)` is what KEDA polls every 30 seconds per pool, and
it counts ready-and-due plus running. Nothing indexed that set, so the planner
improvised from whatever else was available.

What it does depends on the **ratio of live tasks to table size**, and measuring
three points is what made the shape clear.

| Table | Live | Plan | Buffers | Time |
|---|---|---|---|---|
| 1M | 1k | bitmap OR over the existing partial indexes | 92 | 0.28 ms |
| 1M | ~300k | parallel seq scan | 30,733 | 86.6 ms |
| 1M | ~300k | **index-only scan on `idx_tasks_live`** | **867** | 28.2 ms |
| 200k | 200k | parallel seq scan, with or without the index | 5,351 | 16.7 ms |

**A hypothesis of mine that the measurement refuted**, recorded because the
correction is the useful part. I expected cost to grow with *completed history* —
a table full of finished tasks making the probe slower forever. It does not: at a
1,000-task backlog against a million rows the existing partial indexes answer it
in 92 buffers.

The real shape is a ratio. When the live set is a small fraction the planner is
already fine. When it is nearly all of the table a sequential scan is genuinely
cheaper and the index correctly goes unused. In the middle — a long-lived
deployment carrying a real backlog, which is the normal operating point — the
index is a 35× reduction in I/O, and that middle is the one region that had
nothing.

So this is a smaller finding than finding 1, and still worth the index.

`idx_tasks_live on (queue, status, run_after) where status in ('ready','running')`
gives an index-only scan with `Heap Fetches: 0`. `run_after <= now()` is not
immutable so it cannot sit in a partial index's `WHERE`; it rides as an indexed
column so the filter is answered without touching the heap.

## Cleared — fan-in is linear

The shape `matrix` produces is N children feeding one successor, and
`cascade_task_status` fires per completed row and decrements `pending_deps` on
every dependent. That is the obvious place for an accidental O(N²).

```
  100 children     7.4 ms    74 us/child
  500 children    27.1 ms    54 us/child
 2000 children   157.1 ms    78 us/child
```

Linear, with a constant of roughly 75 µs, and the successor correctly reached
`ready`. `idx_task_deps_reverse` on `depends_on_task_id` is why — without it each
completion would scan the dependency table.

**Recording a cleared suspicion matters as much as recording a defect.** The
alternative is that somebody re-derives the worry in six months and pays for the
measurement again.

## The design rules these produce

Stated as rules rather than as observations, so a future change can be checked
against them.

**1. The claim path must not sort.** The index and the `ORDER BY` are one
decision, and changing either without the other is a two-order-of-magnitude
regression that no functional test will catch. `dev/scale/02-claim.sql` asserts
the *plan*, not the time: a `Seq Scan on tasks` or an `external merge Disk` in
that output is the failure.

**2. A probe an autoscaler runs is in the hot path.** Anything on a 30-second
cadence gets an index, even when the planner currently copes without one.

**3. Cost that scales with the backlog is acceptable; cost that scales with the
table is not.** The task table only grows, so every index the hot paths depend on
is partial on a live status. That is also what keeps them small: the claim index
is 1.3 MB for 200k ready tasks against a 66 MB table, and 6.4 MB at 1M.

**4. Depth is the test condition.** A probe added to `dev/scale/` defaults to a
deep queue. Both defects above are invisible at fixture scale, and a shallow
probe would have reported health.

**5. Sizing, measured rather than assumed.** A task row costs ~340 bytes
(66 MB for 200k, 338 MB for 1M), so a million-task backlog is a third of a
gigabyte. The 64 KB payload cap is what keeps that true, and it is why
`outputs.md` insists a step return a receipt rather than its rows.

## The poll, and why it was never the bottleneck

`percolate-core`'s worker is a poll loop — `P8_POLL_SECONDS`, default 2 — and
**nothing in the collection subscribes to `task_ready`**, although the database
emits it from three places. That is a real gap, and the measurements say it is a
much smaller one than it looks.

An empty-queue claim is **0.044 ms and 8 buffers**: an index probe against a
partial index that contains only claimable rows. The idle poll costs
`workers ÷ interval` trivial queries per second, **independent of task rate**, and
it only runs when a worker is idle — a busy worker loops straight back into
`claim_task` without sleeping. Polling is most expensive exactly when the system
has spare capacity to serve it.

So the engine's scaling problem was never the poll. It was finding 1, on the same
query, hidden for the same reason.

What a listener would buy is the `interval/2` mean latency on an idle queue. What
it costs is a dedicated backend per worker — `LISTEN` is session state and cannot
be pooled in transaction mode, against a `max_connections` of 100. `task_ready`
is also one channel for every queue, so every worker in a deployment wakes for
every task anywhere; and Postgres collapses duplicate `(channel, payload)` pairs
within a transaction, so a matrix expanding 500 children emits **one**
notification. The signal says *something arrived*, never *how much* — and
fan-out is the workload this engine is built for.

The layer that actually scales is below it: KEDA on `queue_depth`, changing the
number of workers rather than the attentiveness of one, with `SKIP LOCKED` making
a worker joining or leaving cost no coordination at all. At `minReplicas: 0`
there is nobody to notify, and first-task latency is the autoscaler's interval
plus pod start, which no notification can improve.

**Recommendation: lower `P8_POLL_SECONDS` on an interactive queue before adding a
listener.** Two seconds to 250 ms is 8× the poll rate on a 0.044 ms index probe,
which is nothing, and it buys most of the latency. If a listener is added later
it must be per-queue, and it must remain an optimisation over a poll that still
runs — a worker acting only on notify strands a task forever on one missed
notification, and that is a failure this design currently cannot have.

## Confirmed on a cluster

Everything above is single-node compose, so the same probes were run on a
three-node `kind` cluster — database pinned to the control plane, claimers barred
from it by node affinity, so **every claim crosses a node boundary**. The harness is
[`dev/scale/kind/`](../../dev/scale/kind/README.md).

Same bounded methodology on both sides, 200,000 ready tasks, 2 pods × 4
connections:

```
  (queue, priority, run_after)             43.6 claims/s   183.4 ms mean
  (queue, priority desc, created_at)    9,406.7 claims/s     0.85 ms mean
```

**216× on a cluster, against 177× on compose.** The finding is not an artefact of
one substrate. Absolute throughput is lower than compose (9,407 against 13,965)
and latency higher (0.85 ms against 0.57 ms), which is the network hop plus
nested virtualisation and is the number to expect in a real deployment rather
than the compose one.

### A measurement error worth more than the measurement

The first kind run reported **22,839 claims/s per pod** and it was wrong.

A time-boxed `pgbench` against a queue that drains mid-run measures the
**empty-queue no-op path** for the remainder and reports it as throughput. The
queue had gone from 200,000 ready to zero inside the first few seconds, and every
subsequent "claim" was returning null very quickly.

The fix is to bound a run by transaction count and then **check the arithmetic**:
the ready count must fall by exactly `pods × clients × transactions`. The clean
run started at 200,000 ready and ended at 160,000 ready plus 40,000 running,
which is exactly the 40,000 claims requested, so the number is trustworthy.

A second contaminated run came from resetting the queue while claimer pods were
still terminating — they kept claiming through the reset. Scale to zero and wait
for the pods to be *gone*.

Both are recorded because a scale harness that can silently report a number 5×
too good is worse than no harness, and neither error announces itself.

### The reaper, tested by killing the workers

Two thousand tasks were left `running` by benchmark pods that no longer existed —
the exact condition the lease fence and `reap_stale_tasks()` exist for, and one
compose cannot produce honestly.

```
reaper while leases were fresh (<2 min)     reaped=0
reaper after the timeout                    reaped=258
convergence: 84 -> 888 -> 269 -> 0 running
```

Correct on both sides. It does **not** steal work from a lease that is merely
young, it reaps by lease age rather than in bulk, and every one of the 2,000
tasks came back to `ready` with `attempts` incremented. Nothing was lost and
nothing was double-claimed.

### The connection budget is the ceiling on worker count

Thirty claimer pods at four connections each is 120 wanted against
`max_connections = 100`:

```
FATAL:  sorry, too many clients already
```

**Including the operator.** `p8` is a superuser and
`superuser_reserved_connections = 3`, and a `psql` as `p8` was still refused —
thirty pods reconnecting in a tight loop win the race for three reserved slots.
So the failure mode of connection exhaustion is not that tasks stop; it is that
**you cannot get in to see why**.

Two consequences worth stating as rules.

**Workers must be pooled or few.** A worker pool sized by KEDA on queue depth can
outgrow the database's connection budget long before it outgrows its throughput,
and the budget is the limit that bites first. Either put a pooler in front or cap
`maxReplicas` against `max_connections` deliberately rather than by accident.

**This is the argument against a `LISTEN`-based worker, quantified.** `LISTEN` is
session state and cannot be pooled in transaction mode, so a listening worker
holds a dedicated backend for its whole life. The ceiling that took thirty
polling pods to reach arrives at exactly `max_connections` listening workers, and
no pooler can move it.

## What moved into the engine, and why each one had to

The harness started as shell scripts and ad-hoc SQL. Everything it needed twice
is now a function or a view in `schema.sql`, on the principle that **a scaling
property you can only check by remembering to write the query is a property
nobody checks.** Each of these closed a gap the measuring found.

| Surface | Replaces | The gap it closes |
|---|---|---|
| `workflow.check_hot_paths()` | eyeballing `EXPLAIN` for "Seq Scan" | the defect was a *plan*, so the assertion has to be about the plan |
| `workflow.purge_completed()` | a batched delete loop in bash | **nothing in this engine could delete a task**; the table only grew |
| `workflow.v_unclaimable` | nothing — you had to already suspect it | work no worker can ever claim, which produces no error of any kind |
| `workflow.v_backlog` | `v_queue_depth`, which is a count | depth cannot tell a queue draining in seconds from one nothing serves |
| `workflow.v_capacity` | nothing | connection headroom, which is the ceiling that arrives first |
| `workflow.seed_load()` | twenty lines of raw `INSERT` | every scale test was reinventing the column list |

Two of them are worth more than the convenience.

**`check_hot_paths()` refuses to pass on a shallow queue**, and that is the
design rather than a limitation. The claim defect is invisible below a few
thousand ready rows because the planner picks the index at any shape when the
ready set is small — so a gate that ran on a fixture would have reported health
for the entire life of the bug. It returns `inconclusive` and says why. An
honest inconclusive is worth more than a false pass, and this is the one place
in the collection where that trade is explicit.

```
empty database        inconclusive   deepest queue has 0 ready task(s), below the 2000 needed to judge
20k ready, old index  FAIL           claim_task is scanning and sorting 20000 ready tasks to return 20
20k ready, fixed      ok             index-backed at depth 20000 (Index Scan -> Limit -> LockRows)
```

**`purge_completed()` was a production gap wearing a test harness as a
disguise.** It was written because `--clean` was slow, and building it revealed
that the engine had no retention at all — which matters far beyond a test, since
finding 2 showed the autoscaler's plan depends on the ratio of live rows to
total rows, and an unbounded table degrades the thing that decides how many
workers you get.

Building it found three defects, all by running it, and each is now a comment in
the function:

1. **It purged nothing, silently.** The terminal statuses were written as
   `('succeeded','failed','cancelled')`; `workflow.runs` uses `completed`.
   `agentic.runs` *does* use `succeeded`, and both constraints are named
   `runs_status_check`, which is how the wrong vocabulary looked right. There is
   now a load-time assertion against the constraint itself.
2. **It keyed on the wrong column.** `runs.updated_at` is maintained by a touch
   trigger, so it means *last modified* — retention keyed on it is retention
   keyed on when somebody last looked at the run. It uses `completed_at`, and
   falls back to `updated_at` only because a run can reach a terminal status with
   a null `completed_at`, and keyed on `completed_at` alone such a run would be
   immortal and invisible.
3. **It aborted mid-batch on a foreign key.** Three references into
   `runs`/`tasks` are `NO ACTION`: a schedule's `last_run_id`, a sub-workflow
   parent's `child_run_id`, and tasks' `compensates_task_id`/`matrix_parent_id`
   (`agentic.runs.workflow_task_id` was a fourth, and is now `on delete set
   null`). So it batches by **run** rather than
   by task — a batch that split a run would block on its own siblings — and skips
   runs still referenced, reporting the count as `runs_skipped` so an operator
   watching the table not shrink has an answer rather than a mystery.

None of those three would have been found by reasoning about it, and the second
and third would each have produced a purge that appeared to work.

## What is still unmeasured

Named rather than implied, because the gaps are where the next defect is.

- **Matrix expansion at width.** `expand_matrix` inserts N children in the
  transaction that completes the parent; 5,000 children in one statement is
  untested, and that transaction holds locks while it runs. `batch_size`
  (§20j) is the lever that makes this width a choice rather than a consequence
  of the row count — 5,000 rows at `batch_size: 50` is 100 children — but the
  chunking arithmetic itself, and the per-child scan for constant columns that
  a batched template needs, are also unmeasured at that width.
- **`runs.context` write amplification.** `outputs.md` claims a JSONB column
  rewritten per completion is quadratic once a fan-out is wide. Believable,
  unmeasured, and the reason a fan-in reads handles.
- **Concurrency past 32 workers.** Throughput peaked at 8 and regressed at 32 on
  10 cores (14,243 → 10,334 claims/s), which is oversubscription rather than a
  contention limit — the actual `SKIP LOCKED` ceiling is unmeasured.
- **The reaper and the ticker at depth.** Both are `pg_cron` jobs sweeping the
  task table once a minute, and neither has been run against a million rows.
  **Narrowed by REM-109**, which does not close it: `reap_stale_tasks` now takes
  a `p_limit` (default 1000) and orders by `heartbeat_at`, so a tick costs at
  most that many rows and the next one takes the rest instead of the cost of a
  pass being the size of the backlog. What is still unmeasured is the *sweep* --
  the `where` clause scans running tasks whatever the limit does to the write
  half -- and the ticker, which REM-109 did not touch. The heartbeat also
  changes what a reap MEANS: it now indicates a dead worker rather than a long
  task, so reaps arrive in clumps when a pod dies instead of steadily, which is
  the arrival pattern the bound was chosen for and not the one it was measured
  against.
- **KEDA itself.** The scaling *decision* is untested: these runs scaled pods by
  hand. Whether `queue_depth` drives sensible replica counts under a bursty
  arrival pattern is unknown.
- **A pooler.** Every number here is direct connections. PgBouncer in transaction
  mode in front of the claim path is the obvious answer to the connection
  ceiling and has not been measured.
- **Sustained multi-hour load.** Everything here is seconds to minutes. Autovacuum
  behaviour on a task table churning at thousands of rows a second is unknown,
  and it is the most likely place for the next surprise. **One precondition is
  now in place** and it was not before REM-109: `workflow.purge_completed` is
  scheduled daily by every install path, so the table has an upper bound at all.
  Until then nothing deleted a finished run anywhere, which made this gap
  unmeasurable rather than merely unmeasured -- `queue_depth` degrades with the
  live-to-total row ratio (finding 2), so a long run's numbers were a function
  of how long the database had existed. Autovacuum tuning itself is untouched.
