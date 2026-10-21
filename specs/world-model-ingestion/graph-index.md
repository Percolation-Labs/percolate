# Graph indexing — structure extractors, and how an extracted graph lands

**Status: built, and run against a model — with two seams recorded below.**

- **Built and asserted:** `specs/world-model-ingestion/graph.sql` — the two
  reference tables, the vocabulary, the type-scoped resolver, `aiq.upsert_graph`
  and the two workflow entry points. `dev/tests/query/10-graph-index.sql` holds
  it up; `graph-demo.sql` is the worked example, two contracts landing and a
  traversal that finds one from the other.
- **Run.** §6's ingest branch is wired and has spent tokens:
  `content.install_ingest_workflow(p_graph_index => true)` installs it beside
  the embedding branch, `content.windows_to_index` is the row function §6.2
  names, and five uploaded documents produced **~90 soft nodes and ~70 extracted
  edges** (counts move between runs; a model is reading),
  every extracted edge carrying the resource, run and agent that made it.
  The measurement and the wiring live in [`ingestion.md`](ingestion.md) §1.
- **Two seams that shape how it runs, both measured, both recorded in
  `ingestion.md` §7:** the extractor is called as a `rest:` step
  (`aiq.extractor_call_at_run`) whose prompt and schema are read *from its
  agent row* — the agent stays the unit of authorship. That was written when an
  `agent:` step's route was not served; the runtime now serves
  `/v1/chat/completions`, and the branch has not been switched back. And a `matrix:` template
  accepts no `output_schema`, so a fan-out child's answer arrives as a string;
  `content.land_graph_windows` parses it and drops the edges a model
  mis-numbered or invented, counting both rather than losing them silently.
- **Still not built:** the bulk indexer's scope predicate (§6.3). Soft nodes
  are resolved outside this path, by the resolver worker
  (`core/percolate_core/resolve`) and `aiq.dream`, both writing through
  `aiq.promote_soft_node`.

**That order was deliberate and it paid.** The model half costs money and is
not where the bugs were. The database half — "given this JSON, does the right
graph appear, and does the wrong JSON get refused" — is completely testable
with a literal, and testing it found five things this document had wrong,
including a silent cross-tenant write. §11 lists them.

Everything below describes the design; where running it changed the design,
the text says so at that point rather than only in §11.

> Relationship to the other documents. `ai-query-layer/graph-identity.md` is
> authoritative on `nodes`/`node_keys`/`edges` and every invariant this one
> extends; where the two disagree, that one wins. `extraction.md` is
> authoritative on the cost argument for extraction, and §2 below is written
> against it rather than around it. `brief.md` §3.5 is the Content Server, whose
> ingestion pipeline §6 adds a step to.

---

## 0. The claim in one paragraph

A **structure extractor** is a structured-output agent — a row in
`agentic.agents`, not code. Most of them declare a *domain* schema and their
output lands in a domain table. One of them declares no domain at all, only a
graph: a list of nodes and a list of edges. That one is the **null structure
extractor**, and its output is the special case that can be handed to a **graph
upserter** rather than to a domain table. Its endpoints do not all have to be
Postgres rows: §4's three **residences** let an extracted entity resolve to a
typed table, to a **Parquet dataset in the lake**, or to nothing at all. Because the extractor is a row, the
upserter is a registered step function, and the fan-out is an ordinary `matrix`,
**graph indexing is a step any workflow can have** — the content ingestion
pipeline is the first consumer, not the only shape.

---

## 1. The family, and why the null member is the interesting one

`agentic.agents` already enforces that `category = 'extractor'` requires a
`structured_output_schema` — "an extractor without a declared shape is a model
call with extra steps." That constraint defines a family. This document names
its members:

| member | declares | output lands in |
|---|---|---|
| **typed, relational** | a domain schema: a motif slot list, a filing's fields | a Postgres domain table, via `chained_action` or a `sql` fan-in |
| **typed, tabular** | a row schema | a **Parquet dataset in object storage**, via `content.register_dataset` — the lake path, because the tabular rule in `schema.sql` is that the right home for a table is a table |
| **null** | *no domain* — only the graph shape of §2 | `aiq.edges`, with endpoints resolving into any of the three residences of §4 |

**The three compose, and the third one references the second.** A tabular
extractor that turns a file into dataset rows and a graph extractor that names
those rows as entities are the two halves of "map this file" — §4's `lake:`
scheme is what lets the graph name the lake table's output without copying it
into Postgres.

"Null" is the empty domain, not a degenerate agent. A typed extractor asserts
*what kind of document this is* and reads slots accordingly; `extraction.md`
measured that a template written for one `(source, doctype)` pair reaches 66%
typed-slot fill, and 44% when pointed at the wrong document type. The null
extractor asserts nothing about the document. It says only: here are the things
this text names, and here is how it connects them.

**That is a floor, and it is the state every source starts in.** The hundredth
source has no template on the day it is added, and a heterogeneous pile —
uploads to a channel, a crawl, someone's shared drive — never has one at all,
because there is no `(source, doctype)` pair to write one against. The null
extractor is what runs in the meantime, and it keeps running underneath a
typed extractor once one exists, because "what is this connected to" is not a
question a slot list answers.

### The cost objection, taken head on

`extraction.md`'s whole economics say: **a model's job is to author the
template, not to read the documents** — one call per source-format, amortised
over every document that source publishes, rather than one call per document.
The null extractor is one call per document. So it is precisely the shape that
argument rejects, and it needs a defence that is not "but graphs are nice."

The defence is that the argument's premise does not hold here. Template
amortisation requires a format to write a template *for*. Structural datapoint
extraction is free and works everywhere (114 datapoints, no model) because
dates and amounts have surface form; **entities and relations do not**, and
`extraction.md` measured that directly: generic motif regexes produced 4 motifs
across 32 documents and zero on the most structured source in the set. There is
no free tier for this. The choice is a per-document call or no graph.

Three consequences follow, and they are the whole cost design:

1. **The model is chosen for the floor, not the ceiling.** The task is naming
   entities and picking a relation from a closed list of about ten. That is the
   cheapest tier of model that can follow a schema, and paying more for it buys
   very little, because §5 throws away everything the model was confident about
   that does not resolve.
2. **It is off by default on the upload path** (§6). Embedding costs an
   embedding call per *chunk*; this costs a *completion* per **document**.
   Fewer calls, each far more expensive — different orders of money, and they
   must not be turned on by the same install.
3. **It is bounded per run, by construction.** `max_fanout` is mandatory
   (`workflow-engine/YAML.md`), so a bulk index over a corpus larger than the
   ceiling is *many bounded runs draining a never-indexed set*, not one
   unbounded one. §6.2 treats that as the intended operating mode rather than a
   limitation to work around.

### Documents, not chunks — and what to do when one does not fit

The unit is the **document**, not the chunk. The first draft of this section
said chunks, and argued that the node registry would stitch the pieces back
together. It does not, and cannot.

**Chunking destroys the product.** An embedding is a property of a *span*, so
chunking is exactly right for the semantic index — a chunk is the unit that gets
retrieved, so it is the unit that gets a vector. An edge is a property of a
*relationship between two mentions*, and those mentions are routinely paragraphs
apart: the subsidiary named in the header and the facility named on page four.
Split the document and that edge is not in any chunk's input, so no amount of
downstream cleverness recovers it. The registry merges endpoints that two chunks
each **named**; it never invents an edge that no chunk **stated**. Stitching
recovers identity, not adjacency — and adjacency is the whole product.

**Chunking is also more expensive,** which is what makes this an easy call
rather than a tradeoff. Input tokens are roughly the document either way, but
per-call overhead — system instructions, the schema, the vocabulary — is paid once per
*call*, so a twenty-chunk document pays it twenty times. Output multiplies too:
a company named in twelve chunks is emitted as a node twelve times, and every
copy has to be resolved and merged. One call per document is cheaper *and* more
accurate. There was never a reason to prefer chunks here except the context
window, and that reason has largely expired: a cheap model's window now holds
most documents whole, so "does it fit" is a length check rather than an
architecture.

### When it does not fit: window, and say that you did

A document past the model's window is split into **overlapping windows**, and
only then does the registry argument apply — as damage control, labelled as
such. The same key in two windows resolves to one node, so entity identity
survives the split; an edge straddling a boundary does not. Overlap buys some of
them back and is a knob with a cost, not a fix.

A resource indexed by windowing must **record that it was**. "This graph is
missing its cross-window edges" is a durable property of the resource, not a
detail of a run nobody kept, and the difference shows up the first time someone
asks why two obviously-connected things are not connected.

### The payload cap is the constraint that actually bites, and it is 64KB

Matrix rows are copied verbatim onto every child task — `chunks_to_embed`'s own
comment already warns that "a column added here is a column stored N times" — so
a row carrying a document's full text meets `workflow.max_payload_bytes`,
default `65536`. That is roughly fifteen to twenty pages, which is *most*
documents and nowhere near all of them. Three ways out, all real, and the choice
is a queue configuration rather than a change to anything in this document:

1. **Raise the cap for the indexing queue.** Simplest, and its cost is honest
   rather than hidden: the corpus is then stored a second time, in
   `workflow.tasks`, until those rows are pruned.
2. **Pass the resource id and let the extractor fetch the text**, through the
   content tool the Agent Runtime already gives an agent. One extra round trip,
   no second copy, and it is the shape that scales — this is the better answer
   for a large corpus and the one to build toward.
3. **Window it**, which the largest documents need anyway.

**What shipped differs, and the difference costs edges.** At document
granularity the per-upload case would be *one document* and a plain `agent:`
step. The installed branch is a `matrix` over the document's chunks instead
(§6.2): the window is the chunk, so the extractor reads exactly the span the
embedder embedded, and a relation stated across a chunk boundary is lost the
way §1 describes.

---

## 2. The wire shape

The null extractor's `structured_output_schema`, and therefore the step's
`output_schema`, is this:

```json
{
  "nodes": [
    {"k": "company",  "n": "Acme Corporation", "a": {"sector": "logistics"}},
    {"k": "person",   "n": "Dana Reyes",       "a": {"role": "CFO"}},
    {"k": "facility", "n": "Tilbury depot",    "a": {}},
    {"k": "lake:shipments", "n": "ABC-771",     "a": {}}
  ],
  "edges": [
    {"s": 1, "t": 0, "r": "works_for", "a": {}},
    {"s": 0, "t": 2, "r": "operates",  "a": {"since": "2019"}},
    {"s": 3, "t": 2, "r": "located_in", "a": {}}
  ]
}
```

The fourth node carries an explicit **residence scheme** (§4.2): its payload is
a row in a Parquet dataset, not in any Postgres table. Bare kinds like the first
three are the normal case and the only case a null extractor usually emits — the
scheme is there for a *typed* extractor that knows what it is mapping onto.

| field | on | is |
|---|---|---|
| `k` | node | **kind** — a claim about what this is, optionally carrying a residence scheme (`pg:`, `lake:`, `soft:`). Resolved, never trusted (§4). |
| `n` | node | the name **as the document wrote it**. Normalisation to a key happens at land time, not in the model. |
| `a` | node, edge | attributes. A free-form object, deliberately not a schema. |
| `s`, `t` | edge | **ordinals into `nodes`**, zero-based. |
| `r` | edge | relation, from the closed vocabulary of §5.3, declared in the same schema as an `enum`. |

Top-level keys are spelled out; per-item keys are one character. That split is
not aesthetic — top-level names are paid once per document and item names are
paid once per item, so the second is where the tokens are.

### Ordinals, and the one hazard they carry

**Why ordinals.** Naming endpoints by string is the dominant cost of the edge
list: a document that states eight relations about "Acme Corporation" pays that
string sixteen times. An ordinal is one token. On the example above the
ordinal form is roughly a third of the string form's edge-list cost, and this
is *output*, which is the expensive direction. The one-character item keys save
a handful of tokens per item on top — real, smaller, and free.

**The hazard, named because it is the one that will actually happen.** An
ordinal is a *positional* reference into a list. Anything that filters, dedupes,
sorts or truncates `nodes` between the model and the resolver **silently
rewires every edge** — no error, an edge from the wrong company to the wrong
person, and a graph that goes on answering confidently. The failure has no
symptom at the point it is introduced, which is the most dangerous kind of
failure.

The rule that prevents it:

> **Ordinals are resolved exactly once, inside the upserter, against the node
> list as the model emitted it.** Nothing may reorder, filter or deduplicate
> that list first. Deduplication is a deduplication of *resolved node ids*,
> after resolution — never of the emitted list.

And three smaller rules, all chosen so a mistake is loud:

- An ordinal out of range **raises**. It does not skip the edge: a dropped edge
  is a hole in a graph that still answers, which is worse than a failed run.
- A self-edge (`s = t`) is **dropped and counted in the receipt**. It is a model
  artefact ("Acme, a subsidiary of Acme"), not a wiring bug, so it should not
  fail a run — but it is reported, because dropping something silently is how
  this collection has previously reported success while losing data.
- A relation outside the vocabulary is **flipped if it is a declared inverse,
  and otherwise dropped and NAMED in the receipt**. The vocabulary stays closed
  — §5.3's argument is untouched, and the edge is still not written — but the
  refusal used to `raise`, which aborted the transaction and threw away every
  node and every valid edge the document had produced. Measured on a four-node,
  five-edge payload with one invented relation: 4 nodes and 4 good edges lost.
  An invented relation is the same species of model artefact as a self-edge and
  gets the same treatment.

  The flip is worth its own sentence, because the artefact is nearly always the
  same one. On a 159-document extraction, 8 of 1,041 edges were refused this way
  and **all eight were `owned_by` or `owned`** — the model reaching for the
  inverse of `owns`, which `relation_types.inverse_label` can express and the
  extractor's enum cannot offer. If the name is a vocabulary relation's declared
  inverse, the endpoints are swapped and the forward form is stored, which is
  the single orientation this design keeps precisely so a reader can ask either
  way. Vocabulary membership is checked first, so a term that also happens to be
  another term's inverse stays forward.

The receipt therefore carries `self_edges_dropped`, `edges_flipped_to_inverse`
and `edges_dropped_unknown_relation` — the last as the list of names, not a
count, because "3 edges dropped" sends a reader to the extractor with nothing to
look for.

### Two gates, and today only the second one is real

The step's `output_schema` check is the first gate. It covers exactly what this
shape needs — `type`, `required`, `properties`, `enum`, `items`,
`additionalProperties: false` — and a violation is **retryable**, which
`workflow-engine/YAML.md` calls the only deliberately-retryable failure in the
engine: the same prompt genuinely can conform on the next attempt, so
`max_attempts` is a budget for "ask again."

What that check cannot express is that `s` is a *valid ordinal*, because
numeric bounds are not supported and the bound depends on a sibling array's
length. So the range check is the upserter's, and the two gates have a clean
seam: **shape at the step, referential integrity at the land.**

**The first gate runs on an ordinary step, and not inside a `matrix`
template**, which rejects the key. The shipped ingest branch is a matrix, so
there the upserter's validation is the only shape gate — which makes it
**load-bearing rather than belt-and-braces**. It must therefore reject a malformed payload with a
message naming the agent that produced it, not assume a check upstream already
ran.

---

### 2.9 Two properties the wire shape does not carry, and must

Both are intent here; the mechanism is the upserter's and is deliberately not
specified in this section.

**A returned surface is a claim about the source, and is checkable.** G11 exists
because a hallucinated node is not a low-confidence node — it is a fabricated one,
and confidence scoring is the wrong instrument for it. The check is a string
search against the resource the extraction ran on, it is close to free, and it is
the reason a model's output can be landed at all. It belongs here rather than in
each consumer, because every consumer of the null extractor otherwise writes it,
and most will write it late.

Two ordering details are load-bearing. The model returns **strings, not offsets** —
an offset returned by a model is a second thing to hallucinate, and the source
already knows where the string is. And a surface that fails is **dropped and
counted**, so a vocabulary or prompt regression shows up as a rising number rather
than as silently thinner graphs.

**Not every consumer wants resolution, and the ones that do not want it are not a
special case.** §4's `soft:` prefix already lets a *kind* decline resolution, which
is the right primitive at the wrong granularity for a consumer whose entire method
is to decide identity later, in bulk, over accumulated evidence. G12 raises the
same declaration to the extractor.

The cost of getting this wrong is not symmetric, which is why it is an invariant
rather than a setting. Measured end to end on a consolidation fixture: merging nothing scores 0.605 on as-of accuracy and a tuned heuristic
0.608, while 400 eager merges score 0.215 and 700 score 0.021, with conflation
rising 1.06 → 2.77. **Resolution as an eager write-time decision is worth +0.003
and is ruinous shortly past the point where it looks like it is working.** Leaving
two nodes apart costs almost nothing; joining two wrongly costs everything, and
the fuzzy step in `graph-identity.md`'s lookup order is exactly where that happens
if it runs at write time over extracted names.

---

## 3. Routing is declared, not sniffed

A workflow names `land_graph` (or `land_graph_fanout`, §5) as its landing step,
exactly as the embedding pipeline names `land_embeddings`. There is no runtime inspection of "does this output
look like a graph."

What inspection exists runs at **definition time, and only to refuse**:
`aiq.is_graph_schema(jsonb)` returns true for the shape of §2, and wiring an
agent whose declared schema is not that into a graph-index step is refused when
the definition is written rather than discovered when the run fails. This is the
same discipline `expand_embed_steps` applies to models — resolve and refuse
early, so the failure lands on the author instead of on the operator.

---

## 4. Kind prefixes, and the three residences

`k` is a claim made by a cheap model about what kind of thing this is. Two
things can go wrong with it, and they are different problems.

The first is the one with a wrong answer available: a kind can **name a
registered entity type** — one with a real table, real attributes, a real
inclusion predicate and a PGQ-walkable vertex — and treating that claim as a
fact is how a machine writes rows into a human's table. §4.3 onwards is about
refusing to.

The second is an assumption the first draft of this document made without
noticing: **that a kind names a Postgres table or names nothing.** That is not
the world this collection is in.

### 4.1 Identity is always in Postgres. Payload need not be.

`content.datasets` registers Parquet under an object-storage prefix, read by
DuckDB, and the tabular rule in `schema.sql` is emphatic that a CSV is not prose,
chunking it is a category error, and the right home for a table is a table.
So a structure extractor mapping a file may be mapping it onto a **data lake
table**, and the entities it names may live there and in no Postgres table at
all. A design that can only resolve kinds to `entity_registry` rows would send
every one of them to the candidate pile, which is the wrong answer for entities
the deployment can already query.

The distinction that makes this cost nothing:

> **Identity is always in Postgres. Payload need not be.**

`nodes`/`node_keys` are a btree index of names — that is the entire scale
argument, and it does not work over Parquet. But `nodes` never held payload
anyway: it holds `entity_type` + `entity_id`, and `graph-identity.md` is
explicit that "lookup hydrates against that table's primary key." Making the
hydration target a dataset instead of a table changes **where a fetch goes** and
nothing whatever about identity, adjacency, the inclusion policy, or PGQ.

So a node has one of three **residences**:

| residence | payload lives in | hydrated by | registered in |
|---|---|---|---|
| `pg` | a typed Postgres table | primary-key fetch | `aiq.entity_registry` |
| `lake` | a Parquet dataset in object storage | DuckDB over `content.dataset_uri(name)` | `content.datasets` |
| `soft` | nowhere — the `attrs` on the candidate itself | nothing to fetch | — |

All three are nodes of the **same** graph, because all three have rows in
`aiq.nodes`. An edge from a `pg` company to a `lake` shipment to a `soft`
candidate is one walk over `aiq.edges`, and no union.

### 4.2 Denoting residence in the wire shape

`k` may carry an explicit scheme:

| `k` | means |
|---|---|
| `company` | **unpinned** — resolve through the cascade of §4.3 and take the first hit |
| `pg:company` | pinned: the Postgres entity type `company` — resolve there, or become a candidate |
| `lake:shipments` | pinned: a row in the dataset `shipments` |
| `soft:initiative` | pinned: do not attempt resolution, this is a candidate |

**Bare is the default, and for the null extractor it is nearly the only form.**
A cheap model reading a press release does not know where anything in this
deployment lives, and asking it to say would be asking it to hallucinate
infrastructure. The scheme exists for the case that actually needs it: a
**typed** extractor written *for* a file whose structure maps onto a known lake
table. There the target is a fact about the extractor, belongs in its prompt and
its schema, and is not a guess at all. Pinning is an authoring affordance for
typed extractors, and mostly absent from null-extractor output.

**The scheme is stripped before the key, and that is a decision rather than a
detail.** Canonical keys stay `dataset/row_key` — `shipments/ABC-771`, never
`lake:shipments/ABC-771` — because residence is a fact about *where a row
currently sits*, and a dataset promoted into Postgres (or a table demoted to
Parquet, which is the likelier direction) must not invalidate every name that
refers to it. Residence lives in a column. It does not live in the key.

### 4.3 The resolution cascade

Every emitted node takes exactly one of four outcomes, tried in this order.

**Fuzzy is off in this cascade, unlike `LOOKUP`'s**, and §11.1 is why: an
extractor is not present to judge a near-miss, and its output is durable. Exact
canonical, short and alias keys only — which makes populating aliases a real
step rather than a nicety.

#### (a) Registered Postgres kind, name resolves — use the real node

`aiq.entity_registry` has a row for `company`, and the lookup cascade
(canonical → short → fuzzy over `node_keys`, `graph-identity.md` "Lookup order")
finds exactly one node of that type. Use its id. The edge lands on the real
typed vertex; PGQ walks it as a company, because the vertex table is `aiq.nodes`
and its `entity_type` already says so. **This is the good case, and it is the
entire reason kinds are in the wire shape at all** — without `k`, every
extracted mention would be a fuzzy match against the whole key space with no
type to narrow it.

#### (b) The kind names a registered dataset — a lake reference

`content.datasets` has a row named `shipments`, so the kind resolves to the lake
residence. A reference row goes into `aiq.lake_nodes` (§4.4) keyed by
`dataset/row_key`, and the edge lands on it. The vertex is as walkable as any
other; hydrating it is a DuckDB read over `content.dataset_uri('shipments')`,
which is the same read anything else in this collection does against that
dataset.

**A lake node is created rather than resolved-or-refused, and the asymmetry with
(c) is the point.** Refusing to invent a `companies` row is right because a
Postgres entity table has an owner, an inclusion predicate, and a projection
that creating a row behind its back would bypass. `aiq.lake_nodes` has none of
those: it is a **reference** table this path owns, and writing a reference to a
Parquet row is not writing the row. Nothing is invented; a pointer is recorded.

**The pointer is not verified, and that is a known dangling-reference risk.**
Checking that `row_key` exists in the dataset means a DuckDB read from inside a
Postgres function, which this collection does not do. So a `lake_nodes` row may
point at a row that is not there — after a `mode = 'replace'` load, most
obviously. Detecting it is a reconciliation job in the same family as
`content.check_drift()`, and §9 records it rather than leaving it to be found.
What *is* checked at write is cheap and catches the common error: the **dataset**
must exist in `content.datasets`. What happens when it does not depends on who
made the claim, and running it changed the answer here. A *bare* kind that
happens to match no dataset falls through to (d) and becomes a candidate — the
model was guessing and a guess is not an error. A **pinned** `lake:` kind
naming no dataset **raises**, because pinning is an authoring affordance: the
extractor's author said where these rows live, and a candidate silently
appearing instead would hide a typo in a prompt behind a graph that looks
fine.

#### (c) Registered Postgres kind, name does not resolve — a candidate, never a company

This is the case to get right. The temptation is to create the company.

**Refused, by invariant 5:** `nodes` and `node_keys` are a projection, and
application code never writes them. Nor may the upserter write the `companies`
row and let the projection follow — it does not know that table's columns, its
tenancy rule, or its inclusion predicate, and a machine-created company nobody
approved is exactly the pollution the inclusion policy exists to prevent.

So the node lands in the soft store (§4.4) under the soft type, carrying
`claimed_kind = 'company'` **as data**. It is a candidate, not a company.
Binding it to a real company is entity resolution — `brief.md` §4's tiered
cascade, mostly not an LLM — which is a separate and later job. What the graph
indexer contributes is the claim, written down with its provenance, so that
cascade has something to resolve.

**An ambiguous resolution is a miss, not a coin flip.** A short key matching
three nodes resolves to none of them and becomes a candidate. `add_node_key`
already sets this precedent — it "refuses an ambiguous target rather than
picking one" — and the reason is the same: picking is wrong silently, and
candidates are wrong visibly.

#### (d) Unregistered kind — a candidate, no error

The model invented `initiative`, or `programme`, or `vessel`. Soft store, same
as (c), `claimed_kind` recorded verbatim. This is not an error condition: an
unregistered kind is the *normal* case for an unindexed corpus, and refusing it
would mean refusing most of what a cheap model finds. The kind vocabulary is
open. The **relation** vocabulary (§5.3) is not, and the asymmetry is
deliberate: a wrong kind is a candidate nobody promoted, a wrong relation is a
typo permanently in the catalogue.

### 4.4 The two reference tables

Two tables, one shape, one trick. Neither holds a graph; both hold *references*
that the ordinary projection turns into identity.

```
aiq.soft_nodes
  id                uuid        primary key
  claimed_kind      text        not null        -- normalized claimed kind
  key               text        not null        -- normalized name
  label             text                        -- name as first seen, for display
  attrs             jsonb       not null default '{}'
  org_id            uuid
  first_seen_at     timestamptz not null default now()
  last_seen_at      timestamptz not null default now()
  resolved_node_id  uuid        references aiq.nodes(id)
  unique (org_id, claimed_kind, key)     -- NULLS NOT DISTINCT
```

The `NULLS NOT DISTINCT` is there for the reason `node_keys` needed it and for
no other: `org_id = rbac.shared_org_id()` means shared reference data, which is the normal
state, and under the default two NULLs never conflict — so the constraint would
hold for tenants and not at all for the tier that has the most rows.

**Where a thing's kind actually lives, because there are three plausible answers
and two of them are wrong.** `claimed_kind` above is the one. The other two:

| where you would look | what you get | correct? |
|---|---|---|
| `aiq.nodes.entity_type` | `soft` | **no** — that is *residence*, never kind |
| `aiq.node_keys.kind` | `canonical` | **no** — that is the *key's class* |
| `aiq.node_keys.key` prefix | `company/` | yes, by string surgery |
| `aiq.soft_nodes.claimed_kind` | `company` | **yes** |

`aiq.nodes.entity_type` says where the row lives — `soft`, `lake`, `document`,
or a registered type — and everything the null extractor produces is `soft`
whatever it claims to be, so it separates nothing. `aiq.node_keys.kind` is
always one of `canonical` / `short` / `alias`; it is the *nearer* table, because
it is the one carrying the name you matched on, so it is the one a consumer
reaches first, and filtering entities on it returns `canonical` for every row,
filters nothing, and raises nothing. This column was called `kind` too until the
collision cost a real wrong answer — an identity pass clustered
`company/nxp semiconductors` with `product/semiconductors`, both being `soft`
and both containing the token — and renaming it to what §4.3(c) and (d) had
called it all along cut that pass's candidate pairs from 3,087 to 1,392.
(Measured by the consumer that hit it, not here.)

**And the neighbouring hazard, because it is the same sentence's job.**
`content.register_fetched` gives every document an `aiq.nodes` row with
`entity_type = 'document'`, correctly. An identity or clustering pass that does
not exclude those clusters article *titles* — producing families like
`['cerebras systems', 'cerebras systems (3)', 'cerebras systems (4)']`. Entity
resolution runs over candidates and entities; documents are neither.

**And then the move that makes the whole thing legal — it is registered as an
ordinary entity table:**

```sql
select aiq.register_entity_table(
    p_entity_type   => 'soft',
    p_source_table  => 'aiq.soft_nodes',
    p_key_expr      => 'n.claimed_kind || ''/'' || n.key',
    p_summary_expr  => 'coalesce(n.label, n.key)',
    p_org_expr      => 'n.org_id',
    p_include_where => 'n.resolved_node_id is null'
);
-- The `n.` alias is required, not stylistic: register_entity_table interpolates
-- these expressions into a trigger body whose transition table is aliased `n`,
-- so an unqualified `claimed_kind` does not resolve. Copying this without it fails at
-- registration, which is the good case -- the bad one is an expression that
-- happens to resolve to the wrong column.
```

Everything the soft tier needs then arrives for free, with no new mechanism:

- **Identity is projected, not written.** The statement-level triggers give each
  soft node its `nodes` and `node_keys` rows in the same transaction, so
  invariant 4 — `LOOKUP` after a committed insert sees the node — holds without
  a special case, and invariant 5 is not bent: application code writes a typed
  table it owns, and the projection writes `nodes`.
- **It is already walkable,** because it has a row in `aiq.nodes`. No second
  adjacency copy, and nothing added to the read path.
- **The canonical key is `kind/key`** — `company/acme`,
  `initiative/green-corridor` — which is exactly the qualified form
  `graph-identity.md` calls unambiguous. It is why one `entity_type` for the
  whole soft tier does not collapse two kinds into one identity, and why a
  candidate `company/acme` cannot collide with a real company's canonical key
  `acme` under a different `entity_type`.
- **`include_where` is the promotion path.** Setting `resolved_node_id` makes
  the row stop satisfying the inclusion predicate, and the projection's UPDATE
  eviction — the one `graph-identity.md` records as having been missing at
  first — removes the candidate node. That column write is the *last* step of
  promotion, never the only one: §4.5 is why doing it on its own destroys the
  edges the eviction was supposed to preserve.

**The lake table is the same trick pointed at object storage.**

```
aiq.lake_nodes
  id             uuid        primary key
  dataset        text        not null       -- content.datasets.name
  row_key        text        not null       -- the dataset's business key for the row
  label          text
  attrs          jsonb       not null default '{}'   -- a DISPLAY CACHE, see below
  org_id         uuid
  first_seen_at  timestamptz not null default now()
  last_seen_at   timestamptz not null default now()
  unique (org_id, dataset, row_key)      -- NULLS NOT DISTINCT
```

```sql
select aiq.register_entity_table(
    p_entity_type   => 'lake',
    p_source_table  => 'aiq.lake_nodes',
    p_key_expr      => 'n.dataset || ''/'' || n.row_key',
    p_summary_expr  => 'coalesce(n.label, n.row_key)',
    p_org_expr      => 'n.org_id'
    -- no include_where: a lake reference has no promotion path, because the
    -- row it points at is already the real thing. There is nothing to resolve
    -- it INTO, which is exactly what distinguishes it from a candidate.
);
```

**`attrs` here is a display cache, and must be treated as one.** It exists so a
graph walk can render a hundred vertices without a hundred DuckDB round trips.
It is not the row. It may be stale. **Nothing may compute on it** — the row is
in the Parquet, `content.dataset_uri()` names where, and that is the only
authority. The moment something joins or filters on `lake_nodes.attrs`, the lake
has been forked into Postgres and this table has become the copy it exists to
avoid. Same test as §4.6, different axis.

**One `entity_type` per residence, not one per dataset**, matching the soft
tier's choice and for the same two reasons: `register_entity_table` enforces one
entity type per source table, and a type per dataset would multiply §5.3's
relation-catalogue cross product by the number of datasets. The cost is real and
worth naming: **PGQ cannot filter a match by dataset**, because the vertex
properties are `aiq.nodes`' columns and `dataset` is not one of them. Narrowing
to one dataset is a join to `lake_nodes` after the walk, or a key-prefix
predicate on `node_keys` — both indexed.

### 4.5 Promotion must rewrite edges before it evicts — this is the sharp edge

The bullet above is only half true, and the missing half destroys data.

`edges.src_id`/`dst_id` are `on delete cascade`. Evicting a candidate node
therefore **deletes every edge the indexer wrote about it**, which is the entire
product. So promotion is not a column write; it is an ordered transaction, and
the order is not optional:

```
aiq.promote_soft_node(p_soft_id uuid, p_target_node_id uuid,
                      p_decided_by text, p_tier text, p_evidence jsonb default '{}')
  1. repoint  edges.src_id = target  where src_id = <candidate node>
  2. repoint  edges.dst_id = target  where dst_id = <candidate node>
       -- both ON CONFLICT (src_id, dst_id, relation): the candidate and the
       -- real node may ALREADY share an edge, and the repoint then violates
       -- the unique constraint. Merge instead of failing: union the
       -- provenance arrays, keep the GREATER weight (§11.2), and keep the
       -- fact current if EITHER row held -- valid_to NULL when either side
       -- is open, else the later end; valid_from the earlier. The
       -- candidate's row is deleted, so the merged row is the only place
       -- its currency can survive.
  3. delete   any edge left self-referential by the repoint
  4. update   soft_nodes set resolved_node_id = p_target_node_id
       -- which evicts the candidate node, whose incident edges are now zero
  5. insert   aiq.node_resolutions (canonical_id, merged_id, tier, decided_by, evidence)
       -- canonical_id = p_target_node_id, merged_id = the candidate's registry
       -- node. Same transaction, after the repoint, so a row exists only for a
       -- promotion that completed.
```

**Step 5, and why the ledger is not optional here.** `ai-query-layer/graph-identity.md`
builds `aiq.node_resolutions` on the argument that two rows turning out to be one thing
is the most consequential write the schema accepts, and that until 0.2.0 it was the only
one leaving no trace. It offers an audit in one line — *how much of this graph's identity
rests on a model's guess?* is a `GROUP BY tier`. A promotion **is** that write, and
without step 5 the audit answers for `resolve_nodes` alone, omits every
staging eviction. That is the wrong half to omit: `resolve_nodes` merges two nodes already
registered, where a promotion is what a resolver reaching into the staging area actually
calls, so the tier most worth counting is the one the audit cannot see.

`merged_id` carries no foreign key, and that decision was made for this case: the comment
on the column says a cascade "would erase the record of a merge when the merged node is
removed, which is the one event that makes the record most worth having." Promotion is
that event. The table already survives it; nothing writes to it.

**A promotion's row is a record, not a reversal point, and the two must not be confused.**
`aiq.unresolve_node` restores a `resolve_nodes` merge because that merge moved names and
left the node and its edges intact. A promotion repoints edges and evicts the candidate,
so there is nothing to restore it to. The row says a decision was made, by whom, on what
evidence. It does not make the decision undoable, and `unresolve_node` must refuse a row
whose `evidence` marks it a promotion rather than appearing to succeed.

**Signature.** Recording who decided means `promote_soft_node` has to be told. It takes
`p_decided_by text` and `p_tier text`, and neither can be given a default: a promotion with an
invented decider is worse than no row, because a reader takes it for evidence that somebody
checked.
The `worker` grant moves to the new signature.

**Step 4a: the target answers to the candidate's name.** Before eviction the candidate's
key becomes an `alias` on the target, and the ledger row lists it under `moved_keys` in
`resolve_nodes`' shape. This is `graph-identity.md` invariant 8, a merge deletes no key,
which `resolve_nodes` kept and promotion did not: the candidate's name lives in
`aiq.soft_nodes`, not `node_keys`, so eviction dropped it and the next extraction of the
same name became a new candidate, decided again. Measured on real company names: after 45
promotions, `resolve_mention` found 0 of the 45 names.

The alias is written at every tier, model decisions included. That makes a wrong model
decision durable, since the machine path trusts exact aliases, and the ledger is what
bounds it: every alias a promotion wrote is in `evidence->'moved_keys'` of a row whose
`tier` says who decided, so the model-made ones can be listed and removed together. An
alias added afterwards by `add_node_key` has no such link.

**Not across orgs.** A key is visible to whoever can see its node; its `org_id` is the
uniqueness scope, not a read gate (`node_keys_via_node`). A tenant's candidate promoted
onto a shared node would, with the alias, show the tenant's spelling to every reader of
that node. So the name moves only when candidate and target are in the same org;
otherwise the promotion goes ahead, no key is written, and `evidence->'name'` says
`{"kept": false, "why": "candidate and target are in different orgs"}`.

Step 2's conflict is not a corner case: the reason a candidate is being promoted
is usually that both it and the real node were talked about in the same corpus,
so a shared edge is the expected state, not the exception. A promotion that
fails on the constraint is an outage; one that drops the conflicting edge is
silent loss. Merging is the only correct third option.

### 4.6 This is not an earlier system's `kv_store`, and here is the test

This project explicitly does *not* carry forward an earlier system's "hand-rolled
PL/pgSQL graph traversal over a JSONB `kv_store` cache." A reader arriving at
§4.4 is entitled to think that is exactly what just got re-adopted.

It is not, and the difference is one property: **neither reference table holds
adjacency.** No edge column, no neighbour list, no cached walk. Edges live once,
in `aiq.edges`, and are traversed by the same `graph_neighbors` / `graph_walk`
path everything else uses. What was rejected was a *second copy of
the graph* walked by bespoke code; what these are, is a table of last resort for
entities with no typed table and a table of references for entities whose rows
are in Parquet — both registered through the same front door as any other.

The test is mechanical, so it can be a lint rather than a memory: **if
`aiq.soft_nodes` or `aiq.lake_nodes` ever grows a column referencing another
node, that rejection has been quietly reversed, and this paragraph
is the thing that says so.** §4.4's rule for `lake_nodes.attrs` is the same test
on the other axis: a display cache that starts being computed on has forked the
lake into Postgres.

---

## 5. The upserter

**Two entry points into one core, and the split is forced by the engine rather
than chosen:**

```
aiq.land_graph(p_graph jsonb, p_resource_id uuid) returns jsonb   -- one graph
aiq.land_graph_fanout(p_matrix_task uuid)          returns jsonb   -- many
```

The reason is a real limit worth recording, because the obvious single-function
design does not compile. A **matrix** step's result is
`{"result": {"task_id": …, "fanout": N}}`, which is why `land_embeddings` can
take a task id at all; an ordinary step's result is its payload, and **a step
has no template for its own task id.** So a single `agent:` step — which is what
§6.1's ordinary upload now is — has no task id to hand a landing function, and
must pass the graph itself:

```yaml
    sql: {function: land_graph, args: ['{{steps.graph.result}}', '{{run.resource_id}}']}
```

That works here and would not have worked for embeddings, and the difference is
size: a graph of forty nodes is a few KB and travels comfortably inside the
payload cap, where a fan-out of 1536-dimension vectors does not. `land_graph`
gets to take its data directly because its data is small.

**It is also the safer of the two**, which is worth noticing rather than
treating as luck: `land_graph` takes a payload and a resource id from its own
run's input, so there is no task id to point at somebody else's run and
therefore no guard to get right. `land_graph_fanout` does take one, and carries
the same `workflow.current_run_id` check as `land_embeddings`, for exactly the
reason that function documents — a registered step function handed an arbitrary
task id is otherwise a read of another tenant's run.

Both share the rest:

- They **refuse output that was offloaded as an artifact.** Identical reasoning
  to the embedding case: a document silently absent from the index is a hole in
  a graph that still answers questions. The remedy is named in the error — raise
  the payload cap for the queue, or window the document.
- They return a **receipt**: counts and what was written, never the rows.

### 5.1 What it does, per graph

For each `done` unit — the task itself, or each matrix child — in one pass and
in this order:

1. **Validate.** `nodes` and `edges` present and arrays; every edge's `s`/`t`
   in range; every `lake:` kind naming a real dataset. A failure raises, naming
   the agent and the task. Inside a `matrix`, where `output_schema` cannot be
   declared, this is the only gate on shape (§2).

   **An `r` outside the vocabulary is the exception, and it is not validated
   here at all** — it is handled per edge in step 4, where the name is flipped
   to its forward form if it is a declared inverse and otherwise dropped and
   reported in the receipt. §4.4 has the reason and the measurement: raising
   discarded a whole document's nodes and valid edges for one invented
   relation. This list once said "every `r` in the vocabulary" alongside the
   raise, which contradicted §4.4 and made the eval `f2g-06` in
   `dev/tests/evals/scenarios.yaml` look as if it asserted the wrong thing.
2. **Resolve each node, by ordinal position,** through §4's three outcomes,
   producing an ordinal → `nodes.id` map. This is the single point at which
   ordinals stop existing.
3. **Upsert references.** Candidates by `(org_id, kind, key)` and lake
   references by `(org_id, dataset, row_key)`, both bumping `last_seen_at` and
   deep-merging `attrs` via `content.merge_policy` (§9 records what that merge
   does and does not do), and adding this resource to the observation set.
4. **Insert edges** against the resolved ids, `on conflict (src_id, dst_id,
   relation)` merging provenance (§7).

### 5.2 Weight, and why setting it is a deliberate act

`graph_walk` scores a path as the **product of its edge weights** and orders by
that score — so weight is not decoration, and it is not storage-with-intent
either. It already changes which neighbours come back first.

Machine-extracted edges are written with a weight below the default 1.0. The
intent is exactly the arithmetic: two hops through machine edges at 0.5 score
0.25 and sort below one hop through an authored edge, which is the ordering an
analyst wants and would otherwise have to impose by hand on every query.

Because it is real behaviour, **choosing the number changes the meaning of every
existing traversal in the deployment**, which makes it a deliberate act rather
than a default to be nudged. And a re-assertion takes the **greatest** weight,
never the least: corroboration by a weaker source is not evidence against a
stronger one, and getting this backwards silently demoted authored edges
(§11.2). It is a *provenance-tier prior*, not a confidence
in the fact: it says who wrote the edge, not how true it is. Anything that
starts reading it as truth has taken `tradecraft.md`'s job without doing
`tradecraft.md`'s work.

`extraction.md` already grades one relation below the others — `causal` is
"deliberately low-confidence" — and a cheap model asserting causation deserves
that treatment more than a template does. So the tier prior is per-relation, not
one constant.

### 5.3 The relation vocabulary is closed, and closed twice

*Implementation note:* the two gates live in two tables, not one column —
`aiq.graph_vocabulary` (what an extractor may say, plus its tier prior) and
`aiq.relation_types` (what the edge table permits from anyone). §11.5 says why
the separation is worth a second table.

`aiq.edges` rejects any relation not in `aiq.relation_types`. A cheap model will
emit `works_for`, `worked_for` and `employed_by` for one thing, so without a
constraint the catalogue becomes the synonym pile `extraction.md` warns about —
"an extractor that can emit anything cannot be checked against a schema, cannot
be costed per unit, and cannot be swapped for a cheaper extractor later."

Two gates, in this order:

1. **At the model:** the vocabulary is an `enum` in the extractor's
   `structured_output_schema`. A violation is a shape violation, which is
   retryable — ask again.
2. **At the write:** `aiq.relation_types` rejects what got through. This gate
   exists because gate 1 cannot run inside a `matrix` template (§2), and it
   would stay regardless, because a hand-written edge takes the same path.

**Registering the vocabulary is a cross product, and it has a refresh
obligation.** Because the soft tier is one `entity_type` and the hard tier is N,
`aiq.register_graph_vocabulary(relations text[])` writes the triples for
`('soft' ∪ every registered entity type)² × relations`. Generated, idempotent,
re-runnable — and it **must be re-run after registering a new entity table**, or
the first edge into that new type raises the catalogue error. That error already
names the missing triple, so the message is the instruction; that is the
mitigation, and it is worth preferring over a trigger on `entity_registry`,
which would make one module's registration silently write another's catalogue.

**The starting vocabulary should be the relational subset of `extraction.md`'s
motif list, plus a small generic remainder** — so the null extractor and the
templated extractors land in one vocabulary rather than two that drift:

| relation | from | note |
|---|---|---|
| `is_a` | motif | classification |
| `part_of` | motif | composition, ownership |
| `succession` | motif | replacement over time |
| `causal` | motif | **low tier prior** (§5.2) |
| `mentions` | generic | the weakest useful edge; a co-occurrence, and named as one |
| `located_in` | generic | |
| `affiliated_with` | generic | the deliberate catch-all for "connected, unspecified" |
| `owns` | generic | |
| `supplies` | generic | |
| `party_to` | generic | |
| `binds` | generic | a clause imposing an obligation on a party |
| `contains` | generic | a document containing a part of itself |

Twelve, and generic on purpose: the null extractor runs over a corpus with no known
format, so a rich vocabulary would mostly be a menu the model picks from at
random. A source that has earned a template should use the template's motifs
instead — richer, and grounded in that source's gotchas. **The list above is a
starting point to be measured, not a measurement.** `extraction.md`'s eight
motifs came from 32 real documents; these twelve came from an argument, and the
first thing to do with them is to count which ever get used.

---

## 6. The workflow shapes

Three shapes, one land function. They differ only in what produces the graphs.

| shape | fan-out | when |
|---|---|---|
| §6.1 one upload | **none** — a single `agent:` step | the ordinary ingest pipeline |
| §6.2 one large document | `matrix` over windows | the document exceeds the model's context |
| §6.3 a collection | `matrix` over documents | the bulk indexer |

### 6.1 In the ingest pipeline — one step, off by default

`content.install_ingest_workflow` gains a `p_graph_index boolean default false`,
and installs a branch parallel to the embedding one. Because the unit is the
document, there is nothing to fan out over:

```yaml
  - id: graph
    needs: [parse]
    queue: http                   # see below -- not `agents` by default
    rate_key: structure_extraction
    agent: structure_null
    input: '{{steps.parse.result.text}}'
    output_schema: { ...the shape of §2... }

  - id: land_graph
    needs: [graph]
    sql: {function: land_graph, args: ['{{steps.graph.result}}', '{{run.resource_id}}']}
```

`embed` and `graph` both declare `needs: [parse]`, so the chunk fan-out and the
document-level extraction run concurrently over the same parse, and their
fan-ins are independent: a deployment with no embedding model can still index a
graph, and a failed graph index does not cost the vectors.

**The queue is `http`, not a queue named for the work.** An `agent:` step
compiles to an `http_call`, so it is claimed by the shipped worker like any
other, and the embed branch already routes there. Naming a `queue: agents` that
no pool polls produces a known failure — a step routed to a
queue nobody polls, which does not error, it simply never moves. A deployment
that *does* run a separate pool for completions should route here and scale that
pool; one that does not should leave this alone. `rate_key` is the separate
knob and is the one that actually matters here: model completions and embedding
calls hit different provider limits, so they must not share a key.

**Default off, and this is the one place in the pipeline where the default is
cost rather than capability.** The embedding branch installs itself whenever a
callable model exists, because an embedding call per chunk is cheap and the
whole point of an upload is to make it findable. A completion over the whole
document is a different order of money, so it is opt-in — and the install
function must say which shape it installed, as it already does for the embedding
branch, rather than leaving an operator to infer it from a bill.

**Where the text comes from is the open wiring detail,** and §1 is where it gets
decided: `{{steps.parse.result.text}}` above assumes the parse step returns the
document text inline, which meets the 64KB cap somewhere around fifteen pages.
The alternatives — raise the cap for this queue, or pass `{{run.resource_id}}`
and give the extractor a content tool — are the same three options §1 lists, and
this step's `input:` is the one line that changes between them.

### 6.2 A document that does not fit — fan out over windows

```yaml
  - id: graph
    needs: [parse]
    matrix:
      rows: {function: windows_to_index, args: ['{{run.resource_id}}']}
      max_fanout: 200
      template:
        queue: http
        rate_key: structure_extraction
        agent: structure_null
        input: '{{item.content}}'
```

The fan-in for both matrix shapes is the other entry point:

```yaml
  - id: land_graph
    needs: [graph]
    sql: {function: land_graph_fanout, args: ['{{steps.graph.result.task_id}}']}
```

`content.windows_to_index(p_resource_id uuid)` returns one row per row of
`content.resource_chunks` (`integration.sql`). **Windows are chunks**: the
extractor reads exactly the span the embedder embedded, and a window row carries
the chunk's ordinal so a landed node can be traced to the passage that named it.

That is not the design this section argued for. A chunk is sized for retrieval
(~700 tokens) and a window for a context (tens of thousands), so extracting per
chunk reintroduces the cross-chunk edge loss §1 describes. Overlapping,
context-sized windows — one row for a document that fits — remain the target,
and which shape to install is the kind of decision `install_ingest_workflow`
should make from the resource, not from a global setting.

### 6.3 The bulk indexer — a collection, not an upload

The case this document was asked for: take a collection of documents and map
their structure in one pass. Same template, same land function; only the row
source changes. Since `matrix` rows must come from a registered function rather
than an inline `SELECT`:

| function | rows |
|---|---|
| `content.windows_to_index(p_resource_id uuid)` | one document — one row per chunk |
| `content.resources_to_index(p_scope jsonb, p_limit int)` *(not built)* | a collection: a channel, a dataset, a date range, or "everything never indexed" |

Both return the same `{resource_id, window_ordinal, content}` row shape,
deliberately, so the template is byte-identical between the shapes and there is
one land function rather than several that drift.

**A backfill needs a watermark, or it re-indexes the corpus every night.**
Neither the table below nor `resources_to_index` is built.

```
aiq.graph_index_log
  resource_id     uuid  not null references content.resources(id) on delete cascade
  window_ordinal  int   not null default 0     -- 0 when the document fit
  indexed_at      timestamptz not null default now()
  agent           text  not null      -- which extractor
  vocab_version   int   not null      -- which vocabulary it could emit
  windowed        boolean not null default false
  primary key (resource_id, window_ordinal)
```

"What has never been indexed" is then an anti-join, and re-indexing after a
vocabulary change is a `delete from aiq.graph_index_log where vocab_version < n`
followed by an ordinary run — the *set* is the state, and there is no separate
"needs reindex" flag to get out of step with it. `windowed` is where §1's
"say that you did" obligation is discharged: it is the column that answers "why
is this graph missing an obvious edge."

**Bounded runs are the operating mode, not a limitation.** `max_fanout` is
mandatory, so a corpus larger than the ceiling is drained by repeated scheduled
runs against the never-indexed anti-join. That is the property that makes the
cost predictable per night, and `workflow.schedules.overlap_policy = 'skip'`
(the default) is what stops a slow run being lapped by the next tick —
`brief.md` §4 already names that as solved upstream, and this does not get its
own mechanism.

---

## 7. Provenance, corroboration, and re-indexing

**Every edge this path writes carries where it came from** — resource, window
ordinal, agent, run — in `edges.provenance`. This is not bookkeeping: it is what
makes the machine tier separable from the authored tier, and an edge with no
provenance did not come from here.

**The same edge from two documents is one row,** because edge identity is
`(src_id, dst_id, relation)`. The second insert conflicts and merges: append to
the provenance list, bump a counter.

**That counter is not a trust score, and document granularity is what makes its
unit right by construction.** `brief.md` §4 is already explicit that a
distinct-source-type count is "a weak, gameable proxy for independence" and
"monotonic where it shouldn't be." At chunk granularity the counter had to be
carefully defined to count distinct resources, because two chunks of one
document are one document said twice, not two sources. A document-level
extractor emits each edge once per document, so the natural count *is* the
distinct-resource count — one fewer thing to get wrong, and still the weak proxy
the brief warns about. Anything wanting a real answer goes to `tradecraft.md`.

**Re-indexing must not accumulate.** A resource whose text changed and is
indexed again must not leave last month's edges asserting the old text — the
same rule `land_embeddings` states for vectors ("must not leave the old vector
ranking against the new text").

Here it costs more than an `ON CONFLICT`, and the reason is edge identity: an
edge asserted by resources A and B is **one row with two provenances**, so
"withdraw what A said" is a refcount, not a delete. Retracting a resource's
contribution means removing it from the edge's provenance list and deleting the
row **only when the list empties**. That is the price of `(src, dst, relation)`
being the key, and it is worth paying — the alternative, an edge row per
assertion, makes every traversal deduplicate.

**Windowed resources retract as a unit.** A document indexed in six windows
wrote six graphs, and re-indexing it retracts all six — the provenance key for
retraction is the `resource_id`, not the `(resource_id, window_ordinal)` pair,
because a re-window with different boundaries would otherwise strand the old
windows' edges with no run that will ever withdraw them.

---

## 8. Invariants

Extending `graph-identity.md`'s list, which continues to hold in full.

| # | Invariant |
|---|---|
| **G1** | Neither reference table holds adjacency. Edges live once, in `aiq.edges`. A neighbour column on `soft_nodes` or `lake_nodes` reverses a rejected design (§4.6). |
| **G2** | An extracted node never creates a Postgres typed row. It resolves to one, records a lake reference, or becomes a candidate. |
| **G3** | Identity is always in Postgres, whatever the residence. A lake node stores a reference and a display cache, never the row. |
| **G4** | Residence lives in a column, never in the key. `dataset/row_key`, not `lake:dataset/row_key`. |
| **G5** | Ordinals are resolved exactly once, in the upserter, from the list as emitted. Nothing reorders, filters or dedupes that list first. |
| **G6** | A relation outside the vocabulary is refused at the model and refused again at the catalogue — dropped and named, or flipped when it is a declared inverse, never written and never taking the document with it. |
| **G7** | Promotion rewrites incident edges — merging on conflict — *before* it evicts the candidate. |
| **G8** | Every edge written by this path carries its resource, window ordinal, agent and run. |
| **G9** | The unit of extraction is the document. Windows are a fallback that must record that they were used. *Not yet: the shipped branch extracts per chunk (§6.2).* |
| **G10** | Graph indexing is opt-in on the upload path, and bounded per run everywhere. |
| **G11** | Every surface an extractor returns must reproduce **character-for-character** from the source resource. The extractor supplies the string; the offset is found by searching the source and is never taken from the model. A surface that will not reproduce is dropped and counted, never stored at low confidence. *Not built.* |
| **G12** | An extractor may declare that it **resolves nothing**: every node it returns lands as a candidate, whatever its kind. The declaration is a property of the extractor, not of each kind, so a kind arriving for the first time cannot silently take the resolving path. *Not built.* |

---

## 9. What this does not do

Recorded here rather than left to be discovered, in the order they will bite.

- **No entity resolution in the upserter.** Candidates accumulate under `soft`.
  Promoting them is `brief.md` §4's tiered cascade — canonical registry,
  crosswalk, embedding similarity, LLM last — and runs outside this path:
  `aiq.resolution_candidates`, the resolver worker (`core/percolate_core/resolve`),
  `aiq.dream` and judgements, all writing through `aiq.promote_soft_node` or
  `aiq.record_distinct`. A deployment that indexes
  and never resolves gets a large candidate pile, and that pile *is* the visible
  symptom, which is the intended failure mode: a graph that quietly guessed
  would have no symptom at all.
- **Extracted dates are not validity.** Every traversal now applies
  `valid_from`/`valid_to` through `aiq.edge_is_current` (`graph-identity.md`,
  "Temporal validity"), which makes the older warning here *more* binding
  rather than less: an extracted `{"since": "2019"}` goes in `a`, not in
  `valid_from`. `valid_from` means "when this system was told", the instant a
  retraction is dated against and an as-of read resolves against; a date lifted
  out of a sentence is a claim about the world, from a source that may be
  wrong. Putting one in `valid_from` now silently removes the edge from every
  answer about any earlier instant.
- **Attribute conflicts are not merged, they are overwritten.**
  `content.merge_policy` is reused rather than a second deep-merge being
  written, and what it does is last-write-wins per leaf. Two documents giving
  Dana Reyes different roles is not a merge problem, it is a **disagreement**,
  and recording it as one belongs with `tradecraft.md`'s grading rather than in
  an upserter. Today the later document wins and the disagreement is lost.
- **Cross-window relations are not recovered** (§1). This applies only to
  documents large enough to window; at the default document granularity there is
  no boundary to lose an edge across, which is the main reason §1 chose it.
  Identity stitches endpoints; it does not infer an edge no window stated.
- **Nothing chooses between §6.1 and §6.2 automatically.** Whether a resource
  fits the model's context is a property of the resource, and
  `install_ingest_workflow` installs one shape for the whole channel. Always
  installing the windowing shape is the safe default — `windows_to_index`
  returns a single row for a document that fits — and the cost is one extra
  task per upload.
- **A lake reference is not verified at write** (§4.3b). The dataset must exist;
  the `row_key` is taken on trust, because checking it means a DuckDB read from
  inside a Postgres function. A `mode = 'replace'` load is the case that
  strands them. Detecting stranded references is a reconciliation job in the
  same family as `content.check_drift()`, and it does not exist.
- **`lake_nodes.attrs` goes stale and nothing refreshes it.** It is a display
  cache over Parquet that changes underneath it. Rendering from a stale cache is
  the accepted cost; computing on one is the failure §4.4 forbids, and there is
  currently no assertion that would catch someone doing it.
- **The kind vocabulary is open and unnormalised.** `company`, `corporation` and
  `firm` are three kinds and therefore three candidates. A normalisation table
  is the obvious fix and is deliberately not specified until there are counts to
  build it from.
- **The relation table in §5.3 is an argument, not a measurement**, unlike
  `extraction.md`'s eight motifs. The first operational task after this ships is
  to count which relations are ever emitted and which are never resolved.

---

## 10. Verification (principle-level)

What a test suite has to assert. Written before anything ran, so the claims
above were falsifiable rather than decorative; **most are now asserted** — see
the numbered blocks in `dev/tests/query/10-graph-index.sql`, which do not map
one-to-one onto this list — and finding out which ones failed is where §11 came
from.

1. A node whose kind names a registered type and whose name resolves produces an
   edge incident on the **typed** node id, and `graph_neighbors` returns that
   edge with the typed `entity_type`.
2. A node whose kind names a registered type and whose name does **not** resolve
   creates **no** row in that typed table, and one candidate carrying
   `claimed_kind`.
3. A name matching three short keys creates a candidate, not an edge to one of
   the three.
4. An emitted node list that is reordered before landing changes which edges are
   written — asserted as a **negative**: the upserter given the same payload
   twice, once reordered, must produce two different graphs, proving G5 is a
   real constraint and not a comment.
5. An out-of-range ordinal raises; a self-edge does not, and appears in the
   receipt's dropped count. Nor does an out-of-vocabulary relation: it is
   flipped when it names a declared inverse and named in the receipt when it
   does not, and the rest of the document lands either way.
6. Promoting a candidate that shares an edge with its target leaves **one**
   merged edge whose provenance contains both, and zero edges pointing at the
   evicted candidate. When the target's copy was retracted and the candidate's
   still held, the merged edge is in `aiq.edges_current` at the greater of the
   two weights; and an authored target edge with no `sources` key keeps its
   provenance and gains the candidate's source.
7. Re-indexing a resource whose text changed leaves no edge asserted only by
   that resource's previous generation, and leaves untouched an edge another
   resource also asserts. A resource re-indexed with *different window
   boundaries* strands nothing from the old boundaries.
8. A relation outside the vocabulary is never written. `aiq.upsert_graph`
   refuses it before the catalogue sees it — recovering it if it names a
   declared `inverse_label`, and otherwise naming it in the receipt rather than
   raising — and `aiq.relation_types` refuses an unlisted TRIPLE at write with a
   message naming it, which is the gate a direct `INSERT INTO edges` meets.
9. A registered entity table added after `register_graph_vocabulary` causes the
   next edge into that type to fail with the catalogue error — pinning the
   refresh obligation of §5.3 as a known, message-guided failure rather than a
   surprise.
10. `land_graph_fanout` called with a task id from another run raises, exactly
    as `land_embeddings` does — and `land_graph`, which takes no task id, has no
    such surface to test, which is §5's point about the split.
11. A `lake:` kind naming a dataset that exists creates a `lake_nodes` row whose
    canonical key is `dataset/row_key` with **no scheme in it** (G4), and the
    edge is returned by an ordinary `graph_neighbors` call alongside `pg` and
    `soft` endpoints — one walk, no union.
12. A **bare** kind matching no dataset and no entity type becomes a candidate
    rather than a dangling reference; a **pinned** `lake:` kind naming no
    dataset raises, and the message names the dataset it wanted.
13. A tenant's document naming another tenant's private entity resolves to
    **nothing** and becomes a candidate in the asking tenant's own scope — while
    shared reference data (`org_id = rbac.shared_org_id()`) still resolves for that tenant, so
    the fix has not overshot into making every public company unresolvable.
14. Neither reference table has a column referencing another node — the
    mechanical form of "this is not an earlier system's `kv_store`" (§4.6), checked against
    `information_schema` so it is a lint rather than a memory.
15. A document that fits the model's context is indexed by **one** call, and
    `graph_index_log.windowed` is false; a document that does not is windowed
    and `windowed` is true. The second assertion is the one that matters — it is
    how "why is this graph missing an edge" stays answerable.

---

## 11. What running it changed

Five corrections, all found by executing the design rather than reading it.
Listed with the assertion that now pins each one, so removing a fix fails a
test rather than quietly restoring the bug.

### 11.1 Fuzzy resolution is OFF for machine writers

The cascade ends in fuzzy (`graph-identity.md` "Lookup order"), so the first
implementation used the whole cascade. Measured on the fixture: an extracted
"Northgate Freight Ltd" bound itself to the existing "Northgate Freight", no
candidate was created, and an assertion about a company nobody had heard of
landed on a real company's vertex with nothing raised.

That is the failure this document refuses everywhere else — *picking is wrong
silently, a candidate is wrong visibly* — and the reason the cascade is right
for `LOOKUP` and wrong here is presence: a human typing a query is there to
judge a fuzzy hit, and an extractor is not, while its output is durable. So the
machine path resolves on **exact canonical, short and alias keys only**, and
fuzzy is a per-call opt-in.

The consequence is that **populating aliases becomes a real step**, not a
nicety — which the demo now shows rather than assumes: `demo.companies`
registers its canonical key as `coalesce(ticker, name)`, so Acme Robotics'
canonical key is `acme`, and without three `add_node_key` calls every company
in the extracted graph lands as a candidate and the demo's whole point does not
happen.

### 11.2 Weight is the best tier that asserted an edge, not the last

The first version merged a re-assertion with `least(existing, new)`, on the
reasoning that a tier prior may only demote. Run against an authored edge, that
quietly took an analyst's `1.0` down to the machine prior of `0.6` — and since
`graph_walk` scores a path as the product of its weights, it reordered every
traversal through that edge. **Corroboration by a weaker source is not evidence
against a stronger one.** It is `greatest`. (`10-graph-index.sql` block 11.)

### 11.3 The provenance merge erased provenance it did not write

`jsonb_set(existing, '{sources}', existing->'sources' || new)` is the obvious
spelling and it is a **total erase** on any edge this path did not create: an
authored edge has no `sources` key, so `existing->'sources'` is NULL,
`NULL || jsonb` is NULL, and `jsonb_set` returns NULL — the whole provenance
column, including whatever the analyst put there. The `NOT NULL` constraint on
`edges.provenance` caught it, by luck; on a nullable column it would have been
silent data loss on the most ordinary event there is, a machine agreeing with a
human.

This is the same shape as `agentic.upsert_agent`'s `excluded`-column bug —
*a partial write that reports success* — a known class of failure. The fix is `||` on the object with `coalesce` on
the array, so unrelated keys survive.

### 11.4 Resolution inside a SECURITY DEFINER writer is not RLS-filtered

Found by `dev/tests/query/06-graph-tenancy.sql` §5, which refuses any `aiq`
definer function reachable by a user. The surface bug was the grant — Postgres
grants `EXECUTE` to `PUBLIC` by default, so "granted to worker" was an
*addition* to an access every role already had, and a `revoke ... from public`
was missing.

The bug underneath it was worse. `aiq.upsert_graph` is `SECURITY DEFINER`
because it writes tables the worker holds no grants on, and **a function called
from inside a definer runs as the definer** — so name resolution in the write
path was not tenant-filtered at all. Tenant A uploading a document that merely
*named* tenant B's private company would have resolved to it and hung a real
edge on B's vertex, from a process handling A's upload.

The fix is an **explicit `p_org_id` argument** rather than reliance on ambient
RLS, because ambient RLS is exactly what is absent there: resolution admits
the shared reference tier (`rbac.shared_org_id()`) and the caller's own org, nothing
else. `aiq.resolve_ref` is additionally `SECURITY INVOKER` so a user calling it
directly is filtered by their own policies too. (§10 assertion 13.)

### 11.5 Two vocabularies, not one column

`aiq.relation_types` is the catalogue: what the edge table permits from *any*
writer, authored edges included. `aiq.graph_vocabulary` is what an extractor
may *say*, plus its tier prior. Keeping them separate means a relation an
analyst may author by hand does not thereby become one a cheap model may
invent; registering the vocabulary writes both, so they cannot disagree.

The cross product is real: 12 relations over (registered types + `soft` +
`lake`) generated 430 catalogue triples on the dev database and 108 on a stock
install. Both are generated data, and re-running after registering a new entity
table is the refresh obligation §5.3 names.

### Smaller things running it settled

- **A pinned residence is refused when it misses; a bare one is not.** The
  design had both falling through to a candidate. That is right for a bare
  kind and wrong for `lake:shipments`, which only a typed extractor's author
  writes: for them a miss is a typo, and turning it into a candidate would
  leave a plausible-looking graph pointing at nothing anyone named.
- **Edge attributes ride inside the provenance source entry**, not in a column.
  `{"since": "2019"}` is something a *particular document asserted*, and two
  documents may disagree; a column would have to pick one. The cost is that
  querying an edge attribute means digging into `provenance->'sources'`, which
  is honest about what the value is.
- **The demo must roll back.** The first version committed, and broke
  `06-graph-tenancy.sql` — whose assertion "a walk from NWND returns nothing"
  is true only of the untouched fixture. A demonstration that mutates the
  fixture other tests assert against is a demonstration that breaks the build.
- **The default vocabulary ships as data.** A deployment with an empty
  vocabulary cannot land a single edge, and fails with a catalogue error rather
  than "nobody registered a vocabulary". The *agent* is not installed — which
  model to point it at is a deployment's decision — and is one
  `select aiq.install_structure_null()` away, the same shape as
  `content.install_ingest_workflow()`.
