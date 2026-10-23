# The plan graph

**Authoritative on: what a stored workflow definition reaches, how that is
computed, and which of those reaches are checked.** A companion to
[`spec.md`](spec.md) (the engine) and [`YAML.md`](YAML.md) (the authoring
surface); neither of those answers the question this document exists for.

`workflow.definitions.spec` is a DAG of steps and nothing else. What a step
*reaches* is spread across four schemas: the agent an `agent:` step calls, and
that agent's tool servers and the tools it is narrowed to on each (`agentic`);
the corpus a `p8ql:` step ranks and the space it ranks in (`aiq`); the function
a `sql:` step is allow-listed to run, and the queue and rate key that decide
whether the task is ever claimed (here). `validate_spec` checks the graph's
*shape* — no duplicate keys, no unknown dependency, no cycle with no entry —
and has nothing to say about whether the things a step names exist.

Every one of those reaches is a place a plan can be wrong in a way that
compiles, registers and starts.

Two things follow from writing the join down once, and they are the two the
ticket that produced this document asked for:

- **How data moves through the schema.** A step reads this corpus; this corpus
  is embedded in that model; that model's space is a table with rows in it. The
  chain is three joins across two schemas and nobody was holding it.
- **What an agent is actually able to do.** Its prompt, its model, the servers
  it binds, the tools it is narrowed to on each, and — through a server with
  `serves_agents` — the agents it may hand work to. Intent, and whether the
  intent is backed by anything.

## 1. The shape of it

```
workflow.plan_document('triage')   -- the pipeline, read top to bottom
workflow.plan_graph('triage')      -- the same resolution, as nodes + edges
workflow.plan_defects()            -- every current definition, defects only
workflow.plan_catalog()            -- what this deployment HAS, as one document

workflow.plan_probe('triage')      -- the cheap half of every step, EXECUTED
workflow.plan_status('triage')     -- what the last run actually returned
```

The first four read. The last two answer the questions reading cannot, and §7
says why they had to exist.

`plan_graph` returns `{ok, workflow, nodes[], edges[], defects[], stats}`.
Nodes carry a stable `id` of the form `kind:name`, so the same agent named by
three steps is one node with three edges into it — **and a `detail` object,
which is the entity it stands for, expanded.**

`plan_document` is that same graph projected into the shape a person reads:
steps in rank order, each carrying what it does and the entity it does it to,
inline. §6 says why both exist and what the document deliberately drops.

## 2. Where the split falls, and why

The graph is built in Rust (`extension/percolate_parser/src/plan_graph.rs`) and
the catalog is read in SQL. It is the same split `aiq_parse` already draws:

```
workflow.plan_graph(name, version)          -- SQL: fetch the spec
  └── workflow.plan_catalog()               -- SQL: what exists, RLS-filtered
        ├── agentic.plan_facet()            -- optional
        └── aiq.plan_facet()                -- optional
  └── p8_plan_graph(spec, catalog)          -- Rust: pure, immutable
```

**The catalog is an argument, not a fetch.** `p8_plan_graph` makes no query, so
the graph a caller gets is built from exactly the rows that caller could see —
one RLS decision, taken by Postgres in ordinary views, rather than a second
authorization model living inside a graph builder. It also makes the function
`immutable` and `parallel_safe`, and unit-testable with no database at all.

**A `p8ql` step is parsed, not pattern-matched.** Its source and model are read
by running the step's query through the same `parse_query` that will execute
it. A regex over the query string would be a second, worse implementation of
the dialect, and its failure mode is exactly the one this module exists to
catch: a graph that disagrees with the executor about what a step means reports
health for a plan that does something else.

**Every call into the extension is dynamic.** `percolate_parser` is a separate
extension and the engine installs without it. plpgsql plans a whole statement
before any guard inside it runs, so `if to_regprocedure(...) is not null then
select p8_plan_graph(...)` raises on a deployment that lacks it — the guard has
to sit outside a statement the planner never resolves. `EXECUTE` is what makes
the check mean what it reads as. This is also why `plan_defects` is a
set-returning function rather than the view it would naturally be: a view
referencing `p8_plan_graph` could not be *created* where the parser is absent,
which would turn an optional dependency into a load-time one.

## 3. The vocabulary, closed

An open vocabulary becomes a synonym pile within a month, and a viewer, an
audit and a diff all need to know every kind that can appear.

| Node kind | Is | Lane |
|---|---|---|
| `workflow` | the definition, and any sub-workflow it invokes | workflow |
| `step` | one step; a matrix template is one of these too | step |
| `agent` | a row in `agentic.agents` | capability |
| `tool_server` | a row in `agentic.tool_servers`, or an external host a `rest:` step calls | capability |
| `tool` | one callable on one server (`server/tool`) | capability |
| `function` | a row in `workflow.step_functions` | capability |
| `llm` | the model an agent runs on | capability |
| `source` | a registered corpus (`aiq.semantic_sources` / `lexical_sources`) | data |
| `model` | a row in `aiq.embedding_models` | data |
| `entity` | a row in `aiq.entity_registry` | data |
| `relation` | a table or view a statement step reads | data |
| `queue` | a worker pool | control |
| `rate_key` | a shared throttle | control |
| `signal` | a person, waited on by name | control |

| Edge kind | From → to |
|---|---|
| `contains` | workflow → step |
| `needs` | step → step (the DAG proper) |
| `compensated_by` | step → step |
| `calls` | step → agent \| function \| tool_server |
| `reads` | step → source |
| `embeds_with` | step → model |
| `ranked_in` | source → model |
| `expands_over` | matrix step → the function producing its rows |
| `expands_to` | matrix step → its template step |
| `binds` | agent → tool_server |
| `may_call` | agent → tool |
| `exposes` | tool_server → tool |
| `delegates_to` | agent → agent |
| `runs_on` | agent → llm |
| `summarised_by` | agent → agent |
| `invokes` | step → workflow |
| `waits_for` | step → signal |
| `claimed_from` | step → queue |
| `throttled_by` | step → rate_key |

A **matrix** shows its template as one node, not N children. Drawing N would be
a lie about a number nobody knows until the rows are counted.

**Delegation is followed, and it is not also a tool.** The agent gateway is an
ordinary `tool_servers` row whose tools *are* agents (`serves_agents`), so its
entries become `delegates_to` edges into expanded agent nodes rather than
`tool` nodes. Following stops at depth 4 and says so; a delegation cycle is
legal at runtime and truncation is not evidence of one.

## 4. The catalog, and the one column nothing else answers

```
select jsonb_object_keys(workflow.plan_catalog());
  agents · servers · sources · models · entities · functions · queues · rate_keys · workflows
```

Sections are keyed by name because the builder does lookups, not scans. **A
section that is absent means the subsystem is not installed**, and the builder
treats that as *cannot judge* rather than *everything you named is missing* —
without which a plan graph on an engine-only install would be forty errors
about agents instead of a graph with agents in it.

`aiq.v_plan_sources.spaces` is the column no other view in this collection
carries: which models a corpus is **actually embedded in**, as opposed to which
are registered. Registering a model creates an empty table, so the honest form
of the question is about data:

```
  name  | semantic | lexical |             spaces
--------+----------+---------+--------------------------------
 chunks | t        | t       | ["demo-quad-a", "demo-quad-b"]
```

That row is also why the view is a `full join` rather than a `union`: `chunks`
is registered both semantically and lexically, and a union would have produced
two entries for one name, the second overwriting the first — with the lexical
row's empty `spaces` winning about half the time.

## 5. The defects, and what each one costs

Each carries a `severity`, the node it is about, and the **consequence of
leaving it alone**. The third field is the one that makes the report useful:
*unknown queue* is a shrug; *nothing sizes a pool for this queue* is a decision.

| Code | Severity | The failure it names |
|---|---|---|
| `space_model_split` | error | A query ranks a corpus in a space that corpus has no vectors in. Returns rows, not an error. |
| `unknown_rate_key` | error | `try_consume_rate_limit` updates no row and returns false, so `claim_task` skips the task **forever**. |
| `unknown_agent` | error | The runtime 404s every call; the step exhausts its retries on a name that was never going to resolve. |
| `unknown_function` | error | `execute_sql_step` raises on dispatch — the allow-list working as intended, against a plan that cannot run. |
| `unknown_source` | error | The query returns zero rows rather than raising, which is indistinguishable from a corpus with nothing to say. |
| `unknown_model` | error | No endpoint to call, or no space to rank in. |
| `unregistered_server` | error | The agent runs with a strictly smaller toolset than its definition claims, and answers anyway. |
| `unknown_sub_workflow` | error | `start_workflow` raises at dispatch — the parent fails at the point of the call rather than at registration. |
| `dangling_dependency` | error | The step is never ready and the run stalls with no failure to report. |
| `unknown_relation` | warning | A statement names a table nobody can see. A heuristic over SQL this crate does not parse, so a warning rather than an error. |
| `unconsumed_read` | warning | A step that only reads, that nothing depends on, beside a leaf that acts. Either the caller's second output or a wiring mistake. |
| `unbound_tool` | warning | The allow-list names a tool the server's synced list lacks. A stale `cached_tools` is the other explanation. |
| `unsynced_server` | warning | Nothing has ever asked the server what it exposes, so no allow-list can be checked against anything. |
| `unconfigured_queue` | warning | Default lease, and no autoscaler sizing the pool. |
| `corpus_not_embedded` | warning | The corpus has no vectors in any space: not wrong, early. The search returns nothing until something embeds it. |
| `no_space` | warning | A model registered without `register_embedding_space()`: embedding succeeds and there is nowhere to land the vector. |
| `delegation_depth` | warning | The graph is truncated here. |

**`space_model_split` is the one this is for.** `aiq.expand_embed_steps` pins
one model into both halves of the sugar path, so `p8ql: 'SEARCH … FROM chunks'`
cannot rank in a space it did not embed into. The hand-written pair — an
`embed:` step and a `p8ql_vec` step the author wired together — is outside that
guarantee by construction, and its failure is not an error anywhere: cosine
distance between two spaces is a number, just a meaningless one.

**A statement step is checked by what it READS, not by what it names.** With
`sql: "select ..."` there is no registry entry to look up — the allow-list
stopped being mandatory (`YAML.md`, *A step may carry its own SQL*), and a plan
that said nothing about a statement step would have got worse as the engine got
more expressive. So the relations after `FROM` and `JOIN` are extracted and
checked against what the caller can select, CTE names in the same statement
removed. It is strictly a better question than the old one: naming a table that
does not exist is the mistake people make, and naming an unregistered function
was mostly the mistake of not having asked an administrator yet.

It is also a heuristic, and labelled one everywhere it appears. `from (select
…) t` and `from jsonb_array_elements(x) e` are skipped rather than guessed at,
which means the extraction under-reports by design; a checker that refuses a
working pipeline on a guess is worse than one that stays quiet.

**Overlap with `lint_spec`, stated rather than tidied away.** The engine's lint
already *warns* at insert time that an agent step names an unregistered agent.
The plan graph does not replace it and is not novel there. What it adds is (a)
one report across four schemas instead of one, (b) an answer for definitions
that were inserted as JSON and never linted, and (c) an answer **later** — a
deployment drifts after registration, and `plan_defects()` re-asks the question
against today's catalog.

## 6. Two views, one resolution

The graph answers *what does this reach, and does it resolve*. That is the
right shape for a checker and the wrong shape for a person, who wants the
pipeline: step, then what that step says and does, with the agent's prompt, the
corpus's columns and the tool's description sitting **where they are used**
rather than in a node list to be joined by eye.

```yaml
- id: classify
  kind: agent
  about: asks agent percolate (on anthropic:claude-sonnet-5)
  needs: [retrieve]
  input: 'Classify this outage report using only the passages: {{steps.retrieve.result}}'
  calls:
    agent: percolate
    model: anthropic:claude-sonnet-5
    system_prompt: |
      You are Percolate, the agent for this database...
    servers:
      - {server: p8-query, kind: mcp, url: 'http://query-mcp:8090', synced_at: null}
    tools:
      - {tool: p8-query/query}
  output_schema: {required: [verdict], ...}
  defects:
    - {severity: warning, code: unsynced_server, message: "tool server 'p8-query' has never been synced"}
```

**The document is a projection, never a second resolver.** It reads the graph
that was already built — two views that resolved separately would be two
answers to the only question that matters, and the second one would be wrong
first.

**Curation is the point, and the omissions are the design.** No constraints, no
indexes, no RLS policies, no full JSON Schemas, no ids or lanes or ranks. An
expansion that reproduces everything a workflow touches is a document nobody
reads twice, which fails in exactly the same way as not expanding at all. The
rule for what stays: *if two steps of the same kind would differ in it, it
describes the pipeline.* A url does; a timeout does not, until it does.

The one place the document follows a reference an extra hop is an **agent** —
its servers, its tool allow-list with each tool's description, and who it may
delegate to. That is what an agent can *do*, and a plan that names the agent
and hides those has expanded nothing.

## 7. Probing, and the last run — the two questions reading cannot answer

Reading the plan for a pipeline you did not write leaves two gaps, and both were
found by doing exactly that against a real SEC pipeline.

**What shape does a step return?** An author writing
`{{steps.land.result.cik}}` has no way to know `cik` is a key of it: the
registered function returns `jsonb`, and a statement step returns whatever its
`SELECT` list says. Every prompt written against an upstream step is written
against a shape the plan cannot show.

**Does any of it actually work?** The graph checks that names resolve. It does
not know whether the statement parses, which relations the planner really
touches, or whether the step's argument list matches the signature it names.

### `plan_probe` runs the cheap half

Nothing here executes a step. `EXPLAIN` without `ANALYZE` plans and discards;
`CREATE VIEW` validates and plans without running. So probing a five-step
pipeline costs no SEC request, no model call and no row.

**And that is a property of how the statement is WRAPPED, not of `EXPLAIN`.**
The sentence above was true of the read branch and false of the write branch
for as long as both existed, because plpgsql's `EXECUTE` runs a string of
several statements one after another and `EXPLAIN` covers only the first.
Measured on a live 0.2.0 before the fix: `explain (format json) insert into t
values (1); insert into t values (99); select 1` explained the first insert,
**performed** the second, and returned a plan with no error. The trailing query
is what makes it work — without one, `INTO` raises `42601` and the
subtransaction takes the write back, which is why a payload ending in a query
is the one to defend against.

So each branch is wrapped in something only one statement can parse as:

| branch | wrapped as | what cannot parse |
|---|---|---|
| read | `select * from (%s) t` | anything but a single query |
| write | `with p8_write as (%s returning 1) select count(*) from p8_write` | anything but one INSERT, UPDATE, DELETE or MERGE |

**But the wrapping alone did not hold, and the wrapped string is OPENED AS A
CURSOR rather than `EXECUTE`d.** An author who closes the wrapper's bracket
himself reopens it: `update t set x=x where false returning 1) select 1; set
local request.jwt.claims = '{"sub":"<victim>"}'; with p8_write as (update …`
wraps into three statements, and under `EXECUTE` the `SET` ran and the third
acted as the victim (REM-64, measured — the victim's row was rewritten through
`execute_as_viewer`). SPI refuses to open a multi-statement string as a cursor
(`cannot open multi-query plan as cursor`) and parses the whole string before
running any of it, so nothing after the semicolon executes. That is the exact,
SQL-only enforcement; the wrapping is what makes a legitimate statement parse as
one query, and the cursor is what refuses a string that is more than one.

The write wrapping has one home, `workflow.one_write_statement`, because it was
written for `execute_as_viewer` — which needs it for the same reason, so that a
`SET request.jwt.claims` cannot ride along and change whose rows a step acts on
(REM-64) — and `plan_probe` needed the same rule and did not have it. Both
callers ask that function and open the result as a cursor now.
`dev/tests/workflow/18-a-probe-runs-no-step.sql` asserts a smuggled second write
and a smuggled `SET` are both refused, with a control that fails if the probe
stops probing; `workflow/15` §4b asserts the bracket break-out is refused before
anything is written.

The install also refuses to finish if a new function reachable by
`authenticated` starts building SQL at run time without being declared —
`specs/identity/closing.sql`, which holds that set as a list checked in both
directions. Membership is not an accusation; the install failing when the set
changes is the review.

```
   step   |   probe   | verdict |                     detail
----------+-----------+---------+-------------------------------------------------
 quarters | parses    | ok      | the planner accepted it
 quarters | relations | ok      | reads sec_facts
 quarters | returns   | ok      | {"fp": "text", "fy": "integer", "val": "numeric"}
 typo     | parses    | fail    | relation "sec_factz" does not exist
 land     | arity     | fail    | 'record_chunks' is registered with 2 argument(s)
                                  and this step passes 1
 land     | function  | ok      | p_resource_id uuid, p_chunks jsonb returns integer (may write)
 ask      | env       | skipped | needs P8_AGENT_URL from the worker's environment
 ask      | agent     | ok      | agent 'percolate' exists
```

Four things there are worth more than the rest:

- **`relations` comes from the planner**, which retires the regex §5 uses to
  guess. The heuristic stays in the graph (which must stay pure), and the probe
  is where the real answer lives.
- **`returns` is the output shape before the first run.** A temp view is
  validated and planned at creation and executes nothing, so the column names
  and types are readable for free.
- **`arity` compares the step's argument list to the registered signature.** At
  dispatch that failure reads `function f(text) does not exist`, which sounds
  like a missing function rather than a step passing one argument to something
  that takes two.
- **`skipped` is never `ok`.** The worker's environment, an outbound url,
  whether a credential resolves: all belong to a process this database
  deliberately cannot see, and a probe that passed them would be the false pass
  this collection keeps removing.

Templates are substituted with `null` before probing, because `{{run.cik}}` is
not SQL. That is enough for parsing, relations and column types, and it is
honestly less than a run: a query whose `WHERE` resolves to null plans the same
and returns nothing.

### `plan_status` is the run beside the plan

```
   step   | status | attempts |                      returned
----------+--------+----------+----------------------------------------------------
 quarters | done   |        1 | {"of": {"fp": "string", "fy": "number", ...}, "rows": 2}
 tally    | done   |        1 | {"of": {"n": "number", "peak": "number"}, "rows": 1}
```

Shapes, not values — keys and their types, or a row count. The values are one
select away and would make this unreadable for a fan-out that returned four
thousand rows.

**Which role may ask, which this document did not say.** `plan_status` is granted
to `authenticated`; the other five are operator diagnostics (app_owner or a direct
session) until `workflow.definitions` adopts scope, and are revoked from
`authenticated` in `integration-rbac.sql`. Those five read `workflow.definitions`
only — configuration, the same for every caller. `plan_status`
is the one that reads run rows, and a run belongs to somebody.

It is `SECURITY DEFINER` over `workflow.may_access_run(run, 'select')` — the
predicate REM-77 extracted, which `cancel_run`, `signal_task` and
`reusable_run` already ask — with `rbac.is_operator()` as the leading arm, so a
direct session keeps the installation-wide diagnostic it has always had. Two
consequences for a person, and both are the capability rather than the
mechanism:

- **With no run id it answers about *your* newest run** of this workflow, not
  the installation's. The newest run of an installation-wide definition belongs
  to whoever started it, so "the newest run" is only a well-formed question
  once it is scoped to the asker.
- **Naming somebody else's run returns no rows**, rather than their steps. The
  run id is filtered through the same view rather than trusted.

This paragraph used to say it was `SECURITY INVOKER` "on purpose: `workflow.tasks`
is RLS-enabled and per-tenant, so a caller sees the runs their policies admit."
The policies never ran: `authenticated` holds no `SELECT` on `workflow.runs` or
`workflow.tasks` at all, so the grant check refused first and every call raised
`permission denied for table tasks`. A capability offered to every signed-in
caller that none of them could use, for as long as nobody called it as one
(REM-81). `surface.sql` did not catch it because it asserts that an object
exists, never that a role can reach it — its own §3 debt.

Reading `runs_api`/`tasks_api` instead was tried and is wrong: those views are
owned by `api_viewer` so RLS applies to them, which is what makes them safe for
`authenticated` and also what makes them **empty for an operator** — `app_owner`
with no JWT has no `current_user_id`, so `plan_status` returned nothing to the
caller who has always used it.

The join was already there — `workflow.tasks` is keyed `(run_id, step_key)`,
which is why every step node carries `step_key` (§8).

### What a step does to the world

Every step node now carries `effects`, from a closed set: `reads`, `writes`,
`network`, `model`, `waits`, `fans_out`, `invokes`, `unknown`. Before this, `sql`
covered a query and a delete, and `http_call` covered a free GET and a paid
completion — so a reader could not tell what a plan would spend or change.

`writes` for a registered function is not a guess. It comes off
`pg_proc.provolatile`: a `STABLE` or `IMMUTABLE` function *cannot* write,
because Postgres refuses to let it. That fact is what makes the next check safe.

### `unconsumed_read`

A step that only reads, that nothing depends on, **beside a leaf that does
something**. In the SEC pipeline that was `resolve` — a `LOOKUP` whose result
went into `runs.context` and which no step ever read. Either the caller's second
output, or a step somebody meant to wire in; the defect says which step it is
and lets the reader decide.

The narrowing matters. The first version fired on any read leaf, which meant it
fired on a one-step query workflow — the most ordinary thing anyone writes,
whose answer *is* that query. It lasted one test run.

## 8. The viewer: designed, not built

`percolate-core` gets a viewer eventually; this document is what it will read,
and the contract exists now so that adding one is not a schema change.

- **Every node has a stable `id`**, so a layout can be cached across versions
  and a diff between two versions of a definition is a set difference.
- **Steps carry `rank`** — longest path from a root, which is the only ordering
  a DAG layout needs — and every node carries a `lane` (`workflow`, `step`,
  `capability`, `data`, `control`) for the swimlane a viewer will want.
- **Steps carry `step_key`**, which is the join to runtime state.
  `workflow.tasks` is keyed `(run_id, step_key)`, so colouring a plan with a
  live run is a join rather than a second graph:

  ```sql
  select n->>'id', t.status
    from jsonb_array_elements(workflow.plan_graph('triage')->'nodes') n
    left join workflow.tasks t
      on t.run_id = :run and t.step_key = n->>'step_key';
  ```

  The same join reaches `task_events` for a timeline. **This is deliberately
  not built here**: an overlay is a query a caller writes, and baking a
  `p_run_id` argument into `plan_graph` would put a runtime concern inside a
  function whose entire value is that it is pure and reads only configuration.

## 9. Status, and what running it found

**Verified end to end**, on PG19 with the dev stack's own fixtures loaded: the
Rust half has 20 unit tests, the regenerated extension installs from scratch,
the parser compiles with `p8_plan_graph` in it, and
`dev/tests/workflow/11-plan-graph.sql` passes against a live database with the
freshly built `.so` in place -- including §8 there, which asserts the document
expands the corpus and the agent AT THE STEP that uses them rather than merely
naming them.

That test **skips its graph half loudly** where the installed
`percolate_parser` predates `p8_plan_graph`, in five notices rather than
passing quietly -- the same honesty `check_hot_paths()` applies when it refuses
to pass on a shallow queue. A green run proves only the catalog half unless the
graph notices are absent.

Three things came out of pointing it at the collection's own fixtures, and all
three are why a checker has to be run against real data before it is believed.

**A false positive, fixed.** `agent_of` matched any url ending
`/v1/chat/completions`, reasoning that the Agent Runtime is OpenAI-shaped. The
dev stack's `ask_uploads` has a `rest:` step straight at
`https://api.openai.com/v1/chat/completions` whose `body.model` is
`gpt-4o-mini` -- a **model** name, not an agent -- and the graph reported
`unknown_agent` against a step that is entirely correct. It now matches
an exact agent url, via `workflow.agent_name_path`, and nothing else. A checker that invents defects is worse than
no checker: the first false positive is what teaches a reader to skip the
report.

**`ask_uploads` ranks a corpus in a space it has no vectors in.** True, and
reported as an error:

```
     wf      | severity |        code        |     node
-------------+----------+--------------------+---------------
 ask_uploads | error    | space_model_split  | source:chunks
   step 'retrieve' ranks 'chunks' against 'text-embedding-3-small',
   but that corpus is embedded in: demo-quad-a, demo-quad-b
```

The dev corpus is seeded with literal four-dimension vectors so that
`SEMANTIC`/`SEARCH` are reproducible without an embedding server
(`dev/init/05-corpus-sample.sql`), while `ask_uploads` is written for a
deployment with a real model. Both are correct on their own terms, and the
consequence is still that on this database that query ranks nothing -- which is
exactly the statement no other surface in the collection makes.

**The dev stack has no `workflow.queue_config` rows at all.** Every queue in it
-- `http`, `ingest` -- runs on `claim_task`'s and the reaper's fallbacks (a
lookahead of 20, a two-minute lease). Nothing else says so, because the
fallbacks are correct code and a queue that works is indistinguishable from a
queue that was configured. `11-plan-graph.sql` asserts the warning is present
rather than tolerating it, so the day a row appears for `http` that assertion
is what notices.

## 10. Not done, deliberately

- ~~**No `surface.sql` rows yet.**~~ Done: the four entry points and the two
  facets are registered there now, so a build that ships without them fails the
  audit rather than the first caller.
- **No viewer**, per §8 -- the contract is here, the drawing is not.
- **No status overlay inside `plan_graph`.** §7 builds it as its own function; a `p_run_id`
  argument would put a runtime concern inside the one function whose whole
  value is that it is pure and reads only configuration.
