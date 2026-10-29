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
| 29 Oct 03:05Z | expected 45/60/70/71 regenerated from run 2: text columns became node summaries; every number unchanged | this commit | |

## Runs from empty

| when | head | result |
|---|---|---|
| 28 Oct 21:37Z–29 Oct 00:05Z | 87d67963 / core befca31 | INVALID: Postgres OOM-killed at 22:36Z and 00:05Z; the Docker VM (7.6 GB) held ~10 stacks. 10, 20, 60, 70 matched expected; 30–71 carry crash errors. |
| 29 Oct 01:44Z–03:03Z | 863b914d / core befca31 | PASS, no OOM (VM to itself). Every block ok; setup, step-1 and step-5 checks pass; 20, 30, 40, 50 match expected. 45, 60, 70, 71 differ only where timmy's REM-1233 replaced ids and the budget regex with node summaries; numbers identical; regenerated. 79 min. |
| 29 Oct 05:00Z–05:47Z | 33620e62 / core 746f83f | PASS, final: everything on REM-1237's list. run.sh exit 0, every block ok, every expected file matches, setup/step-1/step-5 checks pass, no OOM. 47 min. Stack 5801 left up as the one test database. |
