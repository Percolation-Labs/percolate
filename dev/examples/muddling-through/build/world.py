#!/usr/bin/env python3
"""Build samples/walk-0 from the reachability study's world walk-0: a synthetic graph, its questions and its verdicts.

    python3 build/world.py <reachability spike dir> samples/walk-0

Run once by whoever refreshes the sample; a reader never runs it. walk-0 has no text, so it cannot go in through
ingestion. Its items, tags and sittings ARE the world, so they go in as a graph: two tables of the sample's own,
projected as `world_item` and `world_tag` nodes, and the links a walk travels as edges between them, all by
construction (REM-1199):

  walk_tagged   world_item -> world_tag    the item carries the tag; provenance {n}, the tag's members
  walk_next     world_item -> world_item   the next item in the sitting; provenance {sitting, pos}
  walk_nearest  world_item -> world_item   one of the item's 3 nearest in meaning; provenance {rank}

A tag is a node here and not a pair of items, as it is on a source's documents (`percolate walk index`), because
walk-0's tags are wide: its 2,407 tags have 45,156 members, which as item pairs would be 26.9 million edges. The tags
are public sample data in the sample's own table, so a tag node publishes nothing.

It writes:

  world.sql        the tables, their rows, the node registrations and the edges, for the sample's sql step
  questions.jsonl  every question: its phrasing, its evidence and what it names as node keys, and `search`, the first
                   1,600 items in the order the world's search ranks them (the world's vectors stay in the study)
  verdicts.json    every P the world's decider gave on the study's walks, as a `percolate walk` verdict file, so each
                   step replays at $0. The decider is the world's own (reach.decide), not Jev: the world has no words
                   for a model to read.
"""
import json
import sys
import uuid
from pathlib import Path


NS = uuid.UUID("6f1c1b8e-1203-4a52-9e9f-000000000000")
SEARCH = 1600


def uid(kind, key):
    return str(uuid.uuid5(NS, f"{kind}:{key}"))


def insert(table, cols, rows, batch=2000):
    """Multi-row INSERTs: the sample's sql step runs a file through asyncpg, which has no COPY FROM stdin."""
    lit = lambda v: "null" if v is None else str(v) if isinstance(v, int) else "'" + str(v).replace("'", "''") + "'"
    out = []
    for i in range(0, len(rows), batch):
        vals = ",\n".join("(" + ", ".join(map(lit, r)) + ")" for r in rows[i:i + batch])
        out.append(f"insert into walk_world.{table} ({', '.join(cols)}) values\n{vals};\n")
    return "".join(out)


def main(spike, dst):
    spike, dst = Path(spike), Path(dst)
    sys.path.insert(0, str(spike))
    import reach
    from percolate_core.walk.engine import TASK as task

    world = spike / "runs/worlds/walk-0"
    store = reach.Store(world)
    name = "walk-0"
    key = lambda i: f"{name}/{i}"
    items = [(uid("item", i), key(i), "claim" if i.startswith("c") else "doc",
              *(store.pos[i] if i in store.pos else (None, None))) for i in store.ids]
    tags = [(uid("tag", t), key(t), len(store.members[t])) for t in sorted(store.members)]
    tagged = [(uid("item", i), uid("tag", t)) for t in sorted(store.members) for i in store.members[t]]
    nxt = [(uid("item", a), uid("item", b), s, k)
           for s, xs in store.by_sit.items() for k, (a, b) in enumerate(zip(xs, xs[1:]))]
    near = [(uid("item", i), uid("item", j), r) for i in store.ids for r, j in enumerate(store.fwd.get(i, []))]

    sql = [Path(__file__).with_name("world_schema.sql").read_text()]
    sql.append(insert("items", ["id", "key", "kind", "sitting", "pos"], items))
    sql.append(insert("tags", ["id", "key", "n"], tags))
    sql.append(insert("tagged", ["item", "tag"], tagged))
    sql.append(insert("next", ["a", "b", "sitting", "pos"], nxt))
    sql.append(insert("nearest", ["a", "b", "rank"], near))
    sql.append(Path(__file__).with_name("world_edges.sql").read_text())
    (dst / "world.sql").write_text("".join(sql))

    qs = []
    for q in map(json.loads, open(world / "questions.jsonl")):
        order = store.nearest(q["vector"], SEARCH)
        qs.append({"qid": f"{name}/{q['qid']}", "phrasing": q["phrasing"], "gold": [key(i) for i in q["gold"]],
                   "named": [key(t) for t in q["named"]], "search": [key(i) for i in order]})
    with (dst / "questions.jsonl").open("w") as f:
        for q in qs:
            f.write(json.dumps(q) + "\n")

    verdicts = {}
    for r in map(json.loads, open(world / "decisions.jsonl")):
        verdicts.setdefault(f"{name}/{r['qid']}", {})[f"{r['kind']}:{key(r['x'])}"] = round(r["p"], 6)
    (dst / "verdicts.json").write_text(json.dumps(
        {"model": "reach-synthetic (the world's own decider, REM-1191)", "task": task, "verdicts": verdicts},
        sort_keys=True, separators=(",", ":")) + "\n")
    print(f"{len(items)} items, {len(tags)} tags, {len(tagged)} tagged, {len(nxt)} next, {len(near)} nearest, "
          f"{len(qs)} questions, {sum(map(len, verdicts.values()))} verdicts", file=sys.stderr)


if __name__ == "__main__":
    main(*sys.argv[1:3])
