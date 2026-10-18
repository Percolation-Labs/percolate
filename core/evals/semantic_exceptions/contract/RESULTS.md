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

## What surprised us

- **The deployment condition was not the measured one.** Every measurement passed a store description to Jev; the query tool did not. The same question then scored above a refusal threshold. The contract now runs both ways.

- **I was wrong about my own contract.** We expected the author's cases to be the safe ground truth. Three of them were overturned by independent labels, and one of my spec's examples misled the held-out writer.
- **Identical wording measured twice changed status.** Three kinds crossed the 0.6 bar between runs with no change at all. A single measurement cannot set a status near the bar.
- **A real defect came from the contract, not the unit tests.** A raised exception looked its kind up in the shipped catalogue, so a repository's own kinds (and every variant) spoke with the default prompt. The unit tests all used the default kinds and could not see it.
