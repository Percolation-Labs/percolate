# Where Each Step Runs

A four-step pipeline — embed a question, hybrid-search, ask a model to judge,
reindex a graph — written as YAML, compiled to task rows, and executed with
**no user code anywhere**.


**Captured, not illustrated.** Every block below is output from running these
commands against PG19 beta3.

| | |
|---|---|
| **resident** | runs inside Postgres — nothing deployed |
| **dispatched** | dispatched to a worker |
| **yours** | your code |

---

## Authoring — one document, four steps

Defined in SQL, because the compiler is a Postgres extension rather than a
service. Nothing needs to be running to author a workflow.

```sql
select workflow.define_yaml($$
name: hybrid_research
steps:
  - id: embed
    rest:
      url: http://localhost:11435/api/embeddings
      method: POST
      body: {model: nomic-embed-text, prompt: '{{run.question}}'}
      jsonpath: embedding

  - id: retrieve
    needs: [embed]
    sql:
      function: p8ql_vec
      args: ['SEARCH "{{run.question}}" FROM chunks LIMIT 3', '{{steps.embed.result}}']

  - id: judge
    needs: [retrieve]
    rest:
      url: http://localhost:11435/api/generate
      method: POST
      body:
        model: qwen2.5:0.5b
        prompt: 'Answer SAFETY or FINANCE only. Evidence: {{steps.retrieve.result}}'
      jsonpath: response

  - id: reindex
    needs: [judge]
    sql: {function: rebuild_graph_index, args: [company]}
$$);
```

Two of these steps need a process. Two do not — and that distinction is the
point of the syntax. It is not an optimisation applied later; it is visible in
which key you reach for.

---

## Compilation — what it compiles to

Ordinary `workflow.tasks` rows. This is sugar over `start_workflow`, never a
second execution engine, so retry, backoff, the reaper, saga compensation,
cancellation and OTel tracing all apply without being re-implemented.

| YAML key | kind | queue | executed by |
|---|---|---|---|
| `p8ql:` | `sql` | `none` | **nobody** — inside Postgres |
| `sql:` | `sql` | `none` | **nobody** — allow-listed function |
| `rest:` | `http_call` | `http` | worker — generic handler |
| `embed:` | `http_call` | `http` | worker — generic handler, at a url from the model registry |
| `agent:` | `http_call` | `http` | worker — Agent Runtime |
| `work:` | `work` | yours | **you** — the only case |

Exactly one action key per step. The compiler rejects zero or two, by name:

```
step 'a' must have exactly one of p8ql/sql/rest/embed/agent/work, found p8ql + rest
step 'b' needs 'typo', which is not a step in this workflow
invalid YAML: steps[0]: invalid type: string "not-a-map", expected struct WfStep
              at line 4 column 5
```

**The `embed` step and the two-step `embed`/`retrieve` pair above are the same
thing, and the pair is now the long way round.** A `p8ql:` step in `SEMANTIC` or
`SEARCH` mode compiles to *both* rows on its own, with the model resolved from
`aiq.embedding_models` and pinned into the query — so this pipeline is three
authored steps rather than four, and the vector can no longer come from a
different space than the one being searched. The capture above is left as it was
run, because it is a capture; `YAML.md` § *A vector query is two tasks, and you
write one* has the shorter spelling and the argument for it.

---

> **This engine is stigmergic, and nobody wrote it down.**
> The trace-field design ([`../trace-field/schema.sql`](../trace-field/schema.sql)) reads the execution
> tier against Grassé's four verbs and finds all of them already shipped: work
> is **deposited** rather than dispatched, a worker **senses** the queue and
> claims by `SKIP LOCKED` rather than being handed anything,
> `pg_notify('task_ready', queue)` **recruits** without naming a recipient,
> exponential backoff is **evaporation** — a failed task withdraws from the
> field and returns — the reaper decays an abandoned claim, the rate-limit
> refill regulates how many foragers a source can attract, and KEDA grows the
> worker population on trail strength.
>
> That reading is worth having for one reason beyond tidiness: it says which
> extensions are natural and which are foreign. **A dispatcher would be a
> foreign body in this engine** whatever its local merits. It also finds the
> gaps are not randomly placed — the engine has a rich *sense* side and almost
> no *deposit* side, which is why nothing reinforces and why `tasks.priority`
> is indexed, read on every claim, and written by nothing.

## Execution — what ran where

One column answers it. `claimed_by` is written by whatever executed the task,
and it was not the same thing twice.

```
 step_key |   kind    | queue | status | claimed_by  | attempts
----------+-----------+-------+--------+-------------+----------
 embed    | http_call | http  | done   | worker-1    |        1
 retrieve | sql       | none  | done   | in-database |        1
 judge    | http_call | http  | done   | worker-1    |        1
 reindex  | sql       | none  | done   | in-database |        1
```

The two `sql` steps were claimed by **in-database** — no poller, no queue
consumer, no deployment. They executed the moment their dependency completed,
inside the same statement that unblocked them. A pipeline of only those steps
finishes with nothing running anywhere.

And the worker that did the other two had no user code in it at all:

```
handlers: ['http_call']
[worker-1] embed (http_call)
[worker-1]   ok
[worker-1] judge (http_call)
[worker-1]   ok
```

One built-in handler. Nothing registered, nothing subclassed, nothing about
embeddings or models compiled into it — an LLM call, a feed pull and a webhook
are the same task to it, differing only in the JSON on the row.

```
chunks=3 | verdict=SAFE | status=completed
```

Hybrid search returned three chunks, the model read them and answered, and the
run completed on its own.

---

## Data flow — two resolvers, deliberately different

`{{run.x}}`, `{{steps.<id>.<path>}}` and `{{env.X}}` resolve **at dispatch** —
never when the workflow is defined. Substituting at author time would make the
stored definition a snapshot of one run, and make the recorded task input a lie
about what was actually sent. Replay is the thing durable execution exists for;
a definition that has already been filled in cannot be replayed.

| Step | Resolved by | `{{env.*}}` | Why |
|---|---|---|---|
| `rest` | the worker | yes | credentials and endpoints live in its environment |
| `sql` | Postgres, `workflow.resolve_args` | **no** | the database has no business reading the deployment's environment |

The in-database resolver substitutes only whole-string references, and they
keep their native type — so a 768-float vector arrives at the next step as an
array, not a string that happens to contain one.

> **Found by running it.** `complete_task` used to write the task's status
> before the run's context. Flipping a task to `done` fires the cascade, which
> can mark a `sql` step ready and execute it *in the same statement* — against
> a context that did not yet contain the output it needed. An embed step
> completed and the search step consuming its vector failed on the very value
> just produced. Context is written first now.

---

## A constraint, visible — why `SEARCH` takes two steps

A `sql` step cannot embed text. That is a model call, and the database makes no
outbound calls by design.

So vector modes compose as *embed, then search*: a `rest:` step produces the
vector, a `sql:` step consumes it. `LOOKUP`, `GRAPH` and `TEXT` need no vector
and stay a single `p8ql:` step.

This is the architecture showing up in the syntax rather than being hidden by
it. The invariant — **the database never blocks on someone else's latency** —
is why no HTTP client extension is installed, and the two-step shape is that
decision made visible at the point where an author would otherwise not think
about it.

> **The same argument, one axiom further out.**
> The trace-field design ([`../trace-field/schema.sql`](../trace-field/schema.sql)) observes that a
> *human's* latency is the same problem five orders of magnitude larger, and
> proposes the sibling invariant: **no task ever blocks on a human.** This
> engine honours the axiom for HTTP and abandons it for people — a `signal:`
> step holds a task in `waiting_external` until somebody moves it, which is
> right for a named approver on one run and is currently the only spelling.

```
task …: output payload is 10424 bytes, over the 8192 byte limit,
        and is not an S3 ref ($ref)
```

A 768-dimension embedding is ~10KB as JSON, and the guard rejected it. The
guard exists to keep multi-megabyte blobs out of the task table, but 8KB was
tight enough to reject ordinary structured intermediates — which pushed authors
toward offloading things that did not warrant it. Now
`workflow.max_payload_bytes`, default 64KB, still a hard limit rather than a
warning.

The second half of that message is also gone: the remedy is an `$artifact` ref
*beside* the payload rather than an `$ref` inside it, because the check reads
top-level keys and the payload is nested under `result` — see
[`outputs.md`](outputs.md), which is where the four things a step can leave
behind are written down.

---

## Failure — retry is a decision, not a default

The worker is the only thing that knows what an HTTP status means, so it
decides; the engine honours the verdict.

```
[worker-1] gone (http_call)
[worker-1]   terminal: HTTP 404 (client error, not retryable): 404 page not found

 status | attempts | max_attempts | terminal
--------+----------+--------------+----------
 failed |        1 |            5 | true
```

**One attempt of five.** A 400 or 404 fails identically on every retry, so
retrying five times with exponential backoff turns a fast failure into a slow
one while burning the caller's rate limit.

| Condition | Verdict | Why |
|---|---|---|
| 4xx (not 408/429) | terminal | the request is wrong and will stay wrong |
| 5xx, 429, 408 | retry | the server may recover |
| connection refused, DNS | retry | transport, not request |
| missing `credential_ref` | terminal | configuration, not weather |
| unresolvable `{{template}}` | terminal | a definition bug |
| unregistered `sql` function | terminal | the name resolves to nothing -- write the query as `sql: "select ..."`, or register it |

A failing `sql` step runs in a subtransaction, so it fails *itself* — it must
not abort the transaction of whichever worker happened to complete the
preceding task. Verified: the caller's transaction survived and committed.

---

## Delegation — an agent step names a row

The agent's prompt, tools and delegation are data in `agentic.agents`.
Changing any of them never touches the workflow.

The runtime serves one handler on two paths: **`POST /chat`**, which answers
with an AG-UI event stream, and **`POST /v1/chat/completions`**, which answers
with an OpenAI completion. In both, `model` names an agent rather than an LLM.
`core/README.md` is the contract.

Because the response is a stream, a workflow step does not call `/chat`
directly. It calls **`POST /internal/run`**, which accepts the task id, returns
`202` immediately, and lets the runtime call `complete_task` when the agent
finishes — the same `mode: "async"` seam every long-running step uses.
`percolate agent serve` answers it, the service `P8_AGENT_URL` names, and so
does `percolate agent gateway`; the runtime completes the task on a `worker`
login (`P8_WORKER_DSN`). `core/README.md` documents both, including
`P8_WORKER_DSN`.

```json
{
    "key": "judge",
    "kind": "http_call",
    "input": {
        "url": "{{env.P8_AGENT_URL}}/internal/run",
        "body": {
            "workflow_task_id": "{{task.id}}",
            "input": {
                "agent": "classifier",
                "prompt": "Classify this - {{steps.retrieve.result}}"
            }
        },
        "method": "POST",
        "mode": "async",
        "timeout_ms": 120000,
        "credential_ref": "P8_API_KEY"
    },
    "queue": "http",
    "depends_on": ["retrieve"]
}
```

An `agent:` step is an ordinary REST step whose URL and auth the compiler fills
in: it posts to `{{env.P8_AGENT_URL}}/v1/chat/completions` with the agent's
name in `body.model`, and waits for the answer. The scheduled form above is
written by hand when a run outlives a request. Nested delegation happens *inside* the runtime rather than being unrolled
into the workflow graph — so a researcher agent calling an analyst agent is one
task here, and a delegation tree there.

`credential_ref` is a **name**. The worker resolves it from its own
environment, so a dump of `workflow.tasks` never contains a secret and a task
stays inspectable and replayable.

---

## Validation — two different questions

| Checked by | Rejects |
|---|---|
| `p8_compile_workflow` (Rust, serde_yaml) | malformed YAML; a step with zero or two action keys; a `needs` naming a step that does not exist — with the offending step id in the message |
| `validate_spec` (plpgsql, on insert) | duplicate step keys; unreachable steps; cycles with no entry point |

Both run. The compiler catches what a reader of the *document* would call a
typo; the engine catches what a reader of the *graph* would call unsound.

---

## What is not built

- **`sequence:` — positional dependencies — is designed and not built.** 21 of
  24 `needs:` clauses in this collection name the step immediately above, so the
  duplication is real; the design, the reason it is opt-in rather than a change
  to `steps:`, and the lint fix it needs first are in `YAML.md` § *Not built:
  `sequence:`, the dependency you did not have to write*.
- **`embed:` was promoted; the rest of the higher-level steps were not.** See
  `YAML.md` § *Higher-level steps: what was promoted, and what was not*. It went
  in ahead of the second-consumer rule because the hand-written pair was not
  merely tedious — it let the embedding model and the searched space disagree
  with no run-time symptom. `chunk:`, `scrape:` and `summarise:` stay absent,
  and the section says what would have to be true for them to move.
- **Two kinds of deployment skew, one of which nothing can detect.** The step
  vocabulary had six features (`matrix`, `signal`, `timer`, `sub_workflow`,
  `continue_on`, `output_schema`) present in the SQL schema and the compiler
  source and absent from the built `percolate_parser.so`. Rebuilding the parser
  closed it — `compiler_capabilities()` now reports `missing: []` and the fault
  matrix runs end to end — but the **published image still carries the old
  `.so`** until it is rebuilt and pushed, so a fresh `docker compose up` gets
  the old vocabulary. `batching` (`batch_size`/`partition_by`, `schema.sql`
  §20j) is the seventh feature and reopened the gap exactly as predicted: the
  SQL half ran and the shipped compiler refused the document, until the parser
  was rebuilt. It is now a probe case *and* a `yaml_feature` row in
  `surface.sql`, so the audit fails on the skew rather than a reader
  discovering it. Never maintain that list by hand: ask
  `workflow.compiler_capabilities()`, which reads whatever `.so` is loaded, and
  `define_yaml()` refuses rather than silently dropping the key (`spec.md` §16).

  The second kind had no probe at all. `aiq.query()` on the live stack was an
  older body than `specs/ai-query-layer/schema.sql`, missing the `SCHEMA` mode
  route — so a mode the parser had just learned to parse raised `unhandled mode
  SCHEMA` from the executor. **`surface.sql` cannot catch this**: it asks
  whether a declared capability *exists*, and a stale function exists. Existence
  and currency are different questions, and `dev/currency.sh` now audits the
  second: it builds a pristine database from the committed script and diffs
  `pg_proc` against the running one (`failure-modes.md` §6).
- **Nothing is benchmarked, and the scale claims have no evidence behind them.**
  `spec.md` §7 targets tens of thousands of completions/sec and millions of
  live tasks. The largest numbers actually run are **589 tasks total, a 32-task
  run, a 30-wide fan-out and one worker** — five orders of magnitude below the
  target, and rate limiting has only ever been exercised serially, never under
  contention. Every result here is a fixture of a few rows.
- **A third of the engine had never been executed by anything, and the
  crash-recovery third has now been.** Measured with `track_functions='all'`:
  47 of 62 `workflow.*` functions invoked, 15 not. `reap_stale_tasks`,
  `heartbeat_task` and `complete_decision_task` — the whole crash-recovery and
  replay story — are now driven by `06-recovery.sql`, which found two defects
  and inherited a third (`schema.sql` §23): a reaped worker could publish a
  stale result over the live one's, and a crash loop was unbounded and
  invisible. What is still unexecuted: no real user-code worker has ever run a
  `work` step outside a test transaction, and `claim_tasks`/`matrix_rows` are
  covered only by the suite. The measured base rate remains the reason to care:
  of the never-executed capabilities run for the first time, nearly all were
  broken.
- **Four assertions in the suite read a function's source text rather than
  calling it** — `pg_get_functiondef(...) like '%assert_run_access%'`. That
  catches a check being deleted and not a check being wrong, which is the exact
  failure `assert_run_access` had twice (the engine acting with no identity;
  unowned scheduled runs). They should be real calls under a set JWT.

### Closed since this list was last written

Kept rather than deleted, because a "what is not built" list that silently
gains entries is trusted and a list that silently loses them is not:

- ~~*The extension has no upgrade path*~~ — `sql/` holds a
  `percolate--<from>--<version>.sql` for every earlier release alongside the
  install script, and `build-sql.py` writes all of them from the same specs, so
  they cannot diverge. An upgrade script is a **replay**: the install script
  re-applied, because the schema is written to be re-runnable rather than to
  carry a hand-authored delta per release. Only what a replay cannot express is
  written by hand, in `specs/migrations/`, and prepended. That is what closes the bug the original entry described —
  a shipped function's signature changing no longer needs
  `ALTER EXTENSION … DROP FUNCTION` by hand on an installed database. The
  entry's reasoning stands and is worth keeping: the second release is the
  problem, not the first, which is why the path was built before it was needed.

- ~~*A fan-out cannot tolerate a failed child*~~ — `continue_on: failed` +
  `min_success` are built, compiled and asserted (`05-faults.sql`); the 404
  that cancelled two aggregates is now tolerated at 19/20.
- ~~*Saga compiles, untested from YAML*~~ — exercised from the compiler, five
  defects found and fixed, asserted in `05-faults.sql`.
- ~~*The worker double-encodes its `http_call` output*~~ — the engine-side
  guard shipped: a double-encoded output is repaired **and** the repair is
  recorded as `output_normalized`, so `encoding_drift()` reports a defect that
  was previously invisible.

---

## See also

- [`YAML.md`](YAML.md) — the full step-type reference and the promotion rule
  for higher-level steps
- [`outputs.md`](outputs.md) — where the thing a step *made* lives: an inline
  payload, rows, a validated assistant message, or a registered artifact, and
  nothing else
- [`hired-steps.md`](hired-steps.md) — proposed: a step that parks work for an
  outside agent (Claude, Codex, a routine) to claim through MCP as itself
- [`failure-modes.md`](failure-modes.md) — what actually goes wrong, grouped by
  the shape of the failure rather than the component, because the shape is what
  transfers
- [`spec.md`](spec.md) — the narrative spec: why Postgres owns orchestration
  state, saga design, the `pg_durable` comparison
- [`schema.sql`](schema.sql) — the engine itself
- [`integration-rbac.sql`](integration-rbac.sql) — ownership, RLS, and the
  authorization boundary on run-scoped entry points
- [`../../README.md`](../../README.md) — what you actually have to run
