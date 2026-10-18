# The conjunction control: does splitting a compound question recover what blending loses?

**Purpose.** Semantic exceptions move search know-how out of every agent and into the data tier, once, so agents and their prompts can be simpler. This is the first case to be tested on that claim, and it is chosen because it can be measured cleanly. A question with independent parts ("X, and Y, and Z") embeds near the average of its parts. That average can land away from the passages that answer each part. If so, the store should be able to say "this has N independent parts; ask them separately", and the agent need not know it.

**Data.** The 620 Dracula passages and their bge-small-en-v1.5 vectors (`../navigate/build.py`). The text is not committed.

1. **Sub-questions.** Two blind agents each read half of 76 sampled passages and wrote one specific question per passage, naming its subject, with its answer (`questions.jsonl`). The passage is the sub-question's gold. A sub-question is kept only if its gold ranks in the top 10 when it is asked alone: one the store cannot answer alone cannot test blending.
2. **Compounds.** These are pairs and triples of kept sub-questions, in two groups:
   - **Orthogonal:** every pair of gold passages has cosine below 0.66.
   - **Related (the negative control):** pairs whose gold passages have cosine at least 0.82.

   A third blind agent, who saw only the sub-questions, joined each set into one natural question in varied styles (`compounds.jsonl`).
3. **Retrieval** is by cosine over the passages with the same embedding model, and k is 10.
   - **Compound recall:** the share of the parts' gold passages in the compound's top k.
   - **Decomposed recall at the same budget:** each of n parts gets its top ⌈k/n⌉, merged.
   - **Decomposed recall unbounded:** each part gets its own top k. This is reported as a reference.
4. **Geometry.** For each part: the rank of its gold passage under the compound question and under the part alone, and the cosine from each.
5. **The label is measured, not judged.** "Splitting helps" means decomposed recall at the same budget exceeds compound recall.
6. **Detection.** Jev reads only the compound question. Its shipped kinds are scored: DECOMPOSITION_REQUIRED, TWO_QUESTIONS and CONJUNCTION. Each is measured for recall gained where it fires and for false alarms on the related control.

**Registered before any compound was measured (18 Oct):**

- **P1.** On orthogonal compounds, decomposed recall at the same budget exceeds compound recall by at least 0.20 on average, and the gain is larger for triples than for pairs.
- **P2.** On the related control, the gain is at most 0.05: blending related parts does not hurt.
- **P3.** DECOMPOSITION_REQUIRED (or TWO_QUESTIONS) fires on at least 80% of the orthogonal compounds where splitting helps, and on at most 20% of the related control.

If a prediction fails, that is reported, not tuned.

**One amendment, made before any compound was measured.** The cuts were registered as 0.55 and 0.75. No pair of kept passages falls below 0.55: passages from one book under bge-small have cosine 0.64 at the 5th percentile, 0.75 at the median and 0.86 at the 99th, across 990 pairs. The cuts are now the 10th and 90th percentiles of that distribution, 0.66 and 0.82. The distribution says nothing about recall, so the change cannot favour a prediction.
