# Graph algorithms — the half of the graph no SQL operator reaches

**Status: ten proposed, nine built and measured, seven shipped, two parked on
the number that parked them, one named as research and not built — plus two
primitives and one schema rule added on a consumer request (§12), measured on
the same harness.**

- **Built and asserted:** `extension/percolate_parser/src/graph.rs` — the CSR
  snapshot, the budget, and nine algorithms over it; `graph-algorithms.sql` —
  the SQL surface, which deliberately wraps **only the six that passed**;
  `dev/tests/query/11-graph-algorithms.sql` holds the behaviour up, including
  the one assertion this whole design turns on (§2.1: a cached snapshot cannot
  cross a tenant).
- **Run.** An internal scale harness, not yet published — three sizes (40k, 394k and 3.94M edges over
  10k, 100k and 1M nodes) on a heavy-tailed fixture with communities, expired
  edges and spread weights, against a live PG19 beta in the compose stack
  (10 cores, 7.65 GiB, arm64, warm cache, one backend, no RLS filtering).
  Every number below is from that harness.
- **Measuring rewrote five of the seven that shipped**, and §8 lists all six
  corrections. Two of them — a walk bounded by a confidence floor that turned
  out to bound nothing, and a shortest path that explored a whole component to
  say "not connected" — cost between 25x and 69x, and neither is visible at
  fixture scale. That is the argument for the harness, not a bonus from it.
- **Still not built:** the fused vector-and-graph proximity index (§4.5),
  which is the one proposal here whose verdict is *research* rather than a
  measurement, and which says so rather than being quietly shipped or quietly
  dropped.

---

## 0. The claim in one paragraph

`GRAPH_TABLE` matches patterns and `pgvector` ranks by similarity; between them
sits a class of question neither can express — **what is most related to this,
how are these two connected, what connects these eight, how dense is the
company this node keeps, and how much of that rests on a model's guess.** Each
one is a *search* rather than a walk: it must rank, it must bound, and it must
be able to stop and say so. This document specifies those searches as compiled,
budgeted, anytime functions over a cached adjacency snapshot; measures each one
at three scales against the recursive CTE that does the job today; and ships
only the ones that survived. The parked ones are parked with the number, so
promoting one is a matter of beating a figure rather than re-arguing a
preference.

---

## 1. Why any of this is compiled, and where the line falls

`brief.md` §3 already reserves `pgrx` for "graph *algorithms* Postgres has no
native operator for" and explicitly excludes CRUD, lookup and traversal. Two
facts make that more than a stylistic preference.

**PG19 has no quantified path patterns.** `brief.md` §3 records it as confirmed
by design rather than by our test: `-[e]->{1,n}` is rejected outright, the
feature was scoped out of the initial implementation, and `DEPTH n>1` therefore
falls back to `WITH RECURSIVE`. Everything past one hop is already leaving
SQL/PGQ.

**A recursive CTE enumerates; it cannot rank, bound or stop.** It will happily
return a hub's three-hop neighbourhood — the harness measured a p95 of 4.5 s
and a worst case of 19.6 s doing exactly that at four million edges — but there
is no expression in it for "the fifty most related", "the three cheapest
routes", "stop after 250 ms and tell me you did". Those are not missing
conveniences; they are the whole content of every algorithm below.

**And the line falls precisely where the measurement puts it, which is not
where enthusiasm would.** At one and two hops the recursive CTE **wins**, and
it is not close:

| at 3.94M edges | p50 | p95 |
|---|---|---|
| recursive CTE, depth 2 | **0.9 ms** | **2.9 ms** |
| `aiq.related` (PPR, ranked) | 93.3 ms | 115.0 ms |
| recursive CTE, depth 3 | 19.7 ms | 4,527 ms |

So the rule this document adds to §3's is: **compiled code earns its place when
the answer is a ranking, a bound, or a search — never when it is a
neighbourhood.** `aiq.graph_neighbors` remains the right function for one hop,
and `aiq.related` is the wrong tool for a job `GRAPH_TABLE` already does in a
millisecond. A recommendation that gets this backwards would make the extension
a tax on the most common query in the system.

---

## 2. One structure: the CSR snapshot

Everything here reads through a single cached structure — compressed sparse row
adjacency over `aiq.edges`, built through SPI, held in the backend. A hop is a
slice index rather than a page access, and that difference is what makes a
local push walk cost what it costs.

The edge record is stored **once**, with both directions indexing into it. That
is the same rule the table follows (`graph-identity.md`: "do not store the
inverse edge"), and here it also halves the temporal columns, which are already
half the width: `valid_from`/`valid_to` are 16 of the record's 32 bytes.
Carrying them is what lets a traversal apply them at edge-relax time (§7).

Measured, and linear in edges across two orders of magnitude:

| edges | build | resident | per edge |
|---|---|---|---|
| 39,568 | 40 ms | 2.2 MB | 55 B |
| 394,438 | 205 ms | 20.9 MB | 53 B |
| 3,937,054 | 3,826 ms | 225.5 MB | 57 B |

Plus scratch — the reusable per-query arrays — at 52 bytes per node, which is
where a million-node graph adds another 52 MB.

Three properties of this cache are load-bearing, and each is a way the design
could be *wrong* rather than slow.

### 2.1 It is built as the caller, so it must not be reused by anyone else

The build runs through SPI in a `SECURITY INVOKER` function, so RLS applies and
the snapshot is correct for the identity that built it. It is also cached, and
a cache built under one tenant's policies and read under another's is a silent
cross-tenant **read** — the same shape as a cross-tenant write found earlier
in the graph index.

Every entry point therefore re-checks a fingerprint — role, JWT claims, and the
two tables' modification counters — and rebuilds rather than serving someone
else's graph. `dev/tests/query/11` §7 asserts it by behaviour: one backend, two
identities, and the second must get a different snapshot. A pooled connection
handed between tenants is not an exotic case, it is how PostgREST works.

**Edges whose endpoint is invisible are dropped at build, not at read.** RLS can
legitimately show an edge and hide a node; a walk that landed on that node would
be disclosing it. The build resolves both endpoints or discards the edge.

### 2.2 It is a stale read, and says so

The modification counters come from the stats collector, which lags. A snapshot
can therefore be behind the graph for the length of that lag, and `built_at`
reports when it was taken. The alternative — `count(*)` per call — costs more
than most of the algorithms it would be guarding. This is a stated limitation,
not a solved problem: **these functions answer from a snapshot, and a caller
that needs read-your-writes must pass `p_refresh => true` and pay the build.**

### 2.3 Its memory is per backend, and that is an availability risk

225 MB at 3.94M edges, per connection that touches the graph, and the peak
*during* a build is roughly twice that — the edge array, the two index arrays
and the id map are all live at once.

This was written as a sizing note. It is not one, and finding that out took a
measurement rather than an argument. **Eight concurrent callers against the
3.94M-edge fixture on a 7.65 GiB machine did not produce a slow query:**

```
LOG:   client backend (PID 36430) was terminated by signal 9: Killed
LOG:   terminating any other active server processes
FATAL: the database system is in recovery mode
```

One graph query took the cluster down, and every other session with it. The
reason nothing in Postgres prevented it is structural: this memory is
Rust-allocated, outside `work_mem`, so no existing setting sees it and the
planner does not know it exists. The bound has to be in the extension.

**So there is admission control, built out of a primitive Postgres already
has.** A backend takes one of `percolate.graph_snapshot_slots` (default 6)
session-level advisory locks before it builds, and holds it as long as it holds the snapshot.
Session-level locks are released when the connection ends, which is exactly
when the memory goes back, so the lock and the thing it guards have the same
lifetime. A backend that cannot get a slot is **refused with a sentence**:

```
ERROR: all 6 graph snapshot slots on this cluster are held. Each one is a
backend holding an adjacency snapshot, and the memory is outside work_mem --
so admitting this call is how a graph query becomes an OOM kill and a cluster
restart rather than a slow query. Retry, or release one with
select aiq.graph_snapshot_drop() in a session that is done with it.
```

Re-run at eight clients: six served, two refused, **cluster alive**. That is
the discipline the rest of this surface already follows — convert a quiet
catastrophic failure into a loud refusal — applied to the one failure here that
was not a wrong answer but an outage.

There is also a per-backend ceiling (`percolate.graph_snapshot_max_mb`, default
512), checked
against the arriving size during the build, which catches a different case: one
graph too large for any single backend, refused with a pointer to §2.4's
filter. **The two are not substitutes.** The ceiling stops one pathological
graph; the slots stop N ordinary callers. It was the second that took the box.

Below about half a million edges — 21 MB, 200 ms — none of this needs thought.
Above it, three ways to live with it, and the choice is operational:

1. **A worker-shaped workload** — a small number of long-lived backends that
   build once. `workflow-engine`'s pools already look like this.
2. **Preloading at connection start**, accepting the build as connection cost.
3. **Moving the snapshot into shared memory** — a DSA segment built by a
   background worker, versioned by epoch, read lock-free. The measurement above
   promoted this from "the natural next build" to **a requirement above
   single-digit concurrency**: six slots is not a scaling story, it is a guard
   rail, and a guard rail is what you need until the memory is shared.

**Both limits are settings rather than constants**, and that took a second
pass. Compiled in, they were a safety mechanism nobody could adjust without
rebuilding the extension — six is right for 7.65 GiB and wrong for both a
laptop and a real server, and the failure mode of "wrong" is not a slow query.
They are `Suset`: a DBA sets them in `postgresql.conf`, a superuser may change
them for a session, and the roles that *call* these functions cannot touch
them, because a limit its subject can raise is not a limit. Sizing is
`available memory / roughly twice one snapshot`, and `2.3` is the arithmetic.

One wrinkle worth knowing before it wastes an afternoon: setting them through
libpq connection options (`PGOPTIONS`) does not reliably bind, because the
library that defines them loads on first use rather than at startup and the
pending placeholder is a `PGC_BACKEND` assignment to a `PGC_SUSET` variable.
`postgresql.conf` and an in-session `SET` both work.

`aiq.graph_snapshot()` exists so that an operator can ask which backend they are
on and what it is holding, rather than inferring it.

### 2.3b The budget covers the call, not just the walk

Every answer's `elapsed_ms` is wall clock for the **call**, and that took a
correction. The budget used to start after the snapshot was fetched, so a first
call on a cold backend reported this:

```
reported: {"budget_ms": 250, "elapsed_ms": 96.1, "exhausted": false}
actual:   2688.7 ms
```

Both numbers were true of the walk. The one an operator would have written an
SLO against was off by 28x, and "first call per backend" is what a pooled
connection does all day. The meta now carries five fields that keep the cases
apart:

| | |
|---|---|
| `elapsed_ms` | what the caller waited, everything included |
| `walk_ms` | what the algorithm ran for |
| `build_ms` / `snapshot_built` | whether this call paid for a snapshot, and how much |
| `exhausted` | the **answer** is partial — the walk stopped early |
| `over_budget` | the **call** took longer than it was given |

The last two are deliberately separate. Collapsing them makes a complete answer
that arrived late indistinguishable from a truncated answer that arrived on
time, and those are opposite problems with opposite fixes.

### 2.4 It can be built over a subset, and says when it was

`aiq.graph_snapshot(refresh, relations[], weight_floor, as_of)` builds over part
of the edge table. The filter is pushed into the build query, so the rows never
arrive and are never resident — which is the difference between this and the
per-query `relation` argument the traversals already had. That one narrows the
*answer*; this one narrows the *graph*.

The case that forced it is an evidence graph, where a weak opinion is recorded
on every pair that was ever considered — "we looked and found nothing" being a
different fact from "we never looked" — so most edges are below any operating
threshold and none of them belong in a traversal. Measured on the scale fixture,
keeping two relations of six above a 0.6 weight floor:

| | whole table | the 19% kept |
|---|---|---|
| edges | 3,936,814 | 748,944 |
| build | 3,826 ms | **677 ms** |
| resident | 225 MB | **98 MB** |

**The filter is sticky, and that is the load-bearing decision.** Once built, the
filtered graph is what every other function in the module walks until the next
build — a query does not silently widen the graph it was handed. The price of
that is that a filtered snapshot returns a filtered answer, so the filter rides
on every result beside the counts, in the same `snapshot` block that already
carries the build time. A caller unable to tell which graph it just walked is
the same class of silent wrongness the dialect emits `plan` to prevent.

---

## 3. The budget contract

One `Budget` type, carried by every algorithm, bounding two things at once:
wall clock **and** edge visits. The second is not redundant — a bound that is
only wall clock makes a result depend on what else the machine was doing, which
is a property a scale measurement cannot have.

Three rules, and they are requirements rather than conventions:

- **`CHECK_FOR_INTERRUPTS` lives in the budget**, so `statement_timeout` and a
  client cancel still work inside a 200 ms Rust loop that Postgres cannot
  otherwise see into.
- **Every algorithm is anytime.** Running out of budget returns the best answer
  found so far, never an error and never a truncated answer that looks whole.
  What "so far" means is stated per algorithm below, because it differs: for
  PPR it is an under-estimate of every score with the ranking intact; for
  top-k paths it is the best path plus however many alternates were bought.
- **Every answer reports `exhausted`**, and the SQL surface carries it onto
  every row. "Nothing is related" and "I ran out of budget" are different
  facts, and collapsing them is the same failure the dialect's `unresolved`
  field exists to prevent. No algorithm may be added here that cannot say it
  stopped early.

---

## 4. The five indexing backends

### 4.1 CSR adjacency snapshot — **SAFE, ships, with §2.3's constraint**

Specified in §2. It is the substrate the other nine stand on, so its verdict is
the collection's: linear in edges, 57 bytes and about 1 µs per edge, correct
across a tenant switch, and bounded by memory rather than by time.

### 4.2 Reach sketches (HyperANF) — **SAFE, ships**

The planning input, and the answer to why a `DEPTH 3` walk falls over: nobody
knows the frontier is four hundred thousand nodes until they are holding it. A
few passes of HyperLogLog union over the adjacency gives each node's k-hop reach,
and the query is then a constant-time array read — the input a dialect needs to
**refuse or downgrade a query before spending the budget**.

Only the cardinality is kept, not the registers: 64 registers are needed to
union neighbourhoods during the build, and four bytes per node per depth
answers the question afterwards just as well. (Keeping the registers would buy
neighbourhood-Jaccard similarity too. Worth having; not built.)

| edges | build (depth 3) | resident | median error @2 | p95 error @2 |
|---|---|---|---|---|
| 39,568 | 25 ms | 120 KB | 6.7% | 20.5% |
| 394,438 | 188 ms | 1.2 MB | 7.3% | 24.8% |
| 3,937,054 | 2,880 ms | 12 MB | 6.1% | 22.5% |

Linear, cheap, and 12 bytes per node at rest. **Read it as a magnitude, not a
count** — a p95 of about a fifth is fine for "is this walk going to be
thousands or millions" and useless for anything that needs the number itself.
The register count is a measured choice, not a default: 16 registers gave a
51% p95, which is not a bound (§8.1).

### 4.3 Community partition (label propagation) — **PARKED**

Cost is not the problem. Quality is, and establishing that took a second
fixture.

On the standard fixture label propagation returns **modularity 0.02** with 90%
of the nodes in one community. That number has two readings — the method
failed, or this graph has no partition — and the sliding locality window does
make a continuum rather than blocks, so the second reading was live. A planted
fixture (195 disjoint blocks, 90% of edges inside
one) separates them:

| fixture | modularity | what it recovered |
|---|---|---|
| sliding window, 394k edges | 0.027 | one community holding 91% of nodes |
| planted blocks, 399k edges | **0.369** | 43 of 195 blocks intact; the other 76% of nodes shattered into ~18,000 fragments of three or fewer |

So the method does find real structure when structure exists — and then
fragments three quarters of the graph. As a semantic surface that is a
misleading label; as a locality index to cluster `aiq.edges` by, it is worse
than useless, because you would physically reorder a table by a column that
means nothing for most of its rows.

Cost, for the record, is also drifting away from linear — 225 ms at 394k edges
but 15.4 s at 3.94M, against 2.3 s if it scaled — which is the per-node hash
tally and cache behaviour, and is fixable.

**To promote it:** Leiden, or label propagation with a minimum-size constraint
and a consolidation pass. The number to beat used to be stated against this
fixture — ≥80% of planted blocks at ≥0.4 modularity — and a consumer's
measurement has since replaced it with a harder and more honest one.

Running nine clusterers over one evidence graph, each with its own threshold
sweep, paired across six unseen fixtures, they found **connected components
plus a local repair pass beating MCL without one** (F1 0.895 against 0.875), and
the leading methods landing within 0.002 of each other once repair runs —
against a seed spread of 0.017. Which is to say the gain is not in the
clusterer at all.

So the bar is now: **beat connected components plus repair.** No partition
algorithm has been shown to clear it, and until one is, the right thing to build
is the primitive rather than the method — which is exactly what §5.6 and §5.7
are. Recorded alongside, because a measured negative saves the next person the
same week: reweighting edges by the local link-prediction indices (common
neighbours, Adamic–Adar, resource allocation) before clustering made things
*worse*, for every clusterer they tried.

### 4.4 Pruned landmark labels — **PARKED, and in practice dropped**

The most attractive index on paper and the clearest failure in the harness. The
query side was never in doubt — an exact hop distance by intersecting two
sorted lists, measured at **0.10–0.12 ms** at every scale. The build is the
whole question, and it does not survive:

| edges | build | labels/node | outcome |
|---|---|---|---|
| 39,568 | 1.7 s | 77 | complete |
| 394,438 | 93.7 s | 200 (and climbing) | **incomplete** — hit a 20M-entry ceiling after 10,220 of 100,021 roots |
| 3,937,054 | 13.6 s | 20 | **incomplete** — ceiling hit after **67 roots** |

Read the last row carefully: it is *faster* only because it gave up sooner. At
100k nodes the labels were already at 200 per node and 162 MB with 90% of the
roots unprocessed, which extrapolates past a gigabyte for a graph the CSR holds
in 21 MB. Heavy-tailed degree is exactly the shape that defeats the pruning
argument: the hubs that should cover everything are also the ones that make
every label set enormous.

**To promote it:** a bounded variant — landmarks capped at a few hundred hubs,
answering an *upper bound* rather than an exact distance, with the bound
labelled as such. That is a different index with a different contract, and it
should be specified as one rather than smuggled in under this name. Nothing in
this repository needs an exact all-pairs hop distance today; the two questions
that looked like they did are answered better by §5.2 and §5.5.

### 4.5 A fused vector-and-graph proximity index — **RESEARCH, not built**

Today `SEMANTIC` walks an HNSW and `GRAPH` walks `edges`, and `SEARCH` glues the
two result sets with RRF *after the fact* (`brief.md` §3). The proposal is one
navigable index whose neighbour lists are the union of embedding-nearest and
`aiq.edges` adjacency, so "semantically near **and** two hops out" is a single
beam search with a mixed cost function rather than two searches and a join.

It is not built, and it is listed here rather than dropped because it is the
only proposal on this list that would change what the system can *answer*
rather than how fast it answers. It is also the only one whose cost question is
not the build — the build is an HNSW build plus a CSR build, both of which are
known — but **maintenance**: every new node needs a kNN insert and its edges,
every edge write perturbs a neighbour list, and no measurement here says what
that costs under the ingestion rate `world-model-ingestion` actually produces.

**What would settle it**, and it is a day of work rather than a research
programme: build the fused index over a corpus with real embeddings, then
measure (a) recall of the fused search against RRF over the two separate
indexes, on a query set where the right answer is known, and (b) the cost of
one incremental insert at a million nodes. If recall does not beat RRF, the
fusion buys nothing and this stays a note. `brief.md` §3.5's promotion
discipline applies:
it moves out of research when something needs it, not when someone is
interested.

---

## 5. The five query-time algorithms

All five are budgeted, anytime, and reported. All five numbers below are at
**3.94M edges over 1M nodes**, which is the size at which the differences
between them stopped being academic.

### 5.1 Personalised PageRank — **SAFE, ships as `aiq.related`**

Andersen–Chung–Lang local push. The important property is not the ranking but
the **locality**: the walk touches the neighbourhood the mass actually reaches,
never the whole graph, so its cost is a function of the seed's surroundings
rather than of the corpus. Anytime by construction — the residual is the
unpushed mass, so stopping early under-estimates every score and leaves the
ranking intact.

**93.3 ms p50, 115.0 ms p95, 0 of 100 calls over budget.** Against the depth-3
recursive CTE's 19.7 / 4,527 ms, unranked. Against depth-2's 0.9 / 2.9 ms it
loses, and §1 says so out loud.

### 5.2 Top-k shortest paths — **SAFE, ships as `aiq.graph_paths`**

Bidirectional Dijkstra, then Yen for the alternates, with cost `1 − ln(w)` so
that "shortest" means fewest hops tie-broken by confidence. `as_of` is applied
at edge relax, which is the only correct place for it (§7).

The two numbers are different questions and both matter:

| | p50 | p95 | over budget |
|---|---|---|---|
| best path only (`k=1`) | 8.0 ms (mean) | — | **0 of 50** |
| best plus two alternates (`k=3`) | 161.1 ms | 250.7 ms | 34 of 100 |

The alternates are what cost. **The anytime contract here is "the best path,
plus as many alternates as the budget bought"** — which is why the first path
is found by a bidirectional search that also proves unreachability cheaply
(a disconnected pair still answers in single-digit milliseconds), and only then
does Yen start spending. A caller that wants a guarantee should ask for `k=1`.

### 5.3 Dense subgraph — **SAFE, ships as `aiq.graph_dense`**

k-core by peeling, then Bron–Kerbosch with pivoting inside the densest core.
`brief.md` §3's "clique/collusion detection", and the clearest case for
compiled code on this list: maximal clique enumeration is NP-hard, so it cannot
be a query, only a budgeted search. Bounded twice — the induced neighbourhood
is capped *before* the exponential part runs at all.

**16.6 ms p50, 22.0 ms p95, 0 of 50 over budget**, and near-flat across scales
(2.6 ms at 40k edges) because the structural cap, not the graph, sets the cost.

### 5.4 Trust propagation — **SAFE, ships as `aiq.graph_trust`** (after §8.3)

Max-product best path — a Dijkstra in `−ln(w)` space with no hop constant,
because a long chain of certain edges should not be penalised for its length —
plus noisy-OR over the neighbours carrying belief into a node.
`path_confidence` is one path's opinion; `confidence` is that path lifted by
the corroborating ones; `support` is how many of those there were. Read
together they answer *how much of this rests on a model's guess*, which after
two hops nothing else in the system can tell you.

**`support` counts SOURCES, not paths.** Noisy-OR multiplies failure
probabilities, which is sound only for paths that fail separately, and two
paths extracted from one document fail together. So the snapshot carries one
**source root** per edge — the first `provenance.sources[].resource_id`, or the
tier for an edge nobody extracted — and the lift runs over the supporting
neighbours whose best paths, recovered from the walk's parent pointers, use
disjoint roots. Best first, greedily, so the combination is a subset of the
independent evidence rather than the largest one: a lower bound on belief,
never an overstatement of it. Exact network reliability is #P-complete
(Valiant 1979), so the choice is a bound or a sampler, and a query is not a
sampler.

What that is worth, measured on a real knowledge-graph topology (3,253 nodes, 10,362
edges, 40 single-seed queries, Monte Carlo connectivity over 4,000 samples as
the oracle, "overconfident" meaning more than 3 SE + 0.02 above it): with edges
grouped into documents that share a fate, **39–46% of the rows with support ≥ 2
were overconfident** by +0.16 to +0.20 on average and up to +0.65. Counting
only disjoint sources takes that to **0%**, at the cost of caution — the mean
gap on corroborated rows moves to −0.13 to −0.20. With independent edges
nothing moves: the lift was already harmless there (1–2%), and the ranking by
`path_confidence` is unchanged. `extension/percolate_parser/src/graph.rs`'s two
`#[pg_test]`s are that measurement, committed: on their own correlated
fixture the old lift put **26 of the 147 rows it lifted** above the oracle,
by up to **+0.57**, and the disjointness rule puts **none** there while still
lifting 18 of them.

**What it costs.** One `u32` per edge in the snapshot — 4 bytes, a parallel
array rather than a field inside the 30-byte `Edge` that padding would have
rounded to 40. Measured on the scale fixture: **20.93 → 22.51 MB at
394k edges and 225.5 → 241.3 MB at 3.94M**, +7.0 to +7.5% either way. Query
latency at 394k edges, the same 300 seeds under both parsers, best of four
runs each: **p50 1.43 → 1.51 ms, p95 1.65 → 1.76 ms** — under a tenth. The
same probe at 3.94M edges could not be read that cleanly on the machine this
was measured on: the unchanged parser answered at 10.1–11.7 ms against the
6.7 ms in §6, and the backend was OOM-killed repeatedly building a 241 MB
snapshot with 6.3 GiB of a 7.65 GiB VM already resident — which is §2.3's
measurement arriving again rather than a new one.

Two consequences bear on how to read the number. Every **authored**
edge shares one root, so two analyst assertions do not corroborate each other —
an authored edge is already weight 1.0, so this costs a lift that had nothing
to add. And an edge asserted by several documents takes the FIRST one, which
undercounts independence rather than inventing it. On one corpus,
2,260 of 12,626 edges carry sources at all, 81 of them name more than one
resource, and the 2,260 rest on 74 documents — about 30 edges each, which is
the regime the measurement above calls 500 documents.

`naive_confidence` is what `confidence` was before this rule. It ships for one
release, so that a caller can see the size of the correction on their own
graph, and then it goes.

**5.5 ms p50, 6.7 ms p95, 0 of 100 over budget** — after the rewrite. Before
it: 277 ms p50 with **every single call** over a 250 ms budget. §8.3 is the
correction and it is the most interesting one in this document.

### 5.5 Minimum connecting subgraph — **SAFE, ships as `aiq.graph_connect`** (after §8.4)

Mehlhorn's variant of the Steiner 2-approximation: one multi-source Dijkstra
labels each node with its nearest terminal, the metric closure is read off the
edges that cross a territory boundary, a minimum spanning tree over the
terminals picks the connections, and non-terminal leaves are pruned.

This is the operation that turns a result list into a picture. A retrieval
returns eight entities and the honest follow-up is not "which is most relevant"
but "what connects them" — a question no amount of ranking answers.

**129.8 ms p50, 148.4 ms p95, 0 of 33 over budget, all five terminals joined.**
Before the rewrite: 502 ms against a 500 ms budget, exhausted on every call,
and a partial answer.

### 5.6 Connected components — **SAFE, ships as `aiq.graph_components`**

Union-find with path halving, budgeted. The cheapest useful thing on this list
and the one every clustering, blocking or hardening pass is built out of: which
nodes are transitively linked at all, before anything decides what that means.

The component is named by the **smallest node id in it**, which makes the name
stable across runs and independent of iteration order — a component id that
moves between two runs over the same graph is not an id.

It is also the function that most needs §2.4 in front of it. Components over an
unfiltered evidence graph are one blob, because the near-zero edges a threshold
exists to ignore connect everything to everything. Filter the snapshot, then
take components: **184 ms** over 749k edges, 606,580 nodes in 84,563 components
of two or more.

### 5.7 Induced subgraph — **SAFE, ships as `aiq.graph_induced`**

The edges internal to a supplied set of nodes. Trivial, and it exists for a
round-trip argument rather than a compute one: a repair pass over thousands of
small clusters, fetching each cluster's internal edges with its own query, is
thousands of round trips for a few hundred bytes each.

One call answers all of them **when the clusters are components**, because an
edge internal to the union of disjoint components is internal to exactly one of
them. 20,000 nodes in, 142,076 internal edges out, **46.6 ms**.

Both of these are addressed by **id, not by key**, and neither hydrates its
result. Every other wrapper takes keys because every other wrapper answers a
question somebody asked in words; these two are called in a loop by code, with
ids that came out of the previous call, and at a million rows the key join costs
more than the algorithm.

---

## 6. The measurements

Three sizes, one fixture, one machine, one backend. The fixture is heavy-tailed
by construction, each of its properties chosen deliberately; a uniform random graph would make every algorithm here look good for
a reason that does not hold in a real corpus.

**Every figure below is from one run**, the one against the current code, and a
re-run will not reproduce it to three digits. Measured across four runs of the
same harness on the same machine: the 100-iteration latency probes move by
10–30% and the one-shot build probes by up to 2×, because the box is shared and
a cold page cache is worth more than the algorithm on a build. **The slope is
the claim, not the absolute figure** — an operation that is linear across two
orders of magnitude stays linear on someone else's hardware, and one that
exhausts its budget on a third of its calls will exhaust it on theirs. Where a
number decides something in this document — a verdict, a promotion bar — it is a
number with an order of magnitude of headroom, never a 20% margin.

**Query time**, p50 / p95 in milliseconds, with the count of calls that hit the
250 ms budget (500 ms for `connect`):

| | 40k edges | 394k edges | 3.94M edges | over budget @3.94M |
|---|---|---|---|---|
| `related` (PPR) | 7.9 / 16.9 | 22.5 / 31.4 | 93.3 / 115.0 | 0 / 100 |
| `graph_trust` | 0.4 / 0.5 | 1.0 / 1.1 | 5.5 / 6.7 | 0 / 100 |
| `graph_paths` (k=3) | 1.7 / 3.9 | 11.9 / 35.7 | 161.1 / 250.7 | 34 / 100 |
| `graph_dense` | 2.6 / 3.0 | 5.4 / 6.7 | 16.6 / 22.0 | 0 / 50 |
| `graph_connect` (5 terminals) | 2.5 / 2.9 | 25.8 / 37.5 | 129.8 / 148.4 | 0 / 33 |
| `graph_components` (filtered) | 1.4 | 13.2 | 184.3 | one shot |
| `graph_induced` (20k nodes in) | 1.9 | 8.5 | 46.6 | one shot |
| *recursive CTE, depth 2* | 0.1 / 1.0 | 0.1 / 4.4 | 0.9 / 2.9 | — |
| *recursive CTE, depth 3* | 1.1 / 10.5 | 2.3 / 63.1 | 19.7 / 4527.0 | — |

**Index builds**, one shot each:

| | 40k edges | 394k edges | 3.94M edges | resident @3.94M |
|---|---|---|---|---|
| CSR snapshot | 40 ms | 205 ms | 3,826 ms | 225 MB |
| CSR snapshot, 19% subset | 5 ms | 51 ms | 677 ms | 98 MB |
| reach sketches (depth 3) | 25 ms | 188 ms | 2,880 ms | 12 MB |
| communities (label prop) | 18 ms | 225 ms | 15,428 ms | 4 MB |
| landmark labels | 1.7 s | **93.7 s, incomplete** | **13.6 s, incomplete** | 184 MB at the ceiling |

**The cost of each thing, by the question it answers.** The table above is by
function; this one is by the shape of the cost, which is what decides whether a
question is affordable at a size nobody has run yet.

| Question | Cost is a function of | At 3.94M edges | Bounded by |
|---|---|---|---|
| `GRAPH` depth 1–2 | the node's degree | 0.9 / 2.9 ms | the index, and nothing else needed |
| `GRAPH` depth 3 | **the frontier**, which explodes on a hub | 19.7 / 4527 ms | nothing — this is the failure the rest of the table exists to bound |
| `RELEVANCE` | the neighbourhood the score reaches, *not* the graph | 93.3 / 115.0 ms | budget; degrades to a shorter ranked list |
| `PATH` (2 names) | the volume between them, square-rooted by meeting in the middle | 8.0 ms for the best route | budget; the best route first, alternates after |
| `PATH` (N names) | one multi-source walk, capped at 50k settled nodes | 129.8 / 148.4 ms | budget **and** the settle cap; reports terminals joined |
| `graph_trust` | the top-k settled, and nothing beyond them | 5.5 / 6.7 ms | a rank bound, which is why it is the cheapest thing here |
| `graph_dense` | the induced cap, not the graph | 16.6 / 22.0 ms | structural — the exponential part runs on a bounded subgraph |
| `graph_components` | one linear pass | 184 ms over 749k edges | filter the snapshot first, or the answer is one blob |
| `graph_frontier` | O(1) after the sketch build | 0.1 ms | the sketch, built once |
| **any first call in a backend** | **the whole edge table** | **2.7 s and 225 MB** | the slot count (§2.3), not the budget |

The last row is the one that decides deployments, and it is the one every other
number hid until the budget was made to cover the call.

**Under concurrency**, on the same graph and machine, `RELEVANCE` at N clients:

| clients | tps | p50 | p95 | peak container memory |
|---|---|---|---|---|
| 1 | 10 | 90.3 ms | 102.2 ms | 1.04 GiB |
| 4 | 29 | 114.8 ms | 132.7 ms | 3.33 GiB |
| 8 | — | — | — | 5.55 GiB, **OOM kill and cluster restart** |
| 8, with admission control | 14 | — | — | six served, two refused, cluster alive |

Latency barely moves from one client to four; **memory is the constraint, not
CPU**, and it arrives at single digits. That is the finding that turned the
shared-memory snapshot from a roadmap item into a requirement (§2.3).

**The verdict table**, which is the point of the document:

| # | Proposal | Verdict | The number that decided it |
|---|---|---|---|
| I1 | CSR adjacency snapshot | **SAFE**, ships | linear, 57 B and ~1 µs per edge; but 225 MB *per backend* (§2.3) |
| I2 | Reach sketches (HyperANF) | **SAFE**, ships | 2.9 s and 12 MB at 3.94M edges; median 6% error, p95 ~22% |
| I3 | Community partition | **PARKED** | recovers 43 of 195 planted blocks; shatters 76% of the graph into fragments of ≤3 |
| I4 | Pruned landmark labels | **PARKED** (effectively dropped) | does not finish at 394k edges; 200 labels/node with 89% of roots unprocessed |
| I5 | Fused vector+graph index | **RESEARCH**, not built | no measurement; §4.5 says what would produce one |
| Q1 | Personalised PageRank | **SAFE**, ships | 93.3 / 115.0 ms, 0 over budget |
| Q2 | Top-k shortest paths | **SAFE**, ships | 8.0 ms for the best path, 0 over budget; alternates are anytime |
| Q3 | Dense subgraph | **SAFE**, ships | 16.6 / 22.0 ms, bounded by construction |
| Q4 | Trust propagation | **SAFE**, ships | 5.5 / 6.7 ms — after §8.3 turned 277 ms into that |
| Q5 | Minimum connecting subgraph | **SAFE**, ships | 129.8 / 148.4 ms, all terminals joined — after §8.4 |
| R1 | Snapshot build filter (§12) | **SAFE**, ships | 3,826 → 677 ms and 225 → 98 MB on a 19% subset |
| R2 | Connected components (§12) | **SAFE**, ships | 184 ms over 749k edges; linear |
| R3 | Induced subgraph (§12) | **SAFE**, ships | 46.6 ms for 20k nodes; one round trip instead of thousands |

**The verdict is expressed in the code, not only here.** Only the SAFE ones
have an `aiq.` wrapper in `graph-algorithms.sql` and a row in `surface.sql`; the
parked two are reachable only as bare `p8_graph_*` C functions, for re-running
the harness. Nothing can start depending on a parked proposal by accident,
which is the failure mode a verdict written only in prose invites.

---

## 7. Temporal validity: applied at edge relax, and now by default

The filter is applied **at edge relax**, and that placement is the whole
correctness argument: filtering the result set afterwards returns *the k best
paths including expired edges, minus the ones that happened to be expired*,
which is a different and much worse answer than the k best valid paths.

**The default is now(), not "everything".** `as_of` began as an opt-in
argument on `aiq.graph_paths`, `aiq.related` and `aiq.graph_trust`, and
omitting it applied no window at all — so every caller who did not name a time
got the graph's whole history, retractions included, while `aiq.edges_current`
hid exactly those edges from every SQL reader. That was REM-51, and the fix is
one line of meaning: a traversal with no `as_of` walks the graph as of the
statement's `now()`, which is what `aiq.edge_is_current` answers for every other
read path. An explicit past `as_of` still traverses what was believed then,
because retraction is history rather than deletion. `dev/tests/query/11` §6
asserts all three: the retracted edge is gone by default, gone at `as_of now()`,
and there as of before it was retracted.

The derived indexes that are built over the whole snapshot — the reach
sketches, the landmark labels, the communities, and connected components — take
the same view: they describe the graph that holds now. Each is cached with the
snapshot and rebuilt when the tables change, so an edge whose `valid_to` passes
with no write in between is stale in those indexes until the next build. A
traversal is not: it filters per edge, per call.

**What the snapshot is built from is belief periods, not rows** (REM-65).
`aiq.edge_periods` yields one record per interval an edge was believed, so an
edge asserted, retracted and re-asserted contributes two records and an as-of
read inside the retraction crosses neither. The periods of one edge are
disjoint, so at any instant at most one passes the filter and a walk never sees
an edge twice. Where the view is absent — a parser newer than the extension
beside it, mid-upgrade — the builder falls back to `aiq.edges` and the snapshot
is what it always was.

---

## 8. What running it changed

Six corrections, all of them from the harness rather than from review, and
none of them visible below a million nodes.

### 8.1 The sketch had a p95 of 51%, which is not a bound

16 HLL registers gave a 16% median and a **51% p95** relative error. The p95 is
the number that decides whether a planner can act on an estimate, and half a
magnitude cannot gate anything. 64 registers cost nothing at rest (the
registers are not kept) and four times the transient build memory, and brought
the p95 to about 22%. The alpha bias constant is register-count dependent and
had to move with it.

### 8.2 A one-sided shortest path explores a component to say "not connected"

The first implementation was a single-source Dijkstra. At 394k edges it
answered a random pair in 148 ms and exhausted its budget on one call in five;
at 3.94M edges, **96 calls in 100**. The cause is not distance, it is
unreachability: a one-sided search must settle the entire component before it
can say there is no path. Two frontiers meeting in the middle settle roughly
the square root of that volume, and the stopping rule keeps the answer exact.
The same pair at 394k edges went from 148 ms to 12 ms, and exhaustion from 20%
to zero.

### 8.3 A confidence floor does not bound a walk; a rank bound does

Trust propagation was bounded by a confidence floor — stop following paths once
belief drops below `floor`. It seemed obviously sufficient and it bounds
nothing: at 3.94M edges, a floor of 0.2 and a floor of 0.05 **both reached two
thirds of a million nodes**, because five hops of 0.65-weight edges still clear
either, and a small-world graph puts most of itself inside five hops.

The fix is that the question was always a top-k one. The walk settles in
increasing cost, which is decreasing confidence, so **the first k nodes it
settles are the k most confident** — stopping there is exact for the ranking.
277 ms with every call over budget became 5.5 ms with none. A related smaller
defect was found on the way: the corroboration pass ran over every settled node
and charged nothing to the budget, so it took longer than the budgeted walk it
was annotating — a bound that is announced and not kept is worse than no bound.

### 8.4 One walk per terminal is |T| explorations of the same neighbourhood

The connecting subgraph ran a Dijkstra per terminal to build the metric
closure: 502 ms of a 500 ms budget at 3.94M edges, exhausted on every call, and
a partial answer. Mehlhorn's variant gets the same 2-approximation from **one**
multi-source walk — each node labelled with its nearest terminal, the closure
read off the edges that cross a boundary. 502 ms became 130 ms, and every
terminal now gets joined.

### 8.5 `built_at` was a transaction timestamp, and the tenancy test found it

The snapshot recorded `now()`, which is transaction start time. Two snapshots
built in one transaction — which is precisely what happens when a session
changes tenant mid-transaction — reported the same `built_at` while holding
different graphs. The rebuild was happening; the field an operator would use to
*see* it happening could not show it. Found by §2.1's test asserting that the
timestamp must move, which is the assertion working exactly as intended: it
failed on the observability of the guarantee rather than on the guarantee.

### 8.6 The first fixture had no communities to find

Label propagation scored 0.02 modularity, which is unreadable on its own — the
method may have failed, or the graph may have no partition. The generator's
sliding locality window makes a continuum, not blocks, so the second reading
was live and had to be ruled out before parking anything. A second fixture with
planted blocks separated them, and moved the verdict from "seems bad" to "finds
0.369 modularity and then fragments three quarters of the graph", which is a
verdict someone can act on. **A measurement you cannot interpret is not a
measurement**, and the fixture is part of the instrument.

---

## 9. The covering: which questions have a mode, and which do not

The goal the dialect is aimed at is a **covering of the questions people
actually ask of a graph** — not a covering of the functions we happen to have.
Those are different lists, and the difference is the whole design.

| The question, as somebody asks it | How it is answered | Why that shape |
|---|---|---|
| "What is this thing called X?" | `LOOKUP` / `FUZZY LOOKUP` | a mode: the first query anyone makes, and the name is always misspelled |
| "What is around it?" | `GRAPH … DEPTH n` | a mode: one and two hops, where the walk beats everything here by two orders of magnitude |
| "What matters most about it?" | `RELEVANCE` | a mode: asked constantly, and generated SQL gets it wrong *quietly* — a depth cap returns the right rows in the wrong order |
| "How are these two connected?" | `PATH "a", "b"` | a mode: the second question every investigation asks, and inexpressible without ranking |
| "What connects these several?" | `PATH "a", "b", "c", …` | the same mode: a shortest path **is** the Steiner tree of two terminals, so three or more is the question generalised, not a second mode |
| "What does the corpus say?" | `TEXT` / `SEMANTIC` / `SEARCH` | three modes because they disagree, and the disagreement is the point |
| "What is here at all?" | `SCHEMA` | a mode: the only query answerable before you know anything |
| "Something none of these cover" | SQL passthrough | the floor, so the dialect never has to grow a mode per question |
| "How much of this rests on a guess?" | `aiq.graph_trust`, **not a mode** | an *annotation on an answer* rather than a question of its own. The right long-term shape is a modifier that adds `confidence` and `support` columns to `RELEVANCE` and `PATH`, and that is a design to do once rather than twice |
| "Who is clustered around this?" | `aiq.graph_dense`, **not a mode** | a specialist analytic. Real, and not asked constantly — which is the test |
| "How big is this before I walk it?" | `aiq.graph_frontier`, **not a mode** | a planner's question, not a caller's. It belongs in whatever decides *whether* to run a query, not in the language for writing one |
| "What is transitively linked at all?" | `aiq.graph_components` / `graph_induced`, **not modes** | bulk primitives called in a loop by code with ids from a previous call. A dialect is for questions written in words |

**Nine modes, six modifiers.** `brief.md` §2 set the budget at seven and six,
and it has been spent twice — on `RELEVANCE` and `PATH` — with no new modifiers
either time, because `DEPTH`, `TYPE` and `LIMIT` already meant here what they
mean on `GRAPH`. The test for spending it again is the one in the table: a
question asked constantly, that generated SQL gets wrong quietly. Not "we have
a function for it".

The modifiers now each have a coherent domain, which is worth stating because
it is what makes the refusals teachable rather than arbitrary:

| Modifier | Where it applies | What it means there |
|---|---|---|
| `DEPTH` | `GRAPH`, `PATH` | bounds a traversal — hops out, or the longest route worth considering |
| `TYPE` | `GRAPH`, `RELEVANCE`, `PATH` | filters a relation on an edge |
| `LIMIT` | everywhere but `SCHEMA` | how many answers |
| `FROM`, `USING` | the three search modes | which corpus, which embedding space |
| `FUZZY` | `LOOKUP` | trigram over `node_keys`, and only there |

`RELEVANCE "x" DEPTH 2` is refused, and the error is the mode's argument in one
line: *it ranks by how much score reaches a node, not by how many hops away it
is.* `PATH "x"` is refused too — one name is neither a route nor a connecting
subgraph, and whoever wrote it wanted `GRAPH` or `RELEVANCE`.

## 9b. What ships, and how it is called

Six functions, all `SECURITY INVOKER`, all resolving names through the one
resolver (`aiq.lookup`) rather than a private copy:

| | |
|---|---|
| `aiq.related(keys[], …)` | what is related to these, ranked |
| `aiq.graph_paths(src, dst, k, …)` | the k cheapest routes, with `as_of` |
| `aiq.graph_connect(keys[], …)` | the smallest subgraph joining them |
| `aiq.graph_dense(key, …)` | core numbers and cliques around one node |
| `aiq.graph_trust(keys[], …)` | confidence and corroboration |
| `aiq.graph_frontier(key, depth)` | how big is the neighbourhood, before walking it |

Plus two operational entry points: `aiq.graph_snapshot(refresh)`, and
`aiq.graph_reach_build(depth)` — which is a maintenance operation with a real
cost, so it is explicit rather than something a query does implicitly. Its
natural home is a `workflow-engine` scheduled task beside the drift check and
the node-registry rebuild (`graph-identity.md` D10): one scheduler, one retry
mechanism, not a third invented cron job.

**Two of them are dialect modes.**

```
RELEVANCE "<key>" [, "<key>" ...] [TYPE <relation>] [LIMIT n]
PATH      "<a>", "<b>" [, "<c>" ...] [DEPTH n] [TYPE <relation>] [LIMIT n]
```

`brief.md` §1.1 budgets seven modes and six modifiers precisely so the dialect
fits in a prompt, and six new modes would spend that budget on questions an
agent asks far less often than it asks `LOOKUP`. `RELEVANCE` and `PATH` are the two that earn
one — §9 is the covering argument and the test it applies. The modes go from
seven to nine; **the modifiers stay at six**, because `DEPTH`, `TYPE` and
`LIMIT` already mean here exactly what they mean on `GRAPH`.

`DEPTH` is refused, and the refusal is the mode's whole argument in one error
message: *it ranks by how much score reaches a node, not by how many hops away
it is.* A caller who writes it is reaching for `GRAPH`, and the error says so.

Three things the dispatch does that the SQL wrapper does not, all of them
because the dialect's envelope is a contract:

- **`unresolved`**, computed the way `LOOKUP` computes it. `aiq.related` drops a
  seed it cannot resolve, which through a JSON envelope makes "no such entity"
  indistinguishable from "that entity has nothing near it".
- **`exhausted`** on the envelope rather than on every row, and only on this
  mode — emitting it on the six that cannot be truncated is how a reader learns
  to stop looking at it.
- **A refusal that names the fix.** These ship switched off (§11), so a fresh
  install answers `RELEVANCE` with a sentence containing
  `aiq.enable_graph_algorithms('<your role>')` rather than a permission error on
  a compiled function the caller has never heard of.

The other five stay SQL-callable. That is a decision to revisit when something
is asking for them, not now — and `brief.md` §3.7 is the map of what calling
one costs, because every one of them crosses the extension boundary.

---

## 10. Promoting a parked proposal

The three parked items are parked on a number, and the rule is the same as
`brief.md` §3.5's core-versus-extension discipline: **a proposal moves when it beats its
number and something needs it, never because it is interesting.**

| Parked | Beats its number when |
|---|---|
| Community partition (I3) | ≥80% of planted blocks recovered at ≥0.4 modularity on `generate_blocks`, cost linear to 4M edges — i.e. Leiden, or LPA with a size constraint and consolidation |
| Landmark labels (I4) | specified as a *bounded* index answering an upper bound from a few hundred hub landmarks, with the bound labelled — a different contract, not this one tuned |
| Fused vector+graph (I5) | fused-search recall beats RRF over the two separate indexes on a query set with known answers, and one incremental insert at 1M nodes is affordable |

And one item that is not parked but is owed: **the shared-memory CSR** (§2.3).
Nothing here depends on it and everything here is bounded without it, but the
per-backend memory is the constraint that decides how large a graph this
surface can serve, and it is the next thing to build if the answer needs to be
"ten million edges" rather than "four".

---

## 11. Deploying it: shipped experimental means present, inert, and off

Everything here installs with `CREATE EXTENSION percolate`. That is a
deliberate choice and it needs a safety argument, because "we shipped an
experiment" is otherwise a sentence that ages badly.

**Nothing runs until it is called.** There is no background worker, no
trigger, no `_PG_init` hook, no shared memory segment and no startup cost. The
snapshot — the only large allocation on this list — is built lazily on the
first call in a backend and released by `aiq.graph_snapshot_drop()` or by the
connection ending. A deployment that never calls these functions carries twelve
catalog rows and nothing else.

**And nobody can call them.** The C functions revoke themselves from `PUBLIC`
in the extension script (`graph.rs` §13) — they are superuser-installed, so
they would otherwise arrive world-executable, and unlike the parser they are
not pure computation over a string. The `aiq.` wrappers repeat the revoke,
because `integration-rbac.sql`'s blanket one runs *before* this file and
therefore never covered them. Neither half is granted to `authenticated` or
`web_anon` on a fresh install, so they are not reachable through PostgREST at
all.

Turning them on is one call, by `app_owner`:

```sql
select aiq.enable_graph_algorithms('authenticated');
-- and back off again
select aiq.enable_graph_algorithms('authenticated', false);
```

It grants the wrappers **and** the compiled functions under them, because the
wrappers are `SECURITY INVOKER` and a grant on only one half is half a grant
that fails at the first call. It does not grant itself — a gate an end-user
role can open is not a gate.

It does grant `aiq.graph_reach_build`, which the first version withheld as "a
maintenance operation with a real cost". That was reasoning rather than
running, and writing the worked example caught it: the sketch lives in the
backend that built it, over the graph *that caller* could see, so a sketch
built by the owner and read by a tenant comes back as `estimate: null` — the
tenant's snapshot is rebuilt under their own fingerprint and the sketch goes
with it. An index only its author can use is not an index. The cost is real and
is bounded by the same budget as everything else here.

`dev/tests/query/11` §7 asserts both halves of this — that a fresh install is
unreachable, and that one call opens it — and the first version of that
assertion failed, because `enable_graph_algorithms` was created after the
blanket revoke and so kept `PUBLIC EXECUTE` itself. That is the exact class of
ordering mistake a posture written only in prose does not catch.

**What is still true when it is on:** every function is `SECURITY INVOKER` and
builds its snapshot through SPI as the caller, so RLS applies (§2.1); every one
is budget-bounded and interruptible, so a hostile or clumsy call costs a
bounded amount of one backend's time; and the memory is per backend, which is
§2.3's constraint and the one thing an operator must size for before enabling
this on a graph of millions of edges.

**The compiled half needs the image.** These are C functions, so a SQL reload
does not carry them: a deployment running an older
`percolationlabs/percolate-postgres:19` gets the wrappers and not the
functions. Every wrapper checks `aiq.graph_algorithms_available()` first and
fails with a sentence naming `dev/build-image.sh`, rather than with
`function p8_graph_ppr(...) does not exist`.

---

## 12. A consumer request, triaged

A downstream consumer — streaming ingest into an entity graph — sent eleven asks
against this surface and `graph-identity.md`. They are recorded here because
several of them changed the code, and because the triage rule is worth stating
once rather than re-deriving per request:

> **Build it if it is the generic shape of the ask. Roadmap it if it is the
> specific one. Decline it if there is no clear home for it here.**

The distinction is not about effort. A connected-components primitive and a
declared "this predicate identifies an entity" flag are both a day's work; the
first is what *every* clustering, blocking or hardening pass is made of, and the
second encodes one consumer's modelling vocabulary and would sit in our schema
with nothing on our side reading it. That is the line.

The declines are not in this document. They went back to the requester with the
reasoning, because a spec is a record of what a system does and a paragraph
explaining what it deliberately does not do for one consumer belongs in the
conversation with that consumer.

### 12.1 Built (§2.4, §5.6, §5.7, and the schema rule)

| Ask | Built as | Why it was generic rather than specific |
|---|---|---|
| build the snapshot over a subset of relations, above a weight floor | `aiq.graph_snapshot(refresh, relations[], weight_floor, as_of)` | "walk part of the edge table" is what every consumer with a large one eventually needs; theirs is the first to be blocked on it, not the only one it serves |
| connected components | `aiq.graph_components(min_size, budget_ms)` | union-find over the CSR is the most reusable graph primitive there is, and it was already on this document's own candidate list under resolution blocking |
| the internal edges of a node set | `aiq.graph_induced(node_ids[], relation, as_of)` | a round-trip fix, not a compute one, and the round trip is the same for anyone doing per-cluster work |
| canonical ordering for symmetric relations | `relation_types.is_symmetric` + normalisation in the catalogue trigger | **this was a defect on our side, not a feature request.** See below |

**The symmetric rule was more urgent than the request framed it.** They asked
for it so consumers would stop deduplicating by hand. The sharper problem is
that every read path here unions out-edges with in-edges, so a pair stored as
both `(a,b,r)` and `(b,a,r)` is *traversed twice*: personalised PageRank gives
that neighbour twice its share of the mass, and k-core reads the degree as two.
A wrong number rather than an error, and one nothing would have caught.
`graph-identity.md` carries the rule; `dev/tests/query/11` §7 asserts it.

Two departures from what was asked, both recorded because they will look like
oversights otherwise. It is **normalisation on write, not a check constraint** —
a check cannot reach `relation_types`, and a rule the writer must know before it
can insert is a rule every writer gets wrong once. And the column is
**`is_symmetric`**, because `SYMMETRIC` is a reserved word in SQL and the
obvious spelling is a column that must be double-quoted at every use site
forever.

### 12.2 Roadmap — useful, narrow, and staying in the client for now

**`identifying` on the relation catalogue.** A declared flag meaning *two
subjects sharing a value for this relation are the same entity* — an email, a
ticker, a registration number. The argument for declaring it rather than
measuring it is good and is worth keeping: the measured version (inverse of the
mean distinct subjects per object value) correlates well in general but reads
**low on exactly the predicates that matter**, because an identifier's fan-in is
inflated by the very aliases you are trying to merge. So it is not redundant
with the measurement; it is what you have before the measurement is trustworthy.

It is not built because nothing here reads it. A column stored and never
consumed is schema ahead of a consumer, which this collection has a standing
rule against — `build-sql.py`'s own `NOT_SHIPPED` list is that rule enforced.
When something on this side needs the notion, that paragraph is why it will be a
declared boolean rather than a computed score.

**The resolution ledger, with a run id and a canonical projection.** Three of
the eleven asks were additions to `node_resolutions`. The finding that matters
more than any of them: **`node_resolutions` is specified in `graph-identity.md`
and is not built** — four mentions in prose, zero in SQL. D11 is a design
commitment with no implementation behind it, which is worth knowing before
anyone plans around it.

That turns the asks from additions into "build the ledger, with these two
properties from the start", which is better scoped and should be done once:

- **`run_id`** on each resolution, identifying the pass that produced it.
  `decided_by` already records the resolver *version*; `run_id` distinguishes
  two passes by the same version at different thresholds, which is what makes a
  pass revertible as a unit and "what changed between run N and N+1" a query
  rather than a reconstructive diff.
- **A maintained `node_cluster(node_id, canonical_id)` projection** rather than
  path compression per query. `node_resolutions` is a forest and every read path
  needs its closure; each consumer writing its own recursive CTE is how a second
  source of truth starts. Same argument D6 makes for projecting nodes at write
  time, one level up.

It stays on the roadmap because the identity ledger is not a table to design
against a single consumer, and this request is currently the only thing asking
for it. Resolution stays with the consumer meanwhile — which their own numbers
say is nearly free: on their fixtures, not merging at all scores 0.605 and a
tuned merge heuristic scores 0.608, while over-merging drives it to 0.021. The
asymmetry is the whole argument for D11 and it is worth having in this document:
**leaving two things apart costs almost nothing; putting two things wrongly
together costs everything.**

### 12.3 What the request confirmed

Three properties were flagged as depended-upon rather than requested, and all
three hold:

- **`unique (src_id, dst_id, relation)` as a multi-edge discriminator.** A pair
  can carry one edge per kind of evidence, and nothing here collapses them: the
  snapshot stores each edge with its own relation and weight, and parallel edges
  between a pair each carry their own mass in a walk. Their reason for caring is
  worth recording — two channels that had been summed into one number turned out
  to carry *opposite* meanings, one saying "these are the same thing" and the
  other "these are related and therefore different", and it was only visible
  because the numbers were separate.
- **Resolution as a record, not an index behaviour.** Unchanged; see §12.2 for
  the state of its implementation.
- **Derived-index maintenance on the workflow queue.** Already how the one index
  build here behaves: `aiq.graph_reach_build` is an explicit maintenance entry
  point, deliberately not a query-time side effect, whose intended home is a
  `workflow-engine` scheduled task beside the drift check. No bespoke scheduler,
  and none planned.

One number came out of answering them that belongs here rather than in a reply,
because it is a property of this schema and everyone writing to it will meet it.
The catalogue check is a per-row trigger, and on a bulk load it costs **15 µs an
edge at 40k edges and 35 µs at 3.94M** — roughly three times the insert itself,
growing with the graph because it looks up both endpoints' types. That is the
price of the catalogue being a guarantee rather than a description, and
`graph-identity.md`'s bulk-load path (triggers off, load, one set-based
revalidation) is what it is there for.
