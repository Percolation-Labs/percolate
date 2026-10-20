# Scale: the research platform, measured

**Every number here was produced by running it**, with [`dev/scale/research/`](../../dev/scale/research/README.md),
the same rule the workflow engine's scale measurements follow. The question is the one
set for core on 18 September: will every query and index hold at billions of rows. A laptop cannot hold
billions, so the answer comes from how cost grows, not from loading them (§1). REM-500.

## The environment

| | |
|---|---|
| Image | `percolationlabs/percolate-postgres:19-0.2.10`, upgraded to extension 0.2.11 with its upgrade script |
| PostgreSQL | 19beta3 |
| Settings | `shared_buffers` 1 GB, `work_mem` 16 MB |
| Host | 10 cores and 8 GB for Docker on an Apple-silicon laptop, shared with other sessions |
| Corpus | [`generate.sql`](../../dev/scale/research/generate.sql): 8,000 works (96,006 claims) and 80,000 works (960,006 claims) |

A third size, 250,000 works (3 million claims), was generated and then dropped when the disk filled on
18 September. So this file measures one decade, not three. §1 says why that is still an answer.

## 1. How "holds at billions" is decided

A call that holds at billions touches roughly the same number of pages however large the tables are:
an index lookup gains one B-tree level per hundredfold growth. A call that does not hold touches pages in
proportion to a table. The two look the same at fixture size and differ by the size factor at scale.

So each function a signed-in caller can execute runs at two sizes ten times apart, as a real person
under row security, warm, in a transaction that is rolled back. It counts **shared buffers touched**,
which count every page the call and the functions it calls read, and do not depend on the machine.

| Growth in pages from 96 K to 960 K claims | Verdict |
|---|---|
| at most 2× | holds: the cost does not follow a table |
| 2× to 5× | between: named, never rounded to a pass |
| 5× or more | fails: the cost follows a table, and at a billion rows it is a thousand times worse |

**The plan decides where the ratio cannot.** "Claims matching a common word" grew 1.7× and still fails.
Its plan is a scan of every claim that stops at the 20th readable match, so a common word stops early and
a word rare in what the caller may read scans everything, as the rare-word probe shows.

## 2. What failed, and what fixed it

Before and after the fixes in [`fixes.sql`](../../dev/scale/research/fixes.sql), pages per call.

| Call | 96 K claims | 960 K | growth | with fixes, 96 K | 960 K | growth |
|---|---|---|---|---|---|---|
| `list_packages`, first 20 | 157,584 | 1,886,835 (21.7 s) | **12×** | replaced by `list_listed` | 319 (1.7 ms) | 1.25× |
| `list_packages(true)`, my packages | 297 | 1,531 | **5.2×** | 172 | 207 | 1.20× |
| text search on claims, rare word | 1,776,692 | 20,650,169 (7.1 min) | **12×** | replaced by `search_claims` | 7 (0.1 ms) | 0.70× |
| `aiq.lexical` over claims | 1,776,693 | 20,648,832 (3–6 min) | **12×** | unchanged: see §3 | | |
| `trust` | 817 | 6,771 | **8.3×** | 162 | 179 | 1.10× |
| `trust_state` | 100 | 355 | 3.6× | 86 | 100 | 1.16× |
| `revision_signals` | 648 | 6,356 | **9.8×** | 18 | 25 | 1.39× |
| a revision's comments | 140 | 1,392 | **9.9×** | 2 | 3 | 1.50× |
| sources citing one origin | 2,953 | 17,497 | **5.9×** | 1,406 | 1,240 | 0.88× |
| `endorsements_affected_by` | 93 | 227 | 2.4× | 103 | 112 | 1.09× |
| `erase_work` | 10,117 | 91,136 | **9.0×** | 3,365 | 3,419 | 1.02× |

Every other call held before any fix. They are all lookups by id and all writes: `get_package`, the
four access checks, `my_saves`, `submit_package`, `revise_package`, `set_useful`, `add_comment`,
`endorse` and `set_saved`, each at 1.0× to 1.25×. The full table is in `results/`.

### The causes

**A per-revision or per-owner lookup with no index**, eight of them. `revision_signals` counted a
revision's votes with no index on `votes.revision_id`. `trust` read a revision's endorsements, whose only
index on `revision_id` is partial (`withdrawn_at is null`) and so cannot answer a query that includes
withdrawn ones. "My packages" had no index on `works.owner_id`. A revision's comments, sources by origin
and valuations were the same case.

**A cascade that scans a child per deleted row.** `erase_work` deletes a work, and each deleted revision,
claim and work checks its children through foreign keys. Five children had no index on the reference:
`votes` (whose new index had to be non-partial, since erasure deletes withdrawn votes too),
`revisions.base_revision_id`, `works.parent_work_id`, `endorsement_claims (revision_id, claim_key)` and
`saves.work_id`. Found by attributing the call's pages with `pg_stat_statements`.

**A function that visits the corpus to return a page.** `list_packages` calls `visible_head` on every
work, sorts every readable one and returns them all; a `limit` outside it saves nothing. `list_listed`
walks `exposures` newest first through an index and stops at the page, with a keyset for the next.

**Row security before the index.** A policy on `research.claims` calls `research.revision_readable` per
row, and Postgres must apply it before any operator that is not `LEAKPROOF`. The text-search operator
`@@` (`ts_match_vq`) is not, so every search under row security reads every claim. `search_claims`
searches as the definer, so the GIN index answers first, and asks `revision_readable` of each candidate,
so its answer still holds no claim the caller could not read.

## 3. Still open

| What | Why it fails at billions | The fix to try |
|---|---|---|
| **Search on a common term** | `search_claims` grew 2.7× on a term matching 0.8% of claims (44,786 pages for 8,005 matches). A GIN bitmap collects every match before the limit applies, so cost follows the matches: a term in 1% of a billion claims is ten million. | An index that returns matches ranked, so a limit stops early (RUM, not in the image); or claims partitioned by time, searched newest first until the page fills |
| **`aiq.lexical` on a source with row security** | Generic, and runs as the caller, so the policy runs on every row before `@@` (§2). `research_claims` and `research_sources` are closed: each has a definer search, and `aiq.lexical` refuses them and names it (REM-519). `search_sources` at 8,000 and 80,000 works: 4 pages for a word that matches nothing at both sizes; 37,511 and 43,081 for one in a fifth of sources, the common-term cost above (`dev/scale/research/results/sources-*.json`). `chunks` and `skills` are still searched as the caller, by design, and unprobed at size. | A definer search for a source when its size is measured, named in `aiq.lexical_sources.search_with` |
| **`list_packages` still exists** | The application and MCP call it. | They move to `list_listed` and a per-owner listing, then it goes |
| **One table per entity at a billion rows** | Lookups hold: a B-tree at a billion rows is 4–5 levels. But at the measured bytes per row, `research.claims` is 381 GB and `revisions` 526 GB, and index builds, vacuum and a restore follow the table. | Partitioning by work (hash) so maintenance and restore work per partition, decided before the tables are large |
| **The other schemas** | `content`, `aiq` and `agentic` are reachable by `authenticated` (21, 33 and 17 functions) and unprobed. `workflow` has its own harness. | The same probe, per schema |

## 4. What is not measured

- The third decade (3 M claims), dropped for disk. The harness takes any database, so it is one command
  on a machine with room.
- Concurrency: every probe is one caller. Contention is the workflow engine's scale measurements' subject.
- `research.revision_readable` against a large grant set. The corpus has one role and one grant, and a
  person with thousands of org memberships would make the access check itself the thing to probe.
- Writes at volume: `submit_package` holds per call, but a million packages a day is WAL and vacuum,
  which per-call pages cannot show.
