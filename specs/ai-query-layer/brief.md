# AI Query Layer — Spec Brief v0.1

> **Status update.** No longer brief-only: `schema.sql` now implements
> `graph-identity.md` (nodes / node_keys / edges + projection + the five
> modes + one dispatch RPC), and it has been run against a live PG19 beta3
> instance with a real fixture. Everything below that says "should" or
> "will" has either been verified, corrected, or is explicitly flagged as
> still unbuilt — see `schema.sql` §8 for the measured results and
> `dev/tests/query/` for the tests that reproduce them.
>
> **Second status update: "with a real fixture" was doing too much work.**
> The fixture existed in a psql session and was never committed, so no
> measured claim here could be re-run, and every mode was verified by
> somebody watching it once. Both fixtures now ship
> (`dev/init/04-graph-sample.sql`, `dev/init/05-corpus-sample.sql` — the
> latter with literal vectors, so the retrieval modes need no embedding
> server to be reproducible), and all eight modes plus the SQL escape hatch
> are executed by `dev/tests/query/02`–`09` against them.
>
> Running the whole surface rather than the happy path changed this
> document in several places, each marked where it applies. The two worth
> knowing before reading further: `GRAPH` resolved its seed key **fuzzily**
> and reported neither the guess nor the node it walked, and `SEMANTIC`
> **dropped the `FROM` its own parser requires** and searched every
> registered corpus out of an embedding space that carries no row policy —
> returning chunk ids and cosine distances for content the caller could not
> read. Neither was reachable by reasoning about the design; both took
> executing it against data with more than one tenant in it.

## 1. What this is

A single query dialect — **LOOKUP / GRAPH / SEMANTIC / SQL** in one surface — that
lets an agent or a client ask "find this entity," "walk this relationship," "find
things like this," and "run this arbitrary query" without switching APIs. This is
the REM dialect of an earlier Percolate runtime, rebuilt on Postgres 19 native primitives
instead of hand-rolled PL/pgSQL.

## 1.1 Who the dialect is for, and why that sets its altitude

**The caller this is designed for is a language model, not a person at a psql
prompt.** That is not a note about the deployment; it is the thing that decides
where the abstraction line sits, and it is worth stating explicitly because
every naming and scoping decision below follows from it.

The modes are named after the **moves an investigation is made of** — resolve a
name to a thing, walk out from a thing, find things that mean the same, find
things that say the same, ask what exists at all — rather than after the
Postgres features that implement them. Underneath, each mode stands over a
different extension or Postgres feature with its own calling convention: `pg_trgm`
for `FUZZY LOOKUP`, `pgvector` for `SEMANTIC`, `tsvector`/`websearch_to_tsquery`
for `TEXT`, RRF over both for `SEARCH`, joins and `WITH RECURSIVE` over the edge
table for `GRAPH`. A
caller writing raw SQL has to know which of those applies, which operator keeps
the index in play, and — for the vector modes — that the query embedding came
from the same model the column was written with.

**The reason to raise that above SQL is that the mistakes at that level are
quiet ones.** A distance operator that does not match the index opclass returns
rows in the wrong order, not an error. A vector from a different model returns a
number, not an error. A trigram query over `node_keys` returns one row per
matching *key*, so a node carrying a canonical, a short and an alias form comes
back three times — confirmed on the fixture, one company returned three times
for a single misspelling, and a caller that hydrates each row fetches the same
entity three times without anything failing. A model is worse-placed than a
person to notice any of these, because it does not get to see the result look
wrong and go back. The dialect's job is to convert that class of failure into a
refusal: a modifier that means nothing for a mode is rejected rather than
ignored (§3's rule), `SEMANTIC` will not search a space written by a different
model, and `LOOKUP` answers "which nodes match" rather than "which key rows
matched".

**A mode is a procedure, not sugar over one query.** `LOOKUP` is a cascade —
exact canonical, then short/alias, then opt-in trigram, each stage
short-circuiting — because fuzzy-matching a correctly spelled name is a way to
get a worse answer slowly. REM's lazy-then-load discipline (§2) is the same
shape at the next level up: `GRAPH` lazy → review → `LOOKUP` the interesting
keys is a documented two-pass pattern rather than something each agent has to
rediscover. Encoding a procedure once, in the dialect, is strictly better than
restating it in the system instructions of every agent that ever queries this
database.

**Three properties follow, and they are requirements rather than nice-to-haves:**

- **The dialect must stay small enough to fit in a prompt.** Seven modes and
  six modifiers was the budget, and it has now been spent twice: `RELEVANCE`
  and then `PATH` (§3.7, and `graph-algorithms.md` §9) make it **nine**, still
  with six modifiers, because both reuse `TYPE`, `DEPTH` and `LIMIT` rather
  than inventing anything.

  **The count is nine, and `p8_query_grammar()` is what settles it** — this
  document had said seven, eight and nine in three places within a day of the
  two landing. Nine is every entry the grammar returns, `SQL` included; the
  phrase "eight modes plus the SQL escape hatch" elsewhere in this file is the
  same nine counted with `SQL` set aside, which is the only other convention
  worth using and never worth mixing with this one in the same sentence. A mode
  is affordable when it is a question asked constantly that generated SQL gets
  wrong quietly; that is the test, not the count. This is the real argument against growing a mode
  per use case, and it is a different argument from §3.5's core-versus-extension
  discipline, which is about schema and algorithms.
- **The dialect must be self-describing.** `SCHEMA` exists so that a model needs
  neither the grammar nor this deployment's contents in its weights — it asks.
  That is also why `SCHEMA`'s hand-written examples are run back through the
  compiler on every read: a document that has drifted is worse than no document
  when the reader cannot tell.
- **A response must say what the parser understood.** Every result carries
  `plan` — the parsed query, so a model can check that its query meant what it
  thought before reading a single row — and `LOOKUP` additionally carries
  `unresolved`, the keys that came back with nothing. "No such entity" and "that
  entity has no edges" are the distinction agents most often collapse, and the
  response shape has to keep them apart. `unresolved` is emitted *only* by the
  mode that resolves names, so its absence and its presence-but-empty are two
  different readings: emitting it always, empty, for `SEMANTIC` and `TEXT` would
  destroy the second one.

**None of this is an argument against SQL, and the SQL mode is not a
concession.** The named modes will not cover a real question sooner or later,
and the escape hatch is what keeps the dialect from having to grow a mode every
time that happens (§2). The claim is narrower: for the four or five things an
agent asks constantly, a named mode is more reliable than generated SQL, and the
places it is more reliable are exactly the places where generated SQL fails
without saying so.

## 2. What we're keeping from REM, and what we're replacing

REM v1 is actually **five** modes — `LOOKUP`, `SEARCH`,
`FUZZY`, `TRAVERSE`, `SQL` — which this brief's `GRAPH`/`SEMANTIC` naming maps onto
as `TRAVERSE`→`GRAPH` and `SEARCH`→`SEMANTIC`. `FUZZY` (trigram matching via
`pg_trgm`, for misspelled/partial keys and autocomplete) doesn't disappear in the
rename — it's real capability, worth keeping as either a fifth mode or a fallback
qualifier on `LOOKUP` (e.g. `LOOKUP "text" FUZZY`); decide in the full spec, not here.

REM v1 gets the following right, which this spec keeps:

- Five query modes cover what agents actually ask for; a SQL escape hatch means the
  dialect never blocks a real query.
- **Lazy-then-load traversal**: `TRAVERSE key DEPTH n` (lazy, default) returns just
  keys/relation/summary from the index — cheap even at depth 2+, since it never joins
  back to source tables. `TRAVERSE key DEPTH n LOAD` does that join, per-entity-type,
  for full rows. The documented agent pattern is TRAVERSE lazy → review → LOOKUP the
  interesting keys — a real two-pass discipline worth carrying forward as-is.
- A uniform entity envelope (id, tenant/user scoping, `metadata` JSONB, tags,
  soft-delete timestamps) so every entity type composes into search/graph/lookup the
  same way. **`graph-identity.md` is the detailed design behind this bullet** —
  a write-time `nodes` registry (identity) + `node_keys` (exact/short/fuzzy lookup)
  + `edges` (soft, authored links) kept separate from each typed entity table's own
  attributes and from hard FK/junction relationships, which stay relational and are
  never copied into `edges`. Where this brief speaks loosely of "the entity/edge
  envelope," `graph-identity.md` is authoritative on the actual schema.
- **Typed edges as first-class**, not just `links_to`: REM already derives `builds_on`
  and `dreamed_from` edges (from its "dreaming" consolidation process) alongside
  markdown-link-derived `links_to` edges, and `TRAVERSE ... TYPE <relation>` filters
  on them. The `GRAPH` mode preserves this — edge *type* is a first-class part of
  the query, not just the target. In `graph-identity.md`'s
  terms this is the `edges.relation` catalogue: every `(src_type, relation, dst_type)`
  triple is an allow-listed entry, not a free-text string.

What's being replaced, deliberately:

- **REM's execution mechanism** — hand-rolled PL/pgSQL functions walking a JSONB
  `graph_edges` array via recursive CTEs, backed by an UNLOGGED `kv_store` cache table
  that triggers keep in sync with source tables (rebuilt wholesale on migrate — crash-
  safe by design, not by durability), plus an async `embedding_queue` worker pipeline
  for `SEARCH`. Indexed joins over a real edge table and a planner-backed `pgvector`
  index replace the cache's reason to exist (see open questions, §5, on whether any
  cache is still needed once that's measured).
- **No REST layer** — REM is called from a CLI/Python/MCP process, not exposed as
  REST. This spec makes PostgREST the interface.

## 3. Plain relational SQL, on PostgreSQL 18

This section was "the PG19-native direction". Postgres 19's betas shipped
**SQL/PGQ** (`CREATE PROPERTY GRAPH` + `GRAPH_TABLE`), a graph pattern-matching
layer defined as a read-only view over ordinary relational tables, and `GRAPH`
depth 1 compiled to it. SQL/PGQ was withdrawn from PostgreSQL 19 before GA
(October 2026). Because the property graph was only ever a view over tables
modelled relationally from day one, removing it cost one query: depth 1 is now
the same join the reverse direction already used (`schema.sql` §5). Nothing in
the extension needs a server newer than 18.

So the modes compile to:

| Mode | Compiles to |
|---|---|
| `LOOKUP "key"` | Direct row fetch — PostgREST `GET /entities?entity_key=eq.X`, or an RPC for cross-table lookup by key |
| `FUZZY LOOKUP "text"` | `pg_trgm` trigram similarity on the same index (subsumes REM's `FUZZY` mode) |
| `GRAPH "key" DEPTH 1 [TYPE relation]` | One indexed join over `aiq.edges_current` in each direction (`idx_edges_src`, `idx_edges_dst`). The seed key is resolved **exactly** (canonical, then short, then alias) and the answer reports the node it walked in a `seed` object; an unresolvable key comes back with `did_you_mean` and an ambiguous one with `candidates`, rather than either being guessed. `DEPTH` is bounded at 5 in the dialect — "unbounded traversal" is a stated non-goal that nothing was enforcing. |
| `GRAPH "key" DEPTH n>1 [TYPE relation]` | `WITH RECURSIVE` over the same edges, depth- and degree-capped. This was the plan even with SQL/PGQ, whose PG19 implementation rejected quantified path patterns (`-[e]->{1,n}`); depth 1 and the recursion are asserted to agree (`dev/tests/evals/scenarios.yaml` iter-01). |
| `SEMANTIC "text" FROM <src>` | `pgvector` similarity search against the registered model's space (§10), **joined to the corpus named in `FROM`** — the join is what scopes the search to one corpus and what puts the consumer's row policies in the path, since the mode is `SECURITY INVOKER`. Without it the mode read every registered corpus out of a space that carries no policy of its own, and returned chunk ids and distances for content the caller could not read. |
| `RELEVANCE "key" [, "key" ...] [TYPE relation]` | **Compiled, and the one mode that is not a walk.** Personalised PageRank by local push in the `pgrx` extension, over the cached adjacency snapshot — so it returns an *order* rather than a frontier, which is the thing `DEPTH` cannot express. Takes a list because relatedness to a set of seeds is the question an agent holding several entities has. Ships switched off (`graph-algorithms.md` §11) and carries `exhausted` on its envelope, because it is the only budgeted mode. §3.7 is what calling it costs at the extension boundary. |
| `SQL ...` | Passthrough RPC, `SECURITY INVOKER` + read-only — see below; escape hatch, same as REM. The correction below is executed by `dev/tests/query/07-sql-passthrough.sql`, which attempts nine write shapes (four of them past the leading-keyword check that the function's own comment calls "a courtesy, NOT the security boundary") and asserts the refusal. |

**Ten modes now exist** behind a single
`aiq.query(text, vector)` dispatch RPC (`schema.sql` §9), so a client posts one
request shape to one endpoint — the count §1.1 settles, `SQL` included. For
`LAKE` (the object-storage lake reader), the tenth, `aiq.query` returns a
plan and a lake worker runs it, because Postgres cannot reach object storage.
Of the other nine: the five
above; `SCHEMA` (§1.1, §14), which is the one answerable before you know
anything; `PATH` (§3.7), which arrived with `RELEVANCE`; and two added after
running the "R7" case (§11) — the dialect could not find a rare exact token that
appears verbatim in a chunk, because every existing mode searched keys or
vectors, never document text:

| Mode | Compiles to |
|---|---|
| `TEXT "..." FROM <src>` | native `tsvector`/`ts_rank` over a generated column + GIN index. Lexical relevance — **not BM25**; `ts_rank` has its own length normalisation and no k1/b saturation. Chosen over `pg_search` because it is permissive-licensed and in-core; `pg_search` is BLOCKED on PG19 anyway. |
| `SEARCH "..." FROM <src> [USING <model>]` | reciprocal rank fusion of `TEXT` + `SEMANTIC`. RRF rather than score blending, because `ts_rank` and cosine distance share neither scale nor direction, and no fixed normalisation survives a change of model or corpus. |

`USING <model>` names the embedding space (§10) and is rejected on modes where
no vector is involved — silently dropping a modifier the caller wrote is how a
query quietly means something else.

Verified end to end on a live instance, including cross-mode combinations and
tenant isolation (`dev/tests/query/06-graph-tenancy.sql`, `09-retrieval-tenancy.sql`).

**`SQL ...` correction: `SECURITY INVOKER`, not `SECURITY DEFINER`, and
read-only-enforced.** A stress test caught this brief
originally saying `SECURITY DEFINER` here by analogy with this collection's
other RPCs — wrong for this specific one, and worth stating precisely rather
than hand-waving "scoped": every other `SECURITY DEFINER` function in this
collection (the `rbac` schema's) does one narrow, audited thing and
never executes caller-supplied SQL text. This one, by definition, runs
whatever the caller wrote — `SECURITY DEFINER` here would mean arbitrary
caller SQL executing as the function owner, i.e. an RLS bypass and privilege
escalation primitive, exactly the class of bug the `rbac` hardening
pass exists to catch. The passthrough function must instead
run `SECURITY INVOKER` (RLS stays scoped to the calling role, same as if the
caller ran the query directly against PostgREST) and reject anything that
isn't a single read-only statement — checked by parsing (or a
`SET TRANSACTION READ ONLY` savepoint that fails closed on any write/DDL
attempt) before execution, not by trusting client-side query construction.
A single dispatch function (`aiq.query(text) returns jsonb`, exposed as a PostgREST
RPC) parses the mode keyword and routes — one REST endpoint for every mode, so any
client (including AG-UI tool calls from the `agentic` system) hits one contract.

**Where the Rust extension fits.** `pgrx` (Rust framework for Postgres extensions)
is reserved for graph *algorithms* Postgres has no native operator for — centrality,
reputation/trust propagation, clique/collusion detection, batched embedding-distance
pushdown at scale — compiled, memory-safe, in-process SQL functions. It is explicitly
**not** used for basic CRUD, lookup, or traversal; indexed joins, `WITH RECURSIVE`
and `pgvector` already do those natively and faster than a hand-rolled equivalent.

**Three of those four are now built and measured, and the exclusion above is
now a measurement rather than an assertion.** `graph-algorithms.md` specifies
ten proposals, ships seven, and parks the rest on the number that parked them —
and its §1 records that at *two* hops the recursive CTE beats the compiled
ranking by two orders of magnitude, which sharpens this paragraph's rule: the
extension earns its place when the answer is a **ranking, a bound, or a search**,
never when it is a neighbourhood. Batched embedding-distance pushdown remains
unbuilt and is the research item there (§4.5). This split
(plain SQL for traversal, `pgrx` only for algorithms with no SQL equivalent) carries forward from the earlier Percolate runtime's design rather than being
re-derived here.

**Explicitly not used**: Apache AGE. No precedent for it in the earlier runtime, and joins and
`WITH RECURSIVE` over the edge table cover the same ground with less operational
surface (no separate extension to install/upgrade in lockstep with Postgres).

## 3.5 Core + extensions — for both the schema and the algorithms

Two questions this brief originally left open — one graph schema or many,
one `pgrx` module or many — don't need resolving as upfront design decisions.
Resolving them now would mean guessing at consumers that don't exist yet. Both
get the same answer, and it's a standing pattern, not a one-time call: a small,
stable **core**, plus **extensions** that consumers add as they're actually
built, with a deliberate **promotion process** for moving something from
extension into core — never automatic, never speculative.

**Schema.** Core is `graph-identity.md`'s `nodes` / `node_keys` / `edges`
triple; each consumer's hard relationships stay its own FK junctions.
That's small enough to ship now and genuinely consumer-agnostic — it's not a
placeholder, it's the real core. Each consumer (`world-model-ingestion`'s
event/entity graph, `agentic`'s delegation tree, a future application's
domain-specific graph) is an **extension** in exactly one sense: its own typed
entity tables, opted into the shared `nodes` registry via the inclusion policy
(`graph-identity.md` "Inclusion policy") and the write-time projection trigger.
Nothing about a consumer's typed table is core — only the fact that its
included rows get a `nodes`/`node_keys` row is. A consumer's *hard*
relationships stay plain joins.

**Algorithms.** Core is whatever `pgrx` functions turn out to be needed by more
than one consumer — nothing, today. Every algorithm starts as an **extension**:
written for and owned by the specific consumer that needs it
(`world-model-ingestion`'s reputation propagation and collusion detection is the
first concrete one), living in its own feature-gated module or its own crate,
not forced into a shared module speculatively before a second need exists to
generalize from.

**A named exception used to sit here — `fuse_coherence` starts in core — and it
has been withdrawn.** The argument was that a fusion over sources and a
reputation computation over people are the same algorithm with different
weights, that two independent consumers therefore already existed, and that the
second-consumer threshold was met *now* rather than speculatively.

The premise stopped holding. Both consumers moved to
a separate research extension and are specified in the *same document* there, so
they are two consumers of one function but not independent ones, and promoting
on that basis would put unproven research into core on a technicality. The
fusion function prototypes there, as a `pgrx` extension depending on
`percolate`, which keeps deterministic stages in SQL without this repo carrying
weights nobody has fit yet.

Worth keeping the shape of the original argument, because it is still the right
argument once the evidence exists: the shape is shared, the **weights** are
per-domain and passed in, never per-domain code. What changed is only *when* it
earns a place here — on a second, independent consumer.

**The process, not just the split.** An extension is promoted to core when a
*second*, independent consumer needs the same thing — not before, and not
automatically just because the first one exists and works. Promotion means:
move the function or table definition into the core module, keep its interface
stable, update every consumer's spec to point at core instead of its own copy.
This is the same discipline the project applies
to the whole collection (check precedent, generalize on the second real
need rather than the first) — restated here as a standing, named rule for this
system specifically, since it's the one system every other consumer extends and
therefore the one place "core creep" would actually hurt.

## 3.6 Coherence at query time — the read half of the ingestion lens

The coherence algorithm, in a separate research extension, is how data earns its
way into the graph.
This is the other half: how that work survives being queried, instead of being
flattened back into undifferentiated text at the last step.

Nothing here needs a new mechanism — `graph-identity.md`'s `edges` table already
has both columns required. Promotion writes the fused score into
**`edges.weight`** (already there, already defaulting to `1.0`) and the scoring
audit trail into **`edges.provenance`** (already `jsonb`, already meant for this).

Three consequences:

- **`GRAPH` traversal is coherence-ranked for free — now true, and it was not.**
  `graph_walk` returns `path_weight`, the product of the edge weights along the
  path, and orders by depth then by that weight; the row cap therefore truncates
  the far, weak end. A two-hop path through one strongly-corroborated and one
  barely-promoted edge ranks below two strong hops, which is the claim this
  bullet has always made.

  It was false when written. The walk ordered by node **uuid**, never read
  `weight` at all, and its cap dropped whichever nodes the uuids happened to
  drop — so the entire ingestion pipeline's scoring was discarded at the read
  step, which is exactly the failure this section exists to prevent, occurring
  inside the section describing it. Found by running it
  (`dev/tests/query/05-graph-traversal.sql` §4), not by reading it.
- **A dialect qualifier that does not exist yet: `MIN COHERENCE <n>`.**
  `GRAPH "key" DEPTH 2 MIN COHERENCE 0.7` would filter on `edges.weight` at
  traversal time — same shape as the existing `TYPE relation` qualifier, and
  subject to the rule `USING <model>` already established: rejected where it is
  meaningless rather than silently dropped.

  **The parser rejects it today** — `MIN` is not a token it knows, and with no
  `DEPTH` before it the argument counter misreads the whole clause and reports
  "GRAPH takes one argument, got 4". That is the right direction to fail in, but
  this bullet was written in the present tense for a qualifier nothing
  implements, which is the thing this collection's own method section warns
  about. It needs a change to the `percolate_parser` crate, not to SQL — the
  ordering half above lands in the function and is done; the *filter* half is
  unbuilt and is recorded here as unbuilt.
- **`SEARCH` takes coherence as a third rank input** alongside lexical and vector,
  fused the same RRF way and for the same reason — the three share neither scale
  nor direction, so blending scores wouldn't survive a change of model or corpus.

The one that matters most, and is easiest to skip: **`agentic`'s citations should
carry the score and its interval** (`specs/contract/types/agentic.citation.yaml`), so an answer can
distinguish "three independent registries agree" from "one blog said so." Without
that, retrieval discards the entire ingestion pipeline's work at the final step —
which is precisely the failure mode the FEVER result documents (~32% joint
accuracy *with* correct evidence retrieved: fusion failure, not fact scarcity,
dominates).

## 3.7 The extension boundary, and every place we cross it

This collection is **two extensions**, and the split is structural rather than
stylistic. `percolate_parser` carries C functions, so it must be installed by a
superuser. `percolate` owns tables and RLS policies, so it must **not** be —
extension objects belong to whoever runs the script, and a superuser-owned
table has inert policies. Neither half can be what the other is; §3's own
header records both failures being verified against PG19.

So there is a boundary, and SQL crosses it constantly. `aiq.query` calls
`aiq_parse`. The graph wrappers call `p8_graph_*`. The workflow compiler calls
`p8_compile_workflow`, the plan viewer calls `p8_plan_graph`, and both
self-describing schema facets call a grammar function to avoid keeping a second
copy of a grammar. **Twenty-three crossings across four schemas**, at the time
of writing.

**Every one of them is late-bound.** plpgsql resolves a function name at
execution rather than at creation, which is what lets the two halves be
installed separately — and is exactly why the failure is quiet. A database can
install cleanly, pass the surface audit, and fail on the first call because the
compiled half is older than the SQL half. That is not an exotic state: **a SQL
reload does not carry a `.so`**, so it is the normal condition of any stack that
pulled a new schema without a new image, and `dev/reload.sh` says so in its own
header.

`aiq.extension_boundary()` answers "are my two halves in step" from the
catalog rather than from a list somebody maintains:

```
{"ok": true,
 "provider": {"extension": "percolate_parser", "version": "0.1.0", "functions": 21},
 "crossings": [{"caller": "aiq.query", "callee": "aiq_parse", "present": true}, …],
 "missing": []}
```

It reads the bodies, because a hand-written list of crossings drifts in two
directions at once — claiming one that no longer exists, and missing the one
somebody added last week. Deriving it found a false positive worth recording:
the first version matched `aiq_parse()` inside the *error message* several
functions raise to apologise for its absence, and reported four crossings that
were apologies rather than calls. The pattern now requires an argument, with a
second clause for the genuine zero-argument calls that go through dynamic SQL.

**Three rules follow, and they are the reason this section exists rather than a
comment on one function.**

- **A caller across the boundary checks, and the check names the extension.**
  Not `function p8_graph_ppr(...) does not exist`, which reads as a corrupt
  schema, but a sentence saying which extension is missing and how to get it.
  `aiq.query` has done this since it was written; the graph wrappers do it
  through `aiq.graph_algorithms_available()`.
- **The compiled half is pure, or as close to it as the job allows.**
  `aiq_parse` is computation over a string. The graph functions read tables,
  but through SPI as the caller, so RLS applies and the SQL half keeps the
  security model. Nothing across the boundary writes.
- **Version skew is a first-class state, not an error to explain away.** The
  two halves ship on different rails — one in an image, one in a script — so
  they *will* diverge, and the design has to make the divergence legible rather
  than assume it away.

## 4. What's pushed to Postgres vs. what isn't

Pushed: query parsing/dispatch, graph pattern matching, vector search, the RPC
surface itself. Not pushed, structurally: embedding generation for query text
(an external model call — happens in a thin FastAPI/worker step before the SEMANTIC
RPC is called, same "one side effect the app layer owns" pattern as email-sending in
`rbac`).

## 4.5 One idea worth importing: confidence as a time constant

`edges.weight` is a static number — a registry subsidiary claim carries 0.95 and
carries it forever, whether it was asserted this morning or two years ago.

A separate proposal suggests the missing
half is a **half-life**. Under that reading `weight` is an amplitude, and what
it lacks is how long the claim should stay believed without reinforcement: a
model's speculation fades unless independently corroborated, a statutory filing
does not. Confidence then stops being a number nobody can calibrate and becomes
a duration, which is easier to defend — arguing *this should be believed for six
months* is a conversation people can have, and arguing *this is 0.7* is not.

Two consequences if it were ever adopted, both real costs. A decayed weight is a
function of `now()`, so nothing can index it and every ranked read becomes an
aggregate — affordable only at a locus, never over the graph. And it overlaps
the ingestion pipeline's source grading, which attacks the same
calibration problem from the other end; **two mechanisms for "how much do we
believe this" is one too many**, and that is an open question
rather than a plan.

Unbuilt and mentioned here so a future reader of `edges.weight` knows one
proposal already depends on it meaning what it says.

## 5. Open questions for the full spec

- **Resolved — how an agent learns what this deployment can do.** The `SCHEMA`
  mode (`schema.sql` §13). The design question was whether a capability
  document should be written or derived; the answer is *both, split visibly*.
  Anything the catalog can prove is read from it (step kinds off a check
  constraint, callable functions off the allow-list, the edge catalogue off
  the table the trigger enforces), what a catalog cannot express is emitted by
  the Rust crate that implements it, and the examples — the part most likely to
  rot — are rows that get executed on every read. A facet is a registration, so
  a future soft schema (controlled vocabularies, connector
  credentials) is an INSERT and a function rather than a parser change.

  What is **still open**: whether the document should be embeddable, i.e.
  whether an agent should be able to `SEMANTIC "how do I fan out over a query"
  FROM schema` and get the right facet back. That is a genuinely different
  interface — retrieval over the capability document rather than a named
  fetch of it — and it needs a corpus of real agent queries to say whether
  naming four facets is already enough. Not built on the same principle §3.5
  applies elsewhere: generalise on the second consumer.

- **Resolved — one graph or many, one `pgrx` module or many.** See §3.5: both
  are core-plus-extensions with a second-consumer promotion rule, not a
  single upfront design choice. Nothing left to decide here in advance.
- **Resolved — whether `pgrx` can target PG19 beta3 at all.** Confirmed
  directly: `pgrx` v0.19.2 already ships a `pg19` feature; a real extension
  was built, packaged, loaded, and called successfully against a live PG19
  beta3 database.
- **Partially resolved by `graph-identity.md` — not "no cache," a different,
  bounded one.** REM's `kv_store` cached the *whole* graph (a JSONB
  `graph_edges` snapshot per entity, rebuilt wholesale). `graph-identity.md`'s
  `nodes`/`node_keys` is not that: it's a purpose-built identity/lookup index
  over a *curated subset* (the inclusion policy — LOOKUP/FUZZY-able content or
  edge endpoints only, never the full data-plane), kept in sync at write time
  via a same-transaction, **statement-level** (not per-row) trigger — so
  writing a batch of 10k included rows costs one set `INSERT` into
  `nodes`/`node_keys`, not 10k trigger firings, and a bulk `COPY` disables the
  trigger entirely and pays one rebuild pass instead. `edges` themselves are
  written directly, no derived/cached copy, and traversal reads them with
  ordinary joins rather than through a third copy of the graph. What's genuinely **still open, pending
  real data**: whether a *traversal*-result cache (memoizing a hot multi-hop
  recursive-CTE query's output, as opposed to identity lookup)
  is ever needed at real scale — that's a different question from REM's
  `kv_store`, not yet benchmarked, not resolvable by design discussion alone.
