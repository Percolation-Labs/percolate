"""Score ranked fact ids against the fixture's gold, per system and question kind.

hit@1      the top result is a gold fact
recall@5   every gold fact is in the top five (change questions need both sides)
stale>gold a superseded or later fact ranks above the best-ranked gold fact
leak@5     a fact belonging to another user is in the top five
"""
import json, sys
from collections import defaultdict

fixture = json.load(open(sys.argv[1]))
qs = {q["id"]: q for q in fixture["questions"]}
owner = {f["id"]: f["user"] for f in fixture["facts"]}
rows = [json.loads(l) for p in sys.argv[2:] for l in open(p) if l.startswith('{"system"')]

agg = defaultdict(lambda: defaultdict(list))
for r in rows:
    q, ranked = qs[r["q"]], r["ranked"]
    gold, stale = set(q["gold"]), set(q["stale"])
    first_gold = next((i for i, f in enumerate(ranked) if f in gold), None)
    first_stale = next((i for i, f in enumerate(ranked) if f in stale), None)
    m = {
        "hit@1": bool(ranked) and ranked[0] in gold,
        "recall@5": gold <= set(ranked[:5]),
        "stale>gold": first_stale is not None and (first_gold is None or first_stale < first_gold),
        "leak@5": any(owner.get(f) != q["user"] for f in ranked[:5]),
    }
    for k in ("all", q["kind"]):
        for name, v in m.items():
            agg[(r["system"], k)][name].append(v)

kinds = ["all", "current", "historical", "stable", "change", "scoped_agent"]
systems = sorted({s for s, _ in agg})
print(f"{'system':16} {'kind':13} {'n':>3} {'hit@1':>6} {'rec@5':>6} {'stale>gold':>10} {'leak@5':>6}")
for s in systems:
    for k in kinds:
        a = agg.get((s, k))
        if not a:
            continue
        n = len(a["hit@1"])
        pct = lambda name: f"{100 * sum(a[name]) / n:5.0f}%"
        print(f"{s:16} {k:13} {n:3} {pct('hit@1'):>6} {pct('recall@5'):>6} {pct('stale>gold'):>10} {pct('leak@5'):>6}")
    print()
