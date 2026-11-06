"""The questions two systems answer differently, one line each: what each put first, and why the loser lost.

    python3 -I compare.py fixture.json A:a.log B:b.log ranked.jsonl ...

A and B are system names as score.py prints them, each with the log of the runner that built it, whose
"# added fNN: K edges" lines say how many facts that system wrote from each memory. The losing side's cause is
extraction when it wrote no fact from any right answer's memory, invalidation when what it put first is a fact the
question's answer replaced, and ranking otherwise: the right fact was there and something else came first.
"""
import json, re, sys

fixture, sa, sb, *paths = sys.argv[1:]
fx = json.load(open(fixture))
text = {f["id"]: f["text"] for f in fx["facts"]}
systems, written = [], {}
for arg in (sa, sb):
    name, log = arg.split(":", 1)
    systems.append(name)
    written[name] = {m[1]: int(m[2]) for m in re.finditer(r"# added (f\d+): (\d+) edges", open(log).read())}
a, b = systems
ranked = {}
for p in paths:
    for line in open(p):
        if line.startswith('{"system"'):
            r = json.loads(line)
            ranked[(r["system"], r["q"])] = r["ranked"]


def cause(s, q, first):
    if all(written[s].get(g, 0) == 0 for g in q["gold"]):
        return "extraction"
    return "invalidation" if first in q["stale"] else "ranking"


won, why = {a: 0, b: 0}, {}
print(f"{a} against {b}: the questions where one put a right answer first and the other did not")
for q in fx["questions"]:
    first = {s: (ranked.get((s, q["id"])) or [None])[0] for s in (a, b)}
    right = {s: first[s] in q["gold"] for s in (a, b)}
    for s in (a, b):
        won[s] += right[s]
    if right[a] != right[b]:
        loser = a if not right[a] else b
        c = cause(loser, q, first[loser])
        why[(loser, c)] = why.get((loser, c), 0) + 1
        facts = "; ".join(f"{s} wrote " + ", ".join(f"{g} {written[s].get(g, 0)}" for g in q["gold"]) for s in (a, b))
        print(f"{q['id']} {q['kind']:10} right: {' / '.join(text[g] for g in q['gold'])} ({facts})")
        for s in (a, b):
            print(f"    {s:22} {'right' if right[s] else 'wrong, ' + c}: {text.get(first[s], 'nothing')}")
print(f"right first, of {len(fx['questions'])}: {a} {won[a]}, {b} {won[b]}")
print("losses by cause: " + ", ".join(f"{s} {c} {n}" for (s, c), n in sorted(why.items())))
