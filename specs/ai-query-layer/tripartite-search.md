# Tripartite search: one search over any store, through shared tags, claims and questions (REM-1144)

**Status: specified, not built.** Two decisions in §4 belong to Sirsh. Nothing in
this document adds a table until he answers them.

Sirsh's rule (board, 23 Oct 2026, M-20261023-065931-9b72, M-20261023-070116-3647):

- one generic resources table, plus the app's own store tables for brews and for
  long-form pieces;
- exactly **one** tags table, **one** claims table and **one** questions table,
  with their link tables, shared by every store;
- a search scoped to one store or run over all of them, always through those
  shared tables;
- no new entity or table without checking with Sirsh first.

The search itself comes from the LongMemEval experiment's Phase A (REM-1076):
search documents, tags and questions together,
expand each tag or question hit one hop to the documents linked to it, and return
one ranked list of leads.

---

## 1. Where things live today (origin/main, 23 Oct; extension 0.2.30)

Read from `origin/main` of this repository (P), the Percolate application (A; its
`hub_app` DDL is in its deploy catalog, written C) and percolate-core (K).
Cross-checked by a second session (cory) from the REM-1088 audit.

### Stores

| Store | Tables | Text | Embeddings |
|---|---|---|---|
| Generic resources | `content.resources` (P `world-model-ingestion/schema.sql:141`), `content.resource_chunks` (:216) | `resource_chunks.content` | `aiq.emb_<model>` keyed by chunk id; registered as lexical and semantic source `chunks` (`integration.sql:20-23`) |
| Brews | `research.works` (P `research-platform/schema.sql:54`), `research.revisions` (:67) | `revisions.document` jsonb | none on the row |
| Long-form pieces | `hub_app.long_drafts` (C:915), `hub_app.long_draft_versions` (C:925) | `blocks` jsonb | none |

Published brew text is also copied into `content.resources` through
`content.register_text` (A `api/percolate_application/search_index.py`), so the
marketplace's semantic arm reads brews as resources.

### Tags

**No tags or topics table exists in any of the three repos.** The nearest things
are columns: `hub_app.board_items.tags text[]` (C:487, board ideas, not
documents), `hub_app.air_questions.topic` (C:1277), `agentic.agents.tags` and
`agentic.skills.tags`, and a package's `topic` string inside
`research.revisions.document`. `content.resources` and `hub_app.long_drafts`
carry no tags at all.

### Claims

| Table | Role |
|---|---|
| `claims.claims` (P `claims/schema.sql:44`) | identity of a claim across works |
| `research.claims` (P `research-platform/schema.sql:147`) | a claim's text as it occurs in one brew revision |
| `claims.expresses` (:59) | links an occurrence to its `claims.claims` id |

`claims.claims` plus `research.claims` is one claims layer (identity plus
occurrence). They are not a duplicate. Every write goes through a core function.

### Questions

| Table | Role |
|---|---|
| `claims.questions` (P `claims/schema.sql:809`) | the question store; semantic source `questions` (:1206); `claims.find_question` (:1246) searches it by vector |
| `claims.answered` (:840) | a claim's stance on a question, with its evidence revision |
| `claims.bears_on` (:1428) | links an `aiq.edges` fact to a question |

### Link tables between documents and the three layers

- **Brews are linked.** A brew revision reaches claims through `research.claims`
  and `claims.expresses`, and reaches questions through `claims.answered`.
- **Generic resources are not.** No table links `content.resources` or its
  chunks to a claim, a question or a tag.
- **Long-form pieces are not either.** `hub_app.long_draft_origins` (C:942) names
  brews, claims and questions by text `ref_id`, with no FK.

### Duplicates of the one-table rule

| Layer | Parallel tables | Status |
|---|---|---|
| Claims | `hub_app.opinion_claims` (C:1310, public-figure claims for the opinions map) and `hub_app.graph_nodes` with kind = claim (C:570, essay-graph canvas) | each a second store of claim text |
| Questions | `hub_app.air_questions` (C:1271), `hub_app.graph_nodes` with kind = question, and `hub_app.board_items` | `air_questions` is a second question store. The `question_*` sidecars (C:1387-1416) are bookkeeping keyed by `claims.questions` ids, not a second store. |
| Tags | none to duplicate | scattered across the columns listed above |

Experiment and fixture tables, not product: `demo.*`, `calder.*` and `journey.*`
(dev seeds and test fixtures). `aiq.*` is product.

### Search today

| Search | What it reads |
|---|---|
| `aiq.search` (P `ai-query-layer/schema.sql:4101`) | RRF of the lexical and semantic halves of **one** registered source |
| `aiq.query` (:2186) | p8ql: LOOKUP, FUZZY, SEMANTIC, GRAPH (walks `aiq.edges` only), SEARCH, SQL |
| `research.search_claims`, `research.search_sources` | lexical |
| `claims.find_question` | vector |
| App `search_research` (A `mcp_server.py:683` → `library_search.py`) | an in-memory SQLite FTS5 index over the caller's packages and pieces, with no database index and no embeddings |
| App `search_marketplace` (A `marketplace_search.py:254`) | words plus `aiq.semantic_in('chunks', ...)` |

**No search fans out over documents, claims, tags and questions in parallel, and
none expands a hit one hop to connected documents.** Each queries its primary
store. The dev init registers `text-embedding-3-small` (1536 dimensions); no
production registration is in the repos.

### LongMemEval

LongMemEval is in no table. The experiment keeps sessions, tags, links and
embeddings as JSONL and `.npy` files under the spike directory. To meet the rule,
it moves into Percolate (§5).

---

## 2. The search

One function, `aiq.tripartite_search` (name provisional), invoker-rights like
`aiq.search`, so every arm sees only what the caller may read
(`research.revision_readable`, `rbac.may_read`).

```
aiq.tripartite_search(
    p_query    text,
    p_vector   vector,              -- the query embedded once, by the caller's model
    p_stores   text[] default null, -- 'resources', 'brews', 'long_form'; null = all
    p_budget   int    default 20,   -- leads returned
    p_subqueries text[] default null
) returns table(
    lead_kind   text,   -- 'resource' | 'brew' | 'long_form'
    lead_id     text,   -- chunk id, revision id or ld- id
    score       real,
    path        jsonb   -- how it was reached: [] for a direct hit, else
                        -- [{"via":"question","id":...,"sim":...},{"link":...,"p":...}]
)
```

### Steps

1. **Fan out in parallel**, for the query and each subquery:
   - **D, documents:** `aiq.search` over each selected store's registered source;
   - **C, claims and tags:** semantic and lexical search over the claim layer and
     the tag layer (§4.1);
   - **G, questions:** `claims.find_question`.
2. **Expand one hop.** Each C or G hit becomes the documents linked to it, kept
   only when they are in the selected stores and readable. Each lead is scored by
   the hit's similarity times the link's strength (a link's P where one is
   stored, otherwise 1).
3. **Merge** D, expanded C and expanded G into one list by reciprocal-rank fusion
   (k = 60). Each lead keeps the best path that reached it.
4. **Cut at the budget**, and return the leads with their paths, so a caller can
   see why a lead was offered and go on from it.

Subquery decomposition is optional and the caller's job in v1; the function only
fans each one out.

### What this does not do

- It does not rank a question's answers. Answers are read through
  `claims.answers()`, which orders by `claims.authoritative()` (REM-1115).
- It does not decide when a search is finished. A caller reads the leads under
  its own budget.

---

## 3. Measurement before build-out

Sirsh: "Don't build on it until this is measured." This is the first acceptance
test, and Phase A's frozen protocol (REM-1076) is its template.

- **Questions:** LongMemEval held-out questions (never used to set anything),
  first on M (about 500 sessions per question). On S (about 50 sessions),
  measured 23 Oct, every arm collects every source in three to four reads, so S
  cannot separate the arms.
- **Arms:** primary store only (documents: BM25, embeddings, and their fusion)
  against tripartite (documents plus expanded tags and questions).
- **Metrics:** recall at the read budget; **reads to full evidence**, which is the
  rank of the last labelled session (Sirsh's Phase B metric and its baseline);
  latency per query; and cost per query and per ingested document.

The S result already constrains the design: tags picked by embedding similarity
to a topic name **hurt** (3.67 reads against 3.23 for embeddings alone, worse on
13 of 39 held-out questions), while the question layer was neutral (3.10). On M,
the tag hop uses tags chosen by Jev's scores, not by wording.

---

## 4. Decisions for Sirsh

### 4.1 Where tags live

No tags table exists, and the rule says exactly one. Options:

- **(a) A new `claims.tags` table** (path, label, taxonomy version) **plus one
  link table** (document ↔ tag, with P). This is two new tables, so it needs
  Sirsh's yes.
- **(b) Tags as typed nodes in `aiq.nodes`, linked by `aiq.edges`.** No new
  table. But `aiq.edges` is the remembered-facts graph, so a tag would share it
  with facts, and the question side still needs a link (4.2).
- **(c) Tags as `claims.questions` rows of a "topic" kind.** No new table, but a
  topic is not a question, and it blurs the dual.

**Recommendation: (a).** A tag has its own identity and taxonomy version, and the
rule names a tags table. It is the only option that adds tables, which is why it
is Sirsh's call.

### 4.2 How a generic resource links to a question or a claim

`claims.answered` links a claim to a question with evidence in a brew revision.
No table links a resource to a question or a claim. Options:

- **(a) Widen the evidence of `claims.answered`** to allow a resource as well as a
  revision. That is a column change, not a table.
- **(b) A link table** (resource ↔ question, with P), the questions dual of
  4.1(a)'s tag link.

**Recommendation:** (b) if 4.1 is (a), so both links have one shape; otherwise
(a).

### 4.3 The duplicates

Fold or keep: `hub_app.air_questions` into `claims.questions`;
`hub_app.opinion_claims` and essay-graph claim and question nodes into the core
layers. Not needed for the search's first version. Listed so the rule's breaches
are on record.

---

## 5. LongMemEval through it

Once 4.1 and 4.2 are answered:

- sessions go into `content.resources` and `content.resource_chunks` through the
  normal ingest (`content.register_text`);
- Jev topic scores go into the tags layer;
- Jev question links go into the questions layer;
- the seeded questions go into `claims.questions`.

The experiment then calls `aiq.tripartite_search` instead of its own files. The
first run must reproduce the S numbers in §3 before any M result counts.

## 6. Done when

- [ ] The table names above are confirmed (this document) and the duplicates are
      on record (§4.3).
- [ ] Sirsh has answered 4.1 and 4.2.
- [ ] `aiq.tripartite_search` works over each store and over all of them, with a
      test that a private revision's claims cannot reach a lead.
- [ ] LongMemEval is ingested through it and reproduces the S Phase A numbers.
- [ ] Tripartite search is measured against primary-store-only search on held-out
      M questions: recall at budget, reads to full evidence, latency and cost.
