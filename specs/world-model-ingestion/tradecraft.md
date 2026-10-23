# Tradecraft — the grading, corroboration and track-record layer

**Status: spec. The schema is specified in `tradecraft.sql` and not shipped in
the extension until something calls it.** `sources.md` is
how data gets in. This is how the system decides whether what got in is worth
asserting — and the useful discovery is that **almost none of it needs
inventing.** Intelligence services codified this between 1939 and 2015;
open-source investigators codified it again after 2014. Two traditions with no
contact between them converged on the same handful of rules.

So the question is not "what should our method be?" but **"which of these
established steps can a machine enforce, and which structurally cannot?"** That
split (§2) is what makes scoop generation democratisable rather than artisanal.

**The contribution here is not the standards. It is turning three prose
standards into constraints a database enforces** — `tradecraft.sql`, loaded and
exercised by hand against a PG19 beta instance (no test in this tree runs it yet). A rule that lives in a style guide is
followed when someone remembers; a rule that lives in a trigger is followed
always. §8 records what was actually run.

---

## 1. The Admiralty Code — the oldest idea, and still the right one

The NATO grading system ([AJP-2.1 / STANAG 2511](https://en.wikipedia.org/wiki/Admiralty_code)),
in use since 1939, scores every report **twice**:

| Source reliability (letter) | | Information credibility (number) | |
|---|---|---|---|
| A | Completely reliable | 1 | **Confirmed by other independent sources** |
| B | Usually reliable | 2 | Probably true — consistent, unconfirmed |
| C | Fairly reliable | 3 | Possibly true — agrees with some information |
| D | Not usually reliable | 4 | Doubtful |
| E | Unreliable | 5 | Improbable — contradicted |
| F | **Cannot be judged** | 6 | **Cannot be judged** |

Three things this settles that we were deriving from scratch.

**The letter is a property of the source; the number is a property of this
report.** A completely reliable source can file an improbable report — `A5` is a
valid and important grade. Our schema already separates a connector's `health`
from a claim's score for the same reason, and this is 85 years of precedent for
keeping them apart.

**Credibility grade 1 is defined as "confirmed by other *independent*
sources."** The word *independent* is in the 1939 definition. The entire
corroboration-versus-count argument is not a modern
refinement — it is the original standard, which most modern pipelines quietly
dropped when counting became cheap.

**F and 6 are first-class grades, not failures.** "Cannot be judged" is a
recordable outcome with its own symbol. That is `refusal is a first-class
outcome` under a different name, and it means our pipeline refusing to score
something is *conforming to* the standard rather than falling short of it.

---

## 2. ICD 203 — the modern standard, and the automatable half

[ICD 203](https://pangearesearch.substack.com/p/why-analytic-standards-exist)
(2007, revised 2015) governs every US intelligence analytic product. Five
overarching standards, nine tradecraft standards. Mapped against what a pipeline
can actually enforce:

| # | Tradecraft standard | Can a machine do it? |
|---|---|---|
| 1 | **Sourcing** — identify sources, assess accuracy, currency, credibility | **Yes, fully.** This is the connector catalogue plus schema fingerprinting (`sources.md` §5) |
| 2 | **Uncertainty** — express likelihood *and* analyst confidence | **Yes** — §3's lexicon makes it mechanical |
| 3 | **Distinctions** — separate information from assumption and judgment | **Yes, structurally** — this is `claims` vs `assertions` vs promoted facts |
| 4 | **Alternatives** — assess plausible alternative hypotheses | **Partly.** Enumerating alternatives is human; *checking* each against the record is automatable |
| 5 | **Relevance** — implications for the customer | **No.** Requires knowing who is reading |
| 6 | **Argumentation** — clear main message, coherent reasoning | **No.** This is writing |
| 7 | **Analytic line** — state consistency with, or change from, prior published analysis | **Yes** — and nobody does it. §5 |
| 8 | **Accuracy** — precise judgments on likelihood, timing, nature | **Measurable, not automatable** — this is the resolution ledger |
| 9 | **Visuals** — use graphics where they clarify | Yes, trivially |

**Five of nine are mechanisable.** That is the case for systematising this at
all: the majority of what a professional intelligence service demands of an
analyst is bookkeeping that a database does better than a person, and the
irreducible remainder — relevance, argumentation, hypothesis generation — is
exactly the part a human writer is being paid for.

---

## 3. Words of estimative probability — the cheapest thing to adopt

ICD 203 fixes a lexicon with **numeric bands**, so "likely" cannot drift:

| Term | Alternative | Band |
|---|---|---|
| Almost no chance | Remote | 1–5% |
| Very unlikely | Highly improbable | 5–20% |
| Unlikely | Improbable | 20–45% |
| Roughly even chance | Roughly even odds | 45–55% |
| Likely | Probable | 55–80% |
| Very likely | Highly probable | 80–95% |
| Almost certain(ly) | Nearly certain | 95–99% |

Two rules ride with it: **do not mix terms across rows**, and **never combine a
confidence level and a likelihood in one sentence** ("high confidence that it is
likely" is meaningless — one is about the evidence, the other about the world).

This is free to adopt, it makes generated text checkable against a closed
vocabulary, and it makes a **track record scoreable**. A writer who says "likely"
should be right 55–80% of the time, and after enough calls you can measure that.
Without a fixed lexicon there is nothing to score, which is why the resolution
ledger and this table are the same project.

---

## 4. Bellingcat — the open-source tradition arrives at the same place

The [Yemen Project collection protocol](https://yemen.bellingcat.com/methodology/collection-protocol)
is the most precisely specified public example. Its rules, and what each one
already corresponds to in this collection:

| Bellingcat rule | Our equivalent |
|---|---|
| **Preservation is kept separate from analysis** — items logged to a discovery sheet by the archive, before anyone interprets them | `raw/` written unconditionally before any adapter runs (`sources.md` §16.2) |
| **Minimum 3 independent sources from *different channels*** — UGC, media, NGO report, satellite | Distinct source-*type* count, never raw mention count |
| **Satellite imagery can authenticate with fewer sources** | A deterministic check outweighs structural agreement — the fusion weights are not specified here |
| **Content from parties to the conflict cannot be the sole basis** | Provenance weighting; an interested source is not independent |
| **Every investigation step recorded** (Hunchly) | a trace id through ingestion to promotion (not built) |
| **"Investigators never infer intent"** | Refusal as a first-class outcome — the pipeline declines motive |

That last one is the most striking. Bellingcat arrived at *never infer intent*
from courtroom-admissibility pressure; we arrived at *refuse motive, it is not
checkable against any source in the matrix* from checkability alone. Same
rule, different reasoning, no contact between the two.

**"Different channels" is the load-bearing phrase.** Three media reports are one
source. A filing, a satellite image and a court docket are three — because they
could not plausibly derive from one another. Counting *classes of evidence*
rather than *instances* is the whole of corroboration, and it is what a
records-over-distinct-events ratio exists to protect.

---

## 5. The standard nobody implements

**ICD 203 Standard 7 — "state consistency with, or change from, previously
published analysis."**

Every newsroom and every dashboard fails this. A story that reverses last
month's story is published as if last month never happened, and a pipeline that
scores a claim today has no memory of scoring it differently in June.

It is also the **easiest of the nine to automate**, because it needs no
judgement — only a key and a history. `assertion_scores` is specified as a time
series precisely so that "we said 0.3 in June and we say 0.8 now" is a query.

Two things fall out for free once it exists:

- **A changed score is itself a lead.** The score moving is a story even when
  neither endpoint is.
- **It is the only honest basis for a track record.** Standard 8 (Accuracy) is
  unmeasurable without Standard 7's history, and reputation without a track
  record is just seniority.

This is the strongest candidate for the first thing built after the connectors,
and it is worth stating plainly: **it is a competitive advantage available for
the cost of not deleting a row.**

---

## 6. What this actually democratises

The professional apparatus decomposes into three layers with very different
economics:

| Layer | Who | Cost |
|---|---|---|
| **Collection and preservation** | machine | approaching zero; `sources.md` |
| **Grading and bookkeeping** | machine | ICD 203 standards 1,2,3,7 + Admiralty grades |
| **Hypothesis, relevance, argument** | human | the irreducible part |

Historically all three were bundled inside an institution, which is why
investigative capacity correlated with newsroom size. Splitting them is the
actual democratisation: **a single writer with the first two layers automated
has the standing apparatus of a small intelligence desk**, and spends their time
on the third layer where their judgement is worth something.

The failure mode to name now: automating layer three. A model can generate a
plausible hypothesis and a fluent argument, and both will be *coherently* wrong
in a known way — a mutually
reinforcing web that is globally false. Layers one and two exist to constrain
layer three, and inverting that is how you build a machine for producing
confident nonsense at scale.

---

## 7. Adoption order

1. **The likelihood lexicon** (§3). Free, immediate, makes everything else
   scoreable.
2. **Admiralty double-grading** (§1) — source letter on the connector, credibility
   number on the claim. Two columns.
3. **Standard 7 history** (§5). One table, never deleted.
4. **Source-class counting** rather than instance counting (§4).
5. **Alternatives** (ICD 203 #4) — the first genuinely hard one, and the point at
   which a human re-enters the loop.

## 8. The schema, and what it enforces

`tradecraft.sql`. Five tables, three views and three functions, loaded clean with
every rule below exercised rather than asserted.

### 8.1 Two prohibitions the database refuses

**ICD 203's confidence/likelihood rule, as a trigger.** The standard says a
product must not combine a confidence level and a degree of likelihood in one
statement, because one is about the evidence and the other about the world.
Verified — this insert fails:

```
"We have high confidence that the merger is likely to clear"
  -> ICD 203: do not combine a confidence level and a likelihood in one statement
```

**A likelihood with no resolution date is refused outright.** This one is ours,
not ICD 203's, and it is the single most consequential constraint in the schema:

```
"Construction insolvencies are likely to rise"   (likelihood='likely', no resolves_by)
  -> an assessment carrying a likelihood needs resolves_by, or it can never be scored
```

A probability nobody can ever settle is decoration. Refusing it at write time is
what makes Standard 8 (accuracy) measurable at all, and it is why most
reputation systems have no track record — they never required the forward date.

### 8.2 Corroboration counts classes and discounts derivation

`evidence_classes.derives_from` is the load-bearing column: `news` declares that
it derives from `registry`, `court`, `filing` and `igo_report`, so a news report
sitting beside the filing it describes adds nothing. Measured:

| Evidence supplied | records | classes | **independent** | publishable? |
|---|---|---|---|---|
| 9 news reports + 1 registry filing | 10 | 2 | **1** | no — *instances are not sources* |
| filing + court docket + seismic reading | 3 | 3 | **3** | yes |
| satellite + registry | 2 | 2 | **2** | yes — standalone class |
| social ×2 + attention | 3 | 2 | **1** | no |

The first row is the whole point: **ten records collapse to one independent
source**, and the failure message says so rather than just refusing.

`standalone` implements Bellingcat's satellite exception: a deterministic,
hard-to-fabricate class can carry an assessment on two sources where a soft
class needs three.

> `specs/trace-field/schema.sql` reaches the same rule independently as
> `origin_key`: compounding counts distinct origins, never deposits.

### 8.3 Standard 7 is one view

```sql
select subject_key, was, now, change_reason from tradecraft.v_line_changes;
--  merger-x | unlikely | very likely | third-party complaint filed
```

Append-only assessments plus a `supersedes` pointer, and the standard nobody
implements becomes a query. `change_reason` is `NOT NULL` whenever `supersedes`
is set, so a silent reversal is impossible.

### 8.4 The track record uses a proper scoring rule

Brier score, because it is **proper** (Gneiting & Raftery 2007): expected score
is optimised by reporting your true belief, so hedging is penalised rather than
rewarded. Demonstrated on two authors who were both right every time:

| author | n | Brier | stated | actual |
|---|---|---|---|---|
| confident (said *very likely*) | 2 | **0.0156** | 0.875 | 1.000 |
| hedger (said *roughly even chance*) | 2 | 0.2500 | 0.500 | 1.000 |

Identical accuracy, sixteen times the penalty for hedging. An improper rule
would make "roughly even chance" the rational answer to everything, and a
reputation system built on one rewards cowardice — which is the failure mode
coherent-but-false consensus is, arriving through the scoring function
instead of the fusion.

`v_awaiting_resolution` is the queue that makes any of this real: assessments
whose forward date has passed and which nobody has scored. Left unworked it is
precisely why most reputation systems have no track record.

---

## 9. Build order and gates

1. **Lexicon + evidence classes as seed data.** *Gate: an unlisted likelihood
   term is rejected by foreign key; the seven terms round-trip.*
2. **Assessments with the two prohibitions.** *Gate: both refusals in §8.1 fire.*
3. **Corroboration + publishable().** *Gate: nine news reports plus one filing
   returns `n_independent = 1` and refuses — the §8.2 table reproduced.*
4. **Standard 7 history.** *Gate: a superseding row with no `change_reason` is
   rejected; `v_line_changes` shows the reversal.*
5. **Resolution ledger + Brier.** *Gate: a hedger and a confident forecaster with
   identical outcomes score differently, in the right direction.*
6. **Source reliability grading.** *Gate: every connector starts at `F` and no
   code path assigns a letter without resolved outcomes behind it.*

Steps 1–5 need no data beyond fixtures. **Step 6 cannot be gated yet at all**,
which is §10's first open question.

---

## 10. Open questions

- **Who assigns the Admiralty letter, and on what?** Every source starts at `F`
  — "no basis exists for evaluating reliability" — and can only earn a grade from
  resolved outcomes. With a 60–120 day resolution horizon that means the letters
  are honestly worthless for two to four months, and there is no shortcut: a
  grade assigned on impression is exactly the certificate-from-authority the
  Admiralty Code was designed to replace.
- **Does the lexicon survive contact with a model?** Generated text drifts toward
  hedging, and the constraint here is a foreign key on seven terms. Whether a
  model can be held to them reliably enough to score is untested.
- **`derives_from` is a static declaration.** `news` derives from `registry` in
  general, but a piece of original reporting that broke a story derives from
  nothing. The column is right on average and wrong in exactly the cases that
  matter most — a genuine scoop by a journalist is scored as derivative.
- **Independence is still not checkable.**
  Bellingcat's different-channels rule and this schema's derivation model are
  both better proxies than counting. Neither is a proof, and an adversary who
  learns the class taxonomy can fabricate across classes.
- **Nothing scores the assessments themselves for tradecraft compliance.**
  ICD 203 products are graded against the nine standards by a separate reviewer.
  Whether that review is itself automatable — grading the grader — is the
  regress, and it is unbuilt.
