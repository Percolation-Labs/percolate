# The claims layer

**Status:** brief, 2026-09-06, written against Percolate's own unpublished design draft
(claims-layer spec, draft 0.3); section numbers prefixed 'source' refer to it. This file
is the part that only someone inside Percolate can write — what the primitives
are actually called here, what already exists, and the four questions Appendix A
left open because the author did not have the development-engine notes.

**A second tenant, 2026-09-18.** [`graph.md`](graph.md) specifies the same layer for the
Percolate application's claims: identity across revisions and packages, assertions made in
transactions, and as-of reads. §16 there maps this brief's claims onto that substrate.

**Where it sits.** A cross-cutting layer over the extension's subsystems; it needs no new
mechanism, only a data model they share.

## 1. The whole idea, in one sentence

**A falsifier-typed claim, anchored to a symbol, re-asserted on the diff that
touches it.**

Everything either side of that sentence is built and published by somebody.
Structural code graphs are commoditised and free. Knowledge graphs with
lifecycle are proven — MOOSEDev returns 0.98–1.00 on supersession,
set-completeness and negation where top-k vector retrieval returns 6–27%.
Specifications have a grammar (EARS) and a tool ecosystem. Nobody has connected
them, and the connection is **two fields and a loop**: a `falsifier` column, an
`anchored_at` edge, and a trigger with a diff as its stimulus.

## 2. The two properties that matter

Everything else is negotiable.

**Falsifier typing.** Every claim declares *how it is checked*. This is the
anti-rot mechanism and it is why this differs from every predecessor: UML
round-tripping, MDA, architecture documentation and ADRs all died of prose that
drifted, and lifecycle status is a *manual* answer to staleness where a falsifier
is a mechanical one.

**Change-triggered re-assertion.** Claims are excited by diffs, not read on
demand. MOOSEDev's retrieval is agent-initiated: it improves what an agent finds
when it thinks to look, and does nothing about the case where it does not think
to look — which is the case that produces incidents.

## 3. What this is not

Taken straight from the source, because each one is a trap we can afford:

- **Not a retrieval product.** The graph buys *nothing* on ordinary relevance
  recall or token cost against vector memory. That is the published result and
  reproducing it is a validity check, not a failure. Anything sold as "better
  context" competes exactly where the graph demonstrably does not win.
- **Not a structural code graph.** Take an MIT one.
- **Not new notation.** EARS exists.
- **Not a separate store**, which is §7.2 of the source and the reason this
  belongs here at all.

## 4. Why a multi-modal database is the argument, not a preference

The claims layer needs all four modes **on the same objects at once**:

| mode | carries | here |
|---|---|---|
| relational | claim rows, discharge results, exception scopes, expiry | ordinary tables |
| graph | `anchored_at`, `depends_on`, `supersedes`, `exception_of` | `aiq.nodes` / `aiq.edges`, and the relation catalogue refuses an unlisted triple |
| vector | semantic recall over prose claims and rationale | `content.resource_chunks` + a registered embedding space |
| key-value | discharge cache, anchor resolution state, run artifacts | `jsonb` columns, `workflow.runs.context` |

Split those across four systems and a supersession query — the exact shape that
beat vector memory 0.98–1.00 against 6–27% — becomes a join across a graph
store and a relational store with a vector store consulted separately. That is
the *expressive* argument made from the demand side.

## 5. The mapping, which is the part only we can write

The source specifies a system. Percolate already has most of its parts under
different names, and Appendix A explicitly asks for ours to be used rather than
a parallel vocabulary.

| source calls it | here it is | built? |
|---|---|---|
| a claim is a model, so a table, so an agent | `agentic.agents` rows are tables; an entity type is a registration (`aiq.register_entity_table`) | **yes** |
| falsifiers are registered functions, searchable, activated by name | `workflow.register_step_function(name, fn, arg_types, timeout, description)` | **yes**, and it already lints an unregistered call |
| the trigger is a query wave, not a pipeline step | a workflow document: `sql` steps run in-database with no worker, `matrix` fans out from a query result inside the transaction that completes its parent | **yes** |
| claim types are subclasses, not a config enum | a vocabulary table with a foreign key, per the push-down rule (not an enum) | **yes** |
| anchors resolve on every incremental index | nothing. **This is the build.** | no |
| the four edges | `aiq.relation_types` triples; the catalogue refuses an unlisted one at write | table exists, triples do not |

**So the trigger drops off the build list**, exactly as §13 says: in the data
tier it is a query plan over registered functions rather than a service. What
is left to build is the claim model, the anchoring, and the extraction
composition.

## 6. Appendix A, answered

The source was written without the development-engine notes and flags four
things likely to change. Three of them we can settle.

**§9 step boundaries — use the engine's stages.** The five steps (radius,
select, discharge, residual, emit) are the author's reconstruction. They map
onto a workflow document without a parallel vocabulary: radius and select are
`sql` steps over the catalogue and the edges, discharge is a `matrix` step that
fans out one task per registered falsifier, residual is an `agent` step, emit is
the run's output. One document, no new engine.

**§7.3 claims as agents — yes, and it is not a pun here.** The general position
that every agent is a table is already this collection's, and the consequence
the source wants (a claim can be asked to re-assert itself; its falsifier is the
tool it activates) falls out of `agentic.agents.tools` being a binding rather
than code.

**§14 tenancy — the development engine is the first tenant.** The source
assumes this and is right, and we have the evidence: an internal
self-model application already loads the development repository into
Percolate — 2,854 nodes, 8,271 edges, a claim × deployment matrix — using only
the existing subsystems and nothing claims-specific. It is an application, so the
claims layer is core and the engine is its tenant, not the reverse.

**§15 phasing — Phase 1 is partly instrumentation, not a build.** The source
says Phase 1 is schema plus tier-3 mining. Here, tier-3's inputs are already
rows: 12 postmortems, 237 eval `because:` lines, 4,550 (commit, file)
pairs and 21,979 session events are loaded and queryable today. Phase 1 is therefore
mostly *typing* what exists rather than extracting it.

**The one we cannot settle** is §18's first bullet, granularity: how coarse a
claim should be. Too fine and it is a lint rule, too coarse and it is
unfalsifiable. The source calls it probably empirical per domain and that is
right; the self-model is the instrument that would answer it.

## 7. Anti-rot rules — non-negotiable, adopted verbatim

Every predecessor died here, so these are copied rather than reinterpreted.

1. A claim declares a falsifier **or** an expiry. No exceptions.
2. Prose claims rank below executable ones in surfacing order, and expire
   without sentiment.
3. A claim that fires falsely twice is auto-demoted. Otherwise the ignore file
   arrives.
4. Supersession is a first-class edge, never a delete. History is the asset.
5. An exception carries its own expiry, independent of the claim.
6. Orphaning surfaces **once**, then expires. Silent orphans are the rot vector
   wearing a new hat.
7. Claim text is readable by a human without the tooling. Storage in the data
   tier is not an excuse for opacity.

Rule 1 replaces the `expires` date this collection had already designed for
itself and got wrong: a date says a claim is old, a falsifier says it is wrong.
The freshness fingerprints built in an internal self-model application are the
*mechanical* half of rule 1 and are not a substitute for it.

## 8. Anchoring is the technical risk

Stated plainly because it is the thing nobody has demonstrated: **a claim bound
to a line number is dead on the first refactor.** Anchors resolve on every
incremental index, not on read, in this order:

1. **Exact** — fully qualified name matches. Cheap, covers most changes.
2. **Content** — body hash matches a symbol elsewhere. Catches moves and renames.
3. **Structural** — call/import neighbourhood overlap above a threshold against
   the pre-change graph. Catches split and merge, approximately.
4. **Orphan** — nothing resolves.

Multi-anchored claims survive while *any* anchor resolves, and a cross-cutting
claim is anchored to every symbol it constrains, which is what makes it
cross-cutting. Orphaning is an **event, not a cleanup**: the refactor that
deleted the anchor may have deleted the reason, or quietly violated it. Never
auto-delete an orphan — demote and keep it for supersession history.

**We have half of this already and should not pretend otherwise.** Exact
resolution is a join against `pg_proc` and works today. Content hashing is the
`subject_fp` fingerprint already computed in the self-model. Structural
resolution needs the pre-change graph, and nothing here stores one.

## 9. Extraction, cheapest first

| tier | source | cost | note |
|---|---|---|---|
| 1 | types, signatures, existing tests, static analysis | **free** | already discharged. Persist only the **exceptions** to them |
| 2 | dynamic invariant inference, adversarially filtered | cheap | Daikon proposes, generated counterexamples attack, survivors persist. ClassInvGen beats both Daikon and pure-LLM generation |
| 3 | **history** — reverts, bug-fix commits with linked issues, incident postmortems, review comments containing warnings, ADRs | expensive | SZZ locates the introducing commit; AgenticSZZ reframes it as search over a temporal graph of history |
| 4 | human | residual | if this is large the economics fail, and we know within one repo |

**Tier 3 is where the rejected alternative lives, and the rejected alternative
is what distinguishes a claim from a lint rule.** It is also the least reliably
mineable thing in the list, and §17 names that as a kill criterion: if tier 3
yields assertions without rationale, the exception layer becomes tier 4 only and
the whole thing gets re-priced.

**And it is worse than expensive: the rationale is largely not there to mine.**
A repository is the record of the branch taken with the branch point deleted —
git records that a node id is `md5(sha)::uuid` and nothing records that the
`gen_random_uuid()` default was the *more* plausible option and why it lost. So
tier 3 recovers what somebody happened to write down, which is systematically
the options that were close. The decision model, kept in an internal application, is the response:
capture the rejected alternative at the moment of the decision, where it costs
nothing, instead of reconstructing it afterwards, where it cannot be done
faithfully at any price.

Tier 1 is the rule the development repository keeps rediscovering: **do not persist a claim
the compiler already discharges.** A type is a claim discharged for free.
Deriving a claim does not remove it from the graph; it moves it to a cheaper
edge.

## 10. Writes from agents land as `proposed`, never `active`

Promotion needs a human or a passing falsifier. Without that gate an agent
writes its own justification for the change it just made, and the graph records
what happened rather than what should hold.

This is a policy that pushes down: `status` is a vocabulary table with a foreign
key, and the promotion path is a `SECURITY DEFINER` function that checks a
permission, so an agent physically cannot write `active` — which is a stronger
statement than a convention and is what the push-down rule asks for.

## 11. What would kill it

Adopted from §17 with our own numbers where we have them.

| risk | signal | response |
|---|---|---|
| mined claims are cheap and static | cross-cutting fraction < 20% in Phase 1 | kill; we built a linter |
| the trigger over-surfaces | median > 15 claims per change | fix selection or kill |
| maintenance exceeds re-derivation | claim-authoring hours rising per sprint | kill — camp R's cost with camp E's promise is the worst arrangement available |
| anchors do not survive refactors | orphan rate > 10% per month | §8's resolution order is insufficient; this is *the* technical risk |
| agents write their own justifications | proposed claims correlate with the writing agent's own diffs | §10's gate; audit it |
| dogfooding substitutes for evidence | no public replay published | a discipline risk, not a technical one |

**And the strongest argument against the whole design**, which strengthens every
six months: if a model gets cheap enough to re-derive rationale from history at
query time, a maintained graph is an index with an expiry date.

**The one part of the graph that argument does not reach** is the rejected
alternative. No model re-derives what was never written down, however cheap it
gets, because the options nobody took are not in the history to be mined — which
is why the decision model is authored rather than extracted, and why
it stays load-bearing at any inference price.

## 12. Evaluation

**Retrospective replay is the only evidence that moves a reliability-first
reader.** Take historical incidents and reverts, reconstruct the graph as of the
parent commit using *only* data available then, and ask two questions
**reported separately**:

- **Existence** — did the violated claim exist in the graph?
- **Selection** — would the trigger have surfaced it on the offending diff?

High existence with low selection means the anchoring is wrong, not the claims.
Collapsing them into one number hides exactly the thing worth knowing. SZZ
supplies the labels. Runnable on public repositories, so it can be published —
and §14's rule is **dogfood for the story, publish the replay for the proof**,
because a strong result on your own corpus with the transcripts withheld is
the criticism earlier systems drew, and we do not get to repeat the mistake.

The retrieval benchmark is adopted wholesale: B0 (no memory), B1-notes (flat
files), B1-mem0 (vector), **B1-rag (BM25 over our own content, flattened)**, then
the full system. B1-rag is mandatory — it is what separates a structural claim
from a better-corpus claim.

## 13. Build order

**Phase 1 — schema and tier 3 only.** Mine reverts and fix commits, anchor to
symbols, surface claims in the structural radius on each change. No falsifier
typing, no discharge, no edges. Exit: cross-cutting fraction ≥ 20%, median
claims per change ≤ 5 and p95 ≤ 12, sampled reviewer relevance ≥ 50% useful.

**Phase 2 — falsifier registration and discharge.** Tiers 1–2, the adversarial
filter, the four-bucket output. Exit: ≥ 60% of surfaced claims discharged
without a model; false-fire rate below one per change.

**Phase 3 — edges and propagation.** Cheap here, so earlier than the source's
0.2 had it, but still after Phase 1 answers whether the claims are real. **Every
predecessor built this first and died.**

The four output buckets are re-asserted, failed, stale, and
**touched-but-unfalsifiable**. The fourth is the honest one and nobody currently
prints it. Re-asserted claims are counted, not listed — nobody reads a list of
things that passed.

## 14. The decision layer

The decision model records **the options that were live, scored, with the
one taken marked.** Inside this layer rather than beside it: a claim says what
must hold, a decision says what we chose and what we rejected, and they need the
same anchoring, the same supersession-not-delete rule and the same vocabulary
tables. It answers §9's kill criterion directly, and it carries one structural
finding that lands before Phase 3 of [`sequence.md`](sequence.md) commits to a
shape: **`depends_on` between two claims is usually a shared decision.** Two
claims move together because one decision constrained both, and modelling that
claim-to-claim loses the reason and pays n² edges for it.

A model and a twenty-eight-decision sample exist in an internal application; nothing is in the extension.

**A decision needs a falsifier for the same reason a claim does, and this is
the strongest argument for keeping them in one layer.** §2 says a claim earns
its keep by being falsifier-typed: state what would have to be observed for
this to be wrong, or the claim cannot do any work. A decision's version of that
is a revisit condition — the thing that, if it became true, means reopen this.

The decision model already maps `falsifier` onto `why_not`, and
that mapping is right but it points BACKWARD: a `why_not` says what was wrong
with an option we did not take. The measurement over the sample turns that into
a second asymmetry, distinct from the one the decision model is built on, and
sharper than expected:

| | recorded |
|---|---|
| rejected options carrying a `why_not` | **39 of 39** |
| decisions carrying a `revisit_when` | **1 of 28** |

Every road not taken records why it was wrong. Almost no road taken records
what would make it wrong. The layer built precisely to preserve what the
working tree cannot hold turns out to preserve the backward-facing half in
full and the forward-facing half not at all — which is exactly why a decision,
once made, never decays.

Twenty-seven have none. Nine of those are hubs
that other decisions depend on, and they carry 146 of the ledger's 153
exposure, where exposure is reach times cost to undo. The heaviest is
`arch.postgres-is-the-system` — twenty-five decisions standing on it, marked
irreversible, and no condition under which anybody would look at it again.

The symmetry is exact and so is the failure:

| | cannot fail | count |
|---|---|---|
| a claim with no check | nothing can report it broke | 46 |
| a decision with no revisit condition | nothing can report it is stale | 27 |

Both look healthy for the same reason, which is that nothing is capable of
reporting on them. The difference is visibility: a missing test reads as a gap
to everyone, while nobody expects a decision to carry a falsifier, so its
absence reads as nothing at all.

An attempt to generate the missing conditions found the limit of the
extraction contract in §10. A model proposed one per hub from the `why_not` of
the strongest rejected option, quoting it verbatim, and nine of nine quotes
verified against the ledger — but only about four of nine were usable. The
rest were tautological: *"revisit if the coordination problem is resolved
without introducing seams between systems"* is the decision restated as its own
negation, and nothing could ever observe it.

So citation checking establishes provenance and not usefulness, and the second
signal it needs is the falsifier itself: **a proposed condition must name what
would evaluate it.** The four usable ones all point at something the repository
can be queried for; the four useless ones name a state of the world nobody can
check. That is §2's typing requirement doing work at proposal time rather than
at review time, and it is one mechanism serving both halves of this layer
rather than two.
