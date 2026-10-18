"""Step 5: do agents shown the exception split, and get the recall back?

    python e2e.py <questions.json> <keymap.txt> <query-log.jsonl> [--out e2e.json]

Each agent answered 20 compound questions through the query tool, at most 3
queries each, one session per question (<agent>-q<N>). The score is read off
the query log, no judge: the share of a question's parts whose answering
passage the agent had seen by the end of that question (the questions share
parts), and, stricter, in that question's own queries. `keymap.txt` maps the
store's passage keys to the row ids the tool returns ("key|id" lines).
Agents S* ran against the shadow server, O* against the on server.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2]))

from percolate_core.semantic_exceptions.log import JsonlLog  # noqa: E402


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("questions")
    ap.add_argument("keymap")
    ap.add_argument("log")
    ap.add_argument("--out")
    a = ap.parse_args()
    qs = {str(q["n"]): q for q in json.loads(Path(a.questions).read_text())}
    key = dict(l.split("|", 1) for l in Path(a.keymap).read_text().split() if "|" in l)
    sessions: dict[str, list] = defaultdict(list)
    for e in JsonlLog(a.log):
        if e.session_id and "-q" in e.session_id:
            sessions[e.session_id].append(e)
    seen_by: dict[str, list] = defaultdict(list)
    for sid, evs in sessions.items():
        seen_by[sid.partition("-q")[0]].extend(evs)
    rows = []
    for sid, evs in sessions.items():
        agent, _, n = sid.partition("-q")
        q = qs.get(n)
        if q is None:
            continue
        evs.sort(key=lambda e: e.at)
        # What the agent had seen by the end of this question: the questions
        # share parts, and an agent may answer from a passage an earlier
        # question's search returned, which is a fair use of what it found.
        end = evs[-1].at
        got = {i for e in seen_by[agent] if e.at <= end for i in e.stats.get("ids") or ()}
        own = {i for e in evs for i in e.stats.get("ids") or ()}
        gold = [key[p] for p in q["parts"]]
        rows.append({
            "agent": agent, "arm": "shadow" if agent.startswith("S") else "on", "q": n,
            "parts": len(gold), "queries": len(evs),
            "recall": sum(g in got for g in gold) / len(gold),
            "recall_own_queries": sum(g in own for g in gold) / len(gold),
            "split": len(evs) >= len(gold),
            "decomposition_shown": any("DECOMPOSITION_REQUIRED" in e.shown_codes for e in evs),
            "decomposition_raised": any("DECOMPOSITION_REQUIRED" in e.codes for e in evs[:1]),
        })
    # A question answered with no query of its own leaves no session. It is
    # scored on everything the agent saw in the whole run, and flagged, so the
    # arms can be read with and without it.
    for agent, evs in seen_by.items():
        asked = {r["q"] for r in rows if r["agent"] == agent}
        got = {i for e in evs for i in e.stats.get("ids") or ()}
        for n, q in qs.items():
            if n in asked:
                continue
            gold = [key[p] for p in q["parts"]]
            rows.append({"agent": agent, "arm": "shadow" if agent.startswith("S") else "on",
                         "q": n, "parts": len(gold), "queries": 0, "no_queries": True,
                         "recall": sum(g in got for g in gold) / len(gold),
                         "recall_own_queries": 0.0, "split": False,
                         "decomposition_shown": False, "decomposition_raised": False})
    out = {}
    for arm in ("shadow", "on"):
        rs = [r for r in rows if r["arm"] == arm]
        if not rs:
            continue
        mean = lambda xs: round(sum(xs) / len(xs), 3) if xs else None
        out[arm] = {
            "questions": len(rs),
            "answered_without_a_query": sum(1 for r in rs if r.get("no_queries")),
            "recall": mean([r["recall"] for r in rs]),
            "recall_pairs": mean([r["recall"] for r in rs if r["parts"] == 2]),
            "recall_triples": mean([r["recall"] for r in rs if r["parts"] == 3]),
            "recall_own_queries": mean([r["recall_own_queries"] for r in rs]),
            "queries_per_question": mean([r["queries"] for r in rs]),
            "split_share": mean([float(r["split"]) for r in rs]),
            "first_query_raised_decomposition": mean([float(r["decomposition_raised"]) for r in rs]),
            "decomposition_shown": mean([float(r["decomposition_shown"]) for r in rs]),
            "recall_when_split": mean([r["recall"] for r in rs if r["split"]]),
            "recall_when_not_split": mean([r["recall"] for r in rs if not r["split"]]),
        }
    text = json.dumps({"arms": out, "rows": rows}, indent=1)
    if a.out:
        Path(a.out).write_text(text + "\n")
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
