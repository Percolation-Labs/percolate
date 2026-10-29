# integration/part-three (REM-1237)

Local consolidated branch for part three; not for main. One test database: project muddling-through on 5801, image
percolationlabs/percolate-postgres:19-integration built from this tree, core from percolate-core's integration/part-three.

## Merged (merge commits, never squashed)

| at | what | head merged | core |
|---|---|---|---|
| 28 Oct 21:22Z | percolate#316 edges closed, never deleted (bill) | 556cde2a | core#146 at 1c171aa → befca31 |
| 28 Oct 21:23Z | generated SQL regenerated: the merge had dropped #316's trigger | ff1ecbc9 → own commit | |
| 28 Oct 21:25Z | run.sh takes PROJECT and PG_PORT | 08db8036 | |
| 28 Oct 21:31Z | percolate#309 blocks 70/71 (mike) | 715b0191 → 4cd7b874 | |
| 28 Oct 21:33Z | REM-1234 aiq.edges_as_of (bill) | 71afd448 → 87d67963 | |
| 29 Oct 01:20Z | run.sh fails a block whose output shows the database lost | c9c76b16 | |
| 29 Oct 01:38Z | REM-1231 keyless walk, walk_coverage, walk_why(run, labels) (cory) | d4ec26f8 → 2577c830 | |
| 29 Oct 01:41Z | REM-1232/1233/1236 run relations, node summaries, harness/ (timmy) | dea3b8c2 → 413b21d0 | |
| 29 Oct 01:43Z | setup keeps the span-2 graphs the replayed walks read (timmy's finding) | 863b914d | |
| 29 Oct 04:58Z | percolate#305 tagger + #306 describe via mike's c8/rem-1204-integration (walk_kept(uuid, timestamptz, text) joins timmy's node keying and the describe task) | c1f475ba → 33620e62 | core#145 at 06e084db → 746f83f |
| 29 Oct 09:25Z | REM-1238 worked examples from the stack's runs: harness/examples.py, blocks/35-examples.sh (timmy). Fast-forward. No expected/35: its output quotes BEAM's answer text, which the repo must not hold, so run.sh checks 35 runs, not its numbers | 6569c45b | |
| 29 Oct 03:05Z | expected 45/60/70/71 regenerated from run 2: text columns became node summaries; every number unchanged | this commit | |
| 29 Oct 14:30Z | REM-1245 the walk keeps a board (walk-stack.sql, F8–F14 to mike's spec, settings recorded per run, walk_structure with oracle), plan-index strip with 1,858 pieces re-embedded, step 1 now 21/12 (james) | cfb1ce8d → 5065145a | |

## Runs from empty

| when | head | result |
|---|---|---|
| 28 Oct 21:37Z–29 Oct 00:05Z | 87d67963 / core befca31 | INVALID: Postgres OOM-killed at 22:36Z and 00:05Z; the Docker VM (7.6 GB) held ~10 stacks. 10, 20, 60, 70 matched expected; 30–71 carry crash errors. |
| 29 Oct 01:44Z–03:03Z | 863b914d / core befca31 | PASS, no OOM (VM to itself). Every block ok; setup, step-1 and step-5 checks pass; 20, 30, 40, 50 match expected. 45, 60, 70, 71 differ only where timmy's REM-1233 replaced ids and the budget regex with node summaries; numbers identical; regenerated. 79 min. |
| 29 Oct 05:00Z–05:47Z | 33620e62 / core 746f83f | PASS, final: everything on REM-1237's list. run.sh exit 0, every block ok, every expected file matches, setup/step-1/step-5 checks pass, no OOM. 47 min. Stack 5801 left up as the one test database. |
| 29 Oct (timmy, own project timmy-1238 on 5871) | 6569c45b / core 746f83f | PASS: run.sh exit 0, every block ok including 35, every expected file matches. The run from empty for REM-1238's merge. |
| 29 Oct, ended 14:28Z (james, own project james-land on 5911) | 33e752fb / core image 0.2.14 (released today; not the integration core build) | PASS: build and run.sh exit 0, every block ok including 35, every expected file matches. The run from empty for REM-1245's merge. cfb1ce8d, merged on top, adds only walk_structure's judged_to_answer, which no block reads; test 48 covers it. |
| 29 Oct 16:03-16:09Z (james, james-land on 5911) | c96023cb (all of james/rem-1245-walk-stack plus percolate main at 0.2.35, SQL regenerated) / core image 0.2.14 | PASS: build and run.sh exit 0, every block ok including 35, every expected file matches. 6 minutes where earlier runs took 47-79; every capture has its content, so the speed is most likely REM-1249's walk_start fix (not measured). b7aae1c6 on top changes comments and test assertions only. The run for PR #320. |
| 29 Oct 13:31-14:13Z | 40dfbed1 / core 746f83f (cory's 9a9ddfb8 strip of pieces) | FAILED the expected files, not a block: 30, 50, 70, 71 differ by small shifts; step 1 and step 5 pass. Cause: the plan-index strip changed the stored text, so search's keyword half ranks differently (search's seeds 8-10 reorder on step 1). The keyless setup gate read 0. |
| 29 Oct 14:17-14:58Z | 70a7d331 / core 746f83f (cory's full strip, 1c884952; the 1,858 changed pieces re-embedded from their stripped text) | Every block ok; the step-1 check FAILED as written: search's own top 500 on step 1 holds 12 of 27, not 15 (the walk still 21). Decided by bill (14:20Z), by principle: the stripped stack is the record, since the walk and search must not read a benchmark artifact. |

## Regenerated from the 70a7d331 run (REM-1245), with the cause

Cause for every line below: BEAM's plan index ('->-> n,m' and its rarer forms) left both halves of search, the stored
text (keyword half) and the re-embedded vectors (vector half), so search's order moved, and every walk that starts from
it moved a few reads. The walk's settings are pinned (memoryless, source) in every published block, so none of this is
the question stack. Why search reads 3 fewer of step 1's 27: measured by mike (29 Oct ~14:45Z, $0, his marker.txt; builds
B = stripped text with the old vectors and C = marked text with the new vectors, on james's 5921/5931). Across 36
questions, stripping the text changes nothing and re-embedding moves search by under 2 points; evidence in plan
steps 1-12 lost no more rank. Step 1's 15 -> 12 is the re-embedding of its changed pieces on that one question and
does not generalise, so the pre-strip search numbers stand.

| file / check | before -> after |
|---|---|
| run.sh step-1 check | walk 21 / search 15 at 500 -> 21 / 12 |
| expected/30-a-miss-explained.txt | per-wave leads and evidence shift by 1-3 (e.g. wave 3: 85 -> 87 leads) |
| expected/50-tag-range.txt | lead counts by kind shift (next 213 -> 215; terms of 3-5 messages 4 -> 3) |
| expected/70-wave-by-wave.txt | search's seeds 8-10 reorder, and the waves after follow |
| expected/71-blind.txt | search ranks of the walk's off-search evidence shift by 1-25 |
| expected/20, 40, 45, 60 | unchanged |

