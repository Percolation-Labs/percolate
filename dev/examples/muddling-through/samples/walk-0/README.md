# walk-0, a synthetic world

A world built to have a known answer: 5,778 documents and 7,499 claims in 214 sittings, 2,407 tags from 32 generic
ones to 442 planted terms that each touch at most ten items, and 30 questions in five phrasings, each with its evidence.
Half the evidence is a satellite, reachable only by a nearest-meaning hop.

It has no words. An item is a key (`walk-0/d12657`), its tags and its place in a sitting, so the walkthrough runs on it
the steps whose point is the graph's shape: the coverage certificate (step 2) and near-miss exploration (step 4).

- `world.sql` holds the tables `walk_world.items` and `walk_world.tags`, projected as `world_item` and `world_tag`
  nodes, and the edges `walk_tagged`, `walk_next` and `walk_nearest`, all derived from the world by construction.
- `questions.jsonl` has every question with its evidence (`gold`), the tags it names, and `search`, the first 1,600
  items in the order search ranks them. The world's vectors stay in the study; search's order is what a walk needs.
- `verdicts.json` holds every P the world's own decider gave on the study's walks (182,545 of them), as a
  `percolate walk` verdict file. The decider is not Jev: there are no words for a model to read.

`build/world.py` made all three from the reachability study's `runs/worlds/walk-0`.
