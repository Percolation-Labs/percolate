#!/usr/bin/env python3
"""Complete replay documents for walk-0's step questions: a P for every clue the world can raise.

    python3 build/world_replay.py <reachability spike dir> samples/walk-0/replay

The walk on Percolate judges one round a wave (REM-1199), so it raises clues the study's walk never asked about, and
walk-0 has no words for Jev to read. The world's own decider (reach.decide) is deterministic -- its noise is a hash of
the question and the clue -- so this asks it about every clue there is: each tag, and next and near for each item. One
document per question, in the shape `percolate walk` and aiq.walk_* read: {model, task, verdicts: {qid: {key: P}}},
keyed term:<tag key>, next:<item key> and near:<item key>.

Before writing, it checks the decider against every P the study recorded (decisions.jsonl) and refuses on a mismatch:
a replay that disagrees with the study would move the steps without saying why.
"""
import json
import sys
from pathlib import Path

QUESTIONS = ["q6"]  # step 2, the certificate; step 4's instruction questions are added from the world's questions


def main(spike, dst):
    spike, dst = Path(spike), Path(dst)
    sys.path.insert(0, str(spike))
    import reach
    from percolate_core.walk.engine import TASK

    # The study recorded its walks with the decider fitted to Jev's own calls on rendered clues (jev_fit.json), not the
    # hand weights; the check below is what found that.
    reach.WALK["decider"] = "jev"

    world = spike / "runs/worlds/walk-0"
    store = reach.Store(world)
    qs = {q["qid"]: q for q in map(json.loads, open(world / "questions.jsonl"))}
    wanted = QUESTIONS + [k for k, q in qs.items() if q["phrasing"] == "instruction"]

    bad = 0
    for r in map(json.loads, open(world / "decisions.jsonl")):
        if r["qid"] in wanted and abs(reach.decide(qs[r["qid"]], (r["kind"], r["x"]), store) - r["p"]) > 1e-9:
            bad += 1
    if bad:
        sys.exit(f"the decider disagrees with {bad} recorded P values; refusing to write a replay")

    key = lambda i: f"walk-0/{i}"
    dst.mkdir(parents=True, exist_ok=True)
    for qid in wanted:
        q = qs[qid]
        v = {f"term:{key(t)}": round(reach.decide(q, ("tag", t), store), 6) for t in sorted(store.members)}
        for i in store.ids:
            v[f"next:{key(i)}"] = round(reach.decide(q, ("next", i), store), 6)
            v[f"near:{key(i)}"] = round(reach.decide(q, ("near", i), store), 6)
        doc = {"model": "reach-synthetic (the world's own decider, REM-1191)", "task": TASK,
               "verdicts": {key(qid): v}}
        (dst / f"{qid}.json").write_text(json.dumps(doc, sort_keys=True, separators=(",", ":")) + "\n")
        print(f"{qid} ({q['phrasing']}): {len(v)} verdicts", file=sys.stderr)


if __name__ == "__main__":
    main(*sys.argv[1:3])
