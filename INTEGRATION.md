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

## Runs from empty

| when | head | result |
|---|---|---|
| 28 Oct 21:37Z–29 Oct 00:05Z | 87d67963 / core befca31 | INVALID: Postgres OOM-killed at 22:36Z and 00:05Z; the Docker VM (7.6 GB) held ~10 stacks. 10, 20, 60, 70 matched expected; 30–71 carry crash errors. |
