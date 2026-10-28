# walk-0, a synthetic world

A world built to have a known answer: 5,778 documents and 7,499 claims in 214 sittings, 2,407 tags from 32 generic
ones to 442 planted terms that each touch at most ten items, and 30 questions in five phrasings, each with its evidence.
Half the evidence is a satellite, reachable only by a nearest-meaning hop.

It has no words. An item is a key (`walk-0/d12657`), its tags and its place in a sitting, so the walkthrough runs on it
the steps whose point is the graph's shape: the coverage certificate (step 2) and near-miss exploration (step 4).

- `world.sql` holds the tables `walk_world.items` and `walk_world.tags`, projected as `world_item` and `world_tag`
  nodes, and the edges `walk_tagged`, `walk_next` and `walk_nearest`, all derived from the world by construction.
- `questions.jsonl` has every question with its evidence (`gold`) and the tags it names. Search's order is stored as
  `walk_seed` edges from each `world_question` node, the first 1,600 items.
- `replays.jsonl` stores, for step 2's q6 and step 4's six instruction questions, a P for every clue the world can
  raise (`replay/<qid>.json`), from the world's own decider. It is not Jev: there are no words for a model to read.
- `question-texts.jsonl` stores each question by uri `question:walk-0/<qid>`, without its answer key: the database
  never holds it, and `build/labels.py` reads it from `questions.jsonl` for the evaluation functions.

`build/world.py`, `build/world_replay.py`, `build/replays.py` and `build/questions.py` made them from the
reachability study's `runs/worlds/walk-0`.
