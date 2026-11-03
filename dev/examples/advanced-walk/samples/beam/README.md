# BEAM: when the judge is sure of many leads

BEAM is a benchmark of long-term memory in chat assistants: long conversations in which a person mentions things
across many sittings, and questions that need several of those mentions at once. This sample holds two of its
conversations, one document per exchange, and one question on each. On both, the judge scores tens of leads at one
half or more, so the walk's budget rather than its judgement decides what it reads.

**The questions (questions.jsonl, written by the fetch).**
- **1M:16:event_ordering:1**. The walk's leads take every read they are allowed (80 of the 100; search keeps 20),
  and a fact that search alone would read by its 100th result is pushed out. Under the rule below, the walk reads 5
  of the 7 needed exchanges, where search alone reads 6.
- **1M:26:event_ordering:1**. Many leads clear the bar, and travelling them highest first decides which one goes
  first. Under the rule below, the walk reads 2 of the 8, where search alone reads 2. Together with 1M:16, it shows
  the cost of a confident judge in a small budget.

**Loading.**

    python3 harness/beam_fetch.py samples/beam    # BEAM downloaded and sha256-checked; vectors made here
    percolate sample load samples/beam
    percolate walk index --source beam-1m16
    percolate walk index --source beam-1m26

The fetch runs the walkthrough's harness (../muddling-through/harness/beam_fetch.py) for conversations 1M:16 and
1M:26. That harness pins BEAM's revision, checks its sha256, and writes one document per exchange. Before it runs,
the fetch embeds the exchanges' pieces here with BAAI/bge-small-en-v1.5, the model the stack's worker runs; on the
walkthrough's pieces these match the stack's own vectors at cosine .99999. So `sample load` stores them at once,
rather than queueing them for the stack's embedding pipeline.

**Replays, a stand-in judge's, NOT Jev's (replays.jsonl).** One document per question in `walk-replays`, holding every
P a stand-in judge (Claude, asked with no outside knowledge) gave on that walk, under the rule: each round's top three
leads plus any at one half or more, highest first, at most ten exchanges each. Pass a replay's document id as the
run's `replay`, with `offline: true` and settings `{"travel": "topk", "topk": 3, "travel_cap": 10, "order": "p",
"waves": 2}`, and walk.sql walks without calling a judge. On both questions the offline walk reads the same 100
exchanges in the same order as the walk that recorded them. They are not Jev's verdicts, and each says so in its
metadata (`judge`) and model.

Licence: CC BY-SA 4.0 (see LICENSE).
