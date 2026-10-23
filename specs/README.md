# Percolate specifications — index

This folder is *what* the Percolate extension builds: one directory per subsystem, each with its narrative, its schema and the tests that hold it.

[**Research platform**](research-platform/core-claims-contract.md) moves reusable
research, trust, engagement and access into Percolate, and specifies the existing
REST/MCP integration.

Five systems, each speced independently but sharing one philosophy: **Postgres is
the system, not the backing store for one.** Identity, permissions, workflow state,
agent conversations, graph/semantic queries, and the world model all live in
Postgres as tables, functions and views — the
application layer is kept as thin as the problem structurally allows.

## What the design is answerable to

Three words, each of which some mechanism in here has to keep rather than the
collection asserting it about itself: **expressive**, **secure**, **scalable**.
The first is load-bearing, and it does not mean what it usually means.

### Expressive — of the control structure, not of the syntax

The question is whether this collection can state how a mixed collective of
people, models and processes coordinates, or whether it forces that into a shape
borrowed from a paradigm built for something else. Most of what we inherit is
inverted for this problem:

- **Code is the noun and data is what code operates on.** But a model is
  stateless and its process disposable, so the process cannot be where anything
  lives.
- **The human calls and the machine returns.** Here the machine initiates and the
  human is the slow, optional, highest-authority participant — request/response
  has both the latency and the agency the wrong way round.
- **Control flow is written before the run.** But choosing the next step is
  itself the work, so a fixed plan is too rigid and a model looping freely is no
  control structure at all.
- **The tool registry lives inside the runtime.** That makes the process the
  locus of capability, so what an agent may do is a deployment artifact rather
  than something you can query, scope and audit.

The correction is not a better orchestrator, it is moving the locus. **State is
the coordination substrate, and tools, models, sources and people attach to it as
edges.** Work is deposited rather than dispatched and whoever can act forages
against the same medium, which is what lets participants that unlike coexist:
they are not callers and callees in a protocol, they are readers and writers of
one field. A delegation is a parent row rather than a stack frame; a fan-out is
decided by a query result inside the transaction that completes its parent,
rather than by a controller holding a plan; a tool is an OpenAPI or MCP binding,
so *what may this agent do* is a join. The consequence people notice first — that
a capability is authored rather than deployed — is the symptom, not the claim.

It is also what makes human-in-the-loop a data-model question instead of a
scheduling one. A scheduler that has to hold a policy about a person who answers
in six hours has three options and all three are bad: hold the slot, time out, or
escalate. Against a substrate the
decision is just a row: a `signal` step sits in `waiting_external` costing no
process, and `signal_task` checks who you are through the same RBAC as everything
else. The direction that extends it is that a standing judgement should outlast
what surrounds it rather than win by a priority column, and that a question
deposited at a locus should change the field for every future forager rather than
unblock only the agent that asked — a proposal held under the rule that no
task waits on a human. The same reasoning is why a
permitted and recorded override beats a hard block: a gate nobody can override
gets routed around outside the system, where nothing observes it.

And it is why these are one collection rather than five products. **Multimodal
query, workflow dynamics, communication semantics and ingestion are normally four
systems, and the coordination problem then lives in the seams between them** —
which is exactly where this class of system fails: a vector built by a different
model than the space it is ranked against, a citation pointing at a chunk that
has since been re-ingested, a workflow that cannot see the conversation that
spawned it, an approval no audit trail records. In one substrate those seams are
joins. That is *Postgres is the system* argued from the demand side rather than
the implementation side.

### Secure — enforced by the substrate, checked at load time

No role is a superuser, the role owning the `*_api` views is not the role owning
the tables, every `SECURITY DEFINER` function pins its `search_path`, and both
invariants are self-checked at load time rather than stated in prose. Because the
four concerns above meet in one place there is one authorization model over all
of them instead of one invented per service: the tools an agent may call, the
rows a query returns, the files a run may read and the tasks a worker may claim
are the same RLS decision, taken where the data is rather than in whichever
process happens to be holding it. That is the form the guarantee has to be in
before a large organisation puts its own data behind it — in the substrate,
rather than in every caller's discipline.

### Scalable — no coordinator, and the hot paths measured

Postgres is the queue: `SKIP LOCKED` claims, `pg_notify` recruits without an
addressee, KEDA sizes the worker pool to queue depth, and no component holds the
plan, so removing any worker degrades throughput without stopping the system. One
queue means one backpressure story rather than four, and
[`workflow-engine/scale.md`](workflow-engine/scale.md) carries the numbers —
including the claim path that was two orders of magnitude slower than it should
have been until somebody measured it.

The three are not independent, and expressivity is the one under pressure from
the other two: everything sayable has to stay enforceable by a policy and
boundable by a scheduler. That is why the refusals belong to expressivity rather
than working against it — a query whose vector and search space use different
models is refused at compile time because the mistake returns a plausible number
instead of an error, and `max_fanout` is mandatory because a forgotten `WHERE`
should cost one step rather than the database. The Ground rules below are where
all three are actually paid for.

## Why these five systems

This is, deliberately, a rough analogue of the subsystems a brain needs, not a
grab-bag of infrastructure. A real agentic system that has to manage and organize
an online existence the way a human does — knowing who it's talking to and what
they're allowed to do (`user-rbac`), reliably carrying out multi-step intentions
over time (`workflow-engine`), recalling and relating what it knows on demand
(`ai-query-layer`), holding a conversation while delegating sub-tasks to itself
(`agentic`), and continuously taking in and making sense of the world outside it
(`world-model-ingestion`) — needs roughly this set of capabilities, not more, not
fewer. None of the five is optional and none stands in for another; that's the test
for whether something belongs in this repo as a sixth system, or belongs inside one
of the existing five.

### And two that ship in core without being one of the five

`research` (24 tables) and `engagement` (7) are in the extension. They fail the
test in the paragraph above — remove them and all five still do their jobs — and
they are core regardless. **What ships in core is core, and saying so is the
point; leaving it as an accident of where somebody wrote it was the problem.**

**They are the memory half, and this document already asked for them.** The
section below says *Memory systems are that same world model written back from
the system's own use*, and then names no mechanism. These are the mechanism.
`research` and `claims` are a **trust-centric claims model**: what the system
knows held as claims rather than as blobs, each anchored to the revision that
asserted it, carrying its sources, citations, argument edges and human
endorsements, with `research.trust()` returning every component and refusing to
collapse them into a score. That is an answer to memory rather than to
publishing, and the writing product is one consumer of it.

`engagement` belongs with it for the same reason and not as a social layer: a
person is part of what is remembered. What somebody saved, followed, voted
useful, valued or commented on is a signal about the claims, and treating the
actors as outside the memory is what makes a recommendation unexplainable.

**The test they pass** is the capability test: a
person using another Percolate client keeps the same research, signals and
permissions without installing the writing hub, and removing the hub from a
disposable stack leaves research, trust and engagement usable. That is the test
for a platform capability. The five-systems test above is the test for a
subsystem, and applying it to a capability was the confusion.

**What the capability test excludes is the part that earns it.** The
publication tables — branding, editions, writer applications, commissions,
editorial decisions — fail it, because nothing outside the writing hub needs them. They belong to the
application that needs them and install themselves there, and no core foreign
key, trigger, view or policy may reference them.

So the line between the two is a sentence somebody has to write: **a table that
cannot be described without naming one product belongs to that product.**
A new table is asked that question in review.

### The context a model receives

All five meet in one place: the context of a single model call. The collection
describes that context with the five components of context engineering, defined
once in [`agentic/brief.md` §5.0](agentic/brief.md). **System instructions** and
**tool definitions and outputs** are `agentic` rows. **Conversation state and
history** is `agentic`'s `messages`, windowed and summarized per branch.
**Retrieved knowledge** is `ai-query-layer` over what `world-model-ingestion`
put into the world model. **Memory systems** are that same world model written
back from the system's own use. `user-rbac` decides which rows of each a caller
may put in front of a model, and `workflow-engine` runs the scheduled work —
summarization, consolidation — that keeps history and memory current.

| System | Status | One-liner |
|---|---|---|
| [`user-rbac`](user-rbac/schema.sql) | **Built** — `schema.sql`, `roles.sql` | Users, roles, permissions, sessions — maximal Postgres pushdown, FastAPI mints JWTs and does the handful of things SQL can't. |
| [`workflow-engine`](workflow-engine/README.md) | **Built** — `schema.sql`, `integration-rbac.sql` | DB-native task/DAG engine — Postgres is the queue, the state machine, and the saga log. Steps are authored in [YAML](workflow-engine/YAML.md) and compiled to task rows; `sql` steps execute inside Postgres with no process at all; a vector query compiles to its own embed step, whose endpoint is a registry row rather than a url in the document; a `matrix` step turns a query result into N tasks in the transaction that completes it, so fan-out needs no controller ([spec.md §15](workflow-engine/spec.md)); a scheduled workflow is a row and `pg_cron` drives one job for all of them ([spec.md §12b](workflow-engine/spec.md)). |
| [`ai-query-layer`](ai-query-layer/USAGE.md) | **Built** — `schema.sql`, two integrations, [`graph-identity.md`](ai-query-layer/graph-identity.md), two committed fixtures and an executed suite per surface (`dev/tests/query/`) | LOOKUP / GRAPH / PATH / RELEVANCE / TEXT / SEMANTIC / SEARCH / LAKE / SCHEMA plus plain SQL in one dialect (`FUZZY` is a modifier on `LOOKUP`, not a mode), on Postgres + pgvector + a `pgrx` parser, fronted by PostgREST. `SCHEMA` is the mode answerable before you know anything: a versioned capability document assembled from registered facets, derived from the catalog where it can be and verified by execution where it cannot ([schema.sql §13](ai-query-layer/schema.sql)). |
| [`agentic`](agentic/brief.md) | Brief + [`plugins.md`](agentic/plugins.md) + `schema.sql`, **installed and bound** — [`reference/`](agentic/reference/README.md) registers one agent over two tool servers; the turn itself is still unexercised here | Postgres data model + AG-UI-shaped REST/streaming contract for multi-agent conversations and delegation — interactive *and* scheduled runs are the same primitive. A declarative, tool-free runtime, deployed Postgres-adjacent like PostgREST: every agent is a row, every tool an OpenAPI/MCP binding, never runtime code. What an agent *knows how to do* is a row too — `skills` are markdown procedures loaded by name or discovered by similarity, and a `plugin` is the named bundle servers, skills and agents install and uninstall as. |
| [`world-model-ingestion`](world-model-ingestion/brief.md) | **Built** — `schema.sql`, `integration.sql`, and a Content Server that uploads, ingests and serves back, round-tripped through the published image. [Ingestion](world-model-ingestion/ingestion.md) parses, chunks and embeds five formats on upload. The **pull** side ships in part: [`polling.sql`](world-model-ingestion/polling.sql) gives an enabled channel with a `poll_interval` a schedule, and [`api-sources.sql`](world-model-ingestion/api-sources.sql) pages an API source with durable checkpoints. The declarative connector library of [`sources.md`](world-model-ingestion/sources.md) §16–17 (`connectors.sql`) is in `build-sql.py`'s `NOT_SHIPPED`, because its rows reach no channel. | Sourcing, corroborating and structuring real-world event data (and uploaded content) into the graph the other systems query. The hard, non-generic one. |

### Cross-cutting directories, which are not systems either

Four directories hold things every system depends on and none of them owns.
They are not in the table above because they fail its test — no system could be
built out of them — and they are not `trace-field`'s kind of directory either,
because they ship.

- [`contract/`](contract/schema.sql) — the published contract: every closed
  vocabulary and payload shape, derived from what the schemas enforce, so a
  client that has never heard of `percolate-core` can fetch it.
- [`identity/`](identity/spec.md) — **what a primary key must be and what a NULL
  is allowed to mean.** `percolate.uuidv5()` for a derived row, `uuidv7()` for a
  created one, and two registries that make a column declare whether its NULL is
  a value or an absence, and refuse an `org_id` that is nullable at all. Five
  catalogue assertions in
  [`checks.sql`](identity/checks.sql) refuse a schema that stays silent on
  either; `dev/check.sh` runs them.
- [`packages/`](packages/schema.sql) — **a domain, installed as a document.** A
  package is `agentic/plugins.md`'s plugin widened to carry its sources, its
  vocabulary and its work, on the same apply-and-prune mechanism and with the
  same provenance column. Its temporary half is a worker image for extractors
  that are not yet core.
- [`claims/`](claims/brief.md) — **a falsifier-typed claim, anchored to a
  symbol, re-asserted on the diff that touches it.** A layer the five compose
  into: relational rows, four graph edges, vector recall over rationale and a
  key-value discharge cache, all on the same objects — which is the *expressive*
  argument above made from the demand side rather than the implementation side.
  Built: [`schema.sql`](claims/schema.sql) ships the claims graph
  (claims, the transactions that make them, and `expresses` links to
  `research.claims`); [`graph.md`](claims/graph.md) is the design and
  [`sequence.md`](claims/sequence.md) the phased gates.

### A sixth directory that is not a sixth system

[`trace-field/`](trace-field/schema.sql) — **mostly a reading, partly a proposal,
nothing new built.** Its claim is that `workflow-engine` **already implements
stigmergy** in its execution tier and nobody wrote it down: work is deposited
rather than dispatched, workers forage by `SKIP LOCKED` rather than receive,
`pg_notify` recruits without an addressee, exponential backoff is evaporation,
the reaper decays an abandoned claim, and KEDA sizes the worker population to
trail strength. That reading is checkable against `schema.sql` line by line,
which is the point — a rebrand would be worthless, so the value has to be in
what it predicts.

It predicts two things. **Which extensions are foreign**: anything adding a
dispatcher, an assignment or an addressee is fighting the substrate whatever its
local merits. And **where the gaps are**, which turn out not to be randomly
placed — the engine has a rich *sense* side and almost no *deposit* side, so
nothing reinforces, and `tasks.priority` sits indexed in the claim path with
nothing writing to it. The proposals are `workflow.*` additions, not yet committed to,
and one new relation — a standing human judgement, which is the only thing here
with genuinely nowhere to live.

It gets a directory rather than a section because a smaller second half
lends two ideas upward into how agents assess findings — confidence as a time
constant, independence before volume — which touches `ai-query-layer` and
`world-model-ingestion`. It is not in the table above because it fails the test
in the paragraph before it; see § *Scope decisions*.

### Running any of it

[the repository README](../README.md#building-and-testing) is the precise answer to "what do I have to
run": `docker compose up`, or `CREATE EXTENSION percolate` on an existing
Postgres 19. Then PostgREST /
Content Server / Agent Runtime as needed, and your own worker only for step
kinds we do not ship. The install is verified against an empty database.

Two documents are worth reading before the specs themselves:

- [`workflow-engine/README.md`](workflow-engine/README.md) — a four-step
  pipeline walked end to end with captured output, showing which steps run
  inside Postgres and which need a worker.
- [`ai-query-layer/USAGE.md`](ai-query-layer/USAGE.md) — worked SQL and REST
  examples for every query mode, plus the two things that make results look
  "missing" (querying as a superuser; forgetting `request.jwt.claims`).

## House style — every spec ships three documents

The three are the narrative, its `schema.sql` and an `ontology.md`; a spec may
also carry a `sequence.md`.

1. **`spec.md` / `brief.md`** — narrative. What the system is, why it's shaped this
   way, what's pushed into Postgres vs. what structurally can't be, worked examples.
   A **brief** is the one-pager version written before deep implementation; it graduates
   into a full `spec.md` (+ `schema.sql`) once the system is actually being built.
2. **`sequence.md`** (optional) — a *spec about how to build and test the spec*: a gantt-like
   phased rollout with an explicit test gate at the end of every phase, so "build
   reliably" isn't left implicit. This is not a project-management artifact for its
   own sake — it exists because Postgres-native builds (extensions, new PG-version
   features, graph/vector indexes) fail in ways that are expensive to discover late,
   so each phase has to prove itself before the next one starts.
3. **`ontology.md`** — the minimum entity/relationship graph for the system: just
   enough nodes and edges that nobody has to hold the whole schema in their head to
   see how the pieces connect. Kept deliberately small — this is a map, not the
   territory (`schema.sql` is the territory).

A system may also carry **named design docs** alongside these three, where one
decision is too load-bearing to leave scattered through the narrative and too
detailed to sit in the brief. They are: `ai-query-layer/graph-identity.md`, authoritative on the
`nodes`/`node_keys`/`edges` schema; `ai-query-layer/graph-algorithms.md`,
authoritative on the compiled algorithms over that schema — what a budgeted,
anytime search costs at four million edges, which of ten proposals survived
being measured, and the number each parked one has to beat; `world-model-ingestion/ingestion.md`,
authoritative on what happens to a file between `POST /files` and a chunk that
answers a question — the parser per format, the three-layer policy, the batched
embedding half, and the defects executing it found; `world-model-ingestion/graph-index.md`,
authoritative on how a machine-extracted graph gets *into* that schema — the
structure-extractor family, the ordinal wire shape its null member emits, and
the three **residences** an extracted entity can resolve into (a typed Postgres
table, a Parquet dataset in the lake, or a candidate), under the rule that
identity is always in Postgres but payload need not be — and, with
`ingestion.md`, carrying a section of corrections that only running it
produced;
`world-model-ingestion/sources.md`,
authoritative on how an external source becomes a resource, an entity or a
moment; `world-model-ingestion/tradecraft.md`, authoritative on grading,
corroboration and track record — what the system is willing to assert, and on
what evidence; `workflow-engine/failure-modes.md`, described below; and
`workflow-engine/outputs.md`, authoritative on the four things a step can leave
behind -- an inline payload, rows, a validated assistant message, or a
registered artifact -- and on which of the four each step kind is allowed to
produce; `workflow-engine/plan-graph.md`, authoritative on what a stored
definition *reaches* -- the agent it calls and that agent's servers and tools,
the corpus a query ranks and the space it ranks in, the function, queue and
rate key that decide whether a task is ever claimed -- and on which of those
reaches are checked before a run rather than discovered during one.
Each is
pointed at from its brief rather than duplicating it — the
brief stays the narrative, the design doc is where the detail actually lives.

**`workflow-engine/failure-modes.md` is a different kind of design doc, and the
pattern is worth copying into the other four systems.** The others are
authoritative about a decision. That one is authoritative about **how this
collection goes wrong**: every entry was produced by running something, not
imagined, and each is grouped by the *shape* of the failure rather than by the
component, because the shape is what transfers — the specific bug gets fixed and
the class comes back somewhere else. It is the hardening surface, so it is the
document to read before designing a new step kind, a new audit, or a new
recovery path, and the document to add to whenever a failure does not fit an
existing shape. Its rule for earning a place is the same one `dev/tests/`
uses: an entry has to name the assertion that would notice the class
reopening.

## Ground rules

- **A new table holding deployment data must be registered for `pg_dump`, and the
  claim is checkable.** `pg_dump` does not dump the data of an extension's tables
  — it writes `CREATE EXTENSION percolate` and stops, on the reasoning that an
  extension recreates its own contents. That is right for a vocabulary and
  catastrophic for a table holding somebody's users, and it was measured: 52
  tables belonged to the extension, 2 were registered, and a dump of a seeded
  database carried no users, agents, graph nodes or content resources. Every
  backup ever taken held the schema and nothing else.

  So: **if the extension creates a table whose rows a deployment writes, add it to
  the `deployment_tables` array in [`contract/schema.sql`](contract/schema.sql)
  §4.** The same array is what `percolate.enums()` reads to mark a vocabulary
  `deployment` rather than `shipped`, so one registration answers two questions —
  whether a backup carries the rows, and whether the published contract may
  freeze them.

  **The check that holds you to it:** `dev/backup-carries-the-data.sh`, run by
  `dev/check.sh` on every push. It builds a from-zero install and asserts that
  every extension table which is *empty there* is registered — empty at install
  means every row it will ever hold came from a deployment. Forget the line and
  CI names the table and this file. It is deliberately not derived from the
  schema text: that rule was written, measured, and was wrong about nine of
  fifty-two tables, because seven are seeded by functions a text scan cannot see
  and two have an insert that matches nothing at install.

  **Tables that hold both kinds of row** — shipped *and* deployment rows, nine
  of them, listed in `seeded_tables` — are registered `WHERE NOT shipped`, and
  `contract/schema.sql` §4 records how a row is marked shipped when seeding and
  a deployment's own registration share one code path.


- **A screen is a view. The UI's surface area is a database object, and it is
  tested in the database tier.** Every list, table and tile a client renders
  resolves to one `*_api` view plus a filter, and every mutation to one
  `SECURITY DEFINER` function. The client is then CRUD over URLs — it composes
  nothing, joins nothing, and decides nothing — which is what makes the whole
  surface testable with `psql` and a second user, rather than with a browser and
  a person.

  The alternative is not neutral. A screen with no view behind it assembles its
  data in the client: three fetches and a join in JavaScript, where no test can
  reach it, no policy applies to it, and the shape it produces exists nowhere
  the database can be asked about. That is how a UI starts deciding what is
  true. The rule is the same push-down this collection applies everywhere — the
  fact belongs at the lowest layer that can refuse a violation of it — applied
  to the one layer that usually gets exempted.

  **What it takes, concretely.** Create the view as `app_owner`, hand it to
  `api_viewer` (`alter view … owner to api_viewer`), grant `select` to
  `authenticated`. A view is owner-privileged, so RLS on the base table is
  evaluated as the *view's* owner: with `api_viewer` — which owns nothing else —
  every policy applies to every caller. Create it as the table owner and it
  bypasses RLS silently; as a superuser, twice over. A view over a table with no
  policy of its own inherits scope by joining one that has (`task_events_api`
  joins `workflow.runs`), and that join is a security control rather than a
  convenience.

  **Three things this rule buys that are easy to miss.** A dashboard shape is a
  named object, so aggregates can stay disabled at the API tier (`PGRST123`) and
  a browser still gets its counts — from one plan, not from whatever group-by a
  caller composed over a million-row table. A permission question is answerable
  without a client: two JWTs and `curl` say what each user's screen contains. And
  writing the view is where the leak gets caught — `grant select on
  workflow.rate_limits` looks like the obvious way to build a queues screen, and
  publishes the email address of everyone who recently tried to sign in, because
  user-rbac keys login throttling into the workflow engine's token bucket. A view
  can filter that. A grant cannot.

  **The check:** a screen that cannot name its view does not ship. The client
  side of that discipline is worth stating too — where the database refuses, the
  UI shows the refusal, naming the object and the error Postgres returned,
  rather than rendering a plausible number. The views
  themselves are in `specs/workflow-engine/integration-rbac.sql` §c2, because
  `dev/owns-its-schema.py` will not let an application shape a core schema:
  they began as an app-side patch, and needing a view on `workflow.definitions`
  was the signal that the mechanism was general rather than a screen's.

- **A `SECURITY DEFINER` function that returns tenant rows is an RLS bypass.
  Either it filters explicitly, or it is `SECURITY INVOKER`.** The policies stay
  intact and stop being evaluated, so nothing about the schema looks wrong
  afterwards — which is why this is a rule rather than a review habit.

  The two legitimate uses of DEFINER are unchanged and are what it is for: the
  *trusted path* (signup, login, token issuance, `claim_task`, audit writes —
  work with no caller identity yet, or work the caller must not be able to do
  directly), and helpers over this collection's own configuration, which hold no
  tenant data to scope. Anything that reads a row somebody owns is neither.

  The case that keeps arising is retrieval. A search function is the one place
  where the leak is invisible from the tables: `ai-query-layer`'s modes are all
  invoker and say so on every function, because a definer version returns every
  tenant's chunks to a correctly-scoped caller. The pressure to make that edit
  recurs — a definer function needs no grant on the sources, so `permission
  denied for table chunks` reads like a request for DEFINER when it is a request
  for a GRANT.

  **Where the substrate cannot help: a service acting for a user.** The agent
  runtime opens its transactions with the caller's claims (`as_caller`), so RLS
  applies to a tool call exactly as it applies to that user — the confused
  deputy, closed. Postgres cannot check it, though: it sees a connection that
  set a role and some claims and cannot know whether they were the right ones.
  So this half is a convention, and the question to ask of any new tool is
  whether it borrows the caller's identity. `agentic/brief.md` §11.2 carries it
  as a requirement for that reason.

  **The check:** two users, one corpus, the same query — the result sets must
  differ, and neither may contain the other's `private` rows. Cheap enough that
  a subsystem exposing a read path has no excuse for not having run it.

- **Target: PostgreSQL 19**, the only major the gate runs; nothing in the SQL
  needs more than 18, and SQL/PGQ, which it once used, was withdrawn from 19
  before GA. [`postgres-versions.md`](postgres-versions.md) has what was
  measured on each and what moving the published image takes.
- **Earlier Percolate designs are prior art, not a template.** Each brief says
  which of their decisions carry forward (a uniform entity envelope,
  cost-cascading entity resolution, AG-UI streaming) and which do not (an
  in-process tool registry, tenant isolation only in the app layer).
- **Postgres pushdown is opinionated, not incidental.** The default assumption for any
  new capability is "can this be a SQL function or an RLS policy PostgREST can expose
  directly?" — the app layer only owns things that are structurally outside SQL's reach
  (OAuth redirects, email delivery, TOTP, WebSocket/SSE fan-out, LLM calls themselves).
- **PostgREST is the REST interface**, not a hand-rolled FastAPI CRUD layer. FastAPI
  (or the AG-UI/streaming bridge, where relevant) sits in front only for the things
  above; everything else is `postgrest`'s auto-generated REST/RPC surface over tables,
  views, and `SECURITY DEFINER` functions.
- **Domain-agnostic microservices, deployed the same Postgres-adjacent way, all
  RBAC-uniform.** Three so far: **PostgREST** (auto-generated REST/RPC), the
  **Agent Runtime** (`agentic/brief.md` §5 — runs agents, has no built-in
  tools), and the **Content Server** (`world-model-ingestion/brief.md` §3.5 —
  file upload, registration, workflow triggering). None of the three knows
  anything about any subsystem's business logic — that's what "domain-agnostic"
  means here, not just "generic-sounding." All three connect to Postgres through
  the same RLS-scoped role model `user-rbac` defines, never a privileged
  backdoor or a second authorization system invented per service — adding a
  fourth domain-agnostic service later should look like these three, not invent
  its own pattern.
- **No role in this collection may be a cluster superuser, and the role owning
  the `*_api` views must not be the role owning the tables.** This is the
  collection's most load-bearing security invariant, and both halves were
  established by reproducing the failure, not by reasoning about it. A view
  exposing a safe column subset (the standard PostgREST pattern for hiding
  secret columns — `user-rbac/schema.sql` §9) is owner-privileged, so a read
  through it evaluates RLS as the **view's owner**. Three consequences, each
  confirmed live against PG19 beta3:
  - A **superuser** owner bypasses RLS unconditionally — every caller sees
    every row. No flag changes this.
  - A **table-owner** view owner bypasses RLS too (owners bypass by default) —
    same outcome.
  - `FORCE ROW LEVEL SECURITY` looks like the fix for the second case and is
    the wrong one: it also subjects `SECURITY DEFINER` functions to RLS (they
    run as the table owner), so with no JWT yet present during signup/login,
    **every write breaks** — signup, login's own audit insert, token issuance
    and rotation, role grants. `INSERT ... RETURNING` fails even for the table
    owner, since `RETURNING` reads the new row back through the SELECT policy.

  The resolution is **ownership separation, not a policy flag**: `app_owner`
  owns tables + functions (bypasses RLS — the trusted `SECURITY DEFINER`
  path), `api_viewer` owns only the views and is not the table owner (RLS
  applies — the untrusted read path). `ENABLE ROW LEVEL SECURITY`, never
  `FORCE`. `user-rbac/roles.sql` defines both roles and `schema.sql`
  self-checks the invariant at load time, refusing to load rather than
  deploying a schema whose central guarantee is silently inert. Applies to any
  RLS policy in any of the five systems, not just `user-rbac`.
- **Every `SECURITY DEFINER` function sets `search_path` explicitly** — `set
  search_path = pg_catalog, public`, or narrower. Standard hardening against the
  CVE-2018-1058 class of vulnerability: a `SECURITY DEFINER` function that calls
  other objects by unqualified name resolves them using the *caller's* session
  `search_path`, so a caller able to create a same-named object earlier in their
  own search path can get it invoked with the definer's privileges instead of the
  real one. Applied across `user-rbac` as hardening even though a live
  reproduction attempt didn't succeed against its current grants —
  the guidance is unconditional, and
  this collection has already shown its grants can't be trusted to stay narrow by
  accident (§9 there). Applies to every `SECURITY DEFINER` function in any of the
  five systems, not just this one.
- **RLS policy predicates wrap function calls in `(select ...)`**, not bare —
  `id = (select current_user_id())`, not `id = current_user_id()`. Confirmed via
  `EXPLAIN`: `STABLE` alone does not
  make the planner hoist a function call into a cached `InitPlan`; the wrapped
  form does, the bare form re-evaluates per row scanned. Matters most exactly
  where it's tempting to skip it — a permission-check function doing its own join
  (`has_permission()`, or anything like it in a future module) — since the bare
  form turns that into a join per row scanned instead of a join once per query.
- **Every append-only event/audit table, and every table representing "one unit
  of work," carries `trace_id`/`span_id`/`parent_span_id` in real W3C Trace
  Context format** — `trace_id` a 32-lowercase-hex-char string (128-bit),
  `span_id` a 16-lowercase-hex-char string (64-bit), generated with `pgcrypto`
  (already core): `encode(gen_random_bytes(16), 'hex')` /
  `encode(gen_random_bytes(8), 'hex')` — confirmed to produce correctly-shaped
  IDs against PostgreSQL 19, no extra extension needed. This
  is the difference between "a free-text column that happens to be named
  `trace_id`" and data that's actually OTel-compliant: exportable as real
  distributed traces without a translation layer, the moment something ships
  it. `workflow-engine` carries `trace_id` on `runs` and
  `span_id`/`parent_span_id` on `tasks` (one trace per run); `user-rbac`'s
  `auth_events` carries `trace_id` and `span_id`, and `agentic`'s `runs`
  carries all three.
- **Postgres can't export OTLP itself** — the database never makes an
  outbound HTTP call itself. The actual export path is an OTel Collector (or
  a small worker in the existing KEDA-scaled pool) that reads these
  well-shaped audit tables and emits real OTLP traces/logs — a real, named
  piece of the deployment shape, not something hand-waved as "future work."
  Postgres's job is only to make sure the IDs and structure are already
  correct so that piece has nothing to translate.

  **Built.** The agent runtime's exporter is
  `core/percolate_core/agentic/telemetry.py`; the collector configuration ships
  with the get-percolate installer. Building it split the path in two. What this bullet did not anticipate
  is that *reading the tables is the wrong way to get traces*, and only the
  right way to get metrics:

  - **Live OTLP from the processes, for traces and logs.** The agent runtime is
    not Postgres — it is a Python process — so it emits spans as they happen
    rather than being reconstructed from rows afterwards. That yields real
    durations, real parent/child nesting and the GenAI semantic conventions
    (`gen_ai.request.model`, token counts, finish reason) that no audit table
    carries. `percolate_core.agentic.telemetry` wraps each turn in one span
    holding `percolate.run.id`, `.session_id`, `.parent_run_id` and `.depth`,
    so the span joins to the `runs` row and the delegation tree and the trace
    tree are literally one tree. A row-reader could never have produced the
    timing, only the shape.
  - **Reading the tables, for metrics.** What only Postgres knows — queue
    depth, oldest wait, connection headroom, runs by outcome — comes from the
    `sqlquery` receiver in get-percolate's collector configuration, pointed at the same `workflow.v_*` views an
    operator reads by hand, so there is no second definition of backlog to
    drift from the first.

  Two findings worth carrying, both measured rather than reasoned:

  - The `postgresql` receiver failed to parse a PG 19 beta `version()` string
    (`19beta3`); `sqlquery` is unaffected. Revisit when the image moves to 19 GA.
  - **Content export is a hole through RLS and is off by default.** Putting
    prompts and completions in span attributes moves them out of the database's
    row-level security into a backend that does not re-apply it. Every read
    path in this collection is RLS-scoped; an exporter is the one component
    that can undo that silently, so it takes a deliberate `P8_OTEL_CONTENT=1`.
- **System fields are a tiered envelope, not a blind "add four columns
  everywhere."** Which tier a table gets is a real decision, not an accident —
  three, confirmed against the actual current schemas (`dev/`
  session, `workflow-engine/schema.sql`):
  - **Mutable entities** (`workflow.definitions`, `workflow.runs`, `workflow.tasks`, `rbac.users`, a
    future `agents`/`resources`): `id`, `created_at`, `updated_at`, and
    `deleted_at` *or* an explicit domain-specific lifecycle field that already
    means "logically gone" (`users.status = 'disabled'`, `refresh_tokens`/
    `api_keys.revoked_at`) — never both a generic `deleted_at` and a
    redundant domain-specific one on the same table. `updated_at` is
    maintained by a shared `touch_updated_at()` `BEFORE UPDATE` trigger, never
    hand-set per statement — confirmed the hard way that hand-setting it is
    exactly the kind of thing that gets missed at some call site
    (`workflow-engine`'s `tasks` table had no `updated_at` at all despite
    being the most heavily mutated table in that schema, and `workflow_runs`'s
    was hand-set in some `UPDATE`s and not verified against all of them).
  - **Append-only event/audit logs** (`task_events`, `auth_events`): a single
    immutable timestamp, named `at` rather than `created_at` specifically to
    signal at a glance "this table has exactly one timestamp and it never
    changes" — no `updated_at`, no `deleted_at`, both would be lies about a
    row that's never mutated.
  - **Pure join/reference tables with no independent lifecycle**
    (`workflow.task_dependencies`, `rbac.user_roles`, `rbac.role_permissions`,
    `rbac.roles`): no timestamps at
    all. Adding them would be padding, not signal.
  - Secondary fields (`tags`, `metadata` JSONB) are per-table, added when a
    table actually needs them — not part of the required envelope.
- **Postgres schemas namespace by subsystem, not everything in `public`.**
  **Done.** Every subsystem has its own schema (`agentic`, `aiq`, `content`,
  `claims`, …); `public` holds only cross-cutting utilities such as
  `public.touch_updated_at()`.
  Schema-qualification removed the redundant prefixes it made possible:
  `workflow_defs`/`workflow_runs` → `workflow.definitions`/`workflow.runs`,
  `task_deps` → `workflow.task_dependencies` (abbreviations spelled out at the
  same time). `rbac`'s tables were already clean — none of them repeated
  "rbac"/"user" — so they were qualified without renaming.
  Cross-schema calls (e.g. `rbac.attempt_login()` calling
  `workflow.try_consume_rate_limit()`) are schema-qualified explicitly at the
  call site rather than relying on `search_path` order — a `search_path` that
  quietly includes another subsystem's schema is exactly the kind of
  ambient-trust surface this collection has spent real effort closing
  elsewhere (`user-rbac/schema.sql`'s `search_path` hardening). Every internal
  reference is qualified too, so no `SECURITY DEFINER` function's
  `search_path` needed widening to accommodate the move.
- **Roles are cluster-level and live in their own file, applied before any
  schema.** `user-rbac/roles.sql` creates them; `schema.sql` only creates
  schema-level objects. Forced by a real constraint rather than chosen for
  tidiness: a non-superuser cannot `CREATE ROLE`, and `user-rbac/schema.sql`
  *refuses to load as a superuser*, so the two cannot share a file. **Two
  distinct non-superuser roles are required**, and this is the single most
  load-bearing detail in the collection's security model: `app_owner` owns
  tables and functions (so `SECURITY DEFINER` functions bypass RLS and can
  write, and can read during login before a JWT exists), while `api_viewer`
  owns *only* the `*_api` views and is deliberately **not** the table owner
  (so RLS applies to it, and every read through a view is filtered
  per-request). Collapsing those two into one role silently returns every row
  to every caller; `FORCE ROW LEVEL SECURITY` looks like the fix and instead
  breaks signup, login, token issuance, and audit writes. Both failure modes
  were reproduced live, in that order, and `schema.sql` now self-checks both
  invariants at load time rather than stating them in prose.

- **Trust is a fused property of coherence, never a single score or a single
  model's confidence.** Wherever a system in this collection produces a
  trustworthiness judgment — `world-model-ingestion`'s `corroboration_score`,
  a per-category author reputation, the confidence
  attached to a resolved entity or a generated answer's citations — that number
  must be a **fusion of at least three structurally different signal classes**:
  structural agreement, provenance/reputation weight, and a deterministic check
  result. No single signal is the trust score; the fusion is. The corollary is
  the design rule: an LLM's output is only trusted after being forced through
  deterministic (or at least checkable) structure, and that structure is what
  makes weak signals detectable in the first place — not a verification step
  bolted onto free generation afterward. `world-model-ingestion/brief.md` §4
  already follows this (algorithmic entity resolution and corroboration filter
  the volume before any LLM sees it); `user-rbac/schema.sql`'s load-time
  self-check is its strongest existing form. Three consequences worth stating,
  because each is currently unmet somewhere:
  - **`corroboration_score` and `reputation` are the same computation, written
    twice** — one over sources, one over people, same shape and same failure
    modes. Two consumers of one algorithm is the point at which it is promoted
    to shared code: they should be one fusion function in the `pgrx` module with per-domain *weights*, not per-domain
    code. The shape generalizes; the weights don't.
  - **More agreement is not monotonically more trust.** Corroboration counted as
    distinct source-type categories is a weak, *gameable* proxy for
    independence, and should be described as one — making descriptions identical
    across nominally independent sources specifically to raise an AI system's
    confidence is an active, documented playbook, not a hypothetical. A
    resonance-aware fusion treats unnaturally fast or uniform convergence as
    evidence of coordination. This gap does not close: independence is under
    adaptive adversarial attack, and detectability comes from watching *how*
    agreement was produced over time, not from inspecting state at one instant.
  - **Coherence is not truth.** A perfectly self-consistent system can be
    globally wrong — which is why a mechanism is used before it is trusted.
    Internal coherence is the cheap check; it
    does not license skipping the expensive one.
  - **Ingestion never resolves a contradiction at write time.** Data enters
    staging as attributed, immutable claims and reaches the world model only by
    promotion — a scored gate, reversible when new evidence arrives. A
    last-write-wins upsert destroys the disagreement between sources on its way
    to storing a winner, and that disagreement is the highest-value evidence the
    system has. Corollary for every scored table: **store the score's components
    and its history, never one mutable number** — a single column can't be
    recalibrated, explained, or audited, and it erases the convergence-over-time
    signal that coordinated-source detection entirely depends on.

  The coherence theory is research in progress and is not specified here; see
  `world-model-ingestion/brief.md` §4.5.

- **Decisions, revisions and uncertainty are rows.** Three corollaries of the
  bullet above, split out because each is a table-shape decision that cannot be
  retrofitted, and each was independently confirmed against Palantir Gotham's
  documented data model — a twenty-year-old system built by people whose worst
  outcome is a wrong identification acted upon, which is this collection's
  design problem approached from the other end.
  - **A decision is a record, not a side effect.** Anything that changes what
    the system asserts — a promotion, an entity resolution, a spec
    registration, an approval — is a row carrying who or what decided, on what
    evidence, under which version of the rule. The test is whether *why is this
    in the graph?* is a join rather than an investigation. Gotham makes this
    structural by accepting no write at all except through a typed action
    carrying parameters, validations and a log; ours is looser, and should at
    least not be loose in a *different* direction per system. Where a gate
    exists, **a permitted and recorded override beats a hard block** — a gate
    that cannot be overridden gets routed around outside the system, where
    nothing observes it. This does not touch `trace-field`'s invariant 6:
    nothing waits on a human, and the record is written whichever way the
    decision goes.
  - **Every merge is reversible, and the reversal is a first-class operation.**
    Entity resolution is a hypothesis, so anything collapsing two records into
    one keeps both constituents *and* the decision that joined them.
    The claim layer is meant to keep `subject_text` after resolution (the
    staging layer of `world-model-ingestion/brief.md` §4.5);
    `ai-query-layer/graph-identity.md`'s
    resolution ledger is the same rule at the identity layer. The asymmetry to
    watch for is a promotion path with no demotion — if a promoted `aiq.edges`
    row cannot be withdrawn with its evidence intact, the collection has
    rebuilt exactly the irreversibility the bullet above exists to avoid.
  - **Uncertainty is a value, not an absence.** "No check was possible" and
    "the check ran and failed" are opposite findings and must never share a
    representation: `inconclusive` as a first-class result, a `NULL`
    determinism term that widens the interval rather than moving the score, a
    `[-1, 1]` structural term so contradiction stays distinguishable from
    ignorance. The same rule extends to identity, where this collection
    currently offers only merge-or-nothing: *these two things may be the same*
    needs its own relation — symmetric, non-transitive, carrying its own
    evidence — or every candidate identity is either asserted or lost.

## Deployment shape (applies to all five systems)

- **Postgres, cloud-native.** One managed/operator-run Postgres cluster per
  environment (e.g. CloudNativePG-style), not per-system databases — the whole point
  of a Postgres-first design is one source of truth these systems can query and
  graph-link against each other.
- **KEDA-scaled worker pool.** Background/async work (workflow tasks, ingestion jobs,
  embedding generation, agent delegation runs) is processed by a horizontally-scaled
  worker pool built from a single Docker image, scaled by KEDA on queue depth —
  consistent with the workflow engine's own queue design, reused rather than
  reinvented per system.

  **A pool is a row, not a manifest** — see
  [`workflow-engine/pools.md`](workflow-engine/pools.md). A consumer declares an
  image, a resource shape and scale bounds in `workflow.pools`; a manager
  process reconciles those rows into Deployments and `ScaledObject`s in one
  namespace and scales each between 0 and N; deleting the row removes the
  Deployment. Consumers get no cluster credentials, and there is no per-pool
  YAML anywhere in this repository. That keeps the deployment surface
  the same surface as everything else here — rows, RLS-scoped, reachable over
  PostgREST — instead of a second control plane written in a different language
  and governed by different permissions.
- **PostgREST, deployed as its own service.** Not a Postgres extension and not
  bundled with Postgres — a standalone server (one binary, its own container/pod)
  sitting in front of the cluster, connecting as an ordinary client over a scoped
  database role and introspecting the schema to generate the REST/RPC surface the
  "Ground rules" above describe. One deployment per environment, same as Postgres
  itself.
- **The agent runtime, deployed the same way as PostgREST.** A purely declarative
  process (`agentic/brief.md` §5) — wraps pydantic-ai, has no built-in tools of
  its own, ever, and executes agents that exist only as `agents` rows in Postgres,
  with every tool an agent can call bound declaratively to an independently
  deployed OpenAPI or MCP microservice. Postgres-adjacent for the same reason
  PostgREST is: it's the one process making the outbound calls (the LLM API,
  the bound tool microservices) that structurally can't happen inside Postgres.
  This is where a code-authored agent definition (`agentic/brief.md` §6) ends
  up after its migration runs — the runtime itself never needs redeploying to
  add, change, or retire an agent.
- **The Content Server, deployed the same way.** File upload, registration
  (`files`/`resources` rows), and workflow triggering
  (`world-model-ingestion/brief.md` §3.5) — Postgres-adjacent for the same
  reason PostgREST and the agent runtime are: it's the one process handling
  the byte stream and the outbound storage call, neither of which can happen
  inside Postgres. One S3-compatible client always, pointed at a real
  S3-compatible endpoint in production or a local S3-compatible container (RustFS) in dev
  and CI — never two storage code paths. Upload → registered → triggers
  the embedding workflow is the primary use case this exists for, not an
  afterthought bolted on once upload works.
- **S3-compatible object storage for files.** Files are a **first-class citizen of the
  data design, on equal footing with Postgres, not an afterthought** — file *content*
  never lives in a `bytea` column. Every file has exactly one Postgres row (bucket,
  key, checksum, size, content type) and exactly one object in S3-compatible storage;
  the row is the source of truth for *what exists*, the object store is the source of
  truth for *bytes*. This shows up concretely in `world-model-ingestion`'s content
  upload path (see its brief) but is a standing rule for any system that stores files.
- **Planned, not built: ephemeral staging environments, in-cluster.** On merge to main, a temporary
  staging environment — the same Postgres/KEDA/S3 shape as production, at smaller
  scale — spins up inside the deployment's own Kubernetes cluster, not a rented/hosted ephemeral-environment
  product. Kubernetes-first: git CI flows authenticate to the cluster via a dedicated,
  narrowly-scoped service account to create it, run checks against it, and tear it
  down — not through a separate automation platform.
- **Connection pooling is the first scaling lever, not an afterthought — and there
  will eventually be a ceiling this doesn't fix.** Postgres is process-per-connection,
  which is exactly why a transaction-mode pooler (`PgBouncer`/`pgcat`) belongs
  in front of it from day one (`workflow-engine/spec.md` §7 calls it mandatory at
  scale); none ships in the dev stack yet and it has not been measured
  (`workflow-engine/scale.md`). Per Tinybird's ["Outgrowing Postgres: Handling
  increased user concurrency"](https://www.tinybird.co/blog/outgrowing-postgres-handling-increased-user-concurrency),
  connection pooling is the "lowest-hanging fruit". But pooling and query optimization only push the
  ceiling out, they don't remove it: connection timeouts, rising CPU, and replication
  lag under real concurrent load are the named warning signs to actually watch for,
  and the honest answer once they show up for a **genuinely analytical, high-read-
  concurrency** workload (most plausibly `ai-query-layer`'s `SEMANTIC`/`GRAPH` reads
  or `world-model-ingestion`'s event/entity graph at real scale) is offloading that
  specific workload to a dedicated analytical store, not trying to out-tune OLTP
  Postgres indefinitely. Not a component to build now — a named, watched-for
  threshold, so it's a decision made on evidence when it's reached, not a surprise.

## Data lifecycle — what happens to a table that only ever grows

The tiered envelope under *Ground rules* says which timestamps a table carries.
This says what becomes of those rows a year later, for every table in the
collection that is only ever appended to. It exists because the cheapest moment
to decide a table's lifecycle is before it has a billion rows in it, and because
the current answer — *we have never run one of these long enough for it
to hurt* — is a reason to write the answer down, not a reason to build a
retention daemon against a hypothesis.

**"No, and here is the number at which to ask again" is a real answer**, and it
is the answer for most of the rows below. Anything this section concludes should
be *built* becomes its own issue with its own cost, priced on whether the
system can live without it. This section authorises nothing.

Three questions per table: **is it partitioned**, **does something delete from
it**, and **does it need per-table autovacuum settings**.

| Table | Deleted by | Partitioned | Autovacuum | Ask again at |
|---|---|---|---|---|
| `agentic.messages` | **cascade** — `run_id` and `session_id` are both `on delete cascade` | no | default | — |
| `agentic.runs` | **cascade** from `sessions` | no | default | — |
| `agentic.sessions` | **nothing. This is the root.** | no | default | 10M sessions |
| `content.resource_chunks` | **cascade** from `content.resources` | no | default | — |
| `aiq.edges` | **nothing, by design** — see below | no | default | when retracted rows outnumber live |
| `workflow.task_events` | `workflow.purge_completed` | no | default | — |
| `workflow.deposits` | **nothing** | no | default | 100M deposits |
| `rbac.auth_events` | **nothing, by design** — an audit log is kept whole | no | default | — |

**Four of the eight are already answered, and the answer is a foreign key.**
This is the part worth internalising: `agentic.messages` and `agentic.runs` are
not independent retention problems, because deleting a session takes its runs
and their messages with it; `content.resource_chunks` is a property of
`content.resources`, not a table anybody retains separately; and
`workflow.task_events` is deleted by `purge_completed`, which `pg_cron` runs
nightly as `workflow-purge` (`dev/image-init/01-percolate.sh`) and which learned to do it
the expensive way — purging a 1M-task backlog once left four to six million
orphaned event rows behind, because `task_events.run_id` is a plain uuid with no
foreign key, so nothing cascaded and nothing complained (`workflow-engine/schema.sql`
§`purge_completed`). **A cascade is a retention policy that cannot be forgotten,
and it is why only two roots below need a decision at all.**

**`aiq.edges` is never deleted and that is the design, not an omission.** The
table is bitemporal: a retraction sets `valid_to` rather than removing the row,
because a derivation that `DELETE`s what it can no longer derive leaves nothing
to audit. Reads go through `aiq.edges_current`. So the growth question here is
not retention but **compaction of retracted rows**, and it becomes live when
rows with `valid_to is not null` outnumber those without — at which point the
options are a partial index on the live set (cheap, reversible) before anything
heavier. Nobody has measured that ratio on a real graph; measuring it is the
first step, not partitioning.

**The two roots with no answer are `agentic.sessions` and `workflow.deposits`.**
Neither is urgent and both are cheap to reason about now:

- `agentic.sessions` is the one place a conversation-retention policy would
  attach, and attaching it there reaches messages and runs for free. It is also
  the one that will be decided by something other than engineering — how long a
  user's conversations are kept is a product and privacy question, not a table
  size question, so this row stays open until somebody answers that. What
  engineering owes is the observation that the answer is a single `delete from
  agentic.sessions where created_at < …` and everything else follows.
- `workflow.deposits` **already has the right index** — a BRIN on
  `deposited_at` (`trace-field/schema.sql`), which is the index a time-ranged
  delete wants and the cheapest one to carry on an append-only table. Nothing
  deletes from it yet, and decay is nearly free precisely because deposits are
  append-only. Revisit with the rest of
  `trace-field`.

**Partitioning: no, for all eight, and the bar for revisiting is high.** These
tables ship *inside an extension*, so partitioning one is an upgrade-path
problem before it is a performance one — `pg_dump`/restore, the
`dev/upgrade-from-every-release.sh` gate and every existing installation all have to
survive the conversion. Before that argument is worth having, price PG19's
native `REPACK … CONCURRENTLY`: reclaiming space without
blocking reads and writes may remove the case for partitioning entirely, which
is the cheapest outcome available.

**Autovacuum: defaults, with one named suspect.**
`specs/workflow-engine/scale.md` calls autovacuum on a churning task table "the
most likely place for the next surprise", and that judgement stands. But note
what the table above shows: the churning table is `workflow.tasks`, which is
*not* append-only and is not in scope here. The append-only tables are the
opposite shape — insert-heavy, update-never — where the default settings are
closest to right and the thing that eventually bites is the insert-only
autovacuum threshold, not the update one. No per-table setting is justified by
anything measured today.

## Scope decisions — what's a subsystem here vs. deliberately not

Recorded so a missing capability reads as a decision, not an oversight:

- **Consolidation/"dreaming" (background synthesis of stored data into new insight)
  lives inside `agentic`**, not as a separate system. A consolidation run is an
  ordinary `agentic` run — same `agents`/`runs`/`messages` shape — just triggered on
  a schedule by `workflow-engine` instead of by a live session. See `agentic/brief.md`
  §3.
- **Usage metering (token/cost/quota tracking) is split across two existing systems,
  not a new one**: `workflow-engine` owns *capture* (every metered action already
  happens inside a task with an event log — §13 there); `user-rbac` owns *policy and
  enforcement* (quotas, limits, `rbac.has_quota_remaining()`, `user-rbac/schema.sql`). Neither system
  needed a new table family to absorb this; it's additive sections on both.
- **Explicitly outside the core five, still, more precisely now**: a
  *generalized* effectors/integrations subsystem — a dedicated, first-class
  abstraction for calling arbitrary third-party APIs, sending email/Slack, and
  auditing every outbound action uniformly — is still out of scope, and still
  deliberately so. What's since been built is narrower and doesn't relitigate
  this: `http_call` (`workflow-engine/spec.md` §3) is a generic *dispatch
  primitive* inside `workflow-engine` itself, not a new subsystem; the Agent
  Runtime and Content Server are two *specific* domain-agnostic microservices
  (Ground rules, above), not a general integrations abstraction covering
  arbitrary third-party APIs. A generalized effectors layer would sit *above*
  these — using `http_call` to dispatch, the same RLS-scoped role model to
  authorize — not duplicate them. Also still out of scope: a delegated-
  credential/secrets vault (distinct from `user-rbac`'s own login credentials —
  tokens an agent borrows to act *as* a user; `http_call`'s `credential_ref`
  and the Agent Runtime's tool bindings both assume this exists without
  building it), and ~~tenant/org-level management~~ — **the tenancy half of that
  third item is built**: `user-rbac` §2b now has `orgs`, `org_members` and a
  private/org/public scope on every owned row, because five subsystems were
  already scoping on an `orgs` array read straight off the JWT with no table
  behind it, and `org_id is null` was doing duty as both "deliberately global"
  and "nobody set it". What stays out of scope is the *management* layer above
  it — billing account, SSO config, org hierarchy — which is what this entry
  was actually about; a tenant that exists and can be joined is not an org
  chart. Both remaining items are real production needs, deliberately treated
  as out of scope rather than added speculatively — revisit if and when a
  concrete consumer needs one.
- **`trace-field` is a reading of `workflow-engine` plus a set of additions to
  it, not a sixth system** — and it is the first candidate this test has been
  applied to since the five were fixed. It fails cleanly: remove it and all five
  subsystems do their jobs, and its own proposals compile to ordinary
  `workflow.tasks` rows claimed by the same workers and retried by the same
  reaper. Almost all of it *is* `workflow-engine`, and it would have been filed
  there but for a smaller second half that lends two ideas to how agents assess
  findings, touching `ai-query-layer` and `world-model-ingestion`. A directory
  keeps the reading and the additions together; the additions themselves are
  in `trace-field/schema.sql`.
  One overlap is unresolved and named in both places rather than quietly
  tolerated: **`trace-field`'s confidence-as-half-life and
  `world-model-ingestion/tradecraft.md`'s source grading are two mechanisms for
  one question** — how much do we believe this — and neither yet has the
  standing to retire the other.
- **Roadmap, not out-of-scope: fine-grained per-resource sharing/ACLs.** Unlike
  the three items above, this one *is* inside `user-rbac`'s domain (it's an
  extension of `has_permission()`, not a new subsystem) — it's just not in spec
  v1. The deferred design is a `resource_grants` table joined into RLS policies
  alongside the role check (`user-rbac/schema.sql` §2b notes it).
