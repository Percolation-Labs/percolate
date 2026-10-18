# The conjunction control: results (18 Oct)

This is the protocol and predictions in `README.md`, run once: 76 blind sub-questions (45 kept), 80 blind compounds (30 orthogonal pairs, 20 orthogonal triples, 30 related pairs), bge-small over the 620 Dracula passages, and k = 10. The raw numbers are in `out/report.json`, `out/measure.json`, `out/jev.jsonl` and `out/detect.jsonl`.

## Blending loses the parts, and splitting recovers them

| group | compound recall | decomposed, same budget | gain | median rank of a part's answer, compound vs alone |
|---|---|---|---|---|
| orthogonal pairs | 0.62 | 0.90 | +0.28 | 6 vs 1 |
| orthogonal triples | 0.18 | 0.93 | **+0.75** | 39.5 vs 1 |
| related pairs | 0.78 | 0.92 | +0.13 | 4 vs 2 |

- **The geometry is the mechanism.** An orthogonal compound's embedding drifts away from each part's answer: mean cosine 0.649 for pairs and 0.637 for triples, against 0.683 for the part asked alone. A related compound lands closer to its answers (0.706 against 0.686).
- **Splitting at the same row budget almost never costs recall.** It lost recall on 3 of 80 compounds (1 orthogonal, 2 related).

**P1 holds.** The gain is +0.28 for pairs and +0.75 for triples, against the 0.20 bar, and triples gain more. **P2 fails.** Related pairs still gain +0.13, against the 0.05 bar: blending hurts a little even when the parts are close.

## Detecting the property from the question alone

| detector (Jev, question only) | orthogonal | related | mean gain where it fires | mean gain where it is silent |
|---|---|---|---|---|
| DECOMPOSITION_REQUIRED (shipped, 0.95) | 50/50 | 30/30 | +0.34 | n/a |
| TWO_QUESTIONS, CONJUNCTION (shipped) | 0/50 | 0/30 | n/a | +0.34 |
| part count (one / two / three or more) | 74/80 counted right | | | |
| "parts unrelated", p ≥ 0.5 | 49/50 | 13/30 | **+0.43** | **+0.06** |
| "parts unrelated", p ≥ 0.7 | 40/50 | 10/30 | +0.44 | +0.19 |

- **P3 fails as registered.** The shipped DECOMPOSITION_REQUIRED fires on every compound, related ones included. It is a compound detector, not an orthogonality detector. TWO_QUESTIONS and CONJUNCTION never fire on these.
- **A question asked about the property itself separates them.** "Are the things `question` asks about unrelated, so that no single passage would answer them together?" is a Noul with criteria. At 0.5 it fires where splitting gains +0.43 and is silent where it gains +0.06. This was added after P3 failed, so it is post hoc, and it has to hold on a fresh set before it ships.

## What this means for the exception

The policy the data supports is simple:
- **Split any question with three or more parts.** Of 20 triples, 19 gained, and the mean gain was +0.75.
- **Split two unrelated parts.**
- **Leave two related parts alone,** where splitting gains little (+0.06 where the detector is silent).

Splitting is never a refusal: it almost never loses recall, and its cost is extra queries, not lost evidence. The exception should be a warning carrying the count and the parts ("this asks 3 unrelated things; search each"), not an error.

## Not yet shown

Step 5 of the README, an agent following the exception and getting better results end to end, has not been run. Neither has the detector on a fresh set of compounds, or on a second store.

## The fresh set (registered bars in README.md, commit da1b529)

There are 90 new passages (54 sub-questions kept) and 72 new compounds (30 orthogonal pairs, 20 triples, 22 related pairs). The code, cuts, writer instructions and detector wording are the same as in the first set. The numbers are in `fresh/out/`.

**The effect replicates.**

| group | compound recall | decomposed, same budget | gain |
|---|---|---|---|
| orthogonal pairs | 0.43 | 0.87 | +0.43 |
| orthogonal triples | 0.20 | 0.87 | +0.67 |
| related pairs | 0.71 | 0.86 | +0.16 |

**The detector, against its bars:**

| bar | needed | fresh set | |
|---|---|---|---|
| F1: fires on orthogonal | ≥ 80% | 42/50 (84%) | holds |
| F1: fires on related | ≤ 45% | 9/22 (41%) | holds |
| F2: gain where it fires | ≥ 0.30 | +0.49 | holds |
| F2: gain where silent | ≤ 0.10 | +0.24 | **fails** |
| F3: parts counted right | ≥ 85% | 70/72 (97%) | holds |

It misses 8 orthogonal compounds that gain a lot from splitting, so it fails F2 and, as registered, it does not ship.

## Which policy to ship, measured on both sets

| policy | recall, first | recall, fresh | extra queries, first / fresh |
|---|---|---|---|
| never split | 0.57 | 0.45 | 0 / 0 |
| split only if "unrelated" ≥ 0.5 | 0.90 | 0.80 | 82 / 70 |
| split 3+ parts or "unrelated" | 0.90 | 0.82 | 82 / 74 |
| **split any compound** | **0.92** | **0.87** | 100 / 92 |

**The calibration question dissolves.** Splitting almost never loses recall, and even related parts gain from it (+0.13 first set, +0.16 fresh). So the best policy for recall is to split every compound, and the relatedness detector only trades recall for fewer queries. The exception that earns its place is the one already shipped. DECOMPOSITION_REQUIRED fired on 149 of 152 compounds across both sets, and agents that follow it should recover about 0.4 of recall on two-part questions and about 0.7 on three-part ones, at one extra query per extra part.

**Still to show:** an agent shown the exception actually splits, and gets that recall end to end.
