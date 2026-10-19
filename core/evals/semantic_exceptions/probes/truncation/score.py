"""Score the P1 run: right answers by arm and group, and what they cost (README.md, T1-T3).

    python score.py <answers dir> <query-log.jsonl> [--out score.json]

A count is right within max(1, 10%) of the store's own count; a date list is
right at F1 >= 0.8 against the store's own dates. Queries are read from the
log by session (<agent>-q<N>). S* agents ran shadow, O* agents on.
"""
from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent


def right(q: dict, ans) -> bool:
    """Right against the store's stemmed text-search truth or its ILIKE truth:
    both are fair readings of "mention", and agents use either."""
    alt = dict(q, answer=q["answer_ilike"]) if "answer_ilike" in q else None
    return _right(q, ans) or (alt is not None and _right(alt, ans))


def _right(q: dict, ans) -> bool:
    if q["kind"] == "count":
        try:
            v = float(re.findall(r"-?\d+(?:\.\d+)?", str(ans))[0])
        except (IndexError, ValueError):
            return False
        return abs(v - q["answer"]) <= max(1, 0.1 * q["answer"])
    got = set(re.findall(r"\d{4}-\d{2}-\d{2}", json.dumps(ans)))
    want = set(q["answer"])
    if not got or not want:
        return got == want
    tp = len(got & want)
    p, r = tp / len(got), tp / len(want)
    return (2 * p * r / (p + r) if p + r else 0) >= 0.8


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("answers")
    ap.add_argument("log")
    ap.add_argument("--out")
    a = ap.parse_args()
    qs = {str(q["n"]): q for q in json.loads((HERE / "questions.json").read_text())}
    queries = defaultdict(int)
    shown = defaultdict(set)
    for line in Path(a.log).read_text().splitlines():
        e = json.loads(line)
        sid = e.get("session_id") or ""
        if "-q" in sid:
            queries[sid] += 1
            shown[sid] |= set(e.get("shown_codes") or ())
    rows = []
    for f in sorted(Path(a.answers).glob("*.json")):
        agent = f.stem
        ans = json.loads(f.read_text())
        for n, q in qs.items():
            sid = f"{agent}-q{n}"
            rows.append({"agent": agent, "arm": "shadow" if agent.startswith("S") else "on",
                         "q": n, "group": "truncated" if q["truncated_at_10"] else "control",
                         "kind": q["kind"], "right": right(q, ans.get(n)),
                         "queries": queries.get(sid, 0),
                         "truncation_shown": "TRUNCATED_AT_LIMIT" in shown.get(sid, set())})
    out = {}
    for arm in ("shadow", "on"):
        for g in ("truncated", "control"):
            rs = [r for r in rows if r["arm"] == arm and r["group"] == g]
            if not rs:
                continue
            ok = sum(r["right"] for r in rs)
            q = sum(r["queries"] for r in rs)
            out[f"{arm}-{g}"] = {"answers": len(rs), "right": ok,
                                 "accuracy": round(ok / len(rs), 3),
                                 "queries_per_question": round(q / len(rs), 2),
                                 "queries_per_right_answer": round(q / ok, 2) if ok else None,
                                 "truncation_shown_share": round(
                                     sum(r["truncation_shown"] for r in rs) / len(rs), 3)}
    text = json.dumps({"summary": out, "rows": rows}, indent=1)
    if a.out:
        Path(a.out).write_text(text + "\n")
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
