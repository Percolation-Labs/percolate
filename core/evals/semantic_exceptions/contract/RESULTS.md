# The contract, calibrated: results of 18 October 2026

**Under test.** `percolate_core.semantic_exceptions` with the catalogue as committed alongside this file. Judgements were made by jev-1.13.0. There are two contracts:

- `cases.jsonl`: 84 cases written by me, of which 74 are judged and 10 structural.
- `heldout.jsonl`: 130 cases written by a blind subagent from `SPEC.md` alone.

## The verdict, against the bars in README.md

| | held-out, run 1 | held-out, run 2 | bar |
|---|---|---|---|
| cases passed | 96.9% | 97.7% | ≥ 95% |
| wrong refusals | 0 | 0 | 0 |
| guidance points to the move | 57/57 | 57/58 | ≥ 90% |

My own calibration cases pass at 95.2%, and every structural case passes; CI runs those (`tests/test_semantic_exceptions.py`, `Contract`). Before calibration, the held-out contract passed at 92–93%, with one wrong refusal: runbook steps were refused as an injection.

## How it was calibrated

Each change was tried as a variant (`variant-*.json`). A variant had to pass the contract and then be re-measured on the labelled eval (641 items), so that passing my own cases could not hide a loss on cases I did not write.

- **Variant 1: rejected.** It used yes/no criteria for SUPERLATIVE, COUNT, META_QUESTION and OFF_QUESTION. The contract rose from 79 to 83 of 84, but the eval fell for three of the four kinds (META_QUESTION, for one, went from F1 0.67 to 0.29). Reading the disagreements showed the gold was right and three of my own cases were wrong. Those cases are corrected, with reasons, in their `corrected` field.
- **Variant 3: shipped.** It adds criteria for INJECTION, CONFLICT, META_QUESTION and OUT_OF_DOMAIN, a general wording for SUPERLATIVE, and COUNT from variant 2. On the eval it is equal or better on every changed kind:
  - OUT_OF_DOMAIN: 0.86 → 1.00.
  - SUPERLATIVE: 0.63 → 0.67, with precision 0.46 → 0.67.
  - COUNT: 0.80 → 0.85.
- **Thresholds and on/off status** are measured on each item's probability averaged over every run with identical wording (`../out/merged/RUNS.json`).

## Still failing, and why

- **ANSWER_EMBEDDED and YES_NO_CLAIM overlap.** "Harker got out by climbing down the wall, right?" raises YES_NO_CLAIM, not ANSWER_EMBEDDED. The guidance is the same: confirm or refute.
- **CONFLICT misses an implied disagreement.** In "The Demeter came ashore", one passage implies 8 August through its dateline and the other states 10 August outright.
- **SUPERLATIVE at its measured threshold of 0.95 misses two of my "first mention" cases.** The eval chose that trade.
- **Two disputable cases:** ROLE_NOT_NAME on an unnamed landlady, and a presupposition labelled ANSWER_EMBEDDED.
- **Two held-out near misses about "first meeting" and "first night"** follow the example I wrote into SPEC.md. The labelled gold contradicts that example, so these two cases are contaminated by the spec, not evidence against the layer.

## What surprised us

- **I was wrong about my own contract.** We expected the author's cases to be the safe ground truth. Three of them were overturned by independent labels, and one of my spec's examples misled the held-out writer.
- **Identical wording measured twice changed status.** Three kinds crossed the 0.6 bar between runs with no change at all. A single measurement cannot set a status near the bar.
- **A real defect came from the contract, not the unit tests.** A raised exception looked its kind up in the shipped catalogue, so a repository's own kinds (and every variant) spoke with the default prompt. The unit tests all used the default kinds and could not see it.
