# Statistics probes: the store answers from its own numbers, not from the question's wording

A probe is a third place Jev can look, between the question and the rows (catalogue section P). The store reads statistics it already keeps, returns a short verdict, reads no content, and makes no round trip to the model. Under the bitter-lesson reading of the conjunction result, the case for a probe is cost and attention, not secret knowledge: the model could ask for the same number, but it rarely knows to, and asking costs it a turn.

## P4: is the answer in the store at all? (registered 18 Oct, before the out-of-domain set existed)

OUT_OF_DOMAIN is judged from the question's wording alone, and on real traffic it could not tell an obscure detail inside the store (0.85–0.90) from a question outside it (0.91–0.92). Whether the store holds something is a fact about the store. The probe is the cosine between the question's embedding and its nearest passage: one approximate-nearest-neighbour read, with no rows returned to anyone.

- **In-domain:** the 166 blind sub-questions of the conjunction sets (`../conjunction/questions.jsonl` and `fresh/questions.jsonl`), each about a detail stated in one passage.
- **Out-of-domain:** 80 questions written by a blind agent who was told the store holds only the novel's text. They cover eight groups: adaptations, Stoker's life, real history and places, other vampire fiction, criticism, plausible details the novel never gives, period facts, and characters' lives after the novel.
- **Measures:** separation (AUC) of in-domain from out-of-domain by top-1 cosine, against Jev's OUT_OF_DOMAIN probability from the question alone, and the two combined. Also the share of each group the probe gets right at the threshold that holds 95% of in-domain questions.

**Predictions:**
- **Q1.** The top-1 cosine separates in-domain from out-of-domain with AUC of at least 0.85.
- **Q2.** Combined with Jev's probability, it beats either alone.
- **Q3.** Group 6, plausible details the novel never gives, is the hardest for both: its nearest passage is near, because the subject is in the book even though the fact is not.
