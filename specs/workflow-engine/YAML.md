# Workflows in YAML — REST + P8QL, no user code

A workflow is a YAML document that **compiles** to ordinary `workflow.tasks`
rows. It is sugar over `start_workflow`, never a second execution engine — so
retry, backoff, the reaper, saga compensation, cancellation and OTel tracing
all apply unchanged.

The point is not ergonomics. It is that a workflow composed only of P8QL and
REST steps needs **no user code anywhere**. The worker stops being something
you write and becomes something purely generic that ships.

```sql
select workflow.define_yaml($$
name: hybrid_research
steps:
  - id: retrieve
    p8ql: 'SEARCH "{{run.question}}" FROM chunks LIMIT 3'

  - id: judge
    needs: [retrieve]
    rest:
      url: '{{env.LLM_URL}}/api/generate'
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

Verified end to end: hybrid search returned 3 chunks, the model classified
them, the graph reindexed, and the run auto-completed — with a worker that had
**only its built-in `http_call` handler registered**.

That first ran with `retrieve` written the long way, as a `rest:` call to the
model and a `sql:` step consuming it. The one-line spelling was verified
separately and the same way — a run of exactly the document above against a
stub embedding endpoint, producing `retrieve__embed` (`http_call`, claimed by
`worker-1`) and `retrieve` (`sql`, `in-database`), with both rank columns
populated in the fused result.

`retrieve` is three authored steps where the pipeline used to need four, and it
is still two tasks: `SEARCH` ranks against a vector, a vector is a model call,
and the database makes none. The compiler writes the embed step (§*A vector
query is two tasks, and you write one*), the model registry supplies its url,
and the model is pinned into both halves so they cannot mean different spaces.
What you do not get is a third execution path — the pair is exactly the pair
you would have written.

---

## Finding out what this deployment accepts

A workflow's vocabulary is partly fixed and partly per-deployment: the step
kinds are the engine's, but the functions a `sql:` step may call, the queues a
step may route to and the agents an `agent:` step may name are all rows on the
database in front of you. `SCHEMA "workflow"` returns both halves, and runs
its own examples through the compiler on every read so a spelling this
deployment no longer accepts reports itself rather than being served as
authoritative:

```sql
select aiq.schema('workflow');
```

Details in `ai-query-layer/USAGE.md` § SCHEMA. Worth knowing while reading the
rest of this file: everything below describes the vocabulary, and that query
describes *this installation's* version of it.

---

## Step types

| YAML | compiles to | who executes it |
|---|---|---|
| `p8ql: '<query>'` | `kind: sql` | **nobody** — runs inside Postgres. A `LAKE` query is the exception: it compiles to `kind: work` on the `lake` queue, because its data is in object storage (the `LAKE` form in [`../ai-query-layer/USAGE.md`](../ai-query-layer/USAGE.md)) |
| `sql: "select …"` | `kind: sql` | **nobody** — the statement you wrote, read-only |
| `sql: {statement, write: true}` | `kind: sql` | **nobody** — a statement that changes the database |
| `sql: {function, args}` | `kind: sql` | **nobody** — allow-listed function |
| `rest: {url, ...}` | `kind: http_call` | the **worker**'s built-in handler |
| `embed: <text>` | `kind: http_call` | the **worker**'s built-in handler, at a url from the registry |
| `agent: <name>` | `kind: http_call` | the Agent Runtime |
| `work: true` | `kind: work` | **you** — the only case needing your code |
| `matrix: {...}` | `kind: matrix` | **nobody** — expansion happens in-transaction (`batch_size`/`partition_by` give a child many rows) |
| `signal: true` | `kind: signal` | **a person**, via `signal_task` |
| `timer: <seconds>` | `kind: timer` | **nobody** — a clock |
| `workflow: <name>` | `kind: sub_workflow` | **nobody** — the child expands in-transaction |

Exactly one per step; the compiler rejects zero or two by name. The last three
are *control* steps — they wait rather than act, which is why declaring one
alongside an action is refused.

All three were unauthorable until a human-in-the-loop workflow was attempted
and the compiler refused the document: `signal`, `timer` and `sub_workflow`
had always been legal *engine* kinds and had never been reachable from YAML.
`sub_workflow` had in fact never executed at all — `start_child_workflow`
inserted a run row without expanding the child's task graph, so composition
was advertised, unreachable, and broken underneath. `matrix:` is
the exception that proves it: a matrix does not *act*, it fans out over an
action, so it carries a `template:` written in exactly this vocabulary — and a
step declaring both `matrix:` and an action of its own is rejected by name.

### A step may carry its own SQL

The shortest way to ask the database a question is to ask it:

```yaml
  - id: quarters
    needs: [land]
    sql: "select fy, fp, val from sec.facts where cik = {{run.cik}} order by fy desc"
```

Read-only, executed inside Postgres with no process anywhere, and the rows come
back under `result` like any other step's output. Nothing to register.

**A statement that changes the database says so**, and the engine refuses one
that does not:

```yaml
  - id: purge
    sql:
      statement: "delete from staging where run_id = {{run.$id}}"
      write: true
```

`write: true` is not a security control — a step runs as the engine owner either
way — but a plan that cannot tell a question from a mutation is a plan nobody
can review, and the refusal is what makes the declaration meaningful.

**The allow-listed spelling stays**, and the engine's own steps use it:

```yaml
  - id: land
    sql: {function: sec_land_facts, args: ['{{steps.fetch.result}}']}
```

A registered function carries a per-function timeout and a description — the
same text a bound tool takes into a model's context — so `step_functions`
remains the answer to "what can a workflow cause to run" for the operations a
deployment wants blessed. What it is no longer is *mandatory*.

#### Whose rows a step sees: the person who started the run

A step's statement, every `p8ql:` query (SEARCH, TEXT, LOOKUP and GRAPH as much
as plain SQL) and a matrix's `rows:` source run **as the person who started the
run**, under row-level security. A run reads exactly what its starter could read
through PostgREST, and writes only where they could write by hand. That holds
for an admin as much as for a member: a run of `ask_uploads` answers each person
from their own documents and nobody else's.

```
Carol (org outside) starts ask_uploads -> retrieve finds none of vector-team's chunks
Alice (vector-team) starts ask_uploads -> retrieve finds her runbook
```

A run nobody started (a schedule, a system pass such as `content_reconcile`)
has no person to act for. It keeps the engine's reach, which is the operator's
trade, made by whoever defined and scheduled it.

**How, since the step runs inside the engine.** A step executes in
`execute_sql_step`, which is `SECURITY DEFINER` and owned by `app_owner`, the
owner of every table, so it bypasses RLS. Postgres refuses `SET ROLE` inside a
definer stack, so the step cannot become the person. What it can do is call
another definer function, and that switches identity to the callee's owner.
`workflow.execute_for` is owned by `api_viewer`, the role that already owns
every `*_api` view for the same reason: it is not the table owner, so RLS
applies. With the claims set to the run's owner, a statement there sees what
that person would see. Only the engine may call it. `integration-rbac.sql`
carries the detail, and `dev/tests/workflow/15-steps-read-as-starter.sql` the
proof.

**And as the actor who started it, not only the person (REM-171).** A person's
agent starts runs with its own narrowed credential, and the run keeps that.
`workflow.runs.started_actor` and `started_credential_id` are set from the
verified claims when the run is created, never from the row, and a scheduled
run takes them from the schedule's creator. `execute_for` mints `actor` and
`api_key_id` back into every step, so `rbac.decide` refuses a step of an
agent's run whatever it would refuse the agent: a human-only capability, a scope
the key lacks, a key revoked since the run began. A run created before this
carries no starter and keeps the person's reach.
`dev/tests/workflow/23-a-step-runs-as-the-agent-that-started-its-run.sql` is the
proof. An HTTP agent step carries the starter too: the worker mints its token
from `workflow.task_principal`, which returns the run's starter beside its
owner (`dev/tests/workflow/24-an-agent-step-carries-its-starter.sql`).

It needs one cluster grant, `grant authenticated to api_viewer`, so the role a
step becomes holds what a signed-in person holds. The image's
`dev/image-init/00-superuser.sql` makes it from 0.2.0, and the extension's preflight refuses to install or upgrade without it
and names the line.

The person's identity is set by `app_owner` and not by the role that runs the
statement: `api_viewer` does not hold `set_config` (`specs/user-rbac/roles.sql`
§6), so a read step's statement cannot rewrite whose rows it sees. A **write**
step's statement could once change the claims, because `SET` is not a function
a grant can take away. It is now opened as a cursor, so it runs as exactly one
statement, and a `SET` alone or beside a write is refused before anything is
written (`dev/tests/workflow/15-steps-read-as-starter.sql` §4b).

**Registered functions are different.** `sql: {function: …}` runs the function
the deployment blessed, as the engine, and a function that serves any caller
scopes itself to the run's owner, found through `workflow.current_run_id` (never
through an argument). That is what registration means: somebody reviewed it.

**`registered` narrows what an author may write:**

```sql
alter database <db> set percolate.sql_policy = 'registered';
```

| policy | meaning |
|---|---|
| `open` *(default)* | a step may carry a statement, or name a function |
| `registered` | statements and SQL-mode `p8ql` are refused, at authoring time and at dispatch; only the allow-list runs |

Whose rows a step sees is the paragraph above, under either policy.

Before 0.2.0 every step ran as the engine owner, and the spec defended that as
"anyone who may define a workflow may read anything". Defining was gated;
starting was not, so a workflow an admin wrote read every tenant for whoever
started it. A walkthrough had a member of one org start
`ask_uploads` and get another org's runbook back.

#### Two guards, and only one of them is the boundary

A read is wrapped as `select … from (<your statement>) t` and runs with
`transaction_read_only` on. The wrap is structural — Postgres refuses a
data-modifying `WITH` anywhere but the top level, so `with gone as (delete …)`
fails on the shape rather than on a keyword list. The read-only transaction is
what catches everything else, including the volatile function that writes.
The keyword check beside them (`^insert|update|delete|…`) is a courtesy that
turns an abort into a sentence naming `write: true`; it is not a filter anything
depends on.

Read-only is switched on inside a **subtransaction that is deliberately
unwound**, because `transaction_read_only = off` is refused once a transaction
is read-only (SQLSTATE 25001). Left on, the first read step would make the
engine's own `complete_task` fail on the next line — which is how that was
found.

#### A `{{template}}` in a statement is a bound value, never a fragment

Every reference becomes a **bound parameter**: the statement is rewritten so
each `{{ref}}` reads `$1->>'<ref>'`, and the values travel beside it as one
jsonb that `EXECUTE ... USING` binds. A run input of `'; drop table x; --` is
therefore a string, not because it was escaped but because it never reaches the
parser. Quotes you write yourself are consumed rather than doubled —
`cik = '{{run.cik}}'` and `cik = {{run.cik}}` mean the same thing.

**One parameter rather than one per reference**, because plpgsql fixes the
number of `USING` expressions at compile time and a statement with a variable
number of references cannot bind one each. A single jsonb keyed by reference
name is bindable; `$1->>'item.ref'` is the extraction.

**The cast comes from the JSON type.** `->>` yields text, where a quoted literal
was unknown-typed and coerced by context — so `where n = {{run.n}}` against an
integer column would be `integer = text` and fail. A JSON number therefore binds
`::numeric` and a boolean `::boolean`, which restores the coercion the literal
form got for free. A value that is genuinely text against a non-text column
still needs your cast.

**This covers `{{item.*}}` in a `matrix:` template too, and did not always.**
Matrix children were substituted as TEXT at expansion, so a row whose column
held `x' || current_user || '` expanded into a statement that ran and returned
the current user — arbitrary SQL out of ordinary row data, executing as the
engine owner. The values in a fan-out are not the author's; they are whatever is
in the table. `expand_matrix` now leaves a `sql` statement templated so
execution binds it. Found by walking an evaluation journey; pinned by
`dev/tests/workflow/13-open-sql.sql` §4b.

**The one thing you cannot template is an identifier.** `from {{run.table}}`
becomes `from ($1->>'run.table')` and fails with `syntax error at or near "$1"`.
That is the parameterisation working rather than a limitation to route around:
values can be bound and names cannot, which is why every driver draws the line
in the same place. A workflow that picks its own tables at runtime is one nobody
can review, and `matrix:` already covers the case where the rows vary.

#### `p8ql:` with plain SQL now executes too

`aiq.query()` recognises a read-only statement by how it starts and returns the
statement rather than running it, so that its own security mode stays irrelevant
to caller-supplied SQL. As a workflow step that produced a task marked `done`
whose result was a note:

```
 status | mode |                               note
--------+------+------------------------------------------------------------------
 done   | SQL  | execute via the SECURITY INVOKER read-only passthrough, not here
```

Found twice — once writing `dev/examples/06-no-worker.sql`, once writing a real
SEC pipeline whose "ask the data" step reported success and answered nothing.
This is `dev/tests/README.md`'s named workflow failure: a partial failure that
reports success, with every task `done`, reached by the most ordinary thing an
author can write.

`workflow.p8ql` now honours the note instead of returning it: the statement goes
through `aiq.sql_passthrough`, which is SECURITY INVOKER and read-only-enforced,
so inside a step it is as expressive as the rest of the step path and called
directly by a user it runs as that user under RLS. Routing it through the
DEFINER path instead would have handed every caller an owner-privileged read of
the whole database.

"As expressive as the rest of the step path" includes that path's trade: inside
a step the invoker is the engine owner, which bypasses RLS. `percolate.sql_policy
= 'registered'` refuses it, and until recently refused only the `sql:` spelling
-- a `p8ql:` step is not a `statement` in the compiled spec, so it went round
the check. It is refused at EXECUTION now, because a definition written while
the policy was open outlives the change. `dev/tests/workflow/13-open-sql.sql`
§5b.

---

## Templates

`{{run.x}}`, `{{steps.<id>.<path>}}` and `{{env.X}}` resolve **at dispatch**,
never when the workflow is defined — substituting at author time would make
the stored definition a snapshot of one run and make the recorded task input a
lie about what was sent.

### The run cannot see itself — unless you ask with `$`

`{{run.*}}` reads the **run input**. The run's own identity is under a reserved
`$` prefix:

| Template | Is |
|---|---|
| `{{run.$id}}` | this run's uuid |
| `{{run.$trace_id}}` | the trace id shared by every task in the run |
| `{{run.$external_id}}` | the idempotency key, if one was given |
| `{{run.$definition}}` / `{{run.$version}}` | the workflow name and version |
| `{{run.$started_at}}` | when the run began, ISO-8601 UTC |
| `{{run.$session}}` | an engine-minted conversation id — see agent steps |

The prefix is reserved rather than plain `{{run.id}}` because an input key
called `id` is not unusual, and shadowing it would make the same template mean
different things depending on the caller's payload. Writing `{{run.id}}` when
there is no such input key tells you to write `{{run.$id}}` instead.

This exists because run-scoped state — land rows keyed by run, aggregate them,
render — is the normal shape of a pipeline, and it **could not be worked around
by passing the id in as input**: the caller does not know the run id until
`start_workflow` returns. The value would have to be an argument to the call
that creates it.

`{{run.$*}}` is bound by the engine *before dispatch*, like `{{item.*}}`, so a
worker never has to learn the namespace.

### Every step nests its payload under `result`

`{{steps.<id>.result}}` is the one idiom to learn. A `sql` step returns
`{"result": ...}`, a `rest` step `{"status": 200, "result": ...}`, a `matrix`
step `{"result": {"task_id": ..., "fanout": N}}`. Reach into it with
`{{steps.<id>.result.<path>}}`.

Two resolvers, deliberately different:

- **`rest` steps** are resolved by the worker, which has `{{env.*}}` because
  endpoints live in its environment. It is an allowlist: `{{env.X}}` reads
  `P8_AGENT_URL`, `LLM_URL` and the comma-separated names in `P8_TEMPLATE_ENV`,
  and refuses any other with `template {{env.X}} is not readable by a
  workflow`. It never reads a credential: a secret goes by `credential_ref`,
  and only to an origin `P8_CREDENTIAL_ORIGINS` binds to it
  (percolate-core `percolate_core/core/egress.py`).
- **`sql` steps** are resolved in-database (`workflow.resolve_args`), and have
  **no `{{env.*}}`** — the database has no business reading the deployment's
  environment. A whole-string reference keeps its **native type**, so a vector
  arrives as an array rather than a string; one embedded in a longer string is
  **interpolated as text**, exactly as the worker does in a url.

The second half of that sentence used to read "only whole-string references are
substituted", and it was not a design decision that had been thought through —
it was a defect, sitting in this file's own opening example. `p8ql_vec` takes
the query as its first *argument*, and the documented pipeline passed
`'SEARCH "{{run.question}}" FROM chunks LIMIT 3'`. Not a whole-string
reference, so it was substituted nowhere: the literal braces reached
`aiq.query`, and `SEARCH` feeds that text to the **lexical** half. Full-text
search for `{{run.question}}` matches nothing, every `lexical_rank` comes back
null, and the fusion quietly degrades to semantic-only — on a query the caller
wrote *because* they wanted both halves. It returns rows. It looks like it
worked.

Type preservation was never in tension with this: a whole-string reference is a
value and still arrives as one. The database half was simply the last place
that had not learned the rule the worker and `{{item.*}}` already used.

---

## Matrix fan-out — the work to do is a query result

Argo Workflows expands a matrix with `withParam`: a step emits a JSON array, a
controller pod reads it, and one pod is templated per element. It works, and it
costs three processes and a serialisation round trip before any real work
starts — plus a window in which the emitting step is `done` and its children do
not exist, so a controller crash strands the fan-out with nothing to resume
from.

Both halves of the alternative already existed here and had not been put
together. `sql` steps run a query with no process; `complete_decision_task`
atomically completes a task **and** inserts the tasks it decided on. A matrix
step is those two facts in one function:

```yaml
  - id: fan
    matrix:
      rows: {function: tier1_concepts, args: ['{{run.tier}}']}
      max_fanout: 5000
      template:
        queue: edgar-xbrl
        rate_key: sec-edgar
        rest:
          url: https://data.sec.gov/api/xbrl/companyconcept/CIK{{item.cik}}/us-gaap/{{item.concept}}.json
          jsonpath: units.USD

  - id: checks
    needs: [fan]
    sql: {function: detect_restatements, args: ['{{run.tier}}']}
```

`items: [...]` replaces `rows:` for a literal set; exactly one of the two.

Zero processes expand the matrix, and **the parent cannot be `done` while its
children are missing, because they are inserted by the statement that completes
it.** That transaction boundary — not the syntax — is the whole difference from
Argo.

### `{{item.*}}` is bound at expansion — and this section used to say the opposite

The row is substituted into the template when the children are created, and
also kept verbatim on each child as `input.item`.

It was originally the other way round: store the row, resolve `{{item.cik}}` at
dispatch like `{{run.*}}` and `{{steps.*}}`. Running the example above against
the real SEC API killed that. All six children failed terminally with

```
unknown template namespace 'item' in {{item.cik}} -- expected steps, run or env
```

which is the **worker's** error, not the database's. Deferring had quietly put
`item` into the contract of a shipped worker image that knows three namespaces,
so the headline case for the entire feature did not work. Only `sql` children
had ever been exercised, because those resolve in-database where the namespace
had been added.

The reversal is also right on the merits. The "author-time resolution makes the
recorded input a lie" rule in Templates above is about a stored **definition**,
which is shared across every run and cannot be resolved in advance. A fan-out
child is not that — it exists for exactly one row, so substituting that row
makes its recorded input say *precisely what will be sent*. Deferring made it
say `{{item.cik}}` and forced a reader to join to `input->'item'` to learn what
was actually requested.

The payoff beyond correctness: a worker never learns that a task came from a
fan-out. Only `item` is bound here; every other namespace still resolves at
dispatch. A whole-string reference keeps its native type, so a numeric column
arrives as a number; one embedded in a URL is interpolated as text. Naming a
column the row does not have fails the matrix step **before any child exists**,
rather than becoming a literal `{{item.typo}}` in a URL and a 404 nobody can
explain.

**Row text is data, and it cannot open a template.** Substitution puts a row's
text into the child input, and that input is resolved again at dispatch: by
the worker for `{{run.*}}`, `{{steps.*}}` and `{{env.*}}`, and by the database
for a `sql` child's arguments. So a row whose text held `{{env.LLM_URL}}` was
resolved as a template. An uploaded session transcript that quoted a workflow
document failed terminally with `template {{env.LLM_URL}} resolved to
nothing`, and a document containing `{{env.<secret>}}` would have put that
secret into the prompt sent to the model provider. Two adjacent values could
also assemble one: a row of `{` beside a row of `{run.secret}}`.

Expansion now replaces every `{` in substituted row text with a sentinel chosen
per child, and records it as `input.braces` when it escaped anything. Each
resolver puts `{` back after its one pass, so the step receives the row's text
unchanged. A `sql` child's arguments are also templated only when they are
strings, so a batch of rows no longer comes back from resolution as a string.
Pinned by `dev/tests/workflow/04-matrix.sql` §8b-bis. The worker half is
`percolate-core`'s `templates.resolve_task`, and both halves are needed: an
older worker sends the sentinel to the model instead of `{`, and an older
database leaves row text unescaped.

### The fan-in had to be built

`checks` above declares `needs: [fan]`, and the natural assumption — that
`pending_deps` already handles this, being an AND-join — is **false**. Its one
edge points at the *matrix* task, which completes at expansion time. `checks`
would fire instantly, over nothing, and the run would report success.

So expansion does three things: insert the children, **rewire every successor
onto them** (an edge each, `pending_deps` incremented to match), and only then
complete the parent. The cascade then decrements the original edge, leaving
exactly N outstanding. An empty row set leaves zero, which correctly releases
the successor immediately — "nothing changed since last time" is the normal
state of a polling pipeline, not an incident.

### Where the row set is recorded

A matrix is a decision task in `spec.md` §5's sense: pure with respect to a
recorded snapshot. A query over live tables is not pure — a watchlist changes —
and the resolution is that **the row set is the snapshot**.

It is not stored where you would first put it. Five thousand rows do not fit in
a 64KB task output, so the matrix task records only a **digest** (count and
hash), and the rows themselves live on the children they produced, one each,
inside the payload cap by construction. `workflow.matrix_rows(task_id)` reads
them back in order. A re-expansion producing a different row set is refused by
name; one producing the same set is a no-op.

### Rows come from a query, or from a registered function

```yaml
  - id: fan
    matrix:
      rows: "select id from documents where processed_at is null"
      max_fanout: 500
      template:
        queue: extract
        work: true
```

This used to be refused, on the same reasoning that refused a `sql:` statement:
expansion is `SECURITY DEFINER`, so a step supplying a statement is a
privilege-escalation primitive with a YAML front end. That reasoning still
describes what happens — it is simply the trade the `open` policy now takes
everywhere, and a fan-out over "everything nobody has processed yet" is the most
natural thing anyone writes here.

Two differences from an ordinary statement step. A row source is **always
read-only**, whatever the step says: it is re-run by every retry of the
expansion, and a row function that mutates while deciding how many children to
make has no good reading. And `rows: {function: …, args: […]}` remains, for the
same reasons it remains on a `sql:` step — and it is what `percolate.sql_policy
= 'registered'` restricts you to.

### `max_fanout` is mandatory

A three-way cross join with a forgotten `WHERE` inserts the cartesian product
as task rows. The ceiling is refused at *authoring* time by the compiler and at
*registration* time by `validate_matrix_steps` — a spec can also arrive as JSON
without passing through the compiler — and blown at *expansion* time before a
single child exists, terminally, because it will fail identically on every
retry.

### The fan-in

The matrix step's output is `{"result": {...}}`, like every other kind, and
carries the handle a successor needs:

```yaml
  - id: report
    needs: [fan]
    sql: {function: edgar_report, args: ['{{steps.fan.result.task_id}}']}
```

`workflow.matrix_outputs(task_id)` — allow-listed, so it is also usable as a
step in its own right — returns every child with its row, status and output
paired (`item` on an ordinary child, `items` on a batched one; exactly one of
the two is non-null). Reduce inside your own function: 5,000 outputs are for aggregating, not
for passing around as a step argument, which hits the payload cap immediately.

Both halves of this were missing at first and the omission was described
wrongly. The output was a bare object, so `{{steps.fan.result}}` — the one
idiom every other step kind teaches — resolved to nothing on exactly this one.
And the digest said how many children there were and nothing about how to find
them. The note claiming no aggregation was needed because "children write to a
domain table and the successor is a `sql` step over it" is true for `work`
children and **false for `rest` ones**, which are the whole worked example: a
generic worker records a response and knows no domain.

### Batching — one child owns a chunk, not a row

A matrix has exactly one granularity by default: one row, one task. That is
right when a row is somebody else's HTTP endpoint, because the task *is* the
concurrency unit and the rate limit is per call. It is wrong the moment a row
is cheap — a hundred four-millisecond writes become a hundred claims,
heartbeats, completions and cascade cycles, and the engine costs more than the
job.

```yaml
  - id: fan
    matrix:
      rows: {function: pending_chunks}
      max_fanout: 5000
      batch_size: 10             # up to ten rows per child
      partition_by: [tenant]     # ...and never two tenants in one child
      template:
        sql: {function: land_chunks, args: ['{{items}}']}
```

`batch_size` says how many rows one worker may own. `partition_by` says which
rows must not be split across workers — a bare string or a list, and rows
sharing those column values stay together. Either one alone makes the step
batched; together they **partition first and then cap each partition**, which
is the combination with an actual use: *group by tenant, but no single task
swallows more than fifty*. Partitions come out in order of first appearance,
and rows keep their source order inside a batch, so the child keys are a
deterministic function of the row set.

The alternative — have the row function return chunks — works and is worse: it
moves a scheduling decision into a domain query, where no reader of the YAML
can see it and no reader of the query can explain it.

**A batched child carries `items`, not `item`.** Its input holds `items` (its
rows, in order) and `batch` (`{index, size, key}`); an unbatched child carries
`item` exactly as before. The shape says how many rows the task owns, so
nothing downstream has to guess. Always emitting `items` — an array of one when
unbatched — would have been the smaller rule and the worse one: every existing
handler and fan-in reads `item`, and rewriting them all to unwrap a
one-element array buys uniformity at the cost of the thing that made the row
visible.

**`{{items}}` is how a child reads its batch**, and it binds at expansion
beside `{{item.*}}` — so a batched `rest` child can POST its ten records as a
request body, and no worker learns the task was batched. It is a *whole value*:
`args: ['{{items}}']` or `body: '{{items}}'`, never spliced into a string,
because an array interpolated into a URL is a request that is wrong in a way no
status code reports. On an unbatched child it is an array of one — which is
what keeps `batch_size` a number you can turn up or down without rewriting the
function underneath it.

**`{{item.<col>}}` still works on a batch — for a column constant across it.**
That is not a leniency; it is the reason `partition_by` is a partition and not
a sort. `partition_by: [tenant]` guarantees `tenant` is one value inside the
child, so `.../t/{{item.tenant}}` means something. Naming a column that varies
fails the step **before any child exists**, with the remedy in the message,
rather than silently substituting the first row's value — a task that processes
fifty rows and addresses one of them, which looks correct in every test written
at a batch size of one.

**`max_fanout` still counts rows.** Letting it count children would be the easy
reading, and would slip a five-million-row cross join past a ceiling of 5,000
by declaring `batch_size: 1000`. The ceiling guards the row set; batching
decides who carries it.

#### What batching costs

Stated because it is not free:

- **Tolerance gets coarser.** `continue_on` and `min_success` count *children*,
  and a batched child is a batch: one failure loses ten rows instead of one, and
  a 90% floor over ten batches tolerates a single failure rather than ten.
- **Retries are per task**, so a retried batch re-does every row in it. An
  idempotent handler is a precondition, not a nicety.
- **The payload cap is now a function of a number in the spec.** N rows in one
  task input is the only place in the engine where that is true, so expansion
  checks the built input against the cap itself and names `batch_size` as the
  remedy — the generic "reduce the payload" message would send you looking for
  the wrong thing.
- **A fan-in written against `item` needs `items`.** `matrix_outputs` returns
  both and exactly one of them is non-null per child; `matrix_rows` flattens
  batches back to the row set, because it returns the snapshot and batching is a
  decision about who executes it.

### Surviving a failed child

```yaml
  - id: fan
    matrix:
      rows: {function: tier1_concepts, args: ['{{run.tier}}']}
      max_fanout: 5000
      continue_on: failed        # a failed child satisfies its dependents
      min_success: 0.9           # ...but at least 90% must succeed
      template: {...}
```

`min_success` takes a fraction (≤ 1) or an absolute count (> 1), because "at
least 8" and "at least 90%" are different intentions and a fan-out whose width
comes from a query cannot always express one as the other. Setting it without
`continue_on` is refused: the first failure would cancel the successors, so the
threshold could never be reached, and the spec would read as if it could.

Two things this had to get right. A tolerated failure must **satisfy** its
dependents, not merely stop cancelling them — skipping the cancel without
decrementing `pending_deps` leaves the aggregate blocked forever, which is
worse than a cancellation because nothing reports it. And the threshold is
checked **before** the successor is released, because a `sql` successor
auto-runs inside the statement that marks it ready.

`min_success` is a **transport** floor. A 200 carrying an empty body counts as
a success; whether the content is useful is the aggregate's job, and
`matrix_outputs` gives it every child's status so it can say so.

### Known sharp edges
- **A large response becomes an artifact ref.** One ordinary single-company
  XBRL concept came back at 69,248 bytes against the 64KB cap. The shipped
  worker offloads an output over the cap: it writes the bytes to object
  storage, registers them, and returns `$artifact` beside the payload
  (`core/percolate_core/worker/artifacts.py`; see *Payload limits* below).
  Without object storage installed the engine still fails the task terminally,
  with the remedy named.
- **No aggregation namespace.** There is no `{{items.<step>}}`; children
  deliberately do not write into `runs.context`, because one JSONB column
  rewritten in full per completion is quadratic write amplification at fan-out
  scale. `matrix_outputs` is the handle-and-reader version of the same thing,
  and a namespace should be promoted only when it can express something that
  cannot.
- **Nested fan-out is rejected**, not supported-but-buggy: a child has no
  static successors to rewire, so grandchildren would never be joined to
  anything and the run would complete before they finished. *Batching* is the
  thing people usually want nesting for — a child that owns many rows — and it
  is above.
- **`min_success` counts children, and batching changes what a child is.** A
  90% floor means something different at `batch_size: 10` than at one row per
  task, and the spec does not warn you: it is the trade you made when you set
  the number.

---

## A vector query is two tasks, and you write one

A `sql` step cannot embed text: that is a model call, and the database makes no
outbound calls by design. So a vector mode is *embed, then search* — two tasks,
and that does not change. What changed is who writes them.

```yaml
- id: retrieve
  p8ql: 'SEARCH "{{run.question}}" FROM chunks LIMIT 5'
```

compiles to:

```
retrieve__embed   http_call   {"url": …, "body": {…}, "jsonpath": "embedding"}
retrieve          sql         p8ql_vec('SEARCH … USING nomic-embed-text LIMIT 5',
                                       '{{steps.retrieve__embed.result}}')
                              depends_on: [retrieve__embed]
```

`LOOKUP`, `GRAPH` and `TEXT` need no vector and stay one task.

**The embed is a prepended predecessor, not a child**, and that is what makes
this cheap where `matrix:` was not. Your step id stays on the step that
produces the result, so every successor still says `needs: [retrieve]` and
still reads `{{steps.retrieve.result}}`. Nothing downstream is rewired, because
nothing moved. `queue:` on the step routes the **embed** half — the search half
runs in-database and is claimed by nobody — so `queue: embed` gives the model
calls a pool of their own without touching anything else.

**The default is `http`, and that is worth knowing next to the pools recipe.**
The example Kubernetes deployment builds a worker pool named `embed` whose workers run
`--queue embed`, because that is the pool the KEDA example scales. An `embed:`
step does not land there unless you say `queue: embed`: the default is the
queue the shipped worker already polls, since a step routed to a queue nobody
polls does not fail — it waits, which is the failure mode with no symptom.
Deployments that run a dedicated embedding pool should say so on the step, and
`SCHEMA "workflow"` lists every queue anything has actually used.

### Throttling one, and why it was unauthorable

An embedding endpoint is the canonical rate-limited call, so:

```yaml
  - id: q
    embed: '{{run.question}}'
    rate_key: openai-embeddings
```

`rate_key` is a step key like `queue`, and `claim_task` refuses to hand out a
task whose budget is spent. **It was accepted only inside a `matrix:` template
until this was written**, which meant the only throttleable call in the system
was a fan-out child — and `start_workflow` had been reading `rate_key` off a
step and writing it to the task the whole time. Same shape as `signal`,
`timer` and `sub_workflow` (§*When the compiler is older than the schema*): an
engine capability with no way to reach it from the document, found by trying to
write the obvious thing. `compiler_capabilities()` probes it, so a build that
predates it says so rather than dropping the key and leaving the step
unthrottled.

### You never write the url, and that is the point

`embed:` is the one action whose endpoint is not yours to write:

```yaml
- id: q
  embed: '{{run.question}}'                    # the deployment's default model
- id: q2
  embed: {text: 'battery safety', model: nomic-embed-text}
```

The url, the request body's shape and the path to the vector in the response
come from `aiq.embedding_models` and `aiq.embedding_providers`, and
`define_yaml` writes them into the step. Three things follow, and only the
first is ergonomic:

1. **A deployment fact stops living in a document that outlives deployments.**
   The registry's `endpoint` may itself be `'{{env.LLM_URL}}/api/embeddings'`,
   so one row serves dev, staging and production.
2. **Nothing new ships.** After expansion this is an ordinary `http_call` on an
   ordinary queue, run by the shipped worker's built-in handler, with retry,
   backoff, the reaper and tracing already applying. An `embed:` step is not a
   new deployable and not a second execution path.
3. **The two halves can no longer mean different models.** This is the one that
   was not an ergonomics problem at all — see below.

### The invariant the two-step form could not hold

An embedding is only comparable inside the space of the model that produced it.
`ai-query-layer/schema.sql` §10 puts it as strongly as it can — cosine distance
between two spaces is "meaningless, not merely imprecise" — and then left a
workflow author holding both ends of it: the `rest:` step named one model, the
query named another with `USING` (or took the default), and **nothing checked
that they agreed**. `aiq.semantic_in` checks the *dimension*, and two 768-dim
models are the same width. The run completes. Every number in it is noise.

So the model is resolved **once, at definition time**, and pinned into both
halves: written into the query as `USING <model>` when it was not already
there, and refused when it was there and disagrees.

```
step 'retrieve' searches the 'nomic-embed-text' space but is handed a vector
produced by 'other-768'. Nothing downstream can catch this: cosine distance
between two embedding spaces is a number, not an answer, and the dimension
check passes whenever the two models happen to be the same width.
```

The pairing is read off the **data flow** — a `p8ql_vec` step whose arguments
reference `{{steps.<an embed step>.result}}` — rather than off a marker the
compiler left behind. That is deliberate: it means the hand-written pair is
checked exactly like the shorthand, so reaching for the raw form is not how you
keep the old defect.

Pinning at definition time rather than at dispatch is the other half. The
stored spec then says which model it meant, and a run does not re-decide
because someone moved `is_default` in between.

### What is refused, and when

Everything here fails while you are authoring, with the step key in the
message, rather than on the third task of a run:

| Written | Refused because |
|---|---|
| `embed: {model: no-such-model}` | not in `aiq.embedding_models` |
| a model registered with no `endpoint` | it is a *space*, not a *call* — the two registrations are made in different places by different people |
| a model whose `provider` has no row | nothing knows its request body's shape or where the vector sits in its response |
| the mismatch above | the vector and the space come from different models |
| a `matrix:` templating `SEARCH` | a template is one step and a vector query is two — but `template: {embed: ...}` is fine, and embeds per row |
| an `embed` marker in a spec inserted as JSON | it never passed the expander, so it has no url — caught by the lint, which is the one gate all three doors into `workflow.definitions` pass |

The last row is the interesting one. `define_yaml` is not the only way a spec
arrives; a migration and a hand-written JSON spec skip the expansion entirely.
An unexpanded marker is an `http_call` with no url, which the worker would
otherwise report as `terminal: http_call task has no 'url'` — a true statement
about a document nobody wrote.

**A matrix template is the other place a marker can sit**, and it was missed on
the first pass: the expander walked top-level steps, so `template: {embed: ...}`
compiled clean, stored a template with no url, and produced exactly that
worker error once per child. Per-row embedding is the obvious use — fan out
over chunks, embed each — so it was reachable rather than theoretical. Both the
expansion and the lint now look in both places, and nothing is pinned inside a
template because a template is one step: no query in it consumes the vector,
and a successor reads the children through `matrix_outputs` with each child's
model recorded on the child.

```yaml
  - id: fan
    matrix:
      rows: {function: chunks_to_embed, args: ['{{run.resource}}']}
      max_fanout: 5000
      template:
        embed: '{{item.text}}'
```

---

## Agent steps

An `agent:` step names a row in `agentic.agents`. The agent's prompt, tools and
delegation are **data**, so changing them never touches the workflow:

```yaml
  - id: triage
    agent: classifier
    input: 'Classify: {{steps.retrieve.result}}'
    session_group: analysis         # the ENGINE mints one id per (run, group)

  - id: deep_dive
    needs: [triage]
    agent: researcher               # may itself delegate to other agents
    input: '{{steps.triage.result}}'
    session_group: analysis         # ...so these two share one conversation
```

**Sessions.** Declaring `session_group` asks the engine for a session id, stable
for the life of the run and bound to `{{run.$session}}`. Steps naming the same
group share a conversation; two groups in one run are two independent threads;
declaring neither stays stateless, which is the right default for a
classification step. An explicit `session: <id>` still wins, for a caller
threading an id it already holds.

Before this, a workflow could not *originate* a session — `session:` resolved
only if the caller had put an id in the run input, and the natural key derives
from the run, which the run could not see.

**That was verified against a stub, and the real runtime never shared one.**
The stub was a fault-injection test server, which echoes a body key `session` back, so two
steps "landed in one conversation" there. The Agent Runtime reads `session_id`
or the `X-P8-Session-Id` header, ignores `session`, and answers 404 for an id it
has no `agentic.sessions` row for, so every grouped step opened a conversation
of its own (REM-957). The compiled step now sends `session_id`, and
`get_task_context` creates the session row as the run's owner before the worker
calls. `dev/tests/workflow/25-the-langgraph-article-runs.sql` §7 pins both, and
the run behind it put two steps into one session of four messages on the
published compose stack.

**Capturing more than the text.** `jsonpath` defaults to
`choices.0.message.content`, which is what almost every step wants. Override it
to capture the envelope instead — a session id the runtime issued, token
counts, tool traces — which were otherwise discarded before reaching
`runs.context`:

```yaml
  - id: audit
    agent: auditor
    jsonpath: ''        # the whole response, not just the assistant text
```

This compiles to an `http_call` at the Agent Runtime with
`credential_ref: P8_API_KEY` — so an agent step is an ordinary REST step whose
URL and auth the compiler fills in, and nested delegation happens inside the
runtime rather than being unrolled into the workflow graph.

---

## Agent steps with a declared output shape

An `agent:` step returns whatever a model felt like returning. The moment you
fan out over N documents and try to combine the verdicts, you need the shape
without inspecting each one — declaring it turns a pile of prose into a column.

```yaml
  - id: classify
    agent: triage
    input: 'Classify: {{item.text}}'
    output_schema:
      type: object
      required: [verdict, confidence]
      properties:
        verdict:    {type: string, enum: [SAFETY, FINANCE, OTHER]}
        confidence: {type: number}
```

The engine parses the answer (a model returns its structured output as message
*content*, i.e. a string) and checks it before anything is stored. Combined
with `matrix`, that is the useful shape: fan out over documents, each child an
agent step with the same schema, and a fan-in that can count `verdict` values
without defensive parsing.

**A shape violation is retryable**, and it is the only failure in this engine
deliberately classified that way. Every other terminal classification exists
because retrying cannot help — a 404 stays a 404, an oversized response stays
oversized. Here the same prompt genuinely can produce conforming output on the
next attempt, so `max_attempts` becomes a real budget for "ask again".
Verified: a step whose endpoint violates its schema twice and conforms on the
third attempt completes in three attempts.

**It is a shape check, not JSON Schema.** Types (including `integer`),
`required`, `properties`, `enum`, `items`, and `additionalProperties: false` —
which is what "combine N agent results safely" actually needs. `$ref`,
`allOf`/`anyOf`/`oneOf`, `pattern`, `format` and numeric bounds are *not*
supported, and are named here rather than silently ignored. Implementing them
in PL/pgSQL would produce a validator nobody audited, wrong in ways only a
corpus would reveal.

Declaring `output_schema` on a `sql` or `matrix` step is refused: the check is
for output this engine did not produce. A registered function's return type is
already known.

## Saga

```yaml
  - id: charge
    rest: {url: ..., method: POST}
    compensate_with: refund
    saga_group: booking
```

Compiles to `compensation_task_key` + `saga_group`, so
`workflow.begin_compensation()` undoes completed steps in reverse order.

**A compensation is kept out of the forward graph; anything it depends on is
not.** A compensation task is created only if the rollback happens, but its
dependencies are ordinary steps that run on every run — including every run
that succeeds. The vector sugar makes this easy to reach without noticing,
because `compensate_with: unwind` where `unwind` is a one-line
`p8ql: 'SEARCH ...'` quietly puts a model call on the happy path; the shape
predates the sugar, since any `needs:` on a compensation step does the same.

It is a **warning**, not a refusal, because it genuinely works — verified by
running a saga to rollback: the compensation resolved
`{{steps.unwind__embed.result}}` and executed. What it does not do is what the
author is picturing, and the cost lands on the runs that never fail.

---

## When the compiler is older than the schema

The compiled parser and the SQL schema ship independently and will eventually
disagree. `workflow.compiler_capabilities()` probes the installed build with a
canary per feature and reports what it *actually* accepts:

```sql
select workflow.compiler_capabilities();
-- {"accepts": {"matrix": false, "output_schema": false, ...},
--  "missing": ["continue_on","matrix","output_schema","signal","sub_workflow","timer"]}
```

`define_yaml` refuses a document declaring anything in `missing`, **including
when it compiles clean** — and that last part is the whole point. A missing step
*kind* fails loudly, so it is easy to notice. `output_schema` is not a kind:
serde drops the unknown key, the document compiles, and the declared contract
simply is not there at runtime. An author who writes a contract and gets a green
run reasonably concludes it is enforced.

A silently dropped contract is worse than an unsupported feature, so this
refuses rather than warns, and says which of the two happened.

**The desugar needed a third kind of probe, and finding that out is the useful
part.** `p8ql_vector_desugar` cannot be probed by compile-success *or* by a key
name. A compiler that predates it accepts `p8ql: 'SEARCH …'` — the document is
correct as written, and always was — and emits a single step calling the
one-argument `p8ql`, which fails at dispatch with `SEARCH … needs
p_embedding`. There is no key to match on and no compile error to catch, so the
canary **counts the emitted rows**: two means the desugar is there. The general
trap the `output_schema` note names ("it did not error" and "it did the thing"
are different questions) has a third case — *it did a different thing, and the
difference is not in the vocabulary at all.*

The same skew is also caught on the way in, by the lint: a `p8ql` step whose
query parses to `SEMANTIC` or `SEARCH` is an error, because that step ranks
against an embedding and passes none. Two mechanisms, deliberately: the probe
explains *why* to a person reading capabilities, the lint refuses the spec
whatever door it came through.

Two other things are refused rather than dropped, for the same reason:

- **An unknown key on a step** is a compile error listing the valid ones, so a
  typo (`ouput_schema`) cannot be mistaken for a feature.
- **`session`, `session_group` and `jsonpath` outside an `agent:` step**, which
  would otherwise be accepted and emit nothing. This is the rule the query
  dialect already applies to `USING`, `DEPTH` and `TYPE`: a modifier that means
  nothing where it is written is an error, because silently discarding it is how
  a document quietly means something other than what it says.

## What the compiler checks, and what the engine checks

Two different questions, both worth asking:

- **The compiler** (`p8_compile_workflow`, Rust/serde_yaml) rejects malformed
  YAML, a step with zero or two action keys, and a `needs` naming a step that
  does not exist — with the offending step id in the message.
- **The engine** (`validate_spec`, on insert) rejects duplicate keys,
  unreachable steps and cycles with no entry point.

Compilation is in the `percolate_parser` extension rather than a service, so authoring
is SQL-native: no process needs to be running to define a workflow.

---

## Payload limits, and the artifact ref

Task `input`/`output` are capped (default 64KB, `workflow.max_payload_bytes`).
A 768-dimension embedding is ~10KB of JSON and passes; anything genuinely
large goes to object storage and comes back as a ref. The default was raised
from 8KB after a real pipeline hit it — 8KB rejected ordinary structured
intermediates, which pushed authors toward offloading things that did not
warrant it.

**A vector is the one payload whose size you know in advance**, and it is worth
knowing where the ceiling is, because the remedy this section names does not
apply to it: an artifact ref resolves to a resource id, and `p8ql_vec` takes
the array. Measured at full float precision, an embedding costs **~20.3 bytes
per dimension**, so the 64KB default holds about **3,200 dimensions**:

| Model width | Bytes | Against the 64KB default |
|---|---|---|
| 768 | ~15.5KB | comfortable |
| 1536 | ~31KB | comfortable |
| 3072 | ~62KB | 95% of the cap |
| beyond | — | raise `workflow.max_payload_bytes`; there is no other remedy |

`dev/tests/workflow/09-embed-sugar.sql` §16 asserts the ordinary case still
fits and reports the arithmetic, so lowering the cap fails loudly rather than
breaking every vector workflow quietly.

**The ref is a sibling of `result`, not a value inside it:**

```json
{"status": 200, "result": {"pages": 12}, "$artifact": "9f3c…-uuid"}
```

The bytes are registered with `workflow.register_artifact(task_id, checksum,
bucket, object_key, size_bytes, …)`, which returns a **resource id** — a row in
`content.resources`, not an `s3://` URI. That is what makes an artifact
RLS-scoped, checksum-deduped, servable by the Content Server, and visible to
`content.check_drift`; a bucket path in a JSONB column is none of those, and
drags a bucket name into a row that is meant to stay inspectable and
replayable.

Reading it back is an ordinary argument — no worker, no process:

```yaml
  - id: render
    work: {queue: reports}          # writes the PDF, registers it, returns the ref

  - id: index_it
    needs: [render]
    sql: {function: artifact, args: ['{{steps.render.$artifact}}']}
```

`{{steps.<id>.$artifact}}` resolves like any other template — `resolve_args`
already admitted `$` in a path, so the spelling needed no resolver change.
A step that produced *only* bytes writes no `result` at all, and
`{{steps.<id>.result}}` then fails loudly, which is correct: there is no value.

### `$ref` was the old spelling, and it never worked

It said return `{"$ref": "s3://…"}`. The size check uses the jsonb `?`
operator, which is **top-level only**, while every step nests its payload under
`result`. Probed at a 64KB cap: `{"$ref": …}` at the top passed the check and
broke every `{{steps.<id>.result}}` reading it; `{"result": {"$ref": …}}` kept
the templates working and was refused as oversized. No shape satisfied both —
a better account of "the worker never implemented it" than "nobody got to it".

The size *bypass* that came with it is gone rather than re-spelled.
`not (output ? '$ref')` exempted a payload that was over the limit **and**
carried a ref — one that offloaded its bytes and then inlined them anyway. A
real ref is about thirty bytes and was never going to trip the cap, so the
exemption had no legitimate caller and admitted exactly the case the rule
exists to reject. The limit is unconditional now.

Both mistakes fail terminally and say what to write instead: the old `$ref`
key, and a `$artifact` holding a bucket path rather than a resource id.

---

## Higher-level steps: what was promoted, and what was not

`embed` was the obvious candidate and it is now the only one. The rule this
file has always stated —
the project's promotion rule, applied to syntax —
is **generalise on the second independent consumer, not the first**, and the
argument for waiting was written here in full: an abstraction designed from
anticipated duplication gets a `raw: true` escape hatch bolted on the moment a
second pipeline wants something slightly different.

What changed is not that the duplication got worse. It is that **the second
reason turned out not to be ergonomic at all.** Writing the embed step by hand
was tedious; writing it by hand *and* naming the model in a second place, with
nothing checking the two agreed, was a correctness hole with no run-time
symptom (§*The invariant the two-step form could not hold*). A shorthand that
only saved typing could reasonably wait. One that closes a silent
wrong-answer path could not.

The promotion test held, and it was run rather than asserted:
`dev/tests/workflow/09-embed-sugar.sql` §2 diffs the stored spec of the
shorthand against the stored spec of the hand-written pair and requires them to
be **equal**. If they ever diverge, this stopped being sugar and became a step
kind needing the argument that goes with one.

Three candidates from the same list are **still deliberately absent**, and the
distinction is worth stating because it is the same one that let `embed`
through:

- **`chunk:`** — "chunk this document" has no single right answer (fixed
  window, sentence, semantic, per-format), and nothing about choosing wrong
  fails silently: you can see the chunks. It is a shorthand that would save
  typing and hide a decision the author must make.
- **`scrape:`** — a `rest:` step plus a parser, where the parser is the whole
  job. There is no deployment-level registry that could supply the missing
  half, which is exactly what made `embed:` expressible.
- **`summarise:`** — an `agent:` step with a prompt. The prompt is the
  content; naming it in YAML rather than in `agentic.agents` moves data into
  code.

The test that promoted `embed` is what refuses these: is there a **fact the
deployment holds and the document cannot** — a registry row that turns an
under-specified action into a fully specified one — *and* does writing it by
hand admit a failure nobody sees? For `embed` both answers are yes, twice over.
For all three of these the first is no.

**`matrix:` remains the counterexample that proves the rule**, on the other
side. The test above is "every high-level step must remain expressible in raw
steps" — a shorthand that cannot be is not a shorthand. `matrix:` cannot be: N
is not known until a query runs, so no fixed set of raw steps expresses it, and
the atomic expand-rewire-complete has no spelling in the existing vocabulary at
all. It is a new `kind`, argued for as one, with its own engine function and
its own tests. `embed:` is the opposite case in every respect — it is one
ordinary `http_call`, and the compiler's whole contribution is knowing where to
point it.

**Where the expansion lives, and why not in the worker.** The obvious home for
this was a new `@handler` in the worker: an `embed:` kind that looks the model
up itself at dispatch. It is one place, it is code, and it would work. It is
the wrong place for two reasons. A dispatch-time lookup re-decides the model on
every run, which is the drift the pin exists to remove — the stored definition
would say `embed`, not *which* embedding. And it would make an `embed:` step a
capability of the **worker image** rather than of the database, so a deployment
could not add a provider without shipping one. Expanding at definition time
from a registry keeps both: the answer is recorded where a reader can see it,
and a new provider is a row.

`ai-query-layer/brief.md` §3.5 states the same generalise-on-the-second rule for
schema and algorithms; step vocabulary is the third place it applies.

---

## Not built: `sequence:`, the dependency you did not have to write

**Status: designed, argued, not implemented.** Recorded here rather than in an
issue because the argument is the useful part and it is about this file's
vocabulary.

### The duplication, counted

Across every workflow document in this collection — specs, references, tests,
fixtures — **21 of 24 `needs:` clauses name the step immediately above**. One
skips backwards (`report` needs `fan`, over `checks`), and two are genuine
multi-dependency joins. So seven eighths of the dependency syntax written here
carries nothing that the document's own order does not already carry, and the
promotion rule in the section above is met several times over on volume alone.

### Why not simply make `steps:` sequential

Because the order of `steps:` means **nothing** today — `validate_spec` computes
reachability from `depends_on` and no code anywhere reads list position. Giving
position a meaning inside the existing key would silently re-interpret every
document that has two root steps: intended parallelism becomes a chain, with no
error, on a definition that already ran. That is the failure this file refuses
in every other place it appears.

It is also not what Argo does, and Argo is the right precedent to read closely
here. Argo has `steps:` (positional, nested lists for parallelism) **and**
`dag:` (explicit `dependencies:`), as two constructs that never mix inside one
template. The separation is the design: once one document can express edges two
ways, a reader has to compute the graph from two sources to know what runs
when. This engine is the `dag:` one — `pending_deps` is an AND-join, fan-in
rewires real edges, cancellation and saga cascade along them.

### The shape

An opt-in at the **document** level, so the document says which discipline it is
under by which key it uses:

```yaml
name: hybrid_research
sequence:
  - id: retrieve
    p8ql: 'SEARCH "{{run.question}}" FROM chunks LIMIT 3'
  - parallel:
      - id: judge
        agent: classifier
      - id: score
        sql: {function: score_run, args: []}
  - id: reindex                 # waits for BOTH
    sql: {function: rebuild_graph_index, args: [company]}
```

- `needs:` inside `sequence:` is **refused**. A pipeline that needs a real DAG
  writes `steps:`. This is Argo's cliff and it is the price of not having two
  edge notations in one document; conversion is mechanical, and the compiler
  should say so in the refusal.
- `parallel:` replaces Argo's nested-list spelling (`- - name: a`), which is the
  one part of its positional form that is genuinely hard to read. A group waits
  for everything in the group before the next item begins.
- It compiles to explicit `depends_on` like everything else, so the **stored
  spec is unchanged** — the graph a reviewer reads in `workflow.definitions` is
  the same graph either spelling produces.

### Acceptance: the same diff test

`sequence:` must compile to exactly the rows the `steps:` spelling of the same
pipeline produces, asserted the way `dev/tests/workflow/09-embed-sugar.sql` §2
asserts it for `embed`: two definitions, one equality. A spelling that produces
different rows is not sugar.

### What it needs first, found by running it rather than by reading

**The lint requires a DIRECT dependency for any `{{steps.x}}` reference, and its
stated reason is false for an ancestor.** Given `a → b → c` where `c` reads
`{{steps.a.result}}`:

```
error | reads {{steps.a...}} without depending on 'a' --
        it resolves to null whenever this step runs first
```

`c` cannot run before `a` in that graph. `runs.context` accumulates every
completed step's output, so a **reachable ancestor** is exactly the condition
that makes a reference safe, and the direct edge is merely the easiest case of
it. Under explicit `needs:` an author works around this by naming both
(`needs: [a, b]`), which is why it has never been reported; a chain has no such
escape, and reading a non-adjacent earlier step — a fetch at step 1 whose id
step 5 wants — is the ordinary shape of a pipeline.

So `lint_spec` (c) must become a reachability check before `sequence:` is worth
having. That fix stands on its own merits and does not wait for this feature:
the current rule refuses a correct diamond today.

### The cost, stated rather than discovered later

A stored definition is versioned, and under `sequence:` a **reorder of the
source rewires the DAG**. It is not silent everywhere — the compiled
`depends_on` changes, so the graph edit is visible in `workflow.definitions`
and in `SCHEMA "workflow"` — but it is invisible in the YAML diff, where a
moved block reads as a formatting change. That is the whole of what is being
traded for the seven eighths above, and it is the reason this is opt-in per
document rather than the default.
