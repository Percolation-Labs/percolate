# Navigating a real store with semantic exceptions

**Under test.**
- **Module:** `percolate_core.semantic_exceptions` on branch `amartey/semantic-exceptions`, from `40b3f54` through the commits named below. Judgements were made by jev-1.13.0.
- **Store:** Bram Stoker's *Dracula* as 620 passages of about 200 words (`build.py`, from the iterative-query spike's 241 dated entries), embedded with bge-small-en-v1.5 and searched by hybrid ranking.
- **Repository:** `nav.py`, with `search` guarded by the module, plus exact `list`, `grep`, `read` and `around`.

**The question.** Does a user of this store feel guided wisely about where to go next?

**How it was tested.**
- I used it myself first.
- Then blind user agents took the same tasks through the same tool, with exceptions on (arm A) or off (arm B), and were not told which.
- A separate agent graded every answer against a written key (`users/KEY*.md`), blind to the arm.
- Each user also wrote down what helped and what got in the way (`users/out-*.json`).

## Results

| round | users | change under test | arm A (exceptions) | arm B (none) |
|---|---|---|---|---|
| 1 | Opus, 8 tasks | guard on `search` | 16, 15 of 16 | 16, 16 of 16 |
| 2 | Haiku, 7 tasks | refusals need precision ≥ 0.85; each exception once per task; store fixes | 14, 14 of 14 | 13, 13 of 14 |
| 3 | Haiku, 7 tasks | the task's question judged when the task starts | 14, 13 of 14 | 12, 13 of 14 |

- **Round 1 hit a ceiling.** With exact tools at hand, a strong user answered everything without guidance. The exceptions arm ran more commands (58 and 74, against 61 and 32), and its notes name the cost: wrong refusals and repeated warnings.
- **On Haiku, arm A scored 55 of 56 and arm B 51 of 56.** Every lost point but one is on the boxes question, which needs reading on from the first hit to find all three London destinations. Arm B missed it in all four runs. Arm A missed it in one, and in rounds 1 and 2 arm A users credited CONTINUES with sending them to the passage that held the counts. This is 8 users and one discriminating task, so it is a consistent direction, not a measurement.
- **Guidance only works where the user meets it.** In round 2, Haiku ran two searches per user and did everything else with `grep` and `list`, so the question-stage exceptions never reached them. In round 3 the task's own question was judged when the task started. Both arm A users then credited it: "The task-start warnings were the most useful part. DECOMPOSITION_REQUIRED and the COUNT and NEGATION warnings pointed me to exact tools" (A5).

## What changed because of it

Each change below was found in use and is committed with its reason:
- **Prompts name the repository's own command** (`actions`) and the records each exception is about. Before this, "filter on an exact field" was right but gave the user nothing to type.
- **A question-stage error refuses only with held-out precision ≥ 0.85.** SUPERLATIVE (0.46) and ARITHMETIC (0.60) refused harmless lookups. COUNT refused a search for a number the text states.
- **`Report.novel`** shows each exception once per task. Repeats taught users to skip the whole block.
- **The gap detectors need an absolute `min_gap`.** A ratio called a 0.019 cosine gap a standout.
- **TRUNCATED_AT_LIMIT needs a known total,** because a ranked search always fills its limit.
- **CONTINUES** marks a passage that is part of a longer record.
- **The repository wiring and store were fixed:** no SINGLE_SOURCE under a source filter, TIME_SKEW measured against the window asked for, heading-only passages dropped, matching across line breaks and from the start of a word, `a|b` in grep, `--by-entry`, and `read` refusing an unknown id with the ids that exist.

## Caveats

- **Small, with a ceiling.** 12 users in all, and one task in seven discriminates. A store large enough that exact tools stop being enough is the next test.
- **Round 1 was not fully blind.** Its control users read help text that described the exceptions layer, though they never saw output from it. From round 2 on, the control help says nothing about it.
- **One reported bug was not reproduced.** B6 said `list --without Arthur --by-entry` printed all nine entries. Re-run, the command returns the one correct entry, and the control arm does not log `list` calls.
- **Store defects the module cannot see.** Users found entry dates that disagree with the dates in their text (e0081 is filed 19 August but reads 30 August) and a passage mislabelled as Seward's. A judged kind for "this record's date disagrees with its metadata" was asked for twice and is not built.

## What surprised us

- **A strong user does not need the store's advice; a weaker one uses it.** We expected the guidance to help everyone a little. Opus ignored it at no loss, while Haiku followed the task-start advice to the exact tool.
- **Where the guidance appears mattered more than what it says.** The same exceptions, attached to `search`, went unseen in round 2 because users chose other tools. Attached to the task, they shaped every plan.
- **The wrong-refusal cost is larger than the right-refusal benefit.** One false refusal made users distrust the next warning, so precision decides which kinds may block.
