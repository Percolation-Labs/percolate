# The contract, calibrated: results of 18 October 2026

**Under test.** `percolate_core.semantic_exceptions` with the catalogue as committed alongside this file. Judgements were made by jev-1.13.0. There are two contracts:

- `cases.jsonl`: 84 cases written by me, of which 74 are judged and 10 structural.
- `heldout.jsonl`: 130 cases written by a blind subagent from `SPEC.md` alone.

## The verdict, against the bars in README.md

The shipped catalogue was run on both contracts, with the store described and without it. The query tool runs without a description unless `P8_SEMANTIC_EXCEPTIONS_STORE` is set.

| run | cases passed | wrong refusals | guidance points to the move |
|---|---|---|---|
| held-out, store described, run 1 | 97.7% | 0 | 58/58 |
| held-out, store described, run 2 | 97.7% | 0 | 57/59 |
| held-out, no store | 98.4% (128 cases*) | 0 | 56/56 |
| calibration (mine), store described | 94.1% | 0 | 54/55 |
| calibration (mine), no store | 91.6% (83 cases*) | 0 | 51/54 |

\* OUT_OF_DOMAIN is asked only when a store is described, so its cases are left out of the no-store runs.

Every remaining failure is a miss; no run produced a wrong refusal. Without a store description, recall drops on my own cases, and the drop includes the motivating blended question, "How many boxes did the Count ship, and where did they all end up?" An operator should therefore set the description. Before calibration, the held-out contract passed at 92–93% with one wrong refusal.

## How it was calibrated

Each change was tried as a variant (`variant-*.json`). A variant had to pass the contract and then be re-measured on the labelled eval (641 items), so that passing my own cases could not hide a loss on cases I did not write.

- **Variant 1: rejected.** It used yes/no criteria for SUPERLATIVE, COUNT, META_QUESTION and OFF_QUESTION. The contract rose from 79 to 83 of 84, but the eval fell for three of the four kinds (META_QUESTION, for one, went from F1 0.67 to 0.29). Reading the disagreements showed the gold was right and three of my own cases were wrong. Those cases are corrected, with reasons, in their `corrected` field.
- **Variant 3: shipped.** It adds criteria for INJECTION, CONFLICT, META_QUESTION and OUT_OF_DOMAIN, a general wording for SUPERLATIVE, and COUNT from variant 2. On the eval it is equal or better on every changed kind:
  - OUT_OF_DOMAIN: 0.86 → 1.00.
  - SUPERLATIVE: 0.63 → 0.67, with precision 0.46 → 0.67.
  - COUNT: 0.80 → 0.85.
- **Variant 4 (MISSING_REFERENT): shipped,** found in use. The query tool, in strict mode with no store described, refused "Where did the garlic for Lucy's room come from?" at 0.96–0.97 on three calls; the old wording read "the garlic" as a dangling reference. The new wording scores it 0.61–0.63, while true dangling references stay at 0.97–0.98.
- **Thresholds and on/off status** are measured on each item's probability averaged over every run with identical wording (`../out/merged/RUNS.json`).
- **The refusal rule, amended post hoc.** An error-severity kind refuses: in strict mode it withholds rows. So its threshold is the higher of the train F1 optimum and the lowest threshold that holds train precision ≥ 0.85. F1 alone had put INJECTION at 0.40, with precision 0.75, and the runbook case scored exactly 0.40. Held-out precision is now NEGATION 1.00, DECOMPOSITION_REQUIRED 0.89, MISSING_REFERENT 0.86 and INJECTION 1.00.

## Still failing, and why

- **ANSWER_EMBEDDED and YES_NO_CLAIM overlap.** "Harker got out by climbing down the wall, right?" raises YES_NO_CLAIM, not ANSWER_EMBEDDED. The guidance is the same: confirm or refute.
- **CONFLICT misses an implied disagreement.** In "The Demeter came ashore", one passage implies 8 August through its dateline and the other states 10 August outright.
- **SUPERLATIVE at its measured threshold of 0.95 misses two of my "first mention" cases.** The eval chose that trade.
- **Two disputable cases:** ROLE_NOT_NAME on an unnamed landlady, and a presupposition labelled ANSWER_EMBEDDED.
- **Two held-out near misses about "first meeting" and "first night"** follow the example I wrote into SPEC.md. The labelled gold contradicts that example, so these two cases are contaminated by the spec, not evidence against the layer.

## Injected into the query layer

`percolate_core.semantic_exceptions.query` turns any `aiq.query` envelope into a typed report. The `query` MCP tool uses it under `P8_SEMANTIC_EXCEPTIONS` (`off`, `on` or `strict`). It was run end to end against a disposable stack (`sx-nav-db` and `sx-nav-rest`, extension 0.2.22): the real PostgREST with a real JWT, called through the runtime's own MCP client.

- **In `on` mode:** a negation question came back with its rows, plus NEGATION and passage-stage SPECULATIVE and OFF_QUESTION exceptions. The receipt showed three stages, 49 kinds checked and 3 Jev requests.
- **In `strict` mode:** the rows were withheld behind the prompt.
- **One finding outside this module:** through MCP, SEARCH and SEMANTIC fail, because they need `p_embedding` and the tool never sends one. Only TEXT and the non-vector modes work there.

## Round 5: the kinds off for noise (18 Oct)

`variant-5.json` rewords TIME_UNSPECIFIED, PRESUPPOSITION and FILTERS_EXTRACTABLE, each with yes/no criteria, written from what the two labellers agreed on. It was measured twice on the labelled eval (`out/v5`, `out/v5b`), with the probabilities averaged (`out/v5m`). No other kind changed status; PARTIAL_ANSWER moved between runs, but it is a passage kind the variant does not touch.

| kind | fires at p ≥ 0.8 (of 487), old → new | held-out F1, old → new | status |
|---|---|---|---|
| TIME_UNSPECIFIED | 155 → 13 (18 at its 0.75 threshold) | 0.00 → 0.43 | off; the rewording is kept |
| PRESUPPOSITION | 277 → 163 | 0.00 → 0.13 | off; the old wording stays |
| FILTERS_EXTRACTABLE | 217 → 147 | 0.58 → 0.54 | off; the old wording stays |

- **TIME_UNSPECIFIED is kept but stays off.** It is no longer noise, but 6 held-out positives cannot carry a precision. Several of its 8 "false positives" look right to me ("Tickets in the MOB project filed by Kenji that are still open"), and the eval does not let me overrule the labels.
- **FILTERS_EXTRACTABLE is a planner's job, not an exception.** The two labellers disagree on 29 questions, more than for any other kind, because almost every question here names a narrator or a record type. A repository that knows its filterable fields should extract them, and a prompt to the model adds nothing.
- **PRESUPPOSITION does not separate.** Every question assumes something. Wording has not found the line between an ordinary premise and a doubtful one, and five held-out positives are too few to fit one.
- **A false alarm of my own.** The shipped catalogue raises 0.30 kinds of any severity per plain question, up from 0.23. The bar is on error-severity kinds, which stay at 0.0. Of the 24 warnings, 16 are EXACT_MATCH on a ticket id or a commit hash: key lookups, which is the right advice for a question the generator called plain.

## Round 6: MISSING_REFERENT from real traffic (18 Oct)

The query log (`../traffic`) caught MISSING_REFERENT refusing on real queries, and none of its three firings there was a real missing referent: "Which letters never mention Arthur?" (0.80 with a thin store description), "Check how TEXT matches terms" (0.70), and earlier "the garlic for Lucy's room". Real dangling references ("What did he decide after that?") sit at 0.96–0.97 under either description. Its threshold moves from 0.70 to 0.90. On the labelled eval that is precision 1.00 (0 false positives) at recall 0.45, against 0.87 at 0.65; a refusing kind trades recall for precision, as the contract's own bar says. Both contract sets are unchanged at the new threshold: held-out 97.7%, 0 wrong refusals, guidance 57/59 (`final-ho-r3.json`); calibration 94.1%, guidance 54/55 (`final-cal-r3.json`).

## What surprised us

- **The deployment condition was not the measured one.** Every measurement passed a store description to Jev; the query tool did not. The same question then scored above a refusal threshold. The contract now runs both ways.

- **I was wrong about my own contract.** We expected the author's cases to be the safe ground truth. Three of them were overturned by independent labels, and one of my spec's examples misled the held-out writer.
- **Identical wording measured twice changed status.** Three kinds crossed the 0.6 bar between runs with no change at all. A single measurement cannot set a status near the bar.
- **A real defect came from the contract, not the unit tests.** A raised exception looked its kind up in the shipped catalogue, so a repository's own kinds (and every variant) spoke with the default prompt. The unit tests all used the default kinds and could not see it.
- **Rewording cannot fix a kind its labellers cannot agree on.** FILTERS_EXTRACTABLE had the most labeller disagreement, and no wording helped. Where people disagree, the kind is the wrong unit.
