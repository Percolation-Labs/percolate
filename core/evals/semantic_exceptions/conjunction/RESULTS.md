# The conjunction control: results (18 Oct)

**How to read this, first: a bitter-lesson result.** Even Haiku splits a compound question on its own. In 135 of 135 question sessions its first query asked one part (step 5a), so for a capable agent the decomposition exception had nothing to do. What the result does show is resilience. A thin agent that carries no search know-how, told only to follow the store, goes from 0.31 to 0.97 (step 5b). That is real, but it is a placeholder with diminishing returns: decomposition is exactly the kind of general principle models learn. And on the way in the case is weak as a design principle, because anything Jev reads from the question could be given to the model directly. The case worth making is on the way out and by statistics probe, where the store sees the whole result or its own counts before the agent does, and where the argument is cost and attention: the same answer for fewer turns, queries and tokens. The result is not that the data tier knows something the model cannot.

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

## Step 5a: capable agents already split (18 Oct)

8 Haiku agents (4 shadow, 4 on) each answered the same 20 orthogonal compounds from the fresh set through the query tool, at most 3 queries per question. Nothing in the prompt mentioned splitting. Each answer was scored from the query log against each part's answering passage (`e2e.py`, `e2e/capable-agents.json`).

| arm | recall | queries per question | exceptions shown |
|---|---|---|---|
| shadow | 0.78 | 2.19 | none |
| on | 0.83 | 1.83 | ALIAS 12, CAUSAL_WHY 7, OUT_OF_DOMAIN 6, COUNT 4, DECOMPOSITION_REQUIRED 1 |

- **No agent ever sent a compound to the store.** In all 135 question sessions, the first query was one part, in both arms. So DECOMPOSITION_REQUIRED had nothing to fire on (shown once in 80 questions). A capable agent already carries this piece of search wisdom, and the exception adds nothing for it.
- **A harmful false positive.** OUT_OF_DOMAIN fired on a part about the East Cliff at Whitby, which is in the book, and one agent stopped looking for it.
- **This is the wrong test of the purpose.** The purpose is that agents should not have to carry the wisdom. The test that matches it is a thin agent that forwards the question as given and is told only to follow what the store raises (step 5b).

## Step 5b: a thin agent, told only to follow the store, splits and recovers the answers (18 Oct)

This is the test that matches the purpose. 8 Haiku agents ran the same 20 compounds. Each one forwarded the question to the store word for word, as `SEARCH "<question>"`, and was told only to do what any SEMANTIC EXCEPTIONS block says, with up to 3 more queries. It was not told to split. The prompt was the same in both arms (`e2e/thin-agent-prompt.txt`). Scores were read from the query log (`e2e/thin-agents.json`).

| thin agent | recall from its own queries | recall, pairs / triples | queries per question | split |
|---|---|---|---|---|
| shadow (nothing shown) | **0.31** | 0.60 / 0.47 (everything seen) | 1.01 | 0 of 80 |
| on (exceptions shown) | **0.97** | 0.96 / 0.97 | 3.65 | 79 of 80 |

- **The store detected the compound on every question, in both arms.** DECOMPOSITION_REQUIRED was raised on the first query of 80 of 80 in shadow, and 79 of 80 in on.
- **Shown it, a thin agent splits every time and finds nearly everything.** Recall is 0.97 against 0.31. That beats the 0.87 measured offline, because the agents also reworded each part.
- **Together with step 5a, this is the claim made measurable.** A capable agent already splits (5a). An agent that carries none of that know-how, told only to follow the store, does just as well once the store says so (5b: 0.97, against 0.83 for the capable agents in 5a). The know-how moved out of the agent and into the data tier.

## Still open

- The relatedness detector, which saves queries rather than recall, failed F2 and does not ship.
- OUT_OF_DOMAIN fired on in-domain parts (the East Cliff at Whitby) in step 5a. That is a false positive to fix before the next kind is tested.
- DECOMPOSITION_REQUIRED is an error and refuses in strict mode. These results support keeping that: a refusal forces the split, and splitting almost never costs recall.
