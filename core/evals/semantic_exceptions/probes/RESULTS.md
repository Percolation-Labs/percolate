# Probe P4: results (18 Oct)

The test had 166 in-domain questions and 80 blind out-of-domain ones (`ood.jsonl`). The P4 probe is the cosine between a question and its nearest passage, under the store's bge-small vectors; it reads no content. It is set against Jev's OUT_OF_DOMAIN probability from the question alone, and against the combination fixed in the code before the run (`ood_p − 4·(top1 − 0.75)`). The numbers are in `out/p4-report.json`.

| signal | AUC | caught at 0% / 1% / 5% false alarms on in-domain |
|---|---|---|
| probe: nearest-passage cosine | 0.896 | 4 / 6 / 50 of 80 |
| Jev, question only | 0.972 | 36 / 50 / 64 of 80 |
| **combined** | **0.981** | 36 / **62** / **72** of 80 |

- **Q1 holds:** the probe alone separates at AUC 0.896, against the 0.85 bar.
- **Q2 holds:** the combination beats both. The gain is where a deployed threshold sits, at low false-alarm rates: 62 against 50 at 1%, and 72 against 64 at 5%.
- **Q3 fails.** The hardest group was not plausible details the novel never gives (the probe caught 7 of 10). It was criticism (3 of 10) and real history and places (4 of 10), whose subjects are the book's, so their nearest passage is near.

## What it means

- **Jev's reading of the question is the stronger signal (0.972 against 0.896).** That is the bitter lesson again. The real-traffic false alarms were not a ranking failure. They were a calibration failure: obscure in-domain details scored just under questions outside the store.
- **The probe earns its place as a second signal, not on its own.** Whether the store holds something is partly a fact about the store. The nearest passage adds that fact at the cost of one nearest-neighbour read, and at a 1% false-alarm rate it raises catches from 50 to 62.
- **Not yet shipped.** The combination's weight was fixed before the run but has been measured on this one set. It needs a fresh set before it replaces the 0.92 threshold, and the query tool would have to run the probe on the query's semantic source.

# Probe P1: results (18 Oct)

There were 16 store-generated questions and 8 capable Haiku agents (4 shadow, 4 on), with at most 4 queries a question (`truncation/score-run1.json`).

**Two corrections to the key, made before scoring.** Both are recorded in `questions.json`. Q2's key counted only the stem of "wolf", where the question asks for "a wolf or wolves". The key is now 44, which every agent found. And "mention" has two fair readings: the store's stemmed text search and a literal ILIKE (Varna: 18 against 21). The scorer accepts either truth.

**One contamination.** S3, a shadow agent, was never shown an exception (the log confirms it). But the agents shared a scratch folder, and O2's saved query outputs there contained the on arm's advice naming `sx.passages`. S3 says a "tool note pointed to sx.passages", and it used SQL. It is reported both ways. The next run gives each agent its own folder.

| arm | truncated, right | controls, right | queries per right answer, truncated |
|---|---|---|---|
| shadow, without S3 | 15/21 (0.71) | 6/27 (0.22) | 2.13 |
| shadow, all four | 22/28 (0.79) | 15/36 (0.42) | 2.23 |
| on | 23/28 (0.82) | 15/36 (0.42) | 1.87 |

- **The count probe never fired.** TRUNCATED_AT_LIMIT was shown 0 times, because capable agents raised the LIMIT to 1000 on their own, so no result filled its limit. Like decomposition, a capable agent handles truncation itself. **T1 fails:** +0.11 on truncated questions, not 0.25, and none of it came from the probe.
- **What did help was disclosure of the table.** The date-list questions (most of the controls) are answerable only by SQL over `sx.passages`, which has source, document and time. One on agent (O1) reached it through the COUNT and NEGATION advice, which names the table and its columns, and answered all 16. The shadow agents without help said "the store does not expose which document a passage belongs to". **T2:** without S3, on beats shadow on controls 0.42 to 0.22, so the arms differ where T2 said they would not. The cause is the named table, not the count.
- **T3 holds.** The on arm spent fewer queries per right answer on truncated questions (1.87 against 2.13).
- **Advice that never reaches the agent does nothing.** Two of the four on agents did not use it. O3 wrote a parser that stripped the SEMANTIC EXCEPTIONS text before reading the reply. O4 raised the LIMIT, so nothing fired, and was never told about the table.

## What it means

The probe as built is redundant for a capable agent: the agent can see truncation and raise a limit. The fact that moved answers was structural and is not in any row: this source is a table, these are its columns, and they include who wrote each passage and when. That is a schema disclosure, given once, on the way in. Under the bitter-lesson reading, it is also something the tool's description could carry for every caller, at no per-query cost, rather than an exception. The next step is to test exactly that: the relation and its columns in the tool description, against the same questions.
