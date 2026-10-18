# The contract: input in, typed exceptions out

The layer is a black box. Each case gives it one input and states what must come out:

- `raise`: codes it must raise.
- `not_raise`: codes it must not raise. These are mostly the near misses, where a word
  suggests a kind but the question is not that kind.
- `exact`: when present, the complete set of codes it may raise. A plain lookup is
  `exact: []`: the store has nothing to say about it.
- `i_would`: the move an experienced researcher would make with this store, written
  before the layer was run. For every case that raises something, `contract.py`
  checks that the guidance the layer renders points to that move. Jev makes the
  check, with the question "Would a reader who follows `guidance` make `move`?"

A case passes when all of its assertions hold. The layer passes its contract when:

1. **Every structural case passes.** These cases are deterministic, and the unit
   tests run them.
2. **On the held-out judged cases, at least 95% pass,** and no error-severity kind
   raises where a case says it must not. A wrong refusal costs more than a missed
   one.
3. **On the guidance check, at least 90% of the raising cases point to the move.**

There are two case files:

- `cases.jsonl`: calibration cases, written by me (the author of the layer). These
  are the cases I tune against.
- `heldout.jsonl`: written by a blind subagent from `SPEC.md` alone, never read
  while tuning. That file is the one the bars above are judged on.

Every change made to pass the contract is also re-measured on the labelled eval
(`../RESULTS.md`), so that passing my own cases cannot hide a loss on cases I did
not write.
