# Global graph identity — write-time nodes, authored edges, PGQ overlay

**Status:** draft for review
**Date:** 2026-08-31
**Kind:** design principle (storage and query substrate). Not an implementation plan.

> Relationship to `brief.md`: this is the detailed design behind the "uniform
> entity envelope" and "typed edges as first-class" bullets in §2, and the
> concrete schema behind §3.5's core+extensions "generic entity/edge envelope."
> Where this doc and `brief.md`/`ontology.md` differ on specifics, this is the
> authoritative version — it supersedes the earlier, simpler description as
> the design matures. `world-model-ingestion`'s `events`/`entities`/`topics`
> graph is a concrete extension consumer: its entity tables
> keep their attributes, its soft relationships live in `edges`, and any
> subsystem's delegation/lineage tree (`agentic`'s `RUN.parent_run_id`,
> `ai-query-layer` consolidation edges) works the same way — see "Relation to
> other work" below for the boundary.

## Goal

One global node identity and one authored edge store, kept in sync at write time, so a lookup by key (exact or fuzzy) and a bounded graph walk stay index-served at large scale. Typed entity tables keep attributes. PostgreSQL property-graph queries, when available, read these tables. They do not become a third copy of the graph.

## Decisions

| # | Decision |
|---|----------|
| **D1** | Identity is a write-time **node registry**, not a `UNION ALL` of entity tables. |
| **D2** | Soft links are written to a first-class **edge table**. JSONB edge lists on entity rows are not the write API. |
| **D3** | Edges reference stable **node ids**, not display keys. Keys are a lookup index. |
| **D4** | Hard links (foreign keys, junctions) stay in the relational schema. They are not copied into the edge table. |
| **D5** | Only included entity types become nodes. Machine-generated data-plane rows are not nodes. |
| **D6** | Node projection is **same-transaction** and **set-based** (statement triggers + transition tables). Bulk load disables those triggers and rebuilds once. |
| **D7** | A scheduled two-way `EXCEPT` is the drift detector. Rebuild is the repair. Drift is a bug in a writer, not a routine merge. |
| **D8** | SQL/PGQ is a **read-only graph definition** over the registry, the edge table, and the hard-link junctions. No extra sync. |
| **D9** | A unified `nodes` table exists so **polymorphic** authored edges have one vertex parent. It is not a copy of attributes. Hard-memory vertices in PGQ stay the typed tables. |
| **D10** | Graph-index maintenance (this doc) and semantic-index maintenance (the ingestion layer's embedding pipeline) are **one architectural concern, not two**: a derived index kept current off a primary-table write. Default mechanism is `workflow-engine`'s existing queue, reused, not re-invented per index type. The one exception is the live `nodes`/`node_keys` projection itself (D6) — synchronous and trigger-based *specifically because* invariant 4 requires same-transaction `LOOKUP` visibility, an actual requirement an async queue can't satisfy. Everything else in this doc that isn't that one write path — the bulk-load rebuild, the drift-repair job — has no such requirement and is a `workflow-engine` task like any other scheduled/background work in this collection. |
| **D11** | Resolution is a **record, not an index behaviour**. Merging two nodes writes a `node_resolutions` row and deletes neither constituent. Unresolve is a supported operation, not a repair. |

## Two memories

**Hard memory** is the relational model: typed tables, primary keys, foreign keys, junctions. It answers "what is this attached to?" with an indexed join.

**Soft memory** is associative: links the schema does not already capture (analyst or agent authored, curated relevance, provenance). It lives only in the edge table.

A fact that a foreign key already states must not also be an authored edge. Duplicating it pays write amplification and creates two sources of truth.

Both are halves of one graph, not the **memory systems** component of a model's context. Either half can hold retrieved knowledge or memory; which one a row is depends on where it came from — ingested from a source, or written from the system's own use — not on whether it is a foreign key or an authored edge.

## Node registry

A node is a graph identity for one included row in one typed table.

```
nodes
  id            uuid        primary key     -- graph identity (stable)
  entity_type   text        not null        -- owning table
  entity_id     uuid        not null        -- PK in that table
  org_id        uuid        null            -- tenant; null = shared reference
  summary       text
  created_at    timestamptz not null
  updated_at    timestamptz not null
  unique (entity_type, entity_id)
```

The registry does not store the entity payload. Payload stays on the typed table. Lookup hydrates with `entity_type` + `entity_id` against that table's primary key. It does not union typed tables to find the row.

## Keys (lookup index)

Keys are how humans, agents, and SIPQL name a node. They are not the edge foreign key.

```
node_keys
  node_id       uuid        not null → nodes(id) on delete cascade
  entity_type   text        not null        -- copied from nodes; uniqueness without a join
  key           text        not null        -- normalized
  kind          text        not null        -- canonical | short | alias
  org_id        uuid        null
  unique (org_id, key, entity_type) NULLS NOT DISTINCT WHERE kind = 'canonical'
```

`entity_type` is copied onto `node_keys` so the unique index does not join `nodes`. The same short string may be canonical for two types (an event and an ontology named Bakhmut). Qualified keys (`places/ukraine/bakhmut`) are unambiguous. Short-key lookup (`kind = short`) is not unique and may return several nodes. Aliases (`kiev` → `kyiv`) are extra rows of `kind = alias`, not mutations of the canonical key.

**The shared tier must be a value, not a NULL, or the unique index does not constrain it.** `org_id` used to be nullable and a NULL meant shared reference data — the normal state for every public entity in a deployment. Under Postgres's default `NULLS DISTINCT` two NULLs never conflict, so the index enforced canonical-key uniqueness for tenants and not at all for the shared tier. Measured on the sample fixture: two companies both took the canonical key `acme`, and `LOOKUP "ACME"` — documented as an exact match — returned two different nodes with nothing to choose between them.

The first fix was `NULLS NOT DISTINCT`. The real fix, [`identity/spec.md`](../identity/spec.md) §4, is that `org_id` is `NOT NULL` and the shared tier is a row: `rbac.shared_org_id()`, a v5 uuid derived from a published namespace so it is the same value in every deployment. The index constrains the shared tier by the same equality as every tenant, and the `NULLS NOT DISTINCT` flag survives as a no-op with a comment saying so.

**Aliases and short keys need a write path, and invariant 5 forbids the obvious one.** The projection derives exactly one key per source row, the canonical one, because that is all an expression over a typed table can produce. The other two kinds are editorial — `kiev` is an alias for `kyiv` because somebody decided so — so two thirds of the lookup cascade had no way to be populated that the invariants permitted. `aiq.add_node_key(existing_key, new_key, 'short'|'alias')` is the named exception: it resolves the target through the ordinary cascade, refuses an ambiguous target rather than picking one, copies `entity_type` and `org_id` from the node so they cannot disagree with it, and refuses `kind = 'canonical'` outright — a second canonical key on one node is not a synonym, it is two names each claiming to be the derived one.

**A key resolves to the reader's own node before a shared one (REM-976, percolate 32149708).** With per-owner private nodes (REM-962), one key can name a node in each scope. `aiq.lookup` keeps, per kind and key, only the nearest scope the reader can see: their own private node, then the org's, then the public one. Two kinds under one key are still two rows. GRAPH's `seed` names the `scope` it walked. `aiq.add_node_key` still counts every scope, because a write must not pick. `aiq.resolve_ref` takes the mention's visibility and owner, which `upsert_graph` reads off the memory. A private node binds only to its owner's private mention, and the nearest scope wins. Percolate's rbac test 25 holds both.

**Lookup order.** Implemented as `aiq.resolve_mention` in `resolution.sql`,
which returns the METHOD alongside the match so a caller can tell an answer from
an escalation, and ambiguity from absence.

1. **Exact** on a normalised key, always attempted, at any length. An exact
   match is an identity and needs no gate.
2. **The entropy gate**, guarding the two guessing steps below it. `aaa` and
   `Bob` cannot be matched by similarity because there is nothing in them to be
   similar about. Shannon entropy per character, with the threshold and the
   minimum length as parameters — the defaults came from graphiti's corpus, not
   ours, and a registry of hex digests has different entropy per character.
3. **The dropped qualification**: one key ending in the mention, at a separator.
   `claim_task` for `workflow.claim_task`, `check.sh` for `dev/check.sh`. The
   separators are a parameter defaulting to `.` and `/`, which are the two this
   extension writes and not the general set.
4. **Fuzzy**: trigram over `node_keys`, not over typed tables, not over the full
   data plane. Above a floor that defaults to 0.62.
5. Anything left **escalates, and says why** — `no-match`, `low-entropy`, or
   `ambiguous`.

**Ambiguity is a distinct answer, not a failure.** Two nodes sharing a name is a
question a similarity score cannot settle; a name matching nothing is a
different question. A caller that cannot tell them apart asks a model the wrong
one, and a filename existing at four paths reported as `no-match` is exactly
that mistake.

**And it reports how large it is, because it returns a sample.** An ambiguous
escalation carries at most five exemplars, ordered by key so that the same
mention resolves the same way twice — `limit` without `order by` is not a bug a
test run finds, it is a bug the next plan change finds. `score` carries the
*total* candidate count, so five-of-five and five-of-forty-four are
distinguishable. Measured over 2,501 backticked tokens from a project's own
documentation against a registry built from that project: 163 ambiguous, 22 of them over the cap, one
at 44. Without the count a model is handed an arbitrary five of forty-four with
nothing saying it was a sample, picks one, and sounds certain — the wrong answer
rather than the error, which is this layer's characteristic failure.

**`score` is read through `method`, never on its own.** It is 1.0 for `exact`
and `suffix` (identities, not estimates), the trigram similarity for `fuzzy`,
the character entropy for `escalate:low-entropy`, and the candidate count for
`escalate:ambiguous`. One column carrying five quantities is a compromise, and
the alternative — five nullable columns, four of them null on every row — is a
worse one; what makes it safe is that the method is returned first and every
consumer branches on it.

**Why the entropy gate does not cover step 1 but does cover step 3.** Exact
matching is an identity and is safe at any length. A suffix match is a *guess*
that a qualification was dropped, and on a short generic word the guess is
usually wrong — in front of the gate it resolved the bare word `done` to a
column named `done`, one match, confidently, and the prose meant no such thing.

Fuzzy search is allowed only on this thin key table (and, if needed, a
still-thinner alias subset). It is not a catalog-wide `UNION ALL` with
`similarity()`.

## Resolution ledger (D11)

**Built in 0.2.0** — `aiq.node_resolutions`, `aiq.resolve_nodes`,
`aiq.unresolve_node` and the `aiq.node_current` view, with
`dev/tests/query/04-graph-identity.sql` asserting the four properties below plus
the one that is easy to lose: a resolution must NOT change what a traversal
returns, or every existing caller's meaning changes the day somebody runs a
resolver. It was specified here long before it existed, and the cost of the gap
was concrete: a consumer building all three identity stages on these surfaces
had a substrate call for every step except recording what it decided, and kept
its clusters in a local table.

Two rows turning out to be one thing is the most consequential write this schema accepts and, until 0.2.0, the only one that left no trace. The cost cascade already knows *which tier* resolved a given pair — the ingestion layer's cost cascade — registry match, crosswalk, embedding similarity, LLM — and says plainly that only the first three are deterministic. That is a decision under uncertainty, and it is currently expressed as an index state nobody can inspect, argue with, or reverse.

```
node_resolutions
  id            uuid        primary key
  canonical_id  uuid        not null → nodes(id)   -- the node that survives
  merged_id     uuid        not null               -- the node folded into it; NOT deleted
  tier          text        not null    -- registry | crosswalk | embedding | llm | human
  evidence      jsonb       not null default '{}'  -- the matched key, score, agent run
  decided_by    text        not null    -- resolver version, agent id, or user id
  undone_at     timestamptz null        -- set on unresolve; the row is never deleted
  org_id        uuid        null
  at            timestamptz not null default now()
  unique (merged_id) where undone_at is null
```

**A merge moves keys; it does not destroy them.** The merged node's canonical key becomes an `alias` on `canonical_id`, carrying the resolution id that moved it, which is what makes unresolve mechanical rather than reconstructive: restore the alias to canonical on the merged node, set `undone_at`, and every edge written against `merged_id` is still there because the node was never deleted. Compare the destructive path — collapse to one row, discard the loser — which cannot be undone at any price because the evidence for the merge and the loser's own history both left with it.

**`tier` is the load-bearing column**, for the same reason `wm.claims.is_deterministic` is: a registry match on a CIK and an embedding-similarity guess are not the same kind of assertion, and anything reading resolutions as ground truth without reading `tier` is unsound. It is also what makes the cheap audit possible — *how much of this graph's identity rests on a model's guess?* is a `GROUP BY`.

**Two functions write this table, and until 0.2.20 only one of them did.**
`aiq.resolve_nodes` folds one registered node into another: names move, the node and its
edges are untouched, and `aiq.unresolve_node` reverses it. `aiq.promote_soft_node`
(the ingestion layer's staging-area promotion) evicts a candidate into a real node: it
repoints the edges and the candidate node goes. Both are the decision this table exists to
record, and the second wrote nothing, so the `GROUP BY tier` audit above answered for
registered merges only and omitted every staging eviction — the path a resolver actually
takes, since a candidate is what a resolver resolves. A promotion's row is a record and not
a reversal point: there is no node left to restore, so `unresolve_node` refuses it rather
than appearing to succeed.

**`decision_model` is the sixth tier.** The first five are `registry`, `crosswalk`,
`embedding`, `llm` and `human`. A decision model returns one option from a declared set
in a forward pass with no generation, which is neither an embedding score nor an LLM's
answer, and recording it as `llm` lost the distinction the column exists to make. This
section used to say to add it with its first caller; that caller was an entity-resolution
run that had to record a decision model's choices as `llm`.

**"Not the same" is a decision too, and `aiq.node_distinctions` records it.** A resolver
that judges a candidate against a node and says no is making the commonest decision in
entity resolution, and until 0.2.20 it had nowhere to put it: the next landing of the same
name asked again. In that entity-resolution run 323 of 1,000 names needed a decision a second
time, most of them already judged to match nothing. `aiq.record_distinct(node, other,
decided_by, tier, evidence)` writes the row, `aiq.decided_distinct(x, y)` answers in either
order, and `aiq.undo_distinct` marks a wrong one undone without deleting it. A live row
binds: `resolve_nodes` and `promote_soft_node` refuse to merge the pair, and
`record_distinct` refuses a pair the ledger already says is one node. It is a separate
table rather than a `relation` column here because every reader of `node_resolutions`,
`node_current` first, takes a row as a merge. A distinction is visible only when both of its
nodes are, as an edge is.

**Candidate identity does not live here.** *These two nodes may be the same* is uncertainty, not a decision, and belongs one layer up in the ingestion layer's staging area, where it can accumulate evidence without asserting anything. This table records only what was decided; a candidate that never resolves never appears in it. Keeping the two apart is what stops embedding proximity — legitimate for proposing a merge, forbidden as a scoring input — from leaking into the graph as a fact.

## Edge table (canonical for soft links)

Authors insert, update, and delete rows here. Application code does not explode JSONB into edges.

```
edges
  id            uuid        primary key
  src_id        uuid        not null → nodes(id) on delete cascade
  dst_id        uuid        not null → nodes(id) on delete cascade
  relation      text        not null        -- catalogue term
  weight        real        not null default 1.0
  valid_from    timestamptz
  valid_to      timestamptz
  provenance    jsonb       not null default '{}'  -- session, rationale
  org_id        uuid        null
  unique (src_id, dst_id, relation)
```

Indexes: `btree(src_id)` forward, `btree(dst_id)` reverse. Reverse questions ("what points at this site?") are first-class. Do not store the inverse edge. Inverse *labels* come from a relation catalogue at read time — and a label the read path shows must be accepted back as a filter, or a result cannot be fed into the next query, which is what the lazy-then-load discipline is made of.

**Temporal validity is read, on every surface, through one rule.** `aiq.edge_is_current(valid_from, valid_to, at)` is that rule — `valid_from <= at` and `valid_to` null or after it — and everything that answers "what holds" goes through it: the `aiq.edges_current` view, the `aiq.knowledge_graph` property graph (declared *over that view*, so a bare `GRAPH_TABLE` match filters), `graph_neighbors`, `graph_walk`, the catalogue refresh, source reliability, edge standing, and the compiled traversals, whose `as_of` now defaults to the statement's `now()` instead of to no filter at all.

It did not, and this paragraph recorded the gap: `valid_from` / `valid_to` were stored and no read path filtered on them, so an edge retracted a year ago was still traversed, while the one view anybody read hid it. Four spellings of "current" and three surfaces applying none is the shape of wrong answer this surface fails by, and REM-51 closed it. `dev/tests/query/05` §14 — which asked to be inverted rather than deleted on the day the filter landed — now asserts the filter; `dev/tests/query/15` asserts it on every other path.

**A retraction that is later undone is a hole, not a gap in the record.** Edge identity is `(src, dst, relation)`, so a re-assertion lands on the existing row and used to overwrite the retraction: `valid_from` stayed at the first assertion, `valid_to` went back to null, and an as-of read *inside* the retracted period saw an edge nobody believed then. The row still holds the current fact; `edge_retractions` holds one row per retraction that was later undone, and `aiq.edge_periods` is the row with those holes cut out of it — one row per interval over which the edge was believed. An as-of read is `aiq.edge_is_current` over `edge_periods`, which is what the compiled snapshot is built from. A current read never consults it, because every hole closed at a revival that has already happened (REM-65).

> **The holes are written by a trigger, not by each writer.** Edges are revived by the ingestion upsert, the catalogue refresh, an application's derivations and a package's dream, each spelling the revival in its own words. `trg_record_edge_retraction` is the one place every revival passes through, including whichever writer is added next. A retraction and revival at the *same* `now()` — what a derivation does when it retires what it owns and re-derives — is not a hole, because nobody stopped believing anything.

**Both endpoints must be nodes.** An authored edge cannot target a data-plane row that has no registry row. If a product is not a node, you do not write `detected_on` into `edges`; you join `annotations.product_id`.

**Catalogue.** Every `relation` is an allowed `(src_type, relation, dst_type)` triple. Out-of-catalogue relations are rejected at write. The check is a `BEFORE INSERT OR UPDATE` trigger rather than a foreign key, deliberately: a foreign key on the term alone would make a relation legal between *any* two types, and the triple is the thing worth constraining. The cost is per row — measured at roughly 15 µs an edge, about three times the insert itself — so a bulk load disables it and revalidates in one set-based pass, per "Bulk load" below.

**A symmetric relation is stored once, in one endpoint order.** `relation_types.is_symmetric` declares it, and the catalogue trigger normalises `src_id > dst_id` by swapping rather than by refusing — a rule the writer has to know before it can insert is a rule every writer gets wrong once. Without this, `unique (src_id, dst_id, relation)` admits both `(a,b)` and `(b,a)` as legal rows describing one fact, and the consequence is not only that consumers dedupe by hand: every read path here unions out-edges with in-edges, so the pair is *traversed twice* — twice the share of the mass in a ranked walk, a degree of two in a k-core. A wrong number rather than an error, which is why `dev/tests/query/11` §7 asserts it. (Spelled `is_symmetric` because `SYMMETRIC` is a reserved word; compared as `uuid`, which is byte order and needs no collation — the same constraint over text keys is a real trap, because a client language's sort order and the database's collation disagree on strings that differ only by a separator.)

## The database's own catalogue (catalogue.sql)

An anchor that **joins rather than matches**. An edge between a document and the
thing it discusses is a `position()` over prose; an edge between two database
objects can be a join on a catalogue identity, and the dependency graph between
them comes from `pg_depend` — exact, complete, and maintained by Postgres rather
than inferred from traces.

`aiq.db_objects` holds functions, tables, views, columns, indexes and roles.
`aiq.refresh_catalogue(schemas, reader_roles)` populates it, registers the
entity type, and derives `depends_on` edges from `pg_depend` (via `pg_rewrite`,
for what a view selects from) and `pg_constraint` (for foreign keys).

**Opt-in, and that is the design.** Nothing runs at install: the table ships
empty and the refresh is a call. A deployment that does not want its own schema
in its graph gets an empty table and pays nothing; one that does gets it without
writing the `pg_catalog` joins every such application would otherwise write
again.

**One row per qualified name; overloads are an attribute.** A canonical key is
unique per entity type, so two overloads of one function cannot be two nodes.
The graph knows a named surface, the row knows the signatures, and a claim
anchored here is anchored to the name.

**The schemas and the reader roles are parameters.** The defaults are what this
extension ships with. A deployment that installed elsewhere, or added a fourth
reader role, would be silently mis-catalogued by a hardcoded list rather than
loudly so.

**No `org_id`, and that is a decision.** Sixteen tables here carry one and this
is not the seventeenth: a database's schema is one shared fact about the
installation, not a per-tenant one — there is no sense in which `aiq.edges`
belongs to an org. A column would have meant either a policy over data with no
owner, or a nullable column nobody sets, and the second is how `org_id IS NULL`
came to mean two different things elsewhere in this schema. It is declared
shared in the read-surface test and registered for `pg_dump` in
`specs/contract/schema.sql`, both of which follow from that decision and neither of
which is visible from it.

**`depends_on` does not promise exactness on behalf of every writer.** The edges
this function writes are exact. The relation is the general one, and an
application may add heuristic edges under it — from a function body that names
an object, or from prose. `provenance.kind` is where a reader learns which they
are holding.

**Dependency edges relate RELATIONS, not columns.** A column row carries its
table's oid, because a column has no oid of its own worth storing, so a join
over `any(oids)` matches every column of a table as well as the table itself.
Left unrestricted, a view reading one table acquires an edge to each of its
columns: measured once at **33,272 of 37,145** dependency edges pointing at a
column. `dev/tests/query/14` pins it.

**It converges rather than being idempotent.** Registering the entity type
creates two functions in `aiq` — the projection triggers — so the first call
changes the schema it is cataloguing and the second sees two more objects than
the first. Stable from there. Cataloguing a schema that the cataloguing extends
is self-referential, and the honest property is that it settles.

## What an edge is worth — use, and weight (edge-standing.sql)

Three questions about an edge that are deliberately *not* fused into one score.
A single "importance" number over them would be a weight fitted against nothing,
which this collection does not admit to core. Each surface reports its own
evidence and lets a caller combine them.

**Has it ever answered a real question?** `aiq.edges` carries `recall_count`,
`probe_count` and `last_recalled_at`, written by `aiq.note_recall` and
`aiq.note_probe`. An edge that is merely still true is a different object from
one that is stale and load-bearing, and until these columns existed the two were
indistinguishable — which matters because usage-based consolidation over the
first will happily delete the second.

`aiq.edge_standing` reads them back as four states: `retracted`, `only ever
probed`, `never used`, `load-bearing`. **`only ever probed` is its own state**
rather than folded into `never used`, because they call for opposite actions:
one says the monitoring found it and nobody else did, the other says nothing has
ever looked. The probe/recall split exists for the same reason — a system
testing itself must not consolidate around its own monitoring.

**Is its weight distinguishable from chance?** `aiq.edge_disparity` is Serrano
backbone extraction: for a node of degree *k* and strength *s*, an incident
edge's normalised weight is *p = w/s*, and under a null that partitions the
strength uniformly at random the probability of a share at least this large is
*(1 − p)^(k−1)*.

It **reports alpha and filters nothing**. The significance level is the caller's
decision and a graph has no business choosing it. Degree 1 returns NULL rather
than "not significant", because the null has no variance with one incident edge
— "no evidence either way" and "evidence of no effect" are different states and
only one of them is evidence.

**Reading a neighbourhood is itself an event.** `aiq.neighbours(key, probe)`
returns a node's depth-one neighbourhood *and records that the edges were read*.
A function rather than a view because a view cannot record that it was read and
no trigger fires on `SELECT`. Depth one is not a parameter: a deeper walk that
marked everything it touched would credit edges the caller never looked at,
which is the opposite of what the counter is for. Callers wanting reach have
`GRAPH` mode and the compiled algorithms.

**These three views are `SECURITY INVOKER`, and it is load-bearing.** A view runs
as its *owner* by default; `app_owner` owns `aiq.edges` and is not subject to its
row-level security, because the table is RLS-enabled but not FORCE RLS and a
table owner bypasses its own policies. On the default, a view here would return
every org's edges to any caller granted select on it.

## Enrichment passes — the seam a scoring consumer needs (intent)

**Status: intent, not built. Recorded here because the gap is conspicuous next to
what is built, and because leaving it undocumented invites each consumer to solve
it with a worker.**

Three registration points already exist and between them they cover most of what
a consumer brings: an extractor is an `agentic.agents` row, landing a graph is a
**registered step function** (`aiq.upsert_graph`), and a maintenance pass is a
`workflow-engine` scheduled task. Adding a kind, a relation or an extractor is an
insert in each case.

There is a fourth shape with no home. A **scoring pass** is handed a set of
candidate node pairs and returns weighted, typed edges — one per kind of evidence,
not one verdict per pair. It is not a model call, because it is quadratic in
candidates and therefore cannot be. It is not a traversal, because it computes
rather than walks. It is not an upsert, because the edges do not exist yet.

The asymmetry this creates is the point: **adding an evidence channel — a new
reason two nodes might be related — has no equivalent of the insert that adds a
kind or a relation.** A consumer that wants one has to bring a worker, which makes
"bring your own worker" the answer to a question it would be better not to raise.

What the seam should look like, at the level this document is written at:

- registered the way `aiq.upsert_graph` is, and run as an ordinary workflow step
  over a `matrix` fan-out, so a pass over an existing collection is the same
  template with a different row source;
- handed pairs and returning `(src, dst, relation, weight, provenance)` rows,
  which is the edge table's existing shape and needs no new storage;
- **one row per evidence kind, never one collapsed score.** `unique (src_id,
  dst_id, relation)` already permits this and it is the property to preserve. A
  single fused number cannot be re-fitted later, and it can hide two channels
  that mean opposite things — an earlier prototype collapsed a "these are the
  same" signal and a "these are directly related and therefore different" signal
  into one column once, and found it only after separating them again. The ground
  rule of the ingestion layer — *store a score's components and
  history rather than one mutable number* — is this, applied to identity.

Deliberately unspecified: what a channel computes, how channels are weighted, and
who decides a threshold. Those are model state, they belong to the consumer, and
a fitted weight stored on a vocabulary table has no run, fixture or version behind
it — see the decline in `graph-algorithms.md` §12 for the same argument made about
a weight column.

---

## Inclusion policy

A typed row gets a `nodes` row if and only if:

1. it is LOOKUP/FUZZY-searchable content, or
2. it is an endpoint of a soft (authored) edge.

Machine-generated data-plane rows (detections, imagery products, high-rate tracks, and similar) stay in their typed tables. They join in after identity is known. They do not sit in `nodes`, `node_keys`, or `edges`.

Rebuild and live triggers use the **same** predicate. A rebuild that uses a wider predicate resurrects evicted nodes and is a bug.

## Write path and sync

### Nodes and keys — derived, same transaction

On INSERT/UPDATE/DELETE of an included typed table:

- Statement-level trigger (`FOR EACH STATEMENT`, `REFERENCING NEW/OLD TABLE`).
- One set `INSERT … SELECT … ON CONFLICT` into `nodes` and `node_keys`.
- Delete/soft-delete removes the node; keys and incident edges follow by cascade (or one set delete).

**The UPDATE path must evict as well as insert, in both senses, or invariant 3 is broken by the projection itself.** Two evictions, both found by running an update rather than by reading the design:

1. *A row that stops satisfying the inclusion predicate keeps its node.* An insert-only projection has no statement that removes one, so a company withdrawn from the graph stayed `LOOKUP`-able and stayed a legal edge endpoint. The drift check then reported the node the projection had just failed to clean up — a detector faithfully finding a bug in the only writer it has. The eviction predicate is `not coalesce(<include_where>, false)`: three-valued logic here leaves the stale node exactly where it was.
2. *A rename adds a canonical key instead of replacing one.* The old name went on resolving forever, and the canonical-key unique index cannot catch it because that index scopes uniqueness **across** nodes, not within one. The second-order effect is worse than the stale name: the ghost key sits in the index, so the next row that legitimately takes the old name collides with a key belonging to a node nobody can see is involved. Short keys and aliases are deliberately not swept — a rename is not a reason to forget a synonym.

**Generated projection functions are named after the `entity_type`, never after the source table's short name.** `split_part(source_table, '.', 2)` is not unique: registering `s1.thing` and `s2.thing` generated one function name twice, and the second `CREATE OR REPLACE` silently rewrote the first with the other type's `entity_type` baked into its body — so rows written to `s1.thing` were projected as the other type. Identity for an entire table, wrong, with nothing raised. Two schemas holding a table of the same name is what a per-tenant or per-consumer layout looks like, not an exotic case. Relatedly, one table projects into exactly one entity type: the trigger names are fixed, so a second registration over the same table can only replace the first's triggers, and that is refused rather than done silently.

Row-level triggers are allowed only on tiny, interactive tables. They are not the default. Bulk `COPY` / `DELETE` of large included tables must not pay one projection per row.

When entity-row edge payload is gone, **entity writes do not touch `edges`**. Changing a name updates `node_keys`. It does not rebuild adjacency.

### Edges — canonical, written directly

The write API for a soft link is `INSERT INTO edges`. Resolution of names happens **once at write**. Traversal never parses names.

A small `sip_link(src_ref, relation, dst_ref)` wrapper — resolving both refs through `node_keys` and inserting the id pair — would be a convenience over that and has never been built. It is named here and in invariant 5 below as a possibility, not as a thing to reach for.

### Bulk load

Disable the projection triggers (or `session_replication_role = replica`), load typed rows, then run one set rebuild of `nodes` / `node_keys`. Authored edges load in a second set insert after nodes exist. Never project inside a long migration transaction that holds locks on the live graph.

**The rebuild is `aiq.rebuild_entity_type(p_entity_type)`, and the check that
it worked is `aiq.check_drift(p_entity_type)`.** Both are installed, both do
the job this paragraph describes, and calling them is the second half of a
two-step instruction whose first half — disabling the projection triggers — is
only safe because a rebuild follows. Skip it and you have `edges` rows whose
endpoints have no `nodes` or `node_keys` row, which you find out from
`check_drift` if you run it and from a traversal quietly returning less than it
should if you do not.

D10 argues the rebuild pass should be a **`workflow-engine` task rather than a
bespoke migration script step**, so that it inherits the claim/retry/
`task_events` machinery every other unit of background work here gets instead
of being a one-off whose failure nothing knows how to observe. That argument
still stands and nothing has been registered: `workflow.definitions` holds
`ingest_file` and nothing else. Until one exists, this is a function call — and
an earlier version of this paragraph named `start_workflow('rebuild_node_registry', ...)`
as though it were not, which is the worst of both, because the sentence telling
you to call it was the only occurrence of that name in the tree.

### Repair

Scheduled identity check, both directions:

```
included_source_rows  EXCEPT  nodes.(entity_type, entity_id)
nodes.(entity_type, entity_id)  EXCEPT  included_source_rows
```

Plus: `edges` endpoints must exist in `nodes`; `node_keys.node_id` must exist. A non-empty diff alerts. Rebuild repairs. Do not "upsert until it looks right" on the read path.

**This drift check is a `workflow-engine` scheduled task** (D10) — the same
mechanism, same reasoning, as the ingestion layer's
files/storage reconciliation job ("a reconciliation job... is part of this
system's definition of done, not an afterthought") and the agent runtime's
`tool_servers` cache-resync. Three different "is this derived state
still correct" checks, one scheduler, one retry/alerting mechanism — not
three independently-invented cron jobs.

## Read path

| Question | How |
|---|---|
| Exact / short / fuzzy "find this node" | `node_keys` → `nodes` → PK fetch on the typed table |
| "What is this attached to?" (hard) | Indexed FK or junction from the typed row. Seed by `nodes.entity_id`. |
| "What is related?" (soft, 1–2 hops) | Recursive walk on `edges` by `src_id` / `dst_id`, depth-capped, degree-capped |
| Mixed | At each hop: union **frontier-scoped** hard joins with soft `edges`. Each hard branch is an equality on the seed id. Never a catalog-wide union of all entity tables. |

Parallel query is not the LOOKUP strategy. Parallel Append of a global union is the slow form of identity. Parallelism may help analytic scans of `edges`; it is not required for point lookup or bounded hops.

## Property graphs (when the server has SQL/PGQ)

**None is declared.** `aiq.knowledge_graph` existed while the target was a PG19
beta; SQL/PGQ was withdrawn from PostgreSQL 19 before GA, and the extension now
runs on 18 with depth 1 as a plain join (`schema.sql` §5). The rules below are
what a property graph would have to obey if a server gains SQL/PGQ again.

`CREATE PROPERTY GRAPH` is catalog metadata, processed like a view. Declare:

- **Vertex table:** `nodes` (key `id`).
- **Soft edge table:** `edges` (source `src_id`, destination `dst_id`).
- **Hard edge tables:** each FK junction that should be walkable (`MATCH` by label), still stored only once in the junction.

`GRAPH_TABLE … MATCH` is then the declarative form of the mixed walk. SIPQL `TRAVERSE` / `RELEVANCE` (`ai-query-layer/brief.md` §2's REM-derived modes) may compile to it. Until then, the recursive CTE over `edges` plus the hard-join branches is the same plan — matching this repo's own confirmed result that `DEPTH n>1` falls back to `WITH RECURSIVE` (`brief.md` §3, `GRAPH "key" DEPTH n>1` row).

Property graphs do not:

- invent a global key (that is `node_keys`)
- store another adjacency copy
- make fuzzy search cheap
- replace the inclusion policy

Do not adopt a separate graph catalog (extension-native storage) that must be dual-written.

## Scale

Exact lookup is a btree on `node_keys`. That remains `O(log n)` at 10⁹ **keys**. The bound that matters is **how many rows are nodes**, not how many rows exist in the database.

- Data-plane billions stay on typed tables (brin/btree/GiST as those tables need).
- `nodes` / `node_keys` stay the curated set plus aliases.
- `edges` stay sparse: out-degree and in-degree budgets; reverse index on `dst_id`.
- Partition `nodes` / `node_keys` by `entity_type` or hash of `id` only after measured cache/bloat pain.
- Do not GIN-trigram the data plane to answer global FUZZY.

## Invariants

1. Typed tables own attributes. `nodes` owns graph identity. `node_keys` owns names. `edges` owns soft links. Junctions own hard links.
2. Every `edges` endpoint exists in `nodes`.
3. Every `nodes` row satisfies the inclusion predicate. Rebuild cannot widen it.
4. LOOKUP after a committed typed insert of an included row sees the node in that transaction.
5. Application code never writes `nodes` or `node_keys` except through the projection (or rebuild). Application code writes `edges` directly — the `sip_link` wrapper is a proposal, not a shipped function, and this invariant holds without it.
6. No read path derives identity by unioning typed tables.
7. PGQ, when present, has no writers.
8. A merge deletes no node and no key. Constituents survive; the merged node's canonical key survives as an alias carrying the resolution that moved it. A promotion (the ingestion layer's staging promotion) evicts its candidate node but keeps the name the same way, unless candidate and target are in different orgs.
9. No `node_resolutions` row is ever deleted. Unresolve sets `undone_at`; a resolution that turned out to be wrong is evidence, not garbage.

## Non-goals

- Replacing typed tables with a single property-bag vertex store.
- Materializing hard FK links into `edges`.
- Unbounded traversal, or a dense mesh without degree budgets.
- Async identity (queue/lag) for LOOKUP.
- A global `UNION ALL` view as the node catalog, even with parallel workers.

## Verification (principle-level)

A design is correct if all of these hold:

- Insert an included entity; `LOOKUP` of its canonical key in the same transaction returns it; PK hydrate returns the typed row.
- Insert an excluded data-plane row; no `nodes` / `node_keys` / `edges` row appears.
- Author an edge by two refs; walk 1 hop forward and reverse by id; inverse label is catalogue-derived, not a second stored row.
- Rename a node; keys change; existing `edges` still attach (ids did not change).
- Delete an included entity; keys go; incident soft edges go; hard junctions follow their own FK rules.
- Bulk insert with triggers off + rebuild matches live trigger projection (`EXCEPT` empty).
- `EXPLAIN` of LOOKUP is an index probe on `node_keys` plus a PK fetch. It is not an Append of typed-table scans.
- A PGQ `MATCH` on the authored relation and a CTE walk on `edges` return the same id pairs for a fixture.
- Merge two nodes, then unresolve: both canonical keys resolve again, edges written against either endpoint while merged are still traversable, and the `node_resolutions` row survives with `undone_at` set (invariants 8, 9).

**These are executed, not asserted, and executing them is what produced most of
the corrections above.** The list sat here unexecuted while the schema it
describes was in production use; `dev/tests/query/04-graph-identity.sql`,
`05-graph-traversal.sql` and `06-graph-tenancy.sql` now run every one of them
against a live PG19 instance over the committed fixture in
`dev/init/04-graph-sample.sql`, and each assertion carries the criterion or
invariant it holds up. Two of the eight passed unchanged (the PGQ/CTE
agreement, and delete cascade); the rest either failed outright or passed for
the wrong reason.

Two of them needed restating rather than just running:

- *"`EXPLAIN` of LOOKUP is an index probe"* is not assertable as written. At any
  fixture small enough to ship, the planner reads a 22-row key table
  sequentially and is right to, so an assertion on the chosen node type fails
  for a reason that has nothing to do with the design. What is size-independent
  is that the predicate is **index-servable** (checked with `enable_seqscan =
  off`) and that the plan touches **no registered source table** — which is
  invariant 6, and the thing a well-meaning rewrite of LOOKUP as a `UNION ALL`
  would actually break.
- *"Rename a node; keys change"* was passing in the sense that a new key
  appeared. Keys did not change; they accumulated. The criterion needs the word
  **replace**.

One criterion is missing from the list and belongs on it: **a walk's seed is
resolved exactly, and the result says which node it walked.** The dialect
resolved seeds fuzzily and reported neither the guess nor the node, so a typo
returned a different node's neighbourhood as a confident answer — a failure no
assertion above can see, because every one of them starts from a node id.

## Theory

Two schools describe graphs over relational data. This spec uses both, in different places.

**View school (SQL/PGQ).** ISO/IEC 9075-16:2023 defines a property graph as a read-only view: `VERTEX TABLES` and `EDGE TABLES` map existing tables via keys and foreign keys. PostgreSQL 19 implements that as a rewriter onto ordinary joins. Direct mapping (entity table → vertex, FK → edge, junction → edge not vertex) is the same rule. A foreign key is never also a stored graph row.

**Materialized-identity school.** Global untyped lookup, aliases, and links that are not foreign keys do not exist in a relational schema. Identity-graph practice materializes `identifier → canonical id` at write time. SQL Server `AS NODE` / `AS EDGE` is the same idea with a stored `$node_id`. SQL/PGQ deliberately dropped that extra identifier as an implementation tactic; it still cannot answer "find any node by this key."

**Why both.** Hard links are view-mapped (D4, D8). Soft links and names are stored (`edges`, `node_keys`). `nodes` is the vertex supertype that polymorphic `relates_to` needs: SQL/PGQ edge tables reference *one* vertex table each. Without a supertype, every pair of types would need its own edge table.

**What the literature agrees on.**

- A node is a thing with identity that is an entry point for query. A junction with no identity is an edge, not a vertex.
- Edge endpoints are ids; names are properties or a key index. Native-graph "NODE KEY = business key" is for `MERGE` in a graph store. Overlay designs use the table key (usually a surrogate) and keep names for lookup. Rename then does not rewrite edges.
- View construction, not the `MATCH` syntax, is what gives SQL/PGQ its power. Identifiers of arity 2 (an edge as a pair of node ids) are sufficient for the standard's NL bound.
- Allowed `(src_type, relation, dst_type)` triples are PG-Schema / PG-Keys.

**What this spec does not take from native graph stores.** Index-free adjacency, quantified path patterns (`*1..5`), and a separate graph catalog. PostgreSQL 19 does not have quantified paths yet. Bounded recursive joins over indexed `src_id` / `dst_id` remain the walk. Do not dual-write Apache AGE or a similar catalog.

## Sources

- ISO/IEC 9075-16:2023, SQL/PGQ. Graph as view over tables. Accessed 2026-08-31.
- PostgreSQL 19 docs, "Property Graphs." Read-only view; same planner as SQL. Accessed 2026-08-31.
- Gheerbrant, Libkin, Peterfreund, Rogova. "On the Expressiveness of Languages for Querying Property Graphs in Relational Databases." SIGMOD 2026 / arXiv:2510.07062. View construction and arity-2 identifiers. Accessed 2026-08-31.
- Angles et al. "PG-Schema: Schemas for Property Graphs." PACMMOD 2023. Types and key constraints. Accessed 2026-08-31.
- Angles, Arenas, Barceló, Hogan, Reutter, Vrgoč. "Foundations of Modern Query Languages for Graph Databases." ACM CSUR 2017. Property graph: vertices, edges, ρ : E → V×V. Accessed 2026-08-31.
- Direct mapping / R2PG-DM (Fletcher et al., TU/e). Entity→vertex, FK→edge, join table→edge. Accessed 2026-08-31.
- Graph data modeling: junction tables are edges, not nodes; node = identity + entry point. Accessed 2026-08-31.
- LDBC "SQL/PGQ data model and graph schema." Separate `$node_id` removed from the standard as an SQL Server tactic. Accessed 2026-08-31.
- Warehouse identity graphs: materialize identifier→canonical id; do not union event tables at read. Accessed 2026-08-31.

## Relation to other work

This spec is the identity and adjacency substrate. Operation-scoped graphs, feed overlays, and site reports are **consumers**: they persist membership and structure in tables, then look up nodes by id/key. They must not invent a second global union of entity types.

Within this repo: `world-model-ingestion`'s `events`/`entities`/`topics` graph is the first real consumer — its typed tables (`events`, `entities`, `topics`) are what get `nodes` rows under the inclusion policy, and "entity relates to entity" / "event mentions entity" edges are `edges` rows, not a second adjacency store. `agentic`'s `RUN.parent_run_id` delegation tree stays a **hard** link (D4) — it's a foreign key with an identity of its own already, not a candidate for the soft `edges` table.

**Machine writers get their own document, and it extends this one rather than
bending it.** The ingestion layer's graph-index design specifies how an LLM-
extracted graph enters these tables: it holds invariants 1–5 unchanged, and the
way it does so is worth knowing here, because the obvious implementation
violates two of them. An extracted node whose kind names a registered entity
type but whose name does not resolve **does not** get a typed row invented for
it, and **does not** get a hand-written `nodes` row (invariants 3 and 5); it
becomes a candidate in a generic `soft` table that is itself registered through
`register_entity_table`, so the ordinary projection gives it identity and the
ordinary eviction takes it away when entity resolution promotes it. That soft
table holds **no adjacency** — edges stay here, once — which is the property
separating it from the JSONB `kv_store` cache an earlier implementation used, which
this design declines to carry forward.

**It also generalises one thing this document left implicit, and the
generalisation is worth adopting here: identity is always in Postgres, payload
need not be.** `nodes` never stored payload — it stores `entity_type` +
`entity_id`, and lookup hydrates against the owning table's primary key — so
nothing above requires that owning table to *be* a Postgres table. A row in a
Parquet dataset (`world-model-ingestion`'s `content.datasets`, read by DuckDB)
is hydrated by a different fetch and is otherwise an ordinary vertex: same
`nodes` row, same `node_keys` btree, same `edges`, same property graph, no
union. The graph-index design calls the three possibilities *residences* — `pg`,
`lake`, `soft` — and keeps residence in a column rather than in the key, so a
dataset promoted into a table does not invalidate every name that refers to it.
The scale argument in "Scale" is unaffected: it is an argument about how many
rows are **nodes**, and it never depended on where their attributes live.

**The graph index and the semantic index are the same problem, twice
(D10).** The ingestion layer's embedding pipeline
(`resource` → chunk → embed → `resource_chunks`) and this doc's node/edge
projection are both "maintain a derived index off a primary write," and both
now resolve to the same default: a `workflow-engine` task. They differ only
where a stated requirement forces a difference — embeddings are async
because embedding generation is an external model call that structurally
can't happen inside the write transaction (`ai-query-layer/brief.md` §4);
node/node_keys projection is sync because `LOOKUP` needs same-transaction
visibility (invariant 4) and the projection itself is cheap, dependency-free
SQL with no reason to leave the transaction. Two different answers to "sync
or async," same one answer to "which mechanism does the async part" —
`workflow-engine`, every time, not a bespoke worker per index.
