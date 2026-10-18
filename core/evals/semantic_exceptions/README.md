# Measuring the judged semantic exceptions

`percolate_core.semantic_exceptions` raises a judged kind when Jev's P(yes) for
its instruction reaches the kind's threshold. This eval measures those thresholds
and says which kinds work well enough to be on by default. The protocol and the
bars below were committed before any fixture existed.

## Data

Every fixture is written by a blind Claude subagent on the subscription, with the
instructions it was given committed beside it (`GENERATE.md`, `LABEL.md`). No
paid generator wrote anything. Jev makes every judgement under test.

There are two domains, so that no threshold is tuned to one corpus:

- `dracula`: a store holding Bram Stoker's *Dracula* as dated journal entries,
  letters, telegrams, cuttings and a ship's log.
- `eng`: a store holding a software company's engineering records: tickets,
  incident postmortems, design documents, commit messages and on-call notes.

**Question stage.** For each domain and each of the 34 question kinds, a generator
writes 6 questions meant to raise that kind. It also writes 40 plain questions per
domain that a person might ask that store and that are meant to raise nothing
unusual. Two generators split the kinds for each domain, and neither sees another's
output.

**Values stage.** For each domain and each of the 7 per-passage kinds, a generator
writes 6 (question, passage) pairs, plus 15 plain pairs. For CONFLICT it writes 10
(question, passage, other) triples that disagree and 10 that agree.

**Gold.** Two labellers, each blind to the generator's target and to the other
labeller, label every item against the full kind list (multi-label). For a given
kind, an item is positive if both labellers apply the kind and negative if neither
does. Items where they disagree are left out of that kind's scores, and the
agreement rate is reported. The generator's target is never gold. How often the
gold contains the target is reported as a check on the generators.

## Measurement

- `run.py` asks Jev once per item and caches every probability in `out/probs.jsonl`,
  keyed by item and model version.
- `score.py` splits items by `sha1(id)` parity into train and test halves. For
  each kind, it picks the threshold on train that maximises F1 over the grid
  0.05..0.95 in steps of 0.05, preferring the higher threshold on a tie. It
  then reports precision, recall and F1 on test.

## Bars (committed before the run)

1. A kind is **on by default** when its test F1 is at least 0.6 with at least 5
   test positives. Otherwise it is **off by default**: still in the catalogue,
   and a caller can enable it.
2. A kind with fewer than 5 test positives is **unmeasured** and off by default.
3. **Noise.** On the plain questions in the test half, the shipped thresholds
   raise on average at most 0.2 error-severity kinds per question. If that bar
   fails it is reported as failed. Any change made after seeing results is
   labelled post hoc.
4. The thresholds shipped in `catalogue.py` are the train-half choices, and
   `RESULTS.md` names the run and the model version.
