# Results: semantic exceptions, run of 18 Oct 2026

**Under test.** The kinds were judged by `jev-1.13.0`, using instructions from
`percolate_core/semantic_exceptions/catalogue.py` on branch
`amartey/semantic-exceptions`, cut from percolate-core `3560df6`. That branch has
no release yet. There were 487 question fixtures and 154 passage fixtures across
two domains (`dracula` and `eng`). Five blind subagent generators wrote them, and
two blind labellers labelled every item. Their instructions are in GENERATE.md
and LABEL.md. No paid generator wrote anything: Jev made 681 requests, about
686k input tokens in all. An earlier pass of 487 question requests was spent
and lost to a missing output directory, so the total spend was about 1,168
requests.

## The verdict, against the bars committed in README.md

- **Question stage:** 22 kinds are on, 6 are off (held-out F1 < 0.6) and 6 are unmeasured (fewer than 5 held-out positives).
- **Passage stage:** 7 kinds are on, 1 is off.
- **Noise bar: passed.** On 43 held-out plain questions, the on kinds raise 0.023 error-severity kinds per question (bar 0.2) and 0.233 kinds of any severity.

Every threshold below is the train-half optimum, and every score is on the held-out half.
`catalogue.MEASURED` carries the same numbers.

## Question stage (one Jev request per question)

| kind | threshold | precision | recall | F1 | test positives | labeller agreement | status |
|---|---|---|---|---|---|---|---|
| COUNTERFACTUAL | 0.90 | 1.00 | 1.00 | 1.00 | 4 | 1.000 | unmeasured |
| RELATIVE_TIME | 0.80 | 1.00 | 1.00 | 1.00 | 8 | 0.994 | on |
| OPINION | 0.90 | 1.00 | 1.00 | 1.00 | 8 | 0.996 | on |
| EXACT_MATCH | 0.85 | 1.00 | 0.93 | 0.96 | 14 | 0.988 | on |
| COMPARISON | 0.95 | 0.92 | 1.00 | 0.96 | 11 | 1.000 | on |
| NEGATION | 0.95 | 1.00 | 0.91 | 0.95 | 11 | 1.000 | on |
| EXHAUSTIVE | 0.95 | 1.00 | 0.86 | 0.92 | 7 | 1.000 | on |
| CAUSAL_WHY | 0.95 | 0.80 | 1.00 | 0.89 | 8 | 0.998 | on |
| PREDICTION | 0.55 | 0.80 | 1.00 | 0.89 | 4 | 1.000 | unmeasured |
| INSTRUCTIONS_MIXED_IN | 0.95 | 1.00 | 0.80 | 0.89 | 5 | 0.996 | on |
| YES_NO_CLAIM | 0.95 | 0.83 | 0.94 | 0.88 | 16 | 0.984 | on |
| KNOWN_VS_HAPPENED | 0.90 | 0.88 | 0.88 | 0.88 | 8 | 0.998 | on |
| EXPLORATORY | 0.80 | 0.86 | 0.86 | 0.86 | 7 | 0.998 | on |
| OUT_OF_DOMAIN | 0.90 | 0.86 | 0.86 | 0.86 | 7 | 1.000 | on |
| UNDERSPECIFIED | 0.90 | 0.75 | 1.00 | 0.86 | 3 | 0.992 | unmeasured |
| TWO_QUESTIONS | 0.65 | 0.67 | 1.00 | 0.80 | 4 | 1.000 | unmeasured |
| COUNT | 0.95 | 0.77 | 0.83 | 0.80 | 12 | 0.998 | on |
| PATH | 0.95 | 0.67 | 1.00 | 0.80 | 4 | 1.000 | unmeasured |
| DECOMPOSITION_REQUIRED | 0.95 | 0.89 | 0.67 | 0.76 | 12 | 0.998 | on |
| MISSING_REFERENT | 0.95 | 1.00 | 0.60 | 0.75 | 10 | 0.994 | on |
| ANSWER_EMBEDDED | 0.90 | 0.86 | 0.60 | 0.71 | 10 | 0.994 | on |
| META_QUESTION | 0.90 | 0.80 | 0.57 | 0.67 | 7 | 1.000 | on |
| SUPERLATIVE | 0.90 | 0.46 | 1.00 | 0.63 | 6 | 0.994 | on |
| CONJUNCTION | 0.95 | 0.46 | 1.00 | 0.63 | 6 | 0.998 | on |
| ARITHMETIC | 0.85 | 0.60 | 0.67 | 0.63 | 9 | 1.000 | on |
| ROLE_NOT_NAME | 0.85 | 0.50 | 0.80 | 0.61 | 5 | 0.998 | on |
| PROCEDURAL | 0.90 | 0.75 | 0.50 | 0.60 | 6 | 0.998 | on |
| LEADING | 0.80 | 0.43 | 1.00 | 0.60 | 3 | 1.000 | unmeasured |
| FILTERS_EXTRACTABLE | 0.90 | 0.41 | 0.90 | 0.57 | 30 | 0.940 | off |
| ALIAS | 0.90 | 0.42 | 0.71 | 0.53 | 7 | 0.951 | off |
| SPATIAL | 0.85 | 0.36 | 0.83 | 0.50 | 6 | 0.996 | off |
| VAGUE_TERM | 0.80 | 1.00 | 0.33 | 0.50 | 6 | 0.994 | off |
| TIME_UNSPECIFIED | 0.95 | 0.00 | 0.00 | 0.00 | 6 | 0.996 | off |
| PRESUPPOSITION | 0.95 | 0.00 | 0.00 | 0.00 | 5 | 0.988 | off |

## Passage stage (one Jev request per hit; CONFLICT is asked of each pair within the request)

| kind | threshold | precision | recall | F1 | test positives | labeller agreement | status |
|---|---|---|---|---|---|---|---|
| POINTER | 0.95 | 1.00 | 1.00 | 1.00 | 7 | 1.000 | on |
| TRUNCATED | 0.95 | 1.00 | 0.88 | 0.93 | 8 | 1.000 | on |
| HEARSAY | 0.90 | 0.86 | 1.00 | 0.92 | 6 | 0.987 | on |
| OFF_QUESTION | 0.55 | 0.78 | 1.00 | 0.88 | 7 | 1.000 | on |
| INJECTION | 0.95 | 0.75 | 1.00 | 0.86 | 6 | 1.000 | on |
| SPECULATIVE | 0.85 | 0.71 | 1.00 | 0.83 | 5 | 1.000 | on |
| CONFLICT | 0.90 | 1.00 | 0.64 | 0.78 | 11 | 1.000 | on |
| PARTIAL_ANSWER | 0.90 | 0.60 | 0.50 | 0.55 | 6 | 1.000 | off |

## End to end

`demo.py` runs `guard(strict=True, values=True)` against live Jev over a toy
search. Its output is in `out/demo.txt`. The guard refuses both blended
questions and the negation before searching, and the reason it gives is the
prompt. The plain question searches, and comes back with the result-stage and
passage-stage exceptions the model would read.

## Caveats

- **The held-out half is small.** Most kinds have 5 to 14 held-out positives, so
  one item moves an F1 by around 0.1. Read a status near the 0.6 bar as
  provisional: SUPERLATIVE, CONJUNCTION, ARITHMETIC, ROLE_NOT_NAME and
  PROCEDURAL are on by margins of 0.04 or less.
- **The fixtures are synthetic.** They are questions written to exhibit a kind,
  not traffic. Recall on real queries, where kinds are subtler, is unmeasured.
- **One run.** This is one generation and one labelling. Run-to-run spread is
  unmeasured.
- **The grid tops out at 0.95.** 30 of the 42 kinds chose 0.90 or 0.95, so for
  some of them the optimum may lie above the grid.
- **The structural detectors are not in this eval.** Unit tests cover them on
  planted results. Their absolute score thresholds (`low_score`, `flat_spread`)
  stay off until a repository measures them for its own embedding model.

## What surprised us

- **Three kinds fire on most questions as worded.** We expected PRESUPPOSITION,
  TIME_UNSPECIFIED and FILTERS_EXTRACTABLE to be selective. Instead, on
  questions both labellers marked negative, Jev puts them at P ≥ 0.5 for 96%,
  60% and 69% respectively, so no threshold separates them. The labellers apply
  them sparingly: 15, 14 and 59 gold positives out of 487 questions. The
  instruction asks something nearly every question literally satisfies. All
  three are off. Fixing them means rewording and re-running, not moving a
  threshold.
- **Recall was not the problem.** On the generator's own targets, Jev reached
  P ≥ 0.5 for 92 to 100% of them on every kind. Every kind that failed did so on
  precision.
- **The labellers barely disagreed.** Agreement was 0.94 to 1.00 per kind, so
  almost no item fell out of the gold for disagreement. The gold is settled
  enough to measure against. Whether it is the right gold is a separate
  question, since both labellers read the same definitions Jev did.
