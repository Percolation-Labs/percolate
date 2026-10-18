"""Read the query log and ask whether the exceptions met real searches where they struggled.

    python traffic.py <query-log.jsonl> [--out report.json] [--store "<one sentence>"]

Every logged query is paired with the next query in its run (log.followups).
For each pair Jev answers two questions, and nothing else is judged:

    retry     is the next query a second attempt at the same information?
              (the first did not serve)
    follows   for a query that raised something: would a searcher following
              the guidance have written the next query? (shown and shadow
              alike: in shadow, did the agent get there on its own?)

The report, per arm (shadow: computed, not shown; on/strict: shown):

    fire rate          share of queries that raised anything
    retry | raised     retry rate after a query that raised something
    retry | silent     retry rate after a query that raised nothing
    lift               retry | raised  /  retry | silent  -- above 1 means the
                       layer speaks where searches struggle (read it in shadow,
                       where speaking cannot have changed the outcome)
    follows            share of raised queries whose next query went where the
                       guidance pointed

and per code: how often it fired and the retry rate after it. A log written
from a session's own data never leaves it except as these judgements; the log
itself is not committed.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2]))

from percolate_core.decide import Jev, Noul  # noqa: E402
from percolate_core.semantic_exceptions import KINDS  # noqa: E402
from percolate_core.semantic_exceptions.log import JsonlLog, followups  # noqa: E402

PROMPT = {k.code: k.prompt for k in KINDS}
RETRY = Noul("Is `next` a second attempt to find the same information as `first` (reworded, "
             "narrowed, widened or split), rather than a search for something different?",
             yes="`next` seeks what `first` sought, in other words, another mode or a different "
                 "scope",
             no="`next` seeks a different fact, source or topic")
FOLLOWS = Noul("Would a searcher who follows `guidance` after `first` have written `next`, or a "
               "search that serves the same purpose?")


def text(e) -> str:
    return f"{e.query}" + (f"  (asking: {e.question})" if e.question else "")


async def judge(pairs, store: str | None) -> list[dict]:
    out = []
    async with Jev(api_key=os.environ["JEV_API_KEY"], concurrency=8) as jev:
        async def one(e, n):
            row = {"id": e.id, "arm": "shown" if e.shown else (
                       "shadow" if e.exceptions_mode == "shadow" else e.exceptions_mode),
                   "codes": e.codes, "refused": e.refused, "empty": e.stats.get("empty"),
                   "has_next": n is not None}
            if n is None:
                return row
            qs = {"retry": RETRY}
            state = {"first": text(e), "next": text(n)}
            if store:
                state["store"] = store
            if e.codes:
                qs["follows"] = FOLLOWS
                state["guidance"] = "\n".join(f"{c}: {PROMPT.get(c, '')}" for c in e.codes)
            r = await jev.ask(state, qs)
            row["retry_p"] = round(r["retry"].p, 3)
            if "follows" in qs:
                row["follows_p"] = round(r["follows"].p, 3)
            return row
        out = await asyncio.gather(*(one(e, n) for e, n in pairs))
    return list(out)


def summarise(rows: list[dict], bar: float = 0.5) -> dict:
    report: dict = {"queries": len(rows), "arms": {}, "codes": {}}
    by_arm = defaultdict(list)
    for r in rows:
        by_arm[r["arm"]].append(r)
    for arm, rs in by_arm.items():
        paired = [r for r in rs if r["has_next"]]
        raised = [r for r in paired if r["codes"]]
        silent = [r for r in paired if not r["codes"]]
        rate = lambda xs: (round(sum(x["retry_p"] >= bar for x in xs) / len(xs), 3)
                           if xs else None)
        rr, rs_ = rate(raised), rate(silent)
        fol = [r for r in raised if "follows_p" in r]
        report["arms"][arm] = {
            "queries": len(rs), "paired": len(paired),
            "fire_rate": round(sum(1 for r in rs if r["codes"]) / len(rs), 3) if rs else None,
            "retry_given_raised": rr, "retry_given_silent": rs_,
            "lift": round(rr / rs_, 2) if rr is not None and rs_ else None,
            "follows": (round(sum(r["follows_p"] >= bar for r in fol) / len(fol), 3)
                        if fol else None),
            "refused": sum(r["refused"] for r in rs)}
    fired = Counter(c for r in rows for c in r["codes"])
    for c, n in fired.most_common():
        after = [r for r in rows if c in r["codes"] and r["has_next"]]
        report["codes"][c] = {"fired": n, "paired": len(after),
                              "retry_after": (round(sum(r["retry_p"] >= bar for r in after)
                                                    / len(after), 3) if after else None)}
    return report


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--out")
    ap.add_argument("--store")
    a = ap.parse_args()
    pairs = followups(JsonlLog(a.log))
    rows = asyncio.run(judge(pairs, a.store))
    report = summarise(rows)
    text_out = json.dumps(report, indent=1)
    if a.out:
        Path(a.out).write_text(text_out + "\n")
        Path(a.out).with_suffix(".rows.jsonl").write_text(
            "".join(json.dumps(r) + "\n" for r in rows))
    print(text_out)


if __name__ == "__main__":
    main()
