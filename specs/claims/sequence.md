# Sequence — the claims layer

A gate is a thing that either happens or does not, run against a live database.
Each phase proves itself before the next starts, and the exit criteria were set
**before** running, per the house style and the source's §15.

## Phase 0 — the corpus is already here (instrumentation, not a build)

Appendix A of the source guesses that Phase 1 might be instrumentation rather
than a build if the engine already loops over its own repository. It does.
An internal self-model application loads the development repository into Percolate today:
2,854 nodes over 8 entity types, 8,271 edges, 920 retrievable passages, and a
claim × deployment matrix.

So Phase 0 is a **re-typing**, not an extraction: the self-model's `claims`
table is already 265 surface declarations and 217 eval assertions, anchored to
`pg_proc` by oid. What it lacks is exactly the two fields the source names.

**Gate 0.** Every existing self-model claim carries a `falsifier` of the correct
type, or an expiry. Measured: the count that acquire one mechanically (a surface
row's `invoke` **is** its falsifier reference) versus the count needing a human.
If the second number is large, tier 4 dominates and the economics are already
in question.

## Phase 1 — schema and tier 3 only

Mine reverts and fix commits, anchor to symbols, surface claims in the
structural radius on each change. **No falsifier typing, no discharge, no
edges.** Every predecessor built the edges first and died.

**Gate 1**, all three, on the development repository:

| | target | why this number |
|---|---|---|
| cross-cutting fraction | ≥ 20% | below this we built a linter, and §17 says kill |
| claims surfaced per change | median ≤ 5, p95 ≤ 12 | above 15 the verification tax moved rather than being paid |
| sampled reviewer relevance | ≥ 50% useful | a person reads twenty and says which mattered |

**And the honest one:** the retrospective replay, existence and selection
reported **separately**. High existence with low selection means the anchoring
is wrong rather than the claims. One data point exists already and it is a
partial hit — the self-model surfaced the right postmortem for
`aiq.register_entity_table` and it named a different defect in the same
function.

## Phase 2 — falsifier registration and discharge

Tiers 1–2, the adversarial filter, the four-bucket output. Falsifiers are rows
in `workflow.step_functions`, so adding a falsifier type is a registration
rather than a release.

**Gate 2.** ≥ 60% of surfaced claims discharged **without a model**, and a
false-fire rate below one per change. A claim that fires falsely twice is
auto-demoted, and that rule is a trigger rather than a convention.

**The discharge plan is discovered, not hardwired.** Register the falsifiers and
let the plan form — which in the data tier means a `matrix` step fanning out one
task per applicable registered function, decided by a query inside the
transaction that completes its parent. Hardwiring the pipeline is the residual
sidecar thinking the source spent draft 0.3 removing.

## Phase 3 — edges and propagation

`anchored_at`, `depends_on`, `supersedes`, `exception_of` as
`aiq.relation_types` triples. Cheap here because the graph exists, which is why
this moves earlier than the source's 0.2 had it — but still **after** Phase 1
answers whether the claims are real.

**And `depends_on` is the one edge to test rather than assume.** Two claims
usually move together because one *decision* constrained both, so the
claim-to-claim edge may be losing the reason and paying n² for it.
The decision model, kept in an internal application, has the alternative already loaded — the
dependency stated on the option, `constrains` derived from it — over
twenty-eight decisions. Measure both shapes on that corpus before this phase
commits to one; it is cheap now and expensive after the edges exist.

**Gate 3.** A supersession query returns the current version of a decision with
recall ≥ 0.95 against a hand-labelled set, and the same question through B1-rag
(BM25 over the same content, flattened) does measurably worse. If BM25 matches
it, the graph is not earning its keep and we have reproduced the source's own
equivalence finding in the place it is supposed to win.

## The benchmark, adopted wholesale

B0 (no memory) · B1-notes (flat files) · B1-mem0 (vector) · **B1-rag (BM25 over
our own content, flattened)** · full system.

B1-rag is **mandatory**. It is the ablation that separates a structural claim
from a better-corpus claim: if the advantage came from better material rather
than from structure, BM25 over the same material captures most of it.

Expect equivalence on relevance recall and token cost. That is the published
result; reproducing it is a validity check, **not a failure**. The win is
supersession, set-completeness and negation — and our addition, the trigger.

## What stops the sequence

Any of [`brief.md`](brief.md) §11's kill signals firing. The one to watch first is the orphan rate: if
anchors do not survive refactors above 10% per month, the resolution order in
`brief.md` §8 is insufficient, and that is the technical risk the whole design
rests on rather than a tuning problem.
