"""Grade users' answers against the key, by Jev, blind to the arm.

    python grade.py <answers dir> <KEY.md> [--out grades.json]

Each user writes `<answers dir>/<user>.json`: {"1": "answer to task 1", ...}.
The key is ../navigate/users/KEY.md, one numbered line per task. For every
(user, task) Jev answers one question -- does the answer give what the key
says, allowing partial credit by the key's own scoring note -- and sees
neither the user's name nor the arm. The arm is read from the file name only
when the scores are summed (S* shadow, O* on), after every judgement is made.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2]))

from percolate_core.decide import Jev, Score  # noqa: E402

GRADE = Score("How much of what `key` says does `answer` give? Give partial credit where `key` names parts. An answer that says "
              "it could not find something earns nothing for that part; one that states a "
              "wrong fact earns nothing for it.",
              ["none of it, or wrong", "a little of it", "about half of it", "most of it",
               "all of it"])


def key_items(path: Path) -> dict[str, str]:
    out = {}
    for line in path.read_text().splitlines():
        m = re.match(r"^(\d+)\.\s+(.*)", line)
        if m:
            out[m.group(1)] = m.group(2)
    return out


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("answers")
    ap.add_argument("key")
    ap.add_argument("--out")
    a = ap.parse_args()
    key = key_items(Path(a.key))
    files = sorted(Path(a.answers).glob("*.json"))
    jobs = [(f.stem, t, str(ans)) for f in files
            for t, ans in json.loads(f.read_text()).items() if t in key]
    async with Jev(api_key=os.environ["JEV_API_KEY"], concurrency=8) as jev:
        async def one(user, task, ans):
            r = await jev.ask({"key": key[task], "answer": ans}, {"g": GRADE})
            # The level, probability-weighted and 0-based, as a share of the key.
            return user, task, round(float(r["g"].value) / 4, 3)
        scores = await asyncio.gather(*(one(*j) for j in jobs))
    by_user: dict[str, dict] = {}
    for user, task, v in scores:
        by_user.setdefault(user, {})[task] = v
    arms: dict[str, list] = {}
    for user, ts in by_user.items():
        arm = {"S": "shadow", "O": "on"}.get(user[:1], "other")
        arms.setdefault(arm, []).append(round(sum(ts.values()), 2))
    report = {"tasks": len(key), "by_user": by_user,
              "by_arm": {arm: {"users": len(v), "scores": v, "mean": round(sum(v) / len(v), 2)}
                         for arm, v in arms.items()}}
    text = json.dumps(report, indent=1)
    if a.out:
        Path(a.out).write_text(text + "\n")
    print(text)


if __name__ == "__main__":
    asyncio.run(main())
