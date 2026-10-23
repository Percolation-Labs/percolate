# Extraction — prose into datapoints and motifs, as cheaply as possible

**Status: spec, with a measured cascade.** `sources.md` gets prose into
`resources`. `tradecraft.md` grades what we assert. This is the step between:
turning unstructured text into **time-series datapoints** and **graph motifs**,
landed in a staging area that a later consolidation pass ("dreaming") reads.

The design goal is stated as a cost: **do this with as few model calls as
possible, and ideally none.** Everything below is organised around that, and §2
is a measurement rather than an argument.

---

## 1. The output vocabulary is closed

Two kinds of thing come out, and only two.

**Datapoints** — a typed value with a span. Untyped as to meaning; typed as to
*form*. Dates, money, percentages, quantities with units, durations, external
identifiers.

**Motifs** — a small named subgraph with typed slots. Eight of them:

| motif | slots | why it exists |
|---|---|---|
| `commitment` | subj, act, when | **the clock** — an obligation with a date |
| `event` | subj, act, obj, when | something happened |
| `attribution` | src, verb, claim | keeps *told* separate from *believed* |
| `measurement` | subj, metric, value, unit, when | a datapoint bound to an entity |
| `is_a` | subj, type | classification |
| `part_of` | a, b | composition, ownership |
| `succession` | a, b | replacement over time |
| `causal` | a, b | **deliberately low-confidence** |

**Closed is the whole design.** An extractor that can emit anything cannot be
checked against a schema, cannot be costed per unit, and cannot be swapped for a
cheaper extractor later — because there is nothing to compare. A closed
vocabulary also makes "what did we fail to extract?" a measurable quantity
rather than a feeling.

`causal` is in the list and scored at 0.4 rather than excluded, because causal
language is *frequent* in prose and almost always weaker than it reads. Catching
it explicitly at low confidence is better than catching it accidentally as an
`event`.

---

## 2. What it costs — measured, not assumed

A cascade of four tiers, run over 32 real documents from four very different
prose styles: UK Gazette insolvency notices, Federal Register rules, arXiv
abstracts, BBC news items.

### Tier 0 — structural. Free, works everywhere.

Regex over forms that carry their own meaning.

| source | docs | chars | datapoints | per 1k chars |
|---|---|---|---|---|
| gazette | 12 | 15,690 | 57 | **3.6** |
| fedreg | 6 | 35,554 | 53 | 1.5 |
| arxiv | 8 | 7,541 | 4 | 0.5 |
| news | 6 | 1,316 | 0 | 0.0 |

114 datapoints, no model, no configuration: 40 long-form dates, 39 US dates, 15
external identifiers, 7 durations, 7 money amounts, 3 percentages, 3 quantities.

**This tier is the cheap win and it should always run.** Note the gradient:
dense in legal and regulatory prose, near-absent in news headlines and academic
abstracts. Structural extraction pays where the writing is *bureaucratic*.

### Tier 2 — generic motif templates. **This failed.**

Eight hand-written motif regexes over the same 32 documents produced **4 motifs
total**: 2 `event`, 1 `causal`, 1 `attribution`.

**Zero on the Gazette** — twelve documents of the most rigidly structured prose
in the corpus. Zero on arXiv.

That is not a tuning problem. Legal notice prose does not put a capitalised
subject before an active verb; it says *"A Petition to wind up the above named
Company of X presented on DATE by Y claiming to be a Creditor"*. A generic
natural-language template cannot match it, and making the regex loose enough to
match would make it match everything.

**Recorded as a negative result: generic motif extraction by pattern does not
work on real prose.** Anyone reaching for it should know it was tried.

### Tier 2′ — per-source templates. This works.

The same twelve Gazette documents, with a template written for *that source*:

| approach | yield |
|---|---|
| generic tier-0 | 57 **untyped** values |
| generic motif regex | **0** |
| per-source template | 37 **typed** slots (44% fill) |
| …scoped to the right document type | **66% fill** (36/54, n=9) |

And the typed slots are things the generic tier cannot produce at all, because
it does not know what the strings mean:

```
court_ref   CR-2026-XXX-000000
company     EXAMPLE TRADING LIMITED
company_no  00000000
sic         00000- Example industry classification
presented   1 January 2026
petitioner  EXAMPLE CREDITOR LIMITED
```

### The unit is (source × document type), not source

The 44% → 66% jump is the finding. The twelve "Gazette" documents are nine
petitions and three other notice kinds, and a petition template scores 44% over
the mixture and 66% over petitions alone. The Gazette publishes **18 notice
categories**; each needs its own template.

**A template keyed on source is wrong. Keyed on (source, doctype) it works.**

---

## 3. Where the LLM goes, and why it is cheap there

The measurement above rearranges the economics completely.

> **The model's job is to author the template, not to read the documents.**

One call per `(source, doctype)`, amortised over every document that source ever
publishes. For the Gazette at ~800 notices a fortnight, that is **one call
instead of eight hundred**, and the call is repeated only when the source
changes its format — which `sources.md` §5.1's schema fingerprint already
detects.

The cascade, cost-ordered:

| tier | what | cost | when |
|---|---|---|---|
| 0 | structural datapoints | free | always |
| 1 | gazetteer against `aiq.node_keys` | free | always |
| 2 | template for `(source, doctype)` | **one model call, ever** | once per format |
| 3 | model reads the document | one call **per document** | only where 0–2 leave the field empty |

Tier 3 is the escape hatch and its usage is the metric that matters: **what
fraction of documents need a per-document call?** If tier 2 templates are
working, it should be the long tail — sources too small to be worth a template,
and prose too irregular to template at all (news, social).

### 3.1 Tier 3 is not "a model reads it" — it is a specialist agent per source

The sharper form of tier 3, and it mirrors what the collection already does with
connectors: **`agentic.agents` holds hundreds or thousands of extractors, one per
`(source, doctype)`, each with a declared output schema** — exactly as
`content.connectors` holds hundreds of sources. An extractor is a row, not code,
and adding one is an `INSERT`.

The framework already has every piece:

| piece | where | state |
|---|---|---|
| per-agent output contract | `agentic.agents.structured_output_schema jsonb` | **exists** |
| per-step contract | workflow `output_schema:` → `tasks.input.output_schema` | **exists** (compiler emits it) |
| validation on completion | `complete_task` → `workflow.validate_shape` | **exists in SQL** |
| retry semantics | shape violation is **retryable** — asking a model again is a real remedy | **exists** |

That last row is the good design decision: a shape violation is not terminal,
because re-prompting genuinely fixes it, whereas an over-size payload is
terminal because the same response will be the same size every time.

**Why per-source agents beat one general extractor**, and why they beat tier 2
templates for irregular prose:

- A specialist's system instructions can carry the source's gotchas — the ones
  `sources.md` §14 already collects as data — so the knowledge that a Gazette
  petition names the petitioner *after* the presentation date lives with the
  extractor rather than in a person's head.
- The output schema **is** the motif slot list, so tier 3 emits the same closed
  vocabulary as tiers 0–2 and lands in the same table. Nothing downstream knows
  which tier produced a row except by the `tier` column.
- Yield is measurable per agent, exactly like `templates.fill_rate`, so a
  specialist that degrades is detectable rather than merely disappointing.

**Untested.** The shape check once did not run: the compiler dropped
`output_schema` silently, and a step declaring `required: [by, title, time]`
completed `done` on the bare integer `49522586`. The compiler now emits the
contract into the task input and refuses keys it does not know, and
`workflow.compiler_capabilities()` probes the emitted spec. What remains is to
build and measure the extractors.

The workflow shapes this needs (the base case, fan-out over specialists, cheap
tiers first with agents only for the gaps, and extractor evaluation) are not yet
written up publicly.

Two properties make this safe to run cheaply:

- **Extract once, interpret many times.** The staging area holds motifs, not
  conclusions. Changing your mind about what a motif *means* costs a SQL query,
  not a re-extraction.
- **Span-anchored and idempotent.** Every row carries `(resource_id, start,
  end)`. Re-extraction with a better template replaces rather than duplicates,
  and any row can be audited back to the text that produced it.

---

## 4. Where it lands

Deliberately schema-light. This is a staging area, not the world model — the
same *told versus believed* split `sources.md` §3 draws, one layer earlier.

```sql
create table extract.datapoints (
    resource_id uuid not null,
    span        int4range not null,
    kind        text not null,          -- date | money | quantity | identifier | …
    value       text not null,          -- verbatim
    normalised  jsonb,                  -- {n: 257, unit: 'count', at: '2026-06-30'}
    tier        int not null,
    primary key (resource_id, span, kind)
);

create table extract.motifs (
    resource_id uuid not null,
    span        int4range not null,
    motif       text not null references extract.motif_types(motif),
    slots       jsonb not null,         -- typed by motif_types.slot_schema
    tier        int not null,
    confidence  numeric not null,
    template_id bigint references extract.templates(id),
    primary key (resource_id, span, motif)
);

create table extract.templates (
    id        bigint generated always as identity primary key,
    source    text not null,
    doctype   text not null,            -- §2: the unit is the PAIR
    motif     text not null,
    pattern   jsonb not null,           -- named capture groups -> slots
    authored_by text not null,          -- 'human' | 'model:<name>' — provenance
    fill_rate numeric,                  -- measured, not claimed
    unique (source, doctype, motif)
);
```

`templates.fill_rate` is measured on registration and re-measured on drift. **A
template that stops filling is the same signal as a schema fingerprint change**,
and it is the cheapest possible detector for a source quietly changing format.

`authored_by` matters because a model-authored template that nobody checked is a different object from
one a person wrote, and the difference should survive in the row.

---

### 4.1 Where this stops, and a coherence layer starts

Two staging areas now exist in the same pipeline, one per layer, and until this
was written nothing said where the line falls or why they disagree about
re-extraction. Both facts are worth having in one place.

**A motif is not a claim.** `extract.motifs` is a *slot-set found in a span* —
"this text contains a commitment, with these fields." A claim in a coherence
layer is a *triple somebody asserted* over a closed predicate vocabulary, with
a stance toward a cross-source assertion. The step between them is
interpretation, and it belongs on the coherence side: this layer finds
structure in text, that layer decides what the structure asserts about the
world. The practical test — if answering it needs a judgement about the world
rather than about the document, it is not a motif.

**They disagree about re-extraction, and both are right.**

- `extract.motifs` is keyed `(resource_id, span, motif)` and a better template
  **replaces** the row. That is correct because a motif is *re-derivable*: it
  is a function of the resource and the template, the resource is immutable,
  and nothing has cited the old row. Keeping superseded extractions would be
  keeping a cache's history.
- A claim is append-only and a re-extraction under a new
  `extractor_version` writes a **new** claim beside the old one. That is
  correct because a claim is *evidence*: it has been scored, attached to an
  assertion with a stance, and possibly promoted to an edge. Overwriting it
  destroys the audit trail the whole method exists to preserve, and "our
  extractor changed its mind" is itself coherence evidence.

So the rule is: **append-only begins at the boundary, not before it.**
Everything on this side of the line is a re-derivable cache and may be
replaced; everything past it is attributed evidence and may only be appended
to. The moment a motif is cited by a claim, the motif's own row must stop
moving — which means promotion has to copy `span_text` across rather than
reference the motif row, since this side reserves the right to overwrite it.

### 4.2 A quote is evidence by one rule

Every extractor that asks a model for a claim also asks for the verbatim span
it came from, and keeps the claim only when that quote is found in the source
(or keeps it flagged, as pgvector-watch does). The check is
`aiq.quote_occurs(quote, source)`, in `ingestion.sql`, and nothing else
restates it: SQL calls it and Python asks the database for it.

The rule, applied to both texts: lowercase; fold every quote mark (`'`, `"`,
`‘ ’ “ ”`) to one; drop the emphasis a model adds around a quote (`*`, `_`,
backticks); collapse whitespace runs to one space. The quote also loses the
spaces, punctuation (`.,;:…-`) and quote marks at its edges. It is evidence when
what is left occurs whole in the source and is at least **8 characters** long,
because a short enough string occurs in anything.

It is an identity check with formatting removed, not a similarity score, and
where it stops is measured. Folding markup took acceptance on the
failure-mode corpus from 12 of 17 to 15 of 17, and all three recovered were
verbatim quotes wearing asterisks. The two left are paraphrase drift: the model
finds the passage and re-types it imperfectly after thirty characters. Accepting
any contiguous 40-character span of the quote recovers one more, and at fifteen
characters it accepts all seventeen, so a fragment rule accepts everything
eventually. Drift stays a miss, and the cost is recorded here rather than
optimised away.

There were eight copies of this check with four rules before: one forgave markup
and had no minimum, one trimmed edges and wanted eight characters,
pgvector-watch forgave nothing and wanted eight, and one took a four-letter
quote. The same quote was evidence in one package and
not the next, so evidence counts could not be compared across them.

## 5. Dreaming — what reads this later

Consolidation is out of scope here and the interface is not. What the staging
area owes it:

- **Append-only, span-anchored, idempotent** — so a consolidation pass can be
  re-run over a growing corpus without double-counting.
- **Confidence and tier on every row** — so consolidation can weight a
  template-extracted `commitment` above a model-guessed `causal`.
- **No promotion.** Nothing here writes to `aiq.nodes` or `content.moments`.
  Promotion is the consolidation pass's decision, and keeping it out of
  extraction is what allows extraction to be cheap and wrong.

**A `commitment` motif is a forward clock**, and the clock is what change
detection over a corpus otherwise lacks. `commitment` is the
one motif whose extraction quality directly determines whether the system can
say "this resolves on 16 September" — which is why it is first in §1's table.

---

## 6. Open questions

- **Tier 1 is untested.** The gazetteer path was prototyped outside this repository and run with an
  empty name list, so its yield is unmeasured. Since `aiq.node_keys` already
  holds canonical and alias keys, this is the cheapest remaining experiment.
- **Can a model author a template reliably?** §3's entire economic argument
  rests on it, and it is unmeasured. The test is direct: give a model five
  documents of one `(source, doctype)`, ask for named capture groups, measure
  fill rate against a human-written template on held-out documents.
- **How is `doctype` determined?** For the Gazette it is a field. For a scraped
  page it is not, and misclassifying a document applies the wrong template —
  which fails quietly at a lower fill rate rather than loudly.
- **What is the tier-3 rate in practice?** Unknown until templates exist for a
  real source set. If it turns out to be most documents, the cost argument
  collapses and this is just an LLM extraction pipeline with extra steps.
- **Motif coverage is unmeasured against ground truth.** We know the generic
  regexes find almost nothing. We do not know what fraction of the *findable*
  motifs in a document a good template finds, because nothing has hand-labelled
  a document to compare against.
