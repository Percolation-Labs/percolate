# World Model Ingestion — Spec Brief v0.1

> **Status update.** The content plane described in §2–§3 is now built:
> [`schema.sql`](schema.sql) ships `channels`, `files`, `resources` and
> `resource_chunks` in a `content` schema, and [`integration.sql`](integration.sql)
> registers that corpus with `ai-query-layer` (so `TEXT`/`SEMANTIC`/`SEARCH`
> search real content) and projects ready resources into the graph as
> `document` nodes. The Content Server is built too
> (`core/percolate_core/content/server.py`): `POST /files`
> hashes the bytes, stores them content-addressed, registers the upload and
> **starts the ingestion workflow**; `GET /files/{resource_id}` proxies the
> bytes back, RLS-scoped. Verified end to end against MinIO.
> **Ingestion is now built too** ([`ingestion.md`](ingestion.md)): the workflow
> the channel names parses PDF, DOCX, HTML, markdown and audio to markdown,
> chunks it with semchunk, and embeds every chunk in one batched call; a
> tabular upload takes the other path and becomes a Parquet dataset DuckDB
> reads from object storage. Five formats were uploaded through a live stack
> and answered questions afterwards.
> The pull side is now **built but not connected**: `connectors.sql` +
> [`sources.md`](sources.md) §16–§20 ship a declarative connector library with a
> working runner — 372 sources registered (sources.md §20), 100 pulled, 45,992
> records — writing to a filesystem store that has no path into `resources`.
> Two tables describe a source and neither references the other;
> [`sources.md`](sources.md) §17.4 reconciles them and names the shape to apply.

## 1. What this is, and why it's different from the other briefs

The other systems in this repo are infrastructure: query mechanics, auth, agent
plumbing. This one is **sourcing, corroborating, and structuring data that has
value on its own** — real-world events and the entities/topics they connect to.
That's a genuinely different kind of hard: not "what's the right Postgres feature,"
but "what's actually true, where did it come from, and is it worth paying for."
This brief is intentionally less settled than the other briefs and flags open
questions rather than pretending a clean abstraction exists yet.

This is downstream of an earlier internal spec for sourcing real-world events on
a small monthly budget; its sourcing, entity-resolution and corroboration design
is the reusable precedent here, and its marketplace machinery is out of scope.

## 2. Two ingestion paths into one entity model

There are two genuinely different ways content enters this system, and both need
to land in the same shape:

1. **Pulled**: automated ingestion from external sources — SEC EDGAR, arXiv, HN
   Firebase, Federal Register, openFDA, Wikipedia RecentChanges, NOAA, FEC, and
   similar free/low-cost APIs (about 25 tested live),
   plus paid social signal (Reddit/X-class APIs, the one place the $200/mo budget
   actually gets spent, because free sources structurally can't see subculture
   chatter).
2. **Pushed**: content someone or something hands the system directly — an
   uploaded file, a Telegram channel post, anything arriving via a "content upload"
   entry point rather than a scheduled pull.

Both are a **`resource`** — this system's unit of ingested content — that
references a **`channel`** describing
where it came from: `kind` (`file_upload` | `http_pull` | `ftp_pull` | `feed` | `telegram` | `manual`),
provider-specific config, and a dedup/resolution key. Making `channel` a first-class
table (not a string column on `resource`) is the concrete answer to "resources could
also be Telegram posts" — a Telegram channel is a `channels` row exactly like an SEC
EDGAR feed is, and adding a new source kind is an insert plus a worker, not a schema
change.

## 3. Files are a first-class citizen, on equal footing with Postgres

Per the deployment ground rules: file **content** never lives in a
`bytea` column. Content upload works like this:

1. Client uploads a file → object lands in S3-compatible storage, keyed by content
   hash (dedup for free — the same PDF uploaded twice is one object).
2. A `files` row is written: bucket, key, checksum, size, content type — the
   Postgres-side pointer, never the bytes.
3. A `resource` row is created referencing that `files` row (`channel.kind =
   'file_upload'`), and a background worker (KEDA-scaled, per the deployment ground
   rules) chunks and embeds it into `resource_chunks` — this is a
   `resource → resource_chunks` pattern carried over from an earlier system, kept as-is;
   it's a good fit and there's no PG19-specific reason to change it.

   **Both halves need code, and the second half is a correction made by
   running it.** Since `workflow-engine/YAML.md` promoted `embed:` to a step
   kind, the embedding half *looked* declarative: a `matrix:` over the chunks
   with an `embed:` template and a `sql:` step landing the vectors. That works,
   and it is one HTTP request per chunk, and it cannot be batched — a step's
   output is capped at 64KB and one 1536-dimension vector is ~31KB of JSON, so
   two do not fit in one output. Embedding a *corpus* therefore belongs to the
   process that receives the vectors ([`ingestion.md`](ingestion.md) §1); the
   declarative fan-out stays exactly right for embedding a *query*. What
   survives unchanged is the part that mattered: the model comes from
   `aiq.embedding_models` rather than from a url in a document. Chunking stays yours because the strategy is a decision the
   author has to make (same file, *Higher-level steps*: `chunk:` is one of the
   three shorthands deliberately refused).
4. `resource_chunks` is what `ai-query-layer`'s `SEMANTIC` mode actually searches —
   the raw file is never queried directly, its chunks are.

This embedding pipeline is the **semantic index** half of a two-index story;
`ai-query-layer/graph-identity.md`'s node/edge projection is the **graph
index** half, maintained by a different mechanism (a same-transaction
trigger, not a `workflow-engine` task) for a stated reason, not by
independent design — see that doc's D10 for the full comparison.

The invariant worth stating explicitly: **every `files` row has exactly one object
in storage, and no object in storage lacks a `files` row.** A reconciliation job
(KEDA-scaled worker, low frequency) is part of this system's definition of done, not
an afterthought — orphaned objects and dangling rows are exactly the failure mode
"files are first-class" is meant to prevent.

**`files` is never a directly-queryable PostgREST table, deliberately.**
Content-hash dedup (above) means one `files` row can legitimately be
referenced by `resource` rows from multiple different tenants — a public PDF
two unrelated users both upload dedupes to one object. That makes any RLS
policy on `files` keyed to a single owner meaningless (there isn't one owner),
so `files` gets `REVOKE ALL ... FROM PUBLIC` like every other internal table
(user-rbac's deny-by-default pattern) and is reached only by
joining through `resources`, whose visibility *is* single-tenant-scoped. A
client asks "give me this resource's file" (a scoped view/RPC joining
`resources` → `files`), never `GET /files` directly — the views-not-column-grants
discipline user-rbac uses, applied here to row-level
(join-time) scoping instead of column-level.

## 3.5 The Content Server — a third domain-agnostic microservice

### The contract

Three routes carry the file contract; the server also serves `/probe`,
`/evidence`, `/research-images` and `/embed`. Everything below it is rationale.

| | | |
|---|---|---|
| `POST /files` → **201** | body: the raw bytes | headers: `Authorization: Bearer <jwt>`, `Content-Type`, and optionally `X-P8-Channel` (default `uploads`), `X-P8-Title`, `X-P8-Title-Utf8` (percent-encoded UTF-8), `X-P8-Org`, `traceparent`. Returns `{resource_id, checksum, bytes}`. **400** empty body or a rejected registration, **401** missing/invalid bearer, **403** the caller lacks `resources:create`, **413** body over `P8_UPLOAD_MAX_BYTES`. |
| `GET /files/{resource_id}` → **200** | — | returns the raw bytes with the resource's stored content type. **404** covers both "no such file" and "not yours" — deliberately indistinguishable, since telling them apart leaks existence. |
| `GET /health` → **200** | — | `{"status": "ok", "bucket": …}`. No auth. |

A push arrives at `POST /files`; the upload registers the resource and starts
the ingestion workflow named on the channel, in one transaction.

**What it does NOT do**, corrected here because this section claimed both for
some time and neither was true:

- **It does not execute `http_call` steps.** Outbound HTTP belongs to the
  worker (`percolate_core.worker`), which is where the built-in handler is
  registered. A separate dispatcher process was proposed for this and withdrawn
  as bloat; the conclusion was one generic worker, not a second server.
- **It does not scrape.** The pull side — polling a source on its cadence,
  fetching, and landing the result — is the connector runner's job
  ([`sources.md`](sources.md) §16), which exists and works. What does not exist
  is the hop from that runner's output into `content.files`/`resources`, so
  nothing it pulls is queryable; §17.4 there is the reconciliation.

**Who owns the pull side:** the worker, as a scheduled workflow whose steps are
ordinary `rest` calls followed by a `sql` step calling `register_fetched`. That
keeps the "get bytes, register, start ingestion" logic in one place — the
database function both paths already call — rather than duplicating it into a
poller. The Content Server owns exactly one thing: the byte stream, in and out.

### 3.5a The cadence is a column, and the schedule is derived from it

`polling.sql`. **A channel that is enabled and has a `poll_interval` has a
`workflow.schedules` row; one that is not, does not.** The schedule is derived
on every write to the channel, so the two cannot disagree and a person never
authors the second one.

This section is short because the scheduler and the landing already existed and the missing
piece was one hop. `workflow.schedules`, `workflow.tick()` and the `pg_cron`
entry are the scheduler; `overlap_policy = 'skip'` is §4's overlapping-poll
problem already solved — a channel polled every minute whose fetch takes ninety
seconds must not accumulate runs — and is named explicitly by the derivation
rather than left to the column default, because it is the property this rests
on. `register_fetched()` is the landing. What was missing is that
`channels.poll_interval` **had no reader**, so "polled every fifteen minutes"
was a value in a column and somebody's memory.

**Three decisions, each of which could reasonably have gone the other way:**

- **The schedule's name is computed, not stored.** `channel_<id without hyphens>`, derived from
  the row. A stored link would be a second place for it to be wrong, and a
  channel deleted by any path would leave a schedule firing a workflow for a
  source that no longer exists.
- **The schedule's `input` is the channel id and nothing else.** Everything else
  is read from the row at fire time, so a channel edited after the schedule was
  made takes effect on the next tick — the same reason `schedules.workflow_name`
  stores a name rather than a definition id.
- **An interval cron cannot express evenly is refused when it is set.**
  `*/7 * * * *` is not "every seven minutes": cron's step restarts each hour, so
  it fires at 0,7,…,56 and then 0 — a four-minute gap, twenty-four times a day,
  with every individual firing looking correct. So a cadence is accepted only
  when it divides its containing unit, and the refusal lands on the person
  setting the interval rather than in `schedules.last_error` once a minute. The
  floor is one minute because that is the ticker's resolution; anything faster
  would be a promise the engine cannot keep.

Step 1 above ("client uploads a file") is a real, deployed component, not a
hand-wave — the **Content Server**, a peer to PostgREST and `agentic`'s Agent
Runtime, deployed the same Postgres-adjacent way. All three now form a recognizable
pattern worth naming once rather than re-deriving per subsystem: a small set of
**domain-agnostic microservices**, each owning exactly one thing PostgREST/
Postgres structurally can't do itself (auto-generated REST/RPC; running an LLM
call; handling a byte stream), each connecting to Postgres through the same
RLS-scoped role model `user-rbac` already defines — no privileged backdoor, no
second authorization system per service. None of the three knows anything
about event detection, entity resolution, or any other subsystem's business
logic; that stays where it already lives.

**What the Content Server does, concretely**: accepts an upload, writes the
object to storage, writes the `files` row, writes the `resource` row
(`channel.kind = 'file_upload'`), and — this is the actual point, not an
afterthought — **starts the embedding workflow**: a direct `start_workflow()`
RPC call (`workflow-engine/spec.md` §4) right after the `resource` row commits,
kicking off chunking + embedding into `resource_chunks`. Upload → registered →
queryable via `ai-query-layer`'s `SEMANTIC` mode is meant to be one flow, not
three manually-wired steps — this is named as **the primary use case** for
content upload existing at all, not one example among several.

**A second index, off the same parse.** Embedding is not the only derived index
a resource wants; the other is the graph. The pipeline may carry a **graph index
step** — a cheap structured-output agent over the document, and a graph upserter
landing what it returns into `ai-query-layer`'s registry, so an upload is
*connected* as well as findable. It hangs off `parse` alongside the embed
branch rather than after it, and the two disagree about granularity on purpose:
embedding fans out over chunks because an embedding is a property of a span,
while graph extraction takes the **whole document** in one call because an edge
is a property of a relationship that a chunk boundary would cut in half. It is
**opt-in**: a completion per document is a different order of cost from an
embedding per chunk, so this is the one branch of the pipeline whose default is
decided by money rather than by capability. [`graph-index.md`](graph-index.md)
is authoritative on it, and §4.46 is the summary.

**Trace propagation on that call, made explicit (not left implicit).** The
Content Server is an OTel trace *origin point*, same as any other request
entry into this collection: if the
upload request arrives carrying a W3C `traceparent` header (a client that's
already inside a larger traced flow — e.g. an agent-driven upload), the
Content Server extracts and reuses that `trace_id`; otherwise it generates a
fresh one, the same "continue, don't restart, whenever an upstream trace
exists" rule — the same rule the agent runtime follows for scheduled runs. Either way, that
`trace_id` is passed as `start_workflow(..., p_trace_id => ...)`'s explicit
fourth argument (`workflow-engine/schema.sql`) — not left to default to a
fresh one at the workflow layer — so the one trace an operator queries
(the audit trail, filtered by `trace_id`) covers
the upload itself, the chunking/embedding task chain, and — since
`workflow-engine`'s own trace propagates through every task it spawns —
any downstream `agentic` consolidation run the pipeline triggers, as one
continuous trace rather than three disconnected ones stitched together after
the fact.

**Storage backend: one S3-compatible client, always** — never two code paths.
"S3-compatible in production, local for testing" doesn't mean a real S3 client
plus a separate filesystem client with its own bugs to find; it means the same
S3-compatible client pointed at a different endpoint — a real S3-compatible
service in production, a local MinIO container (same pattern as
`dev/`'s own Docker Compose approach) in dev/CI/staging. The
Content Server's own code never branches on "am I local or prod" — only its
endpoint configuration differs.

**RBAC, uniformly, like the other two microservices**: uploads and reads are
scoped through the same `current_user_id()`/`has_permission()` primitives
every other module uses — who can upload to which `channel`, and who can read
which `resource`/`files` row, is one RLS policy away, not a bespoke
authorization path invented for this one service. This is also where
`world-model-ingestion`'s open question about channel-level visibility (§6)
actually gets enforced, once resolved — the Content Server doesn't invent its
own answer to it.

**Decided: the Content Server proxies both directions, reads and writes —
not presigned URLs, for now.** Every byte transfer, upload and download alike,
flows through the Content Server itself, the same S3-compatible client on
both sides. Picked over presigned URLs deliberately: a presigned URL is a
second, independent authorization mechanism (its own scoping, its own
expiry) that has to be gotten right *in addition to* Postgres RLS, not
instead of it — proxying keeps exactly one authorization path
(`current_user_id()`/`has_permission()`, same as every other read/write in
this collection) for file bytes the same way it already is for every other
row. The tradeoff this accepts: the Content Server sits in the bandwidth/
latency path for large files, rather than a client talking to the object
store directly. Acceptable for now, and not a dead end if it stops being
acceptable — the Content Server is a stateless service like the other two
domain-agnostic microservices, so it scales the same way (more instances)
before presigned URLs would need to become a second mechanism.

## 4. The event/entity graph

Above the `resource`/`channel` layer sits the actual world model — a two-graph
design is the right target, without its marketplace
machinery:

- **Event/entity graph**: vertices are `events`, `entities` (companies/people/
  products), `topics`. Edges: "event mentions entity," "entity relates to entity,"
  "event follows/resolves prior event." This is exactly the kind of typed-edge graph
  `ai-query-layer`'s `GRAPH` mode is built to query, once PG19's `CREATE PROPERTY
  GRAPH` is in place.
- **Detection pipeline**, cost-ordered (cheap/high-recall first, expensive/precise
  last) — reused as-is because the cost logic is sound independent of Postgres
  version:
  1. Raw ingestion (noisy, high recall) — the `resource`/`channel` layer above.
     **A scheduled poll must not overlap itself**: a source polled every N
     minutes can still be mid-flight when the next tick fires (a slow upstream
     API, a large batch), and two concurrent runs double-ingest and
     double-spend that source's API budget. `workflow-engine`'s
     `idempotency_key` does not cover it, being scoped to one `run_id` — this
     is two runs, not a retry of one.
     **Solved upstream, and this system does not get its own mechanism.**
     `workflow.schedules.overlap_policy = 'skip'` (the default) refuses to
     start a run while the schedule's previous one is still running
     (`workflow-engine/spec.md` §12b, which names this problem as the reason it
     exists). An earlier draft here specified a per-channel
     `pg_try_advisory_xact_lock` in the poll task instead; that is now a second
     mechanism for a solved problem and is withdrawn.
     The one thing to get right when wiring it up is **granularity**, because
     the policy is per *schedule*: one schedule fanning out over N sources
     serialises all N together, which is coarser than needed and will
     head-of-line-block a fast source behind a slow one. One schedule row per
     source gives exact per-source semantics and is the shape to prefer;
     `sources.md` §19.4's `enabled`/`health` split already assumes per-source
     lifecycle anyway.
  2. **Entity resolution**, tiered by cost: canonical registry match (SEC CIK,
     ticker, Wikidata QID) → external crosswalk → embedding-similarity fallback →
     LLM as last resort. Each tier only runs if the cheaper one missed.
  3. **Corroboration scoring by distinct source-type count**, not raw mention
     volume — two outlets citing the same press release is one source, not two.
     This is a concrete, implementable field on every `event` row, not just a
     principle. **It is also only one of three signal classes, and on its own it
     is not a trust score** — a separate research prototype covers what
     actually gets computed. A distinct-source-type
     count is a weak, gameable proxy for independence, and it is monotonic where
     it shouldn't be.
  4. Only events crossing a corroboration threshold go to an LLM for
     interpretation/write-up. Algorithmic filtering is high-volume and cheap; LLM
     synthesis is low-volume and expensive — that ordering is the entire cost story.
- **Primary-source-first**: every `event` row should carry a link to the actual
  filing/record/patent it derives from, not just a news paraphrase of one — both a
  quality property and (per the source spec) a legal-risk mitigant. Worth keeping
  as a required field, not an optional one.

## 4.4 Sources — the connector library

How an external source becomes one of this system's three parse targets is
specified in [`sources.md`](sources.md): a source is a `content.channels` row
plus the schema a probe observed, and the ambition is that adding the hundredth
source costs what the tenth did — an `INSERT`, not a pull request.

The part worth carrying up into this brief, because it constrains everything
downstream: **parsing produces exactly three things** — resources (documents,
feeding `SEARCH`), entities (identified things, feeding `LOOKUP`/`GRAPH`) and
moments (time-anchored occurrences and measurements, feeding a `TIMELINE` this
collection does not yet have). The list is closed. A parser proposing a fourth
kind of output is proposing a fourth way to query, which is a much larger
conversation than adding a source.

## 4.42 Extraction — prose into datapoints and motifs

[`extraction.md`](extraction.md) is the step between a `resource` and the
entities and moments parsed out of it, and it is designed around a cost rather
than a capability: **as few model calls as possible.**

The measurement that shaped it, from 32 real documents across four prose styles:
generic structural datapoint extraction is free and works everywhere (114
datapoints, no model), **generic motif regexes fail outright** (4 motifs across
32 documents, zero on the most structured source in the set), and a template
written for one `(source, document type)` pair gets 66% typed-slot fill on the
same text.

The consequence is the economic one: **a model's job is to author the template,
not to read the documents** — one call per source-format, amortised over every
document that source ever publishes, instead of one call per document.

**And §4.46 costs a completion per document, which looks like a contradiction and
is not.** The two are different jobs with different economics, and the thing that
decides between them is **volume per format**, not preference:

| | when it wins |
|---|---|
| template per source-format (here) | a feed publishing many documents in one shape. The authoring call amortises, and 66% typed-slot fill on the same text is what a generic pass cannot reach |
| completion per document (§4.46) | a heterogeneous corpus in no fixed format, where there is nothing to amortise over, and where the target is nodes and edges rather than typed slots |

Both land through the same upserter, so the choice is a property of the **source**
rather than of the pipeline, and a collection can hold both.

The measurement that separates them, from the research prototype on 159 documents
of unstructured encyclopedic prose: a hand-written generic extractor reached
**precision 0.80 and recall 0.29** on relations — consistent with the "generic
motif regexes fail outright" finding above — while a completion per document
returned **479 relations against 20**, one surface in 952 that did not appear in
the source, and no edge referencing a node it had not emitted, at 0.55 s per
document. Where there is no format to write a template for, the per-document call
is not the expensive option; it is the only one that works.

## 4.43 The scoop brief — what all of this is for

The output everything upstream fills is a brief that must show the claims it
tested and abandoned and the questions that would change its conclusion;
credibility comes from showing its own failures.

## 4.44 Baseline and residual — the organising frame

The frame the rest of this section sits inside is
a **slow** baseline encoding what is normal, a **fast** stream of weak signals,
and the product being the **residual** between them. Scoop-worthiness becomes a
computed quantity rather than a heuristic.

The correction worth carrying up: **the highest residuals are mostly data-quality
failures, not stories.** Three maximum-residual events during one session were a
paging bug, a per-product row count and a quarterly load lag. The residual needs
a data-quality prior in front of it before it needs a human.

## 4.45 Tradecraft — grading what came in

`sources.md` gets data in; [`tradecraft.md`](tradecraft.md) decides whether it
is worth asserting. It is deliberately not novel: the grading model is NATO's
Admiralty Code (in use since 1939), the likelihood lexicon is ICD 203, and the
corroboration rule is Bellingcat's — three prose standards turned into
constraints a database enforces.

The one line to carry up here, because it constrains everything above:
**corroboration counts independent evidence *classes*, never records.** Nine news
reports of one filing is one independent source, and `tradecraft.sql` returns
exactly that with a message saying instances are not sources
(tradecraft.sql is not yet shipped in the extension).

## 4.46 Graph indexing — structure extractors, and where a graph lands

[`graph-index.md`](graph-index.md) is the second index a document gets. §3.5's
pipeline makes an upload *findable* by embedding its chunks; this one makes it
*connected*, by running a cheap structured-output agent over the whole document
and upserting what it returns into `ai-query-layer`'s `nodes`/`edges`. The two
indexes disagree about granularity on purpose, and the second bullet below is
why.

Three things in it are worth carrying up, because they generalise past
ingestion:

- **A structure extractor is a family, and the interesting member is the null
  one.** Any `agentic.agents` row with a declared output shape is a structure
  extractor. Most declare a *domain* schema — some landing in a Postgres table,
  some landing rows in a **Parquet dataset**, which is the tabular path §3
  already takes. The **null** extractor declares no domain at all — only a list
  of nodes and a list of edges — and that is the one output shape handed to a
  graph upserter rather than to a table. Edges name their endpoints by
  **ordinal** into the node list, which is where most of the output token cost
  would otherwise go.
- **The unit is the document, not the chunk.** Chunking is right for the
  semantic index, because an embedding is a property of a span. It is wrong
  here, because an edge is a property of a relationship between two mentions
  that are routinely pages apart — split the document and that edge is in no
  chunk's input at all. Document granularity is also *cheaper*: per-call
  overhead is paid once instead of per chunk. Windowing is the fallback for a
  document that does not fit, and a windowed resource has to record that it was.
- **Graph indexing is a workflow step, not a feature of ingestion.** The
  ingestion pipeline is its first consumer; a bulk indexer over an existing
  collection is the same template and the same land function with a different
  row source.
- **A kind prefix is a claim, not a fact — and it need not name a Postgres
  table.** Identity is always in Postgres, because `nodes`/`node_keys` are a
  btree of names; payload need not be. So a node has one of three
  **residences**: a typed Postgres table, a **Parquet dataset in the lake**
  (hydrated by DuckDB over `dataset_uri()`), or nothing at all. An extracted
  node resolves into one of the first two or becomes a **candidate**, and never
  creates a typed row. This is the part with a wrong answer available, so it is
  the part of that document to read first.

**It costs a completion per document**, which is a different order of money from
an embedding per chunk — fewer calls, each far more expensive — so unlike the
embedding branch it is **off by default** on the upload path.

**Status: built and run against a model.** `graph.sql` ships the reference
tables, the vocabulary and `aiq.upsert_graph`; `dev/tests/query/10-graph-index.sql`
holds it up; `graph-demo.sql` is the worked example. The ingest branch has run
against uploaded documents ([`graph-index.md`](graph-index.md),
[`ingestion.md`](ingestion.md) §1). Soft nodes are resolved by the resolver
worker (`core/percolate_core/resolve`) through `aiq.promote_soft_node`.

That order was deliberate and it paid. The model half costs money and was not
where the defects were; the database half is testable with a literal, and
testing it found five, including a silent cross-tenant write — a tenant's
document naming another tenant's private company resolved to it, because
resolution inside a `SECURITY DEFINER` writer is not RLS-filtered.
[`graph-index.md`](graph-index.md) §11 is the list.

## 4.5 Coherence — the staging layer, prototyped elsewhere

Steps 2–4 above are the sketch. The algorithm behind them — a claim-level
staging area separating *what we were told* from *what we believe*, and a fused
score deciding what is ever promoted — is the theory of how anything enters the
world model at all, not an optional refinement on top of corroboration scoring.

**It is being prototyped in a separate research repository, not here.** That is a
deliberate staging decision rather than a downgrade: it is unproven research
whose correctness needs a simulation or a backtest rather than a test suite, and
this repo is the part that has to be rock solid. It comes back — or parts of it
do — once it has earned that.

### 4.51 Two properties consolidation must have, from the backtest

That backtest has now been run once, on a software project's development
history — 371 commits over 8 days. Build the graph as of T, ask whether what it
says anticipates what happened after T. The result, stable across four cuts:

| | lift |
|---|---|
| two files sharing a co-change neighbour, vs an arbitrary pair | **20.7× – 28.9×** |
| ranking within those candidates, by any weighting tried | **0.7× – 1.3×** |

**Adjacency predicts; weighting does not.** That is a result about one corpus and
it is not the reason for what follows — the reason is that running the test at
all turned up two properties without which no consolidation can be evaluated,
ever, on any corpus. Both are now contract.

**1. Edges carry time, and removal is retraction rather than deletion.**
`aiq.edges` has been bitemporal since it was written, and until recently
`valid_to` had never been set on a single row while the derivations DELETEd what
they could no longer derive. That is not merely lossy. It makes the question
unanswerable: *"does this consolidation anticipate what happened next"* requires
a `next`, and a graph rebuilt by delete-and-reinsert has no history to hold one
out of. `valid_from` now defaults and is NOT NULL, `aiq.edges_current` is the
read path for anything meaning "now", and a derivation retracts.

**2. A consolidation must be able to return nothing, and be tested doing it.**
This is the sharper of the two, because it is the one nobody notices is missing.
Community detection partitions, so every node lands somewhere. Threshold
clustering emits at the threshold, so the threshold is the answer. A GROUP BY
always groups. Each of those is a stage that cannot decline, and a stage that
cannot decline will manufacture confident structure out of noise — which is not
hypothetical, since a twelve-item list of "decaying guarantees" was published
here that turned out to be an artefact of a single rebuild.

The test is cheap and it is the same shape as the disparity filter's own null:
score against a degree-preserving shuffle and require silence. The motif scorer
built alongside this selects 16 schemas on the real graph and **0 of 22 on
shuffled data**. Any promotion rule entering this layer from
the research prototype has to come with the equivalent, and the harness has to
run it, because the failure mode is a stage that looks like it is working
precisely when it is not.

A corollary worth stating for the promotion rule specifically: given the table
above, **promotion should be conservative and adjacency should be cheap.** The
measured value is in having the edge at all, not in the score attached to it, so
a fused score that gates what becomes an edge is spending its complexity in the
half that did not pay.

### 4.515 Consolidation is ATTENTION, and PageRank is the right analogy

The evaluation in §4.51 measures whether consolidation predicts, which is the
wrong question and produced a lift of 1.0 before anyone noticed. Prediction
would be a bonus. **The job is attention: deciding which twenty of ten thousand
things deserve a person's afternoon.**

PageRank is the precedent and it settles the shape of the argument. It forecasts
nothing and needs no labels; its claim is that a global structural property of
the corpus correlates with human relevance well enough that the top N out of
millions is what you wanted. A consolidation stage is making the same bet.

It also says why ranking on structure alone fails. PageRank works for search
because the QUERY restricts the candidate set before the ranking applies; ranked
alone over a codebase graph it returns the largest tables, which are important,
well known, and not news. The analogue of the query is **concern**, so:

> **attention = structural importance × reasons to worry**

with importance damped, because attention must not be a popularity contest.
Measured on the self-model, `ln(degree) × concerns` puts the 77-connection hub
twelfth, behind objects with a quarter of its connections and three times the
concerns.

**Scored the way a search engine is scored.** A person read a project's
incident write-ups by hand and named the classes that keep recurring; one is a
cluster around a single roles table. Against that, precision@10:

| | |
|---|---|
| nodes in the class the human named | 9 of 4,458 |
| base rate | 0.202% |
| of the top 10 by attention, in that class | **5** |

Independent methods over one corpus: the human read prose and named a class, the
ranking counted structural edges.

**And the limit is in the same terms, which is why this framing is better than
the predictive one.** That person named twelve classes and ELEVEN are semantic:
"a check that cannot distinguish pass from fail" is a property of what a file
says, not of how a graph is shaped, and a structural pass cannot reach it by
construction. Recall over the one structurally expressible class is 1 of 1; over
the other eleven it is zero and always will be. Those are the embedding pass's
work, and the two passes are complementary rather than competing.

### 4.52 What a consolidation pass needs, in four parts

Structural consolidation over this graph was run to a positive result: it independently rediscovered a recurring class a
person had named by hand, finding two of the three incident write-ups that class
names, with no embeddings, no
model and no keyword matching. The recipe is four ingredients and **each one was
necessary** — removing any gives noise, tautology, closure, or a buried answer.

**1. A null model over structure.** Score candidates against a
degree-preserving shuffle and take the cut from the null's own maximum, which is
a max-statistic permutation test and therefore family-wise error control rather
than a per-candidate α. Without it every candidate scores positive, *including
on shuffled data*. This is §4.51's decline requirement made operational.

**2. A declared derivation DAG.** A structural null controls for degree. It does
not control for two relations having been computed from the same source, and
when they were, a motif containing both is true by construction. "Two files
co-change and a commit touches both" scored highly and is a definition, because
co-change is derived from the same table `touches` is. Seven of sixteen
selections were artefacts of this kind. **A package must declare which relation
comes from which source**, and motifs whose relations share one are excluded
rather than discounted, because no amount of evidence makes a definition
informative.

This is the correlated-source problem of §4.42 lifted one level: correlated
*relations* rather than correlated extractors, and a provenance discount cannot
catch it because the relations legitimately carry different provenance.

**3. Motifs larger than a triangle.** A triangle is the smallest shape denser
than a tree, so it is where to look first, and it is also geometrically the
shape that finds *transitive closure*. Everything a triangle miner returns over
a graph of containment and dependency relations is "these three are mutually
reachable", which is real and is not news. Diamonds and K4s can express
something else.

**4. Ranking by bits per occurrence, not total gain.** The important one, and
the least obvious. MDL total gain is frequency × density, so it ranks the common
and the dense first — and dense-and-common is exactly what closure looks like. A
shape occurring 5,531 times saved 983 bits, 0.18 each; one occurring 34 times
saved 751 bits, 22 each. The second is the one worth surfacing and total gain
buries it.

> **MDL answers "is this real", and answers it well. It does not answer "is this
> worth telling someone", because description length rewards what recurs and
> usefulness is about what does not.**

That distinction is the transferable result. Any promotion rule arriving from
the research prototype needs both scores, and they are not the same score.

**And a bound on the whole stage:** consolidation recall is bounded by the recall
of the stage that lays down edges. The third incident write-up in that hand-written class was missed because it carries four
`hit` edges where the others carry ten and eleven — the incident is
under-connected, so no consolidation could reach it. Consolidation cannot
recover structure that edge-building did not lay down, which is the same conclusion
§4.51's measurements reach from the other direction.

What stays true here regardless is a standing rule: never let an upsert pick a winner, and store a score's components
and history rather than one mutable number.

(These tables belong to the research prototype; none of them is in this
repository's schema.)

The one-paragraph version. Ingestion splits into **what we were told** and **what
we believe**, and the split is the design. Every source's assertions land as
immutable, attributed `wm.claims` — one atomic claim, one `resource`, the verbatim
span it came from, and an honest flag for whether a *parser* or an *LLM* produced
it. Claims attach to cross-source `wm.assertions` with a stance, including
`contradicts`. Nothing is merged, and nothing is resolved at write time. An
assertion enters the graph only by **promotion**: a fused score — structural
agreement, independence-discounted provenance, deterministic-check results —
whose *lower bound* clears a threshold on at least two sources that survive
independence discounting.

Why this shape rather than an upsert. A last-write-wins `ON CONFLICT DO UPDATE`
on an `events` row destroys the disagreement between sources on its way to
storing a winner — and disagreement is the highest-value evidence this system
has. The staging area exists to stop the pipeline from destroying its own
evidence before anything can score it.

Three things it changes about §4's pipeline as sketched above:

- **A verifiability gate is added between extraction and scoring** (Stage 2).
  Nothing today classifies a candidate by *what kind of check is even possible for
  it*, which means corroboration scoring is currently entitled to signals it may
  not have earned, and ambiguous cases have nowhere to be routed.
- **The score becomes a time series with its components retained**, not one
  mutable `corroboration_score` column. That single table-shape decision is what
  makes coordinated-source detection computable at all — the defense depends on
  watching *how* agreement was produced, which a mutable column erases.
- **Promotion writes `aiq.edges`**, reusing that table's existing `weight` and
  `provenance` columns rather than inventing a mechanism — so `GRAPH` traversal
  is coherence-ranked for free, and "why is this edge in the graph" is a join,
  not a guess. **Demotion is the same mechanism run backwards** and must be
  specified with it: an edge withdrawn when the score falls keeps its assertion
  and its evidence, or the promotion path is irreversible in a collection whose
  ground rules forbid exactly that.

Three additions the same lens implies, each a table shape rather than an
algorithm, and each cheaper now than retrofitted:

- **Candidate identity needs a home that is neither a merge nor nothing.**
  `claim_stances` gives a claim a stance toward an assertion; nothing relates two
  *assertions*. `possibly_same_as` — symmetric, explicitly **non-transitive**, with
  its own evidence and its own confidence — is where embedding proximity
  legitimately lives, as the candidate generation §2.5.3 licenses it for and
  never as a scoring input. Without it the only options are asserting an identity
  or discarding the observation that two clusters look alike, and a system that
  discards it cannot later explain why it merged. A resolution decided from one of
  these rows is what lands in `ai-query-layer/graph-identity.md`'s ledger (D11);
  candidates stay here, decisions go there.
- **Consumers must be able to read staged assertions, not only promoted edges.**
  The promotion gate governs *what the world model asserts*; it should not also
  govern *what a person or an agent may look at*, and today one mechanism answers
  both. The consequence is that the first question anyone actually asks — show me
  the contested cluster, with its interval — has no way to be expressed, because
  every read path binds to `aiq.edges`. Reading `wm.assertions` in `staged` status
  with its score interval attached leaves the gate exactly as strict; it stops the
  gate from doubling as an access control it was never designed to be. A scoop
  brief's mandatory **killed claims** section is unwritable without this.
- **Decay belongs to the predicate, not to the score.** *X acquired Y* does not
  decay; *vessel Z is at position P* decays in minutes, and one `corroboration_score`
  with no half-life reports both with the same confidence — which is how a
  detection system ends up confidently reporting yesterday. Register the half-life
  beside the comparison frame's declared scale, versioned the same way and fixed
  before outcomes are looked at. This is cheap only because `assertion_scores`
  already keeps components per timestamp: decay is then a read-time function over
  a time series, where a single mutable column would have made it a write problem
  and a background job.

## 5. Relationship to the other three systems

- `ai-query-layer` is how this system's graph and `resource_chunks` get queried —
  this system produces the data, doesn't reimplement query mechanics.
- `agentic` is how detection/interpretation actually runs — the LLM-synthesis step
  in §4 is an agent run (with its own delegation/tool-call trail), not a bespoke
  pipeline outside the `agentic` contract.
- `user-rbac` scopes who can see what — some channels/resources may be
  tenant-private (an uploaded file) and others global (a public SEC filing);
  RLS needs a visibility model that isn't just per-tenant ownership.
- `workflow-engine` runs the pipeline itself — every step in §4's detection
  pipeline (raw ingestion, chunking, entity resolution, corroboration scoring,
  the reconciliation job) is a `workflow-engine` task, not a separate ad hoc
  worker loop, for the same reason `agentic`'s scheduled runs reuse it (§3
  there): one scheduler, one retry/backoff mechanism, one place `pg_cron`
  triggers from. This also means the pipeline gets the workflow engine's OTel
  tracing for free — a channel's scheduled poll starts a `trace_id` that
  propagates through every downstream task for that ingestion run (entity
  resolution, corroboration, the eventual `agentic` LLM-synthesis run) without
  this system needing its own tracing mechanism.

## 6. Open questions — genuinely open, not just deferred detail

- **Source economics don't generalize.** The $200/mo budget and ~25-API inventory
  in that earlier spec are specific to one product's domain (events/news/
  markets). A different world-model domain needs its own source inventory and
  budget — this brief's `channel` abstraction is domain-agnostic, but the actual
  sources plugged into it are not, and shouldn't be speced as if they were.
- **Entity resolution's LLM-fallback tier is the expensive unknown.** Cost-cascading
  helps, but the fraction of entities that reach the LLM tier (vs. resolving via
  registry/crosswalk/embedding) is domain-dependent and unmeasured here — needs a
  pilot on real data before this system's cost model is trustworthy.
- **Channel-level visibility/licensing.** Some sources (e.g. paid social APIs) have
  redistribution terms that constrain who can query the resulting `resource`/
  `event` rows, independent of tenant ownership — this needs to be a first-class
  concern in the RLS design, not bolted on later.
- **Dedup across channels, not just within one.** The same real-world event
  detected via an SEC filing *and* a Telegram post needs to resolve to one `event`
  row — cross-channel corroboration is the interesting case, not same-channel
  dedup, and isn't fully worked out yet.
- **What happens when two instances disagree.** Nothing here says what it means
  for two percolate deployments to exchange claims — whether they replicate
  claims, assertions, promotions or all three, and what happens when the same
  assertion is promoted in one and rejected in the other. It is not hypothetical:
  a marketplace of insight contributors is exactly that topology. Worth naming
  now because of *where* the equivalent gap sits in the system this collection
  was read against — Palantir publishes no technical specification at all for
  Nexus Peering, the cross-enclave replication layer every coalition claim of
  theirs rests on: no conflict semantics, no ordering model, no statement of how
  entity-resolution decisions themselves replicate. The hardest part of the
  problem is the part nobody writes down, and the claim/assertion split is
  probably the answer here too — replicate per-source claims and let each
  instance recompute promotion under its own weights, so two instances may
  legitimately believe different things from the same evidence — but that is a
  guess until someone writes it, and it constrains the schema if it is right.
- **Roadmap, not v1: a generic inbound-webhook receiver.** `channel.kind =
  'telegram'` names push delivery as a source *kind*, but nothing here specs
  the symmetric counterpart to `workflow-engine`'s well-specified *outbound*
  `http_call` primitive (`workflow-engine/spec.md` §14) — how an external
  system's own POST (a Telegram bot update, a generic third-party webhook)
  authenticates, gets verified, and lands as a `resource` triggering
  ingestion. Each provider has its own signature/secret-verification scheme
  (Telegram's bot token, HMAC-signed payloads elsewhere), which is exactly
  why this isn't designed as one generic mechanism here — it needs a
  per-provider verification story, deliberately deferred until a concrete
  push-based source is actually being integrated rather than designed against
  a hypothetical one.
