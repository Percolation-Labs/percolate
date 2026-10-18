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
