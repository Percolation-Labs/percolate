"""The questions two systems answer differently, one line each: what each put first, and how many facts Graphiti
wrote from each right answer's episode.

    python3 -I compare.py fixture.json graphiti.log A B ranked.jsonl ...

A and B are system names as score.py prints them. graphiti.log is graphiti_run.py's stderr, whose
"# added fNN: K edges" lines say how many facts Graphiti wrote from each episode.
"""
import json, re, sys

fixture, log, a, b, *paths = sys.argv[1:]
fx = json.load(open(fixture))
text = {f["id"]: f["text"] for f in fx["facts"]}
written = {m[1]: int(m[2]) for m in re.finditer(r"# added (f\d+): (\d+) edges", open(log).read())}
ranked = {}
for p in paths:
    for line in open(p):
        if line.startswith('{"system"'):
            r = json.loads(line)
            ranked[(r["system"], r["q"])] = r["ranked"]
won = {a: 0, b: 0}
print(f"{a} against {b}: the questions where one put a right answer first and the other did not")
for q in fx["questions"]:
    first = {s: (ranked.get((s, q["id"])) or [None])[0] for s in (a, b)}
    right = {s: first[s] in q["gold"] for s in (a, b)}
    for s in (a, b):
        won[s] += right[s]
    if right[a] != right[b]:
        facts = ", ".join(f"{g} {written.get(g, '?')}" for g in q["gold"])
        print(f"{q['id']} {q['kind']:10} right: {' / '.join(text[g] for g in q['gold'])} (facts written: {facts})")
        for s in (a, b):
            print(f"    {s:22} {'right' if right[s] else 'wrong'}: {text.get(first[s], 'nothing')}")
print(f"right first, of {len(fx['questions'])}: {a} {won[a]}, {b} {won[b]}")
