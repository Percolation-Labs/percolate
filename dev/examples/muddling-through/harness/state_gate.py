#!/usr/bin/env python3
"""Evaluation harness, not product: stack.state_gate from the calibration walks' labelled lines (walk spec §14, F12).

    python3 harness/state_gate.py lines.jsonl labels-a.jsonl labels-b.jsonl [settled.jsonl]

lines.jsonl holds every (line, leaf) judgement at P >= 0.5 from the calibration walks: run, qid, leaf, doc, p. Each
labels file gives, per (run, leaf, doc), states_answer as yes, no or no-slice (a part whose term BEAM's answer never
names; counted as not correct, and reported separately), labelled blind to P by the registered rule. settled.jsonl,
once written, gives the agreed label of every line the two labellers disagree on, with both quotes.

It reports the two labellers' agreement (count and Cohen's kappa over yes / not-yes), lists the disagreements to
settle, and, from the settled labels, the gate as registered: the lowest P at which at least 90% of the lines at or
above it state their leaf's answer, pooled over lines (registered) and with each question weighted equally (stated
beside it), with a 95% bootstrap interval over questions (2,000 draws, seed 1248).
"""
import json
import random
import sys

TARGET = 0.9


def key(r):
    return (r["run"], r["leaf"], r["doc"])


def load(path):
    return {key(r): r for r in map(json.loads, open(path))}


def kappa(a, b):
    n = len(a)
    agree = sum(x == y for x, y in zip(a, b)) / n
    pa, pb = sum(a) / n, sum(b) / n
    chance = pa * pb + (1 - pa) * (1 - pb)
    return (agree - chance) / (1 - chance) if chance < 1 else 1.0


def gate(rows, weighted=False):
    """The lowest P whose lines at or above it are at least TARGET correct; None if no P reaches it."""
    for cut in sorted({r["p"] for r in rows}):
        above = [r for r in rows if r["p"] >= cut]
        if weighted:
            by_q = {}
            for r in above:
                by_q.setdefault(r["qid"], []).append(r["ok"])
            share = sum(sum(v) / len(v) for v in by_q.values()) / len(by_q)
        else:
            share = sum(r["ok"] for r in above) / len(above)
        if share >= TARGET:
            return cut
    return None


def main(lines_path, a_path, b_path, settled_path=None):
    lines, a, b = load(lines_path), load(a_path), load(b_path)
    keys = sorted(lines)
    missing = [k for k in keys if k not in a or k not in b]
    if missing:
        sys.exit(f"{len(missing)} lines lack a label from one labeller, e.g. {missing[0]}")
    ya = [a[k]["states_answer"] == "yes" for k in keys]
    yb = [b[k]["states_answer"] == "yes" for k in keys]
    agree = sum(x == y for x, y in zip(ya, yb))
    print(f"agreement {agree} of {len(keys)} ({agree / len(keys):.0%}), Cohen's kappa {kappa(ya, yb):.2f}")
    off = sum(a[k]["states_answer"] == "no-slice" or b[k]["states_answer"] == "no-slice" for k in keys)
    print(f"lines on a part off BEAM's answer (no-slice, by either labeller): {off}")
    differ = [k for k, x, y in zip(keys, ya, yb) if x != y]
    settled = load(settled_path) if settled_path else {}
    open_ = [k for k in differ if k not in settled]
    if open_:
        print(f"{len(open_)} disagreements to settle, quoting the line and BEAM's answer side by side:")
        for k in open_:
            print(json.dumps({"run": k[0], "leaf": k[1], "doc": k[2], "a": a[k].get("quote"), "b": b[k].get("quote")}))
        return
    rows = [{"qid": lines[k]["qid"], "p": lines[k]["p"],
             "ok": (settled[k]["states_answer"] if k in settled else a[k]["states_answer"]) == "yes"} for k in keys]
    g, gw = gate(rows), gate(rows, weighted=True)
    qids = sorted({r["qid"] for r in rows})
    rng, draws = random.Random(1248), []
    for _ in range(2000):
        pick = [rng.choice(qids) for _ in qids]
        draws.append(gate([r for q in pick for r in rows if r["qid"] == q]))
    found = sorted(d for d in draws if d is not None)
    lo, hi = (found[int(0.025 * len(found))], found[int(0.975 * len(found)) - 1]) if found else (None, None)
    print(f"state_gate, line-pooled (registered): {g}; question-weighted: {gw}; "
          f"95% bootstrap over {len(qids)} questions: [{lo}, {hi}], {len(draws) - len(found)} draws with no gate")


if __name__ == "__main__":
    main(*sys.argv[1:])
