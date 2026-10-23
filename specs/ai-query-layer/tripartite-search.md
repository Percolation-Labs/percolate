# Tripartite search: one search over any store, through shared tags, claims and questions (REM-1144)

**Status: built for the resources store** (`specs/claims/tags.sql`). Sirsh decided §4 on
23 Oct 2026. Brews and long-form pieces take the same links next.

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

`claims.search_leads` (`specs/claims/tags.sql`) is invoker-rights like `aiq.search`,
so every arm reads only what the caller may read.

```
claims.search_leads(
    p_query text, p_vector vector, p_model text,
    p_scope       jsonb  default null,    -- a memory's agent and run, as aiq.search narrows
    p_layers      text[] default '{documents,tags,questions}',
    p_documents   text   default 'semantic',   -- or 'lexical', 'hybrid'
    p_budget      int    default 20,
    p_k_tags      int    default 3,       -- tags whose label words the query uses, when the caller chose none
    p_k_questions int    default 5,
    p_min_p       real   default 0.5,     -- a link counts at this probability or above
    p_tags        jsonb  default null,    -- [{"id","w"}]: tags the caller chose (a decision model, a person)
    p_questions   jsonb  default null,    -- the same for questions
    p_stores      text[] default '{resources}'
) returns table(resource_id uuid, score real, rank int,
                document_rank int, tag_rank int, question_rank int, path jsonb)
```

A link with no `p` (a person's, or a rule's) counts as certain. The documents arm ranks
at most the 5,000 nearest chunks, which bounds an unscoped search, not a memory's.

Primary-store-only search is the same call with `p_layers => '{documents}'`. That
makes the comparison in §3 one function with two arguments, not two code paths.

### Steps

1. **Fan out in parallel**, for the query and each subquery:
   - **D, documents:** `aiq.search` over each selected store's registered source;
   - **C, claims and tags:** semantic and lexical search over the claim layer and
     the tag layer (§4);
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

## 3. Measurement (run 23 Oct 2026, REM-1144)

LongMemEval-M pooled into one corpus: 49,018 distinct sessions behind 500 questions,
loaded through `content.register_text`, with stored Jev topic scores as tag links.
Each corpus size is a fresh database, searched with `claims.search_leads`. The test set
is 428 questions outside the development pilot. Recall is the share of a question's
evidence sessions in the first 10 leads:

| corpus | documents (embeddings) | documents (hybrid) | low-overlap, embeddings |
|---|---|---|---|
| 1,859 | 0.710 | 0.735 | 0.337 |
| 5,859 | 0.556 | 0.625 | 0.161 |
| 20,859 | 0.396 | 0.456 | 0.057 |
| 49,018 | 0.297 | 0.360 | 0.024 |

The low-overlap slice is 53 questions whose evidence shares the fewest words and the
least vector similarity with the question.

**Direct search degrades with corpus size,** which is the case the graph exists for.

**At 20,859 sessions the graph does not yet beat it:**

| tag and question arm | recall@10 |
|---|---|
| tags chosen by the query's words | 0.29 (on 214 tagged questions) |
| tags chosen by Jev | 0.27 |
| question links from a query-time Jev check of the candidates | 0.23 to 0.28 |

Why:
- **Tags give reach, not precision.** The Jev-tag hop finds evidence that documents'
  top 20 miss for 11 of the 53 low-overlap questions. But a tag links tens to hundreds
  of sessions, and fusing it as its own RRF list displaces good document hits.
- **Generic seeded duals cannot rank within a topic.** Even used only to re-rank
  candidates holding 53% of the evidence, they place it below plain embeddings.

The design consequences for this function:
1. **Hybrid is the documents arm to beat.**
2. **Tags belong in candidate generation.** They do not belong as an equal-weight list
   in the fusion.
3. **The question layer needs duals specific enough to discriminate.** That is
   dreaming's job, and reads to full evidence against these curves is its metric.

## 4. The schema (decided by Sirsh, 23 Oct 2026)

Sirsh: one new `claims.tags` table, with different sources and hierarchies, and with
optional dual questions that are updated and trained over time. Claims, questions and
tags link to resources canonically. Brews and long-form pieces use the same pattern.

| Table | What it holds |
|---|---|
| `claims.tags` | a taxonomy node: `source` (iab, schema.org, a person's own), `source_version`, `key`, `label`, `path`, `parent_id`. The parent is in the same source and version, enforced by a composite foreign key. A tag is a word, not a sentence, so it is never embedded: it is a lexical source over its label (not its path, whose parent words would match every child). |
| `claims.tag_questions` | a tag's dual questions in `claims.questions`, each with a `weight`, an `origin` (seed, trained, person) and a `retired_at`. Training moves these rows and never the tags. |
| `claims.resource_links` | a resource linked to exactly one tag, question or claim (each a real foreign key, one per row), with the decider's `p` and the decider's name |

Claims and questions are sentences and carry vectors (the `embed_sources` workflow);
tags carry none. `claims.put_taxonomy` queues embedding for the seeded questions it
mints, and it refuses a parent chain that forms a cycle. Every write carries a `claims.tx`. `claims.put_taxonomy` installs a taxonomy with its
seeded duals; it is operator-only, since a taxonomy is shared vocabulary.
`claims.train_dual` moves one dual. `claims.link_resources` writes a decider's links
from resources the caller may write.

Reading: tags and duals are readable by anyone signed in. A link is readable when its
resource is. `claims.question_readable` now also admits a tag's live dual, and a question
that a resource the caller may read links to.

### 4.3 The duplicates

Fold or keep: `hub_app.air_questions` into `claims.questions`;
`hub_app.opinion_claims` and essay-graph claim and question nodes into the core
layers. Not needed for the search's first version. Listed so the rule's breaches
are on record.

---

## 5. LongMemEval through it

Loaded by the experiment's `in_percolate/run.py` (REM-1076):

- sessions go into `content.resources` and `content.resource_chunks` through the
  normal ingest (`content.register_text`);
- Jev topic scores go into the tags layer;
- Jev question links go into the questions layer;
- the seeded questions go into `claims.questions`.

The experiment then calls `claims.search_leads` instead of its own files. The
first run must reproduce the S numbers in §3 before any M result counts.

## 6. Done when

- [ ] The table names above are confirmed (this document) and the duplicates are
      on record (§4.3).
- [x] Sirsh has decided the schema (§4).
- [ ] `claims.search_leads` works over each store and over all of them, with a
      test that a private revision's claims cannot reach a lead.
- [ ] LongMemEval is ingested through it and reproduces the S Phase A numbers.
- [ ] Tripartite search is measured against primary-store-only search on held-out
      M questions: recall at budget, reads to full evidence, latency and cost.
