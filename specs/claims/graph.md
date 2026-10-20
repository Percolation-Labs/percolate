# The claims graph

**Status:** specified 2026-09-18. Steps 1 and 2 of §15 are built in extension 0.2.11, step 3 in 0.2.12 and steps 4 to 6 and 9 in 0.2.13, with step 7's core half and step 8 (`specs/claims/schema.sql`, REM-473 to REM-481, REM-496), and the rest is unbuilt. The spike in §14 has chosen the physical design: typed append-only
tables, recursive CTEs, and Datalog as the language the derived readings are specified in.
Answers REM-434 (what identifies a claim) and proposes answers to REM-432 (what a
relationship between two claims is). Sections name the extension version they describe.

**Where it sits.** This is the claims layer of [`brief.md`](brief.md) with a second tenant.
The brief's tenant is the development engine: claims about code, anchored to symbols and
checked by falsifiers. This file's tenant is the Percolate application: claims that readers
and writers make about the world, extracted from documents and checked against sources and
outcomes. The two share one substrate, and neither owns it: an entity with a stable
identity, immutable assertions about it, and transactions that say who asserted what, when
and why. §16 says what each tenant adds on top.

**Why core and not the application.** Identity, immutability, as-of reads and access are
properties the database must refuse to violate. The application can present a claim graph.
It cannot make an assertion immutable or keep a private draft's claim out of a stranger's
count. That is the push-down rule: a fact
belongs at the lowest layer that can refuse a violation of it.

---

## 1. What a person does with it

**A writer** drafts a package. Their AI extracts the claims, the sources each claim cites,
the people, organisations and studies it mentions, and the edges between claims (this
supports that, this limits that). When the writer revises, each claim in the new draft
either is the claim it was (reworded or not) or is a new one, and the graph records which.
When they publish, their AI asks which existing claims theirs already are, and the answer is
recorded as a proposal that a person can confirm (REM-435).

**A reader** opens a claim, not a package. From it they can walk to:

- the question it answers, and the other answers to that question, grouped by stance;
- the evidence it cites, counted by independent origin, not by document;
- what it rests on, and anything that challenges those, however many steps back;
- who endorsed it, who opposed it, and what each of them checked;
- how it has changed: which revision of which draft first said it, and what each later
  revision did to it;
- how it has closed: still open, settled by a consensus of independent origins, or resolved
  by an event, with when, by whom and how (§12).

**The graph is the product.** A package is one writer's path through it, and a reader can
take a different path (decided 16 September, REM-432). The package stays the unit of writing
and publishing. The claim becomes the unit of reading, trust and history.

## 2. What core has today

Pinned at extension 0.2.11.

| Need | Core today | Gap |
|---|---|---|
| A document with versions | `research.works`, `research.revisions`: immutable, content-hashed, with actor, credential, run and reason (REM-151, 237, 464) | none |
| A claim | `research.claims` is the occurrence, one row per `(revision_id, claim_key)`; since 0.2.11 each `expresses` a `claims.claims` row minted with `uuidv7()` and carried across revisions (REM-473) | none within one work; across works, §5's `same_as` is unbuilt |
| Edges between claims | `research.argument_edges`: six relations, within one revision | no edges across revisions or packages, no index beyond the primary key |
| A claim's frame | in the revision's `document` JSON only | the projection drops it; frames cannot be queried |
| A cited study | `research.sources.origin` and `url`, grouped at read time by a normalised key (REM-219, 430) | the study is a key, not an entity |
| Endorsement of a claim | `research.endorsement_claims`, pinned to the endorsed revision by composite key (REM-154) | endorses an occurrence; nothing rolls it up to the claim |
| Opposition | none | none anywhere |
| Cross-package stance | the application's comparison documents, proposed and confirmed (REM-212, 213) | stored in the application, not core |
| History, as-of | `research.refuse_rewrite`, `research.trust_state(public_id, at)` (REM-464) | per work, not per claim |
| Bitemporal edges | `aiq.edges` with `valid_from`, `valid_to`, retraction, belief periods (REM-51, 65) | no per-assertion actor, status or proposal |
| Outcomes | `tradecraft.resolutions`, in a held-out tradecraft resolutions draft | not installed |

Three claim shapes exist and are unreconciled: `research.claims` (core, shipped),
`market.claims` (the market draft REM-563 retired, never built) and the
self-model's `claims` (an internal self-model application). §16 retires the second and
maps the third.

## 3. The model

Five kinds of thing. Everything else is an assertion about them, made in a transaction.

```
                      ┌────────────────────────── tx ─────────────────────────┐
                      │ who (person | agent | platform), credential, model,   │
                      │ run, reason, at                                       │
                      └───────────────────────────┬───────────────────────────┘
                                                  │ every assertion is made in one
                                                  ▼
 ┌─────────────┐  expresses   ┌─────────────┐  answers   ┌──────────────┐
 │ Occurrence  │─────────────▶│   Claim     │───────────▶│   Question   │
 │ revision,   │              │ (identity   │            │ subject,     │
 │ claim_key,  │              │  only)      │◀──┐        │ outcome, …   │
 │ text, frame,│              └─────────────┘   │        └──────────────┘
 │ locator     │                 │   ▲          │ supports, challenges,
 └─────────────┘                 │   │          │ contradicts, agrees, qualifies,
    │ cites         same_as,     │   │          │ limits, refines, …
    │ mentions      supersedes   └───┘──────────┘
    ▼
 ┌─────────────┐   ┌──────────────┐
 │   Origin    │   │   Entity     │   a person, organisation, product, dataset, place
 │ the study   │   │ (aiq.nodes)  │
 └─────────────┘   └──────────────┘
```

**Claim.** A proposition with an identity and nothing else. Its id is minted once, as
`uuidv7()`, and never changes, is never reused and is never computed from text. A claim has
no text of its own: its text is whatever its occurrences say, and a reader sees the text of
the occurrence they arrived through, or of the latest revision that expresses it. Where an
occurrence says several things, the claim's text is the gloss on its part (§5, *Parts*): the
gloss on the latest confirmed `expresses`, as for whole occurrences.

**Occurrence.** A claim as written in one revision: `research.claims` as it is today, plus
the frame (§7) that the projection currently drops. An occurrence is immutable because its
revision is. It keeps `(revision_id, claim_key)` as its key, so every existing foreign key
(citations, argument edges, endorsement claims, comments) still holds. An occurrence expresses
one claim by default and may express several, one per atomic proposition (§5, *Parts*).

**Question.** What a claim answers, identified by its frame's comparable slots (§7).
Two claims can agree or contradict only if they answer the same question. That rule already
governs comparisons in the application; this makes the question a
thing you can walk to.

**Origin.** The study, dataset or primary document that evidence descends from. Today it is
a normalised key computed at read time (REM-430). As an entity it has identity attributes
(DOI, normalised URL, declared origin text), and two keys that turn out to name one study are
joined by an assertion, not by rewriting either.

**As built (0.2.13, REM-477).** `claims.study_key` is the application's REM-430 key, moved into core: the DOI, else
the address without scheme, `www`, query or trailing slash, else the folded words. It gave the same key as the
application on all 195 origin, address and frame-origin strings in the live corpus (19 September). An occurrence
`cites` the origin each of its sources names by origin text and by address. A source naming two keys is evidence
that they are one study, and the platform asserts that in `claims.origin_links`. **A title never bridges two
addresses:** on the live corpus one title labels both a paper and its data file, so a title belongs
to a study only when every address it is linked to is in that one study. Measured against the application's
per-key grouping over the same corpus, the same 32 claims share a study both ways. Core reports fewer groups for 18
of them, because it counts a source's title and address once, and never more.

**Measured, 24 September (REM-668).** The key names the document, and independence belongs to the study. On 41 live
packages, 5 of 98 multi-source claims count one study twice (a paper and its press release), core splits 7 of 14
studies cited across packages (preprint and journal DOI), and 30 of 251 sources say in their origin text that they
report another study, which `source_studies` passes over for the URL. REM-589 owns the fix.

**Entity.** Anything else a document mentions. These are `aiq.nodes` of registered entity
types, and the claims graph links to them rather than copying them.

**Assertion.** One statement about one or two of the above, made in one transaction:

| field | meaning |
|---|---|
| `id` | the assertion's own id, so a later assertion can be about it (a confirmation, a dispute, an endorsement) |
| `subject`, `predicate`, `object` or `value` | what is said. `predicate` is a row in the vocabulary (§6), never free text |
| `tx` | the transaction that made it |
| `op` | `assert` or `retract`. A retraction is a new assertion; nothing is updated or deleted |
| `status` | `proposed`, `confirmed` or `disputed`, itself changed only by later assertions |
| `evidence` | the occurrences, spans and revisions it rests on, which decide who may read it (§9) |

**Transaction.** Who made a set of assertions, as what (person, agent or platform), with
which credential, model and workflow run, why, and when. It is the pattern
`research.revisions` already follows for documents (actor, credential, run, reason),
applied to every assertion. A transaction is immutable, and it is itself readable as data:
"everything this agent asserted on 16 September" is a query, not a log search.

## 4. What we take from Datomic, and what we refuse

Datomic's model is the reference because it answers the questions this product asks: what
was known when, who said so, and what changed. We adopt its ideas, not its storage.

| Datomic | Here | Adopted? |
|---|---|---|
| A datom `[e a v tx added]` | an assertion: subject, predicate, object/value, tx, op | yes, with status and evidence added |
| Facts are never updated; retraction is a new fact | `op = retract`; `research.refuse_rewrite` generalised to assertions | yes |
| Transactions are entities with their own attributes | `tx` rows carry actor, credential, model, run, reason | yes, and this is where the proposal/confirmation record lives |
| `as-of`, `since`, `history` databases | `claims.as_of(t)`, `claims.since(t)`, `claims.history(entity)` read functions | yes |
| Schema as data: attributes with cardinality, uniqueness, value type | the predicate vocabulary (§6), rows with foreign keys | yes |
| Unique identity attributes and lookup refs | an origin found by DOI or normalised URL | yes |
| Excision | `research.erase_work` extended to assertions (§13) | yes |
| Entity ids with no meaning | `uuidv7()` claims, never derived from text | yes |
| Datalog with recursive rules | Datalog as the **specification** of each derived reading (§6); recursive CTEs that start at the anchor as the implementation | **decided** by the spike (§14) |
| One untyped datom table for everything | typed, append-only tables, one per predicate family, each row naming its transaction | **refused** by the spike (§14): 5× the storage, and access needs typed side tables anyway |
| A peer that caches the whole database | no. Access is decided in Postgres before anything is read | refused |
| Last-write-wins on cardinality-one attributes | a disputed claim keeps both assertions, and the reader sees the dispute | refused |

The last row is the main departure. Datomic resolves a cardinality-one conflict by keeping
the latest value. A claims graph must not: two people asserting different things about one
claim is the information, and "latest wins" would erase the disagreement Percolate exists to
show.

## 5. Identity

REM-434's first question, in three scopes. They are different questions and get different
answers.

### Within a revision

`(revision_id, claim_key)` identifies an occurrence, as today. Nothing changes.

### Across revisions of one work

When a new revision is projected, each occurrence is linked to a claim by an `expresses`
assertion made by the platform in the revision's own transaction:

| The occurrence's claim_key | Its text (normalised) | What the platform asserts | Status |
|---|---|---|---|
| existed in the predecessor | unchanged | expresses the same claim, method `unchanged` | confirmed |
| existed in the predecessor | changed | expresses the same claim, method `reworded` | proposed |
| is new | any | mints a claim; expresses it, method `new` | confirmed |
| disappeared | n/a | nothing: the claim still exists, and its history shows the last revision that expressed it | n/a |

A reworded claim keeps its identity by default, because the writer kept its key, and the
key is the writer's statement of continuity. The assertion stays `proposed` until the writer,
or their agent (relaying the writer's answer on a private draft, or acting with `publish_own_work`), confirms it or
says "new claim". Saying "new"
retracts the `expresses` assertion, mints a claim, and may add `supersedes` from the new claim
to the old. A reader sees "reworded in draft-6, unconfirmed" until then.

**As built (0.2.13, REM-483, core half).** `claims.rewordings(revision)` lists the reworded claims waiting for an
answer, with both wordings. `claims.answer_rewording(revision, key, 'same' | 'new', supersedes)` is the answer. The
work's owner gives it, or their agent holding `research:publish`. "same" adds a confirmed link. "new" retracts
the link, mints a claim for the new wording and, if asked, records `supersedes` from the new claim to the old. The
next revision carries the answer forward. The editor and the revise tool that ask it are the application half.

**Decided (19 September, REM-622): an answer the person relays is theirs, on a private draft.** Saying
"same" or "new" is a judgement, and the person makes it; when they make it in conversation with their connected
agent, the agent may record it, on a private draft only: a revision nobody but its owner may read (not listed, in no
publication, not shared with an org). The transaction names the agent and the credential it used, and
`claims.rewording_answers(revision)` shows the owner every answer with who recorded it, so they can review it. The
person reverses an agent's answer by answering again: later rows retract the agent's link, its question answers and
its `supersedes` proposal, and the history keeps both. A later revision that carries the answer forward closes the
reversal on that revision. On any other revision the rule is unchanged: human-only unless the person let this
connection publish (`research:publish`). The refusal keeps the reason code `human_only` and says, in its message and
detail, which condition would allow it: a private draft, a publishing delegation, or the person answering in
Percolate. **Could have gone otherwise:** keep it human-only everywhere and improve only the refusal, which sends the
person out of the chat for a sentence they already said. **Revisit when** an agent's recorded answer is reversed by
its person in more than one in ten cases.

**Rejected:** minting a new claim on any text change. It is simpler, and it throws away the
writer's statement of continuity: every typo fix would orphan the claim's endorsements,
comments and inbound edges. **Revisit when** a sample of 50 reworded-and-confirmed claims
shows more than 10% where a reader judges the meaning changed.

### Across packages

Two writers reading one study never write the same sentence, and a string match is not
identity. Across works, sameness is a `same_as` assertion between two claims, and it is
always judged, never computed:

1. **Proposed** by an agent at publish (REM-435), by a reader's AI, or by a person, with the
   evidence it rests on (both occurrences, and spans).
2. **Confirmed** by the owner of the asserting side: I may say my claim is the same as
   yours. The other owner may dispute, which adds a `disputed` assertion and does not remove
   mine.
3. **Never merged.** No claim id is rewritten or retired. An identity set is computed at read
   time as the connected component over confirmed `same_as` assertions the caller may read
   (§9), so two readers can see different sets, and each set is correct for its reader.

Identity is per visibility horizon (REM-434, log of 16 September): an agent can resolve only
against what its person may read, so two writers who cannot see each other will mint
separate claims for one proposition. They stay separate until somebody who can see both
proposes `same_as`. That is a property of the access model, and the spec accepts it.

**As built (0.2.13, REM-478).** `claims.assert_relation` writes `same_as` only with an occurrence on each side
(two revisions), a span quoted from each that its occurrence says, and the six slots of *What same means* for both
sides in `spans.slots`. An agent's lands `proposed`. The asserting side's owner confirms it as a person. The other
side's owner may add a `disputed` row as a person, and can do nothing else to it. A disputed edge leaves every
identity set, and the history keeps all three rows.

**Nothing is inherited across `same_as`.** A claim said to be the same as another does not
acquire its endorsements, useful votes, oppositions or outcomes (REM-435). A reader at an
identity set sees each member's own record, grouped, with the member it came from.

### What same means

`same_as` holds only when the two claims are **mutually substitutable**: a reader who
accepts one is committed to the other, and any evidence that would refute one refutes the
other. That requires the same subject, predicate and object; the same scope (population,
setting, period); the same polarity; and the same modality (causal or correlational,
asserted or hedged, descriptive or normative) and size class of effect. Wording, citation
and emphasis may differ. Anything that changes what would make the claim false may not.

Everything short of that has its own relation, and the proposer uses the first that holds:

| The two claims | Relation |
|---|---|
| substitutable | `same_as` |
| one is a narrower or broader version (a special case, a subset of the scope) | `refines` (questions) or `qualifies` (claims) |
| opposite answers to one question, same scope | `contradicts` |
| compatible answers to one question that are still different propositions | `agrees` |
| same subject and outcome, different population, setting or period | `different_scope` |
| same topic, different question | nothing is recorded |

A `same_as` proposal carries the slots it compared, for both sides: subject, predicate,
object, scope, polarity and modality. So a claim with no frame can still be judged the same
as another, and the judgement writes the slots down. A frame (§7) is not required. But
without one, the only evidence for sameness is the proposer's reading. That is 77% of live
claims, and a low `same_as` count there measures the corpus, not the test.

`same_as` between **claims** is a judgement of meaning. An agent proposes it, and the person
it acts for confirms it; no grant confirms it in bulk. `same_as` between **questions**
(§7) is organising, and an agent may confirm it under the application's bulk grant for organising work. The two use one predicate on different
subjects, and the write function checks which kind of subject it was given.

**Measured on the live corpus** (a spike on 19 packages,
106 claims, 18 September). Two judges, `gpt-5.5` and Claude, found no pair of whole claims
that is the same, and a reading of all 106 found none they missed. Every near-miss failed
because one side carried an extra clause. Split into atomic propositions, 5 of 220 atoms
were the same as an earlier atom, across 3 claim pairs, and each was correct on reading.
Between 26 and 84 pairs were `agrees`. `same_as` is rare, and the claim a reader follows
across packages is mostly built from `agrees` and `qualifies`.

### Did you mean: core knows claims sit in a metric space

Everything above waits for somebody to already suspect a pair. Inside one work
`claims.rewordings` finds its one candidate by `claim_key`, which is the writer's own
statement of continuity. Across works nothing looks, so a claim already in the graph and
its restatement in the next package never meet, and the graph sprawls by one claim per
restatement with nothing to notice.

**Claim text is a metric space, and core says so rather than leaving each application to
say it.** `research.claims` is a registered `aiq.semantic_source`, shipped with the
extension beside `chunks` and `skills`, so a claim has a space by construction and the
orphan-vector triggers reach it when a revision is erased. `claims.candidates` reads that
space: given an occurrence and a vector, the claims nearest to it that the caller may read,
ordered by distance.

**Distance ranks and never decides**, which is `aiq.node_resolutions`' rule one schema
along: embedding proximity is legitimate for proposing a merge and forbidden as a scoring
input. The function returns a distance and no score, writes nothing, and asserts nothing.
The answer is `claims.assert_relation`, where an agent's lands `proposed` and identity does
not move until a person confirms (§9). So the deterministic half suggests and the judging
half approves, and neither can do the other's work.

**Four exclusions, and each is the reason a column or a join exists.** The claim itself.
Claims of the same work, which are the rewording question and are already asked. Claims in
revisions the caller may not read, because identity is per visibility horizon (REM-434).
And **any pair that already carries a relation, in either direction and at any status** —
without that last one an answered challenge is asked again on every insert, which is the
difference between housekeeping and a treadmill.

**The floor is the caller's and has no default.** A distance cut is meaningful only against
the model that produced the vectors, and a default would be one model's number applied to
another's scale. What a floor costs is a measured table, not a judgement:

| cosine distance | questions over one week of arXiv, top-1 per insert | pairs, over every pair |
|---|---|---|
| 0.12 | 10 | 11 |
| 0.15 | 41 | 53 |
| 0.20 | 418 | 777 |
| 0.22 | 834 | 2,495 |
| 0.25 | 1,667 | 13,957 |

**Measured** (in an internal self-model application, on 483 arXiv
papers, 3,909 claims, `bge-small-en-v1.5`, 21 September). At a distance floor of 0.15 the
question is asked on **41 of 3,909 claims (1.05%)** — 99% of claims arrive in silence — and
52 candidates produced 5 `same_as`, 13 `agrees` and 3 `different_scope` on reading. Sprawl
from duplicate claims is 0.13% of claims a week, so this is cheap rather than urgent, and
the case for it is that it costs almost nothing to always run.

**Asking per insert is what makes a low floor affordable.** Top-k caps an arriving claim at
k questions however many neighbours it has, where a pass over every pair grows with the
square: at 0.25 the same floor is 1,667 questions per insert against 13,957 pairs.

**No lexical source.** `aiq.register_lexical_source` is not called on `research.claims`.
Measured on the same corpus, 3,299 sentences across 483 papers repeat **no** cross-paper
phrase, and a lexical blocker proposes 97.7% of all pairs. A tsvector column and a GIN
index on every claim would buy nothing here.

**`claims.candidates` leaves `hnsw.iterative_scan` alone, where `aiq.semantic_in` forces `strict_order`, and the
difference is the question being asked.** An empty answer to a *search* looks like "there is nothing", and for a
tenant holding a small share of a large corpus that is wrong — which is what semantic_in's setting buys. An empty
answer to a *challenge* is the right answer 99% of the time, and forcing the scan to resume means walking the whole
index to prove a negative on every save. Measured on 3,909 claims, one call for a claim with no neighbour: **232 ms
forcing it, 13 ms leaving it** — 29 minutes against 55 seconds over the corpus. It costs no recall at this scale,
checked rather than assumed: at a limit of 10 the bounded scan returns every pair an exhaustive one returns and one
more. A caller who wants the exhaustive guarantee raises the setting themselves.

**Registering `research.claims` widens every space's read policy, and two things hold it shut.**
`police_embedding_spaces` ORs one branch per source into each space's policy, so `exists (select 1 from
research.claims s where s.id = <space>.chunk_id)` is now evaluated on spaces holding no claims. A caller who could
put a chosen id into `research.claims` could read somebody's chunk vector out of the content space. They cannot:
no web-facing role holds INSERT on `research.claims`, and the one function in the extension that inserts into it —
`research.project`, security definer — is reachable by none of them. Second and weaker: on that path the id is
`percolate.uuidv5(revision, 'claim:' || claim_key)` where chunks and skills default to `uuidv7()`, and a version 5
uuid can never equal a version 7 one. Weaker because the column has **no default**, so that is a property of the
call site and not of the table; an import path carrying an external id, or a default on the column, would leave
only the grant. **Revisit when** anything else writes `research.claims`.

**A registered source is a branch of every space's read policy, and that branch has to be correlated.** Before
this landed, the planner hashed each branch — one full read of the source table per query, with its row security
evaluated per row. Registering `research.claims` took a top-5 query on an eleven-vector chunk space from 0.4 ms to
**443 ms**, on a space holding no claims at all. `aiq.police_embedding_spaces` now writes `offset 0` on each
branch, which keeps it correlated and costs one index probe per candidate vector. The measurement needed 3,909
claims; at fixture size the planner does not choose the shape that fails.

**Who fills the space is the deployment's embedding pipeline, as it is for `chunks` and `skills`.** Registering
the source is what makes a claim embeddable, visible to the planner and covered by the orphan sweep; it does not
embed anything. A deployment that runs no embed step over `research.claims` has a registered source, an empty
space and a `claims.candidates` that says so by name, which is the state to expect on the day this ships.

**As built (REM-662, extension 0.2.28 with the core worker's `embed_source`): a save queues it.** `research.project`
and `claims.pose_question` queue a run of the shipped `embed_sources` workflow in the writer's transaction, and join
a run that is still waiting. They never call a model and never fail the save: with no callable default model the
revision projects and a NOTICE says so. The step is generic: `op: embed` with `source: <name>` pages through
`aiq.texts_to_embed(source, model, limit)`, the rows of any registered source the default model's space lacks, and
writes through `aiq.record_embeddings`, which only `worker` may call. What a space lacks is the whole queue, so the
backfill is the same call as a save: `select aiq.queue_source_embedding('backfill')`, measured at about 17 s per
1,000 claims with `bge-small-en-v1.5` in process.

**Rejected: core computing the vector.** The embedding is an external model call, which is
the one thing this schema never makes; the vector arrives alongside the query, exactly as
`aiq.query(p_query, p_embedding)` takes it. `claims.candidates` uses the occurrence's
stored vector when one exists and refuses by name when it does not.

**Rejected: a `same_as` core proposes by itself.** Within the retrieved band, distance
cannot tell a relation from an unrelated pair — AUC 0.58 on 53 labelled pairs, with a
bootstrap interval spanning chance. It is good for *here are three to look at* and for
nothing else. Two judges reading the same 52 candidates agreed on 35, one calling 10 of
them a relation and the other 21. **Revisit when** a judge's answers on 200 candidates are
reproduced by a second judge on more than nine in ten.

**Merged for extension 0.2.29 (REM-659, Percolation-Labs/percolate#211): the challenge runs
when a claim's vector lands, and the writer's own agent answers it.** A vector does not exist at save, so the hook
is `aiq.semantic_sources.on_embedded`. `aiq.record_embeddings` calls it with the ids that landed, in its own
subtransaction, and a failure there never fails the embed. The claims source names `claims.challenge_embedded`,
which asks each claim *as its writer* (the work's owner, through `workflow.execute_for` over `claims.candidates`).
It never asks as the coalesced embed run's owner, who is whoever saved first. The candidates are therefore what that
writer may read. They are queued as an `aiq.judgements` row of kind `challenge`, addressed to the writer: nobody else
sees or decides it. It is decided through the same `claim_judgement` and `decide_judgement` calls over query-mcp. The
verdict is `relate` or `none`. A `relate` is `claims.assert_relation` as the judge, so an agent's lands `proposed`,
and the guard refuses a `relate` that names a relation nobody asserted. Percolate calls no model; the writer's agent
is the judge.

- **Each pair is asked once.** A page is taken newest occurrence first. A pair already put to either side, whatever
  the answer, is not asked again, so a `none` does not come back with the next revision. "Only claims that arrived
  earlier" was rejected: the worker embeds a backlog in id order, not arrival order, so a later claim embedded
  first would find its twin missing, and the twin would then skip it.
- **The floor is the deployment's, per model, with no default.** `claims.challenge_floors` holds it, and
  `claims.set_challenge_floor(model, distance, top_k)` sets it. With no row, nothing is challenged, a NOTICE says
  so, and nothing is recorded, so setting the floor and then calling `claims.challenge_waiting()` asks every
  embedded claim that was never asked. That call is also the backfill. `claims.challenged` records each occurrence
  asked.
- Covered by research/41, with thirteen mutants, each of which turned it red.

**Decided (REM-659 box 3): `agrees` with no period is decidable, through the slot value `unstated`.** `unknown` is a
slot nobody checked; `unstated` is a slot the proposer checked and found that *neither* claim states. Two claims
that leave a population or a period open answer the same open-ended question about it, and agreeing is compatible
with every value of it, so `agrees` accepts `unstated` for population and period. The value is checked wherever it
can be: a frame on either occurrence that states the slot makes `unstated` false, and it is refused. `contradicts`
does not accept it, because two claims with no period may be about different periods, so an opposition across it
is not yet a contradiction. Its refusal says what to do instead: mark the slot `differs` and propose
`different_scope`, or decide `none`. **Could have gone otherwise:** keep `unknown` and only improve the refusal.
That would refuse all 4 of the 21 answers core refused on 0.2.18, every one an `agrees` between method claims with
no period on either side, for a requirement no reading of the text could meet. **Revisit when** a sample of
`agrees` labels on `unstated` slots shows more than one in ten where a reader finds the claims are about different
periods.

### Parts: an occurrence can say more than one thing

A written claim bundles propositions: "X, so Y", "X because Y", "X; Y remains open". In the
spike's split, 55 of 106 live claims hold two, 28 hold three, 22 hold one and one holds four. Two claims that share X
but differ in Y are not the same, and X alone is. So the unit that `same_as`, `agrees`,
endorsement roll-ups and closure (§12) attach to is the **atomic proposition**, and an
occurrence may express several claims.

- **One part by default.** The projection asserts one `expresses` per occurrence, as in the
  rules above, and nothing changes for a writer who never splits.
- **Identity is per (occurrence, part).** Among current assertions, `(revision_id, claim_key,
  part)` is unique, and "the latest row decides" keys on (occurrence, part, claim). The
  spike's `a_typed.sql` has no `part` column, so REM-473 adds it with `part = 1` for every
  row it backfills.
- **The writer's agent splits.** At publish (REM-435), the agent that drafted the package
  proposes a split: for each part, a `gloss` (the part as a standalone sentence, pronouns
  resolved, qualifiers kept inside it), its `span` in the occurrence where one exists, and
  the slots above. Each part `expresses` its own claim with `part = 1, 2, …`, and the links
  between parts are ordinary relations (`supports`, `qualifies`, `limits`) with the
  occurrence as evidence.
- **A split is a proposal.** It is `proposed` until the owner confirms it, like a reworded
  claim, and a reader sees the whole occurrence until then. Splitting never rewrites the
  occurrence's text or key, so every foreign key to `(revision_id, claim_key)` holds.
- **Across revisions** a part keeps its claim when the gloss is unchanged, and is `proposed`
  when the gloss is reworded, by the same table as whole occurrences.
- **Endorsement stays on the occurrence** (§8). A person endorsed the words they read, and
  the parts inherit nothing from it.

**Resolution runs on parts, and its candidates come from an index.** At publish the agent
resolves each part against the parts its person may read. The candidates are a bounded,
indexed lookup: parts that answer the same question (§7) and parts whose occurrences cite
the same origin key (REM-219). It is never a scan, and never the corpus placed in the
agent's context, because core's queries must hold at billions of rows. Embedding similarity
only retrieves and never decides. Both lookups scan today (REM-500): text search under row
security reads every row, because `@@` is not leakproof, and `research.sources.origin` has
no index. So the candidate path waits on REM-500. The whole corpus in context is the
small-corpus case only. The spike used it at 220 parts (about 15,000 tokens), and there it
found a `refines` that the embedding top five missed.

## 6. Relations: one vocabulary, with declared meaning

Today two vocabularies do one job (REM-432 q4): in-package `edges` and cross-package
`stance`. They are not synonyms. `supports` is inferential: the first claim is a reason to
believe the second. `agrees` is comparative: two answers to one question are compatible. One
vocabulary holds both kinds, and each row says which kind it is.

| predicate | between | kind | transitive | symmetric | requires |
|---|---|---|---|---|---|
| `expresses` | occurrence → claim | identity | no | no | platform or owner; a part (§5) carries `part`, `gloss` and slots |
| `same_as` | claim → claim | identity | yes, over confirmed only | yes | evidence on both sides |
| `supersedes` | claim → claim | identity | yes | no | the owner of both |
| `answers` | claim → question | framing | no | no | a frame (§7) |
| `refines` | question → question | framing | yes | no | a narrower slot value |
| `supports` | claim → claim | inferential | no | no | nothing beyond the writer's assertion |
| `challenges` | claim → claim | inferential | no | no | nothing beyond the writer's assertion |
| `qualifies` | claim → claim | inferential | no | no | both read |
| `limits` | claim → claim | inferential | no | no | both read |
| `motivates` | claim → claim | inferential | no | no | nothing |
| `compares_with` | claim → claim | inferential | no | yes | nothing |
| `agrees` | claim → claim | comparative | no | yes | same question; spans from both |
| `contradicts` | claim → claim | comparative | no | yes | same question; every frame slot `same` or `overlaps`; spans from both |
| `different_scope` | claim → claim | comparative | no | yes | the slot that differs, named |
| `same_source_opposite` | claim → claim | comparative | no | yes | a shared origin; a span from each |
| `cites` | occurrence → origin | evidence | no | no | a source in the revision |
| `mentions` | occurrence → entity | evidence | no | no | a locator |
| `resolved_as` | claim → value | outcome | no | no | §12, an event |
| `consensus_as` | claim → value | outcome | no | no | §12; independent origins counted |

The vocabulary is `claims.predicates`, and `claims.assert_relation` writes the rows between two claims. Since 0.2.13
(REM-479) it enforces the comparative rows' requirements itself, the application's stance-label
rules moved in unchanged. The proposer's `frame_match` judges each slot, spans come from both passages, and
`same_source_opposite` is checked against the origins both claims cite. A comparison's author need not own either work:
a comparative label, and `qualifies` across two works, is asserted by anybody who may read both revisions. Whoever
asserted a label may restate it. `uncertain` is not a relation; it is a pair with a requirement missing.

The comparative rows carry the application's stance-label rules (the requirements in the table above)
unchanged. The server enforces them as it does today; they move from the application's
validator to the vocabulary row's check.

### What implication licenses

REM-434's fourth question. **No relation between two claims is transitive except the
identity relations.** `A supports B` and `B supports C` do not make A a reason to believe C
with any strength the graph can state, so nothing is ever shown as "A supports C".

Two derived readings are licensed, and each is shown as derived, with its path:

- **Rests on.** The reflexive, transitive closure of `supports` and `motivates` backwards
  from a claim: everything it depends on. This is how a correction propagates (the paper's
  R6): when a source's capture is removed, or an origin is resolved false, every claim that
  rests on it is listed as affected. `research.endorsements_affected_by` does this today for
  one revision; this generalises it to the graph.
- **Challenged through what it rests on.** C is challenged through B when C rests on B and
  something challenges or contradicts B. This is REM-433's first question, and a reader sees
  it as "a claim this depends on is disputed", with the path, never as "this claim is
  disputed".

The two readings and the identity set, as Datalog rules (§14): the rule is the definition,
and the recursive CTE that implements it starts at the anchor and is checked against it.

```
rests(C, Y)  :- rel(R, Y, P, C), rests_kind(P), confirmed(R).        % P in {supports, motivates}
rests(C, Y)  :- rel(R, M, P, C), rests_kind(P), confirmed(R), rests(M, Y).
challenged_through(C, Y, Z, P) :- rests(C, Y), Y != C, rel(R, Z, P, Y), P in {challenges, contradicts}, confirmed(R).
dependents(X, Y) :- rests(Y, X).
same(A, B)   :- rel(R, A, same_as, B), confirmed(R).
same(A, B)   :- same(B, A).
same(A, B)   :- same(A, M), same(M, B).
```

`confirmed(R)` means the latest assertion about R, as of the read's date, has status
`confirmed` and is not a retraction. `Y != C` is there because `supports` can form a cycle, and
through a cycle a claim rests on itself: a challenge aimed at C directly is a challenge to C,
not one "through what it rests on". The spike found the rule and the CTE disagreeing on exactly
this before the inequality was written (§14).

`same_as` is transitive over confirmed assertions only, and an identity set larger than
the confirmed edges justify is not computed: a proposed edge never extends a set.

## 7. Questions and frames

REM-432's first question: is the node the claim or the question? **Both.** A claim is what a
writer asserts; a question is what makes two claims comparable. The frame is how a claim
finds its question.

**A question can exist before it has a frame.** A reader asks "Do AI coding tools make
experienced developers faster?" long before anybody has filled subject and outcome, and 77% of
live claims have no frame. So a question may be minted from a phrasing alone, and its frame
slots arrive later as assertions. A claim with no frame can still `answer` a question: the
`answers` assertion is judged, carries its actor and date like any other, and holds the
claim's stance on the question (`yes`, `no`, `depends` or `unknown`). Stance on a question is
not `direction`, which is a frame slot about a measured effect. The application keeps a
reader's own wording of an idea as its own record, pointing at the core question
(REM-485).

The frame's comparable slots identify a question:
`subject` and `outcome` are required, and `population`, `setting`, `period`, `comparator` and
`evidence_type` refine it. `direction` and `magnitude` stay on the occurrence, because they
are the answer, not the question.

- **Minting from a frame.** A frame whose `subject` and `outcome` match an existing question's (after
  normalisation) answers that question; otherwise a question is minted. A frame that differs
  only in a refining slot answers a question that `refines` the broader one.
- **Matching is computed for slots and judged for meaning.** Normalised string equality on
  slots can say two frames are the same; it cannot say "developer productivity" and
  "programmer output" are one outcome. That judgement is a `same_as` between questions, with
  the same proposal rules as §5.
- **As built (0.2.13, REM-476).** A framed occurrence's slots are `claims.frames`. A question is
  `claims.questions`, keyed by normalised subject and outcome plus the normalised refining slots, and a refined
  question names the broader one in `refines`. `claims.answered` records which question a claim answers: the
  platform asserts it from the slots, confirmed because the match is computed, with stance `unknown` because a
  stance is judged. A frame with a subject but no outcome is kept and answers nothing.
- **A refined question is found by its own words (0.2.29, REM-1099).** Its `search_text` is the frame's subject
  and outcome followed by its refining slots in brackets. Before this a refined question read and embedded
  exactly like the question it refines, and search listed every such pair as twins. Production on 20 Oct held
  266 questions, all with distinct keys: 121 refined questions with their 121 bases, 24 phrased questions and none
  posed twice. The upgrade drops the refined questions' vectors once and queues the embed run.
- **As built: questions minted from a phrasing** (coalescing). A question
  may carry a `phrasing` (one polar sentence, 10 to 200 characters, ending in a question mark) in place of a
  frame, keyed `q:` plus its normalised words; a check requires a frame or a phrasing. `claims.pose_question`
  mints one for any research writer and returns the existing id for the same words; the question stays unreadable
  until a readable claim answers it, so the id says only that the words exist. `claims.propose_answer` records a
  claim's stance (`yes`, `no`, `depends`) from a revision the caller may read: `proposed` for an agent or another
  reader, with the judge's probability in `p`, and `confirmed` when the work's owner makes it as a person.
  `claims.withdraw_answer` retracts a stance by a later row, for whoever made it or the work's owner.
  `claims.question_web(at, min_works)` is an invoker read of every question the caller can see answered from at
  least `min_works` works, one latest answer per claim, `unknown` left out. Question `same_as` (two phrasings,
  one question) is not built yet.
- **A frame is required for comparative relations, not for writing** (REM-432 q3). A claim
  without a frame can be published, supported and challenged within its package. It cannot
  be labelled `agrees` or `contradicts` with anything, which is the rule today; the spec
  makes the consequence visible by counting framed claims per package (22% of the live
  corpus, 23 of 106 claims, counted on 18 September).

## 8. What attaches to what

REM-434's third question.

| Record | Attaches to | Why |
|---|---|---|
| Endorsement | the **occurrence** (an exact revision), as today | a person checked words in a revision, and a later rewording was not checked (a later revision does not inherit an endorsement) |
| Opposition | the **occurrence** | new: the mirror of an endorsement, with what was checked and why it fails. The record `challenges` alone cannot carry |
| Comment | the occurrence, as today (`engagement.comments.claim_key`) | a comment quotes words |
| `supports`, `challenges`, … | the **claim**, with the occurrences it was asserted from as evidence | an argument survives a rewording |
| `agrees`, `contradicts`, … | the **claim**, with spans from both occurrences | a stance is about what is claimed; the spans say where |
| `same_as`, `supersedes` | the **claim** | identity is about the proposition |
| Resolution, consensus | the **claim** | whether something turned out true, or came to be agreed, does not depend on its wording |
| Useful vote, valuation | the **revision**, as today | readers value a package |

**The claim page shows occurrence-level records grouped by occurrence.** An endorsement of
the wording in draft-5 appears under draft-5, marked "wording since changed" when the latest
occurrence differs. It is never shown as an endorsement of the claim in general.

## 9. Access

An assertion is readable exactly when the caller may read every occurrence and revision in
its evidence. A claim is readable when the caller may read at least one occurrence that
`expresses` it. A question or origin is readable when at least one readable claim reaches it.

Consequences, each of which the build must test:

- Counts are taken after the access filter, never before. "3 claims answer this question" means three the caller may read.
- An identity set is computed over the caller's readable `same_as` assertions only, so a
  private draft cannot join two public claims in anybody else's view.
- A transaction is readable to its actor and to an operator. Another reader sees the
  actor's kind (person, agent, platform) and model on each assertion they may read, and not
  the rest of the transaction.
- The existence of a claim minted from a private draft is not observable: its id appears in
  no readable assertion, count or error message.

Whether row security can express these rules at acceptable cost over the chosen physical
design is the spike's third question (§14).

## 10. Reading the graph

Read functions, each `security invoker` so row security decides what they return, each
accepting `p_at timestamptz` for an as-of read (default now):

| function | returns |
|---|---|
| `claims.claim(id, at)` | the claim, its occurrences, its question, its identity set |
| `claims.neighbourhood(id, predicates[], depth, at)` | typed paths out of a claim, each hop with its assertion, status and tx |
| `claims.rests_on(id, at)` | §6's derived closure, with paths |
| `claims.challenged_through(id, at)` | §6's second derived reading, with paths |
| `claims.answers(question_id, at)` | every readable claim answering a question and its refinements, grouped by stance |
| `claims.evidence(id, at)` | citations grouped by origin, with the independent-origin count REM-219 returns today |
| `claims.question_evidence(question_id, at)` | the same, over every readable claim answering the question, grouped by stance, each origin counted once however many claims cite it |
| `claims.history(id)` | every assertion about the claim, oldest first, with each tx |
| `claims.revision_diff(from_revision, to_revision)` | claim-level: added, dropped, carried unchanged, reworded (and whether confirmed), edges gained and lost |
| `claims.as_of(public_id, at)` | a work's claim graph as it stood at a time, extending `research.trust_state` |

**Built in 0.2.12 (REM-475):** `claim`, `neighbourhood`, `rests_on`, `challenged_through`, `history` and
`revision_diff`, with `relations_at` and `identity_set` beneath them. **In 0.2.13 (REM-476):** `answers`, with
`answers_of` and `frame_coverage`, and `evidence` with `same_study` (REM-477). `question_evidence` comes with
comparisons (REM-479); `as_of` is built with the claim page (REM-482), which is its first reader.

**Which revisions a reading counts (REM-584, extension 0.2.15).** The additive `claims.reading` API selects
current caller-visible heads, an explicit pinned revision set, or historical exposed/owned heads at a cutoff.
All modes enforce present permissions; both evidence revisions of a relation must belong to the selected set.
The result names that set and cutoff. Legacy graph calls continue to include every readable revision, so a
challenge dropped from draft-2 can still appear through draft-1 in a legacy call. A reading is consistent whether it is
current, pinned or historical.
Assertion cutoffs use transaction start timestamps and the highest row id within each statement key, not a
commit-order clock. Origin-link statements are keyed by both origins, evidence revision and source key; one
source retracting its assertion does not retract another source's assertion of that pair.

REM-603 also makes `origin_record` and `frame_coverage` count active occurrence/answer state. Answering a
framed rewording **new** now retracts its former question link and asserts that link for the new identity;
all previous rows remain available to historical readings. REM-590 gives
every generated assertion a durable execution receipt,
without publishing credentials or protected inputs.

`revision_diff` is what "traverse claims against versioned drafts" means in practice: a
writer sees what their edit did to the argument, and a reader returning to a package sees
what changed since they last read it, per claim rather than per paragraph.

## 11. Writing the graph

Every write is a `security definer` function that opens one transaction record, checks a
permission through `rbac.require`, and appends assertions. There is no `insert` grant on any
table, which is how `research.*` works today.

- **The projection writes occurrences and `expresses`.** `research.project` gains the §5
  rules, in the revision's own transaction, so a package write stays one statement.
- **An agent's assertion lands `proposed`**, and only a person or a passing check moves it
  to `confirmed` (`brief.md` §10). An agent token cannot write `confirmed`, and the
  function refuses rather than downgrading.
- **Comparative relations are checked at write.** The vocabulary row's requirements (§6) are
  enforced by the write function; a `contradicts` without spans from both sides is refused,
  not stored as `uncertain`.
- **Nothing is updated.** Status changes, disputes and retractions are new assertions. A
  trigger refuses `update` and `delete` on every assertion table, as `research.refuse_rewrite`
  does for revisions; `claims.erase` is the one way data leaves (§13).

## 12. Closure

The paper's R7: a source's reliability can be learned only
from independently checked outcomes, and a record that was never kept cannot be recovered.
Most claims never get such an outcome. Contested questions rarely end in a verdict,
and some close by convergence rather than by an event (decided 18 September, REM-495). So
closure comes in three kinds, and each keeps its own record.

| Kind | What closes it | Record | May teach reliability |
|---|---|---|---|
| Open | nothing yet, perhaps never | none: the absence of the other two, read as the state of the debate on a date | no |
| Consensus | independent origins converging over time | `consensus_as` on the claim | no |
| Event | something that happened and can be cited: a ruling, a published result, a reported figure, a replication | `resolved_as` on the claim | yes, and only this kind |

**Every claim starts open.** Its package's `next_check` is the closure condition, typed
`event`, `consensus` or `none expected` (REM-498). An open claim is shown as the positions
on its question, the independent origins behind each, and the next check. Open claims whose
next check names a date are the Watch list (R9).

**An event resolution** is an assertion `resolved_as` with a value (`held`, `failed`,
`partly`, `unresolvable`), the event, its captured source, the date it was checked, the
check that settled it (a named method and a citation), and who ran it. Anybody who may read
the claim proposes it, by hand or through discovery's closure query
(REM-497). A person with a resolver grant confirms
it. A search hit is a candidate until it is opened and imported, as for counterpoints.

**A consensus state** is an assertion `consensus_as` with a value (`holds`, `rejected`),
the independent origins counted for it, the date from which it held, and who confirmed it.
It is proposed from origin counts over time (origins as entities, REM-477), never from
package counts, and a person confirms it. It is labelled consensus, never a verdict. A new
independent origin that disagrees reopens the claim: the assertion is retracted, not
overwritten, so the history shows both states. Agreement among copies is one origin
repeated and never makes a consensus. That is the error the paper warns against, and
counting by origin is what separates the two.

**As built (0.2.13, REM-480).** `claims.resolutions` holds tradecraft's fields adapted: `value`, `event`,
`evidence_ref` (what settled it), `checked_on`, `method`, and the transaction for who ran it. The evidence is a
revision the proposer may read that expresses the claim. `claims.propose_resolution` is open to any reader.
`claims.review_resolution` needs `research:resolve`, a person-only permission nobody holds without a grant, and adds
a row restating the proposal as confirmed or disputed. `claims.origin_record` tallies confirmed resolutions per
study. It is a count, and nothing computes a score.

**As built (0.2.13, REM-496).** `claims.consensus` records a position, the independent studies behind it and the date
from which it held. The studies are counted by `claims.consensus_studies` from origin entities: those cited by the
claim, its confirmed identity set and the claims confirmed to agree with it, each study once. They are counted as
the proposer may read them, and never taken from the proposer: `record_consensus` refuses a study that is not behind
the claim. A proposal needs two. A person holding `research:resolve` confirms, disputes or reopens it, each a
later row. `claims.consensus_of` reports a confirmed contradicts from a study the consensus did not count, made
after the confirmation, as dissent. It reports it and does not act on it. Consensus never enters
`origin_record`.

**Adapt, do not write anew:** `tradecraft.resolutions` in
a held-out tradecraft resolutions draft already names the fields. It moves into the
claims layer as the `resolved_as` predicate's value shape, and the held-out tradecraft
tables stay held out.

**Collect before computing.** Nothing computes source reliability from resolutions until
there are enough of them to fit anything: `ontology.md` admits no fitted weight to core
before an instrument exists. Consensus never enters that computation. The build ships the
records and a count per kind.

**Who confirms, as operated.** `research:resolve` is granted per person, through an application role and `rbac.grant_with_basis`, never role-wide and never to an agent or
token. Anybody who confirms needs a grant of their own.

## 13. Erasure

`research.erase_work` is the one way a work leaves (REM-464). It must also erase:
occurrences of the work's revisions; assertions whose evidence is only those occurrences;
and claims left with no occurrence. Assertions that cite the erased occurrences alongside
others lose that evidence and are re-checked against §9 rules. A tombstone records what was
erased, when and why, and keeps no text.

**As built (0.2.13, REM-481).** `erase_work` counts the claims graph resting on the work, lets the cascade take every
row one of its revisions evidences, and `claims.sweep_erased` removes the claims, origins, questions and transactions
only those revisions minted that nothing names any more. The tombstone is `claims.erasures`: counts, no text. An
assertion is one statement from its own evidence, so the same relation asserted from another work is another row
and survives, and a relation between the erased work and another goes with it. **Known limit:** an origin or
question another work still cites or answers stays, and its label is the wording first written, which can be the
erased author's.

## 14. The spike

REM-433, widened. It decides the two rows §4 left open, and it runs before any schema in
this file is built.

### Four candidate designs

| | Shape | For | Against |
|---|---|---|---|
| **A. Typed tables** | `claims.claims`, `claims.questions`, `claims.origins`; one table per predicate family (`identity`, `relations`, `framing`, `evidence`, `outcomes`), each append-only with `tx` and `op` | foreign keys on every endpoint; row security per table; the existing house style | a new predicate family is a migration; as-of is repeated per table |
| **B. One assertion table** | `claims.assertions(id, subject, predicate, object, value jsonb, tx, op, status)`, predicate a foreign key to the vocabulary | Datomic's shape; a new predicate is a row; one as-of implementation | endpoints have no foreign key (subject can be any kind); row security on one wide table |
| **C. `aiq.edges` reused** | claims and questions as registered entity tables; relations as `aiq.edges` with `aiq.relation_types` triples | bitemporal, retraction and as-of already built and tested (REM-51, 65); one graph for world model and claims | `(src, dst, relation)` is unique, so two people asserting the same relation collapse into one row; no per-assertion actor, status or evidence; edges are not read-gated |
| **D. Datalog over datoms** | pg_mentat's datoms and rules inside Postgres | recursive rules as the query language | in our spike (September 2026), supported PostgreSQL 13–18, and the extension targets PostgreSQL 19; licence unstated; an extension beside ours |

### The questions, each run against every design that can express it

1. What challenges this claim through what it rests on, among works the caller may read?
2. Which works cite one origin and read it in opposite directions?
3. Which claims rest on a source whose capture was removed or is unverified?
4. What did this claim's neighbourhood look like on a given date?
5. What is this claim's identity set, over confirmed `same_as` the caller may read?
6. What changed, claim by claim, between two revisions of one work?

### What is measured, per design

- **Representational:** lines per question; where the access rule appears (once, or per
  join); what the design cannot express, and whether that is a feature (a design that makes
  it easy to compute `same_as` is a worse fit, per §5).
- **Access:** each of §9's four consequences as a test that passes or fails, and the cost of
  row security on questions 1 and 5.
- **Performance:** each question at 10³, 10⁵ and 10⁶ assertions on a synthetic corpus shaped
  like the live one (106 claims, 97 edges and 96 sources across 19 packages, 18 September),
  scaled up. The live corpus alone is too small for any performance answer, which the
  finding states.
- **Writes:** assertions written per package revision, and the time `research.project`
  takes with them, against today's.

### Exit

A written finding choosing A, B or C for storage and CTE or Datalog for traversal, one
recommendation per axis, stating which axes showed no difference at our size. Nothing ships
from the spike's branch. **Prior, stated before running so it can be wrong:** A for storage,
CTEs for traversal, and C's bitemporal functions reused rather than its table.

### Result, 18 September

(Internal spike.)
Four designs were loaded with one synthetic corpus at 870, 110,795 and 1,102,974 assertions.
Each answered the six questions on the same anchors, with answers checked against design A's.

- **Storage: A.** Every question under 1 ms at 1.1 million assertions except Q2 (34 ms). B
  answered the same, in 5× the storage, and needed typed side tables for row security. C
  answered Q4 wrongly: its unique `(src, dst, relation)` key keeps one row per triple, so a
  relation shows `confirmed` at a moment when it was only `proposed`.
- **Query language: recursive CTEs.** In our spike (September 2026), pg_mentat (Datalog, design D) returned wrong answers
  without an error twice: an unknown rule was ignored, and two rules in one query lost the
  join between them. Its bottom-up evaluation took 14–16 s on Q1 and Q3 at 110,795
  assertions, where A took under 2 ms. It had no access model and supported PostgreSQL 18 at
  most.
- **Datalog as vocabulary: yes.** Each derived reading in §6 and §10 is specified as a rule,
  and the rule is the definition the CTE is checked against.
- **The prior's third part was wrong.** C's validity interval cannot hold a proposal and its
  confirmation as two facts, so nothing of `aiq.edges` is reused.
- **The first build carries two things the spike found.** An index on occurrences by
  `(revision_id, claim_key)`, which took Q2, Q3 and Q6 from up to 198 ms to under 35 ms. And
  a policy that hides another actor's transactions, which no design had (§9).

## 15. Build sequence

Each step is a card (§17) and a gate a database either passes or fails.

| Step | Builds | Gate |
|---|---|---|
| 0 | the spike (§14) | a finding with a choice per axis |
| 1 | **built, 0.2.11 (REM-473):** transactions, claims, occurrences linked by `expresses`, the §5 rules in `research.project`, backfill of every existing revision | every occurrence in a backfilled database expresses exactly one claim; a reworded key is `proposed`; re-projecting a revision writes nothing new |
| 2 | **built, 0.2.11 (REM-474):** the predicate vocabulary and relation assertions; `argument_edges` projected as `supports` and the rest | the six in-package relations answer through the new tables with the same rows as `argument_edges`; `update` and `delete` refused |
| 3 | **built, 0.2.12 (REM-475), except the question and origin reads:** read functions (§10) and the access tests (§9) | every §9 consequence has a test that fails when its rule is removed |
| 4 | **built, 0.2.13 (REM-476):** questions and frames | frames survive projection; two frames with equal `subject` and `outcome` answer one question |
| 5 | **built, 0.2.13 (REM-477):** origins as entities | `find_packages_citing_the_same_study` returns the same `independent_evidence` computed from origin entities as from REM-430's keys |
| 6 | **built, 0.2.13 (REM-478):** cross-package `same_as`, proposed and confirmed | an identity set never includes a proposed edge or a claim the caller cannot read |
| 7 | **core half built, 0.2.13 (REM-479):** comparisons move into core as comparative assertions | every confirmed alignment in the application appears as a confirmed assertion with the same spans |
| 8 | **built, 0.2.13 (REM-480, REM-496):** closure | a resolution and a consensus state are recorded, confirmed by a person, and counted per kind |
| 9 | **built, 0.2.13 (REM-481):** erasure | `erase_work` leaves no occurrence, assertion or claim that only the work supported |

Steps 1 to 3 are the minimum that lets the application dogfood (§16). Steps 4 onward can be
reordered by what the application needs next.

## 16. Dogfooding

**The application moves to the graph in three steps, each shippable alone.**

1. **Read.** The web claim view and the MCP tools read `claims.*` for identity, history and
   `revision_diff`, while packages keep being written as today. The projection does the
   rest.
2. **Ask.** The writer's edit and the publish step ask the §5 questions ("same claim
   reworded, or a new one?"; "is this claim one of these?"). REM-435 is the publish half.
3. **Retire.** The application's comparison store and `market.claims` are retired in favour
   of comparative assertions and claim entities. Done for the draft: REM-563 retires the market
   SQL, and the application's data model now describes the tables it built.

**The engineering tenant** ([`brief.md`](brief.md)) maps onto the same substrate. A code
claim is a claim; its anchor to a symbol is a `mentions`-like predicate to an `aiq.nodes`
symbol; its falsifier and discharges are that tenant's own predicates in the vocabulary.
Nothing in §3 to §13 is specific to research documents except occurrences, frames and
questions, and the engineering tenant can leave those unused. The self-model's claims table
is loaded through the same write functions once step 2 ships, which tests the substrate on a
corpus of 482 claims that nobody wrote for it.

## 17. Cards

Parent card REM-472; each §15 step is one card.

## 18. Decisions, with what would reopen them

| Decision | Rejected | Revisit when |
|---|---|---|
| A claim's id is minted, never computed from text | `uuidv5(normalised text)` across packages | never: text equality is not identity, and computing it would merge claims no person judged the same |
| A reworded claim keeps its identity, as a proposal | a new claim on any text change | more than 10% of 50 confirmed rewordings are judged by a reader to change the meaning |
| Cross-package identity is judged and never merged | a canonical id chosen by a merge | a merge is asked for by a reader who cannot otherwise follow an argument, three times |
| `same_as` means mutually substitutable; close is `agrees` or `qualifies` | a similarity threshold, or "the same point" as the reader's intuition | a sample of 50 confirmed `same_as` pairs has more than 5 that a second reader says differ in what would make them false |
| Identity attaches to atomic parts, and an occurrence may express several claims | one claim per written sentence | after 200 confirmed splits, more than 20% of parts are judged by a reader to have lost meaning the whole occurrence carried |
| No inferential relation is transitive | `supports` as transitive | a reader study shows readers want "A supports C" shown, and can tell it from "A supports B" |
| Endorsements attach to occurrences | to claims | an endorser asks to endorse a claim in all its wordings, and a way to state that is designed |
| Outcomes are collected before anything is computed from them | a reliability score from day one | 200 confirmed resolutions across 20 origins |
| Only event resolutions may teach reliability; consensus is its own record | consensus as a `resolved_as` value | a study shows that early agreement with a later consensus predicts event outcomes |
| Typed append-only tables; recursive CTEs; Datalog as the spec language (§14) | one datom table; `aiq.edges`; pg_mentat | an agent-facing query language is wanted, in which case a Datalog surface compiled top-down over these tables, under row security, is the thing to build |
