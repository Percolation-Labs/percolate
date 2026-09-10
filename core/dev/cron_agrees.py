#!/usr/bin/env python3
"""Does the browser's cron matcher still agree with the database's?

`ui/static/cron.js` exists so the Schedules screen can say what an expression
means and when it next fires. It is therefore a second implementation of
`workflow.cron_matches_local`, and a preview that disagrees with the engine is
worse than no preview: it tells somebody their job runs at a time it does not.

So this runs both over the same grid of (expression, local time) pairs and
fails on any disagreement. It needs a database with the workflow schema; the
tests in `tests/test_cron.py` pin the behaviour that can be checked without one.

    python3 dev/cron_agrees.py                       # docker exec into p8-dev-db
    P8_PSQL="psql -U p8 -d p8dev" python3 dev/cron_agrees.py

Exit status is the point: non-zero on any disagreement, so it can gate a change
to either implementation.
"""

from __future__ import annotations

import json
import os
import random
import shlex
import subprocess
import sys
from pathlib import Path

CRON_JS = (Path(__file__).resolve().parents[1]
           / "percolate_core" / "ui" / "static" / "cron.js")
PSQL = os.environ.get("P8_PSQL", "docker exec p8-dev-db psql -U p8 -d p8dev")

EXPRESSIONS = [
    "* * * * *", "0 2 * * *", "*/15 * * * *", "0 */2 * * *", "0 9-17 * * 1-5",
    "0 0 13 * 5", "30 6 1 * *", "0 0 1 1 *", "5 4 * * 0", "5 4 * * 7",
    "0 12 * * 6,0", "15,45 * * * *", "0 3 */2 * *", "0 0 * * 1-5",
    "59 23 31 12 *", "0 8 1,15 * *", "*/5 9 * * 1", "0 0 29 2 *",
    "10 5/10 * * *", "0 22 * * 1-5", "0 0 1-7 * 1", "*/20 8-10 * 3,9 *",
]

# Fixed dates that have caught something before — leap day, month ends, both
# UK daylight-saving boundaries — plus a random spread for everything else.
STAMPS = [
    "2026-01-01 00:00", "2026-02-28 23:59", "2028-02-29 12:00", "2026-03-13 05:04",
    "2026-03-29 01:30", "2026-05-13 00:00", "2026-06-01 06:30", "2026-07-04 12:00",
    "2026-10-25 01:30", "2026-11-01 09:15", "2026-12-31 23:59", "2026-09-13 00:00",
]
_rng = random.Random(int(os.environ.get("P8_CRON_SEED", "5")))
STAMPS += [f"2026-{_rng.randint(1, 12):02d}-{_rng.randint(1, 28):02d} "
           f"{_rng.randint(0, 23):02d}:{_rng.randint(0, 59):02d}" for _ in range(18)]


def javascript(cases: list[tuple[str, str]]) -> list:
    script = f"""
import {{ matchesLocal }} from {json.dumps(CRON_JS.as_uri())};
const cases = {json.dumps(cases)};
console.log(JSON.stringify(cases.map(([expr, stamp]) => {{
  const [date, time] = stamp.split(" ");
  const [Y, M, D] = date.split("-").map(Number);
  const [h, mi] = time.split(":").map(Number);
  const dow = new Date(Date.UTC(Y, M - 1, D)).getUTCDay();
  try {{
    return matchesLocal(expr, {{ year: Y, month: M, day: D, hour: h, minute: mi, dow }});
  }} catch (e) {{ return "error: " + e.message; }}
}})));"""
    out = subprocess.run(["node", "--input-type=module", "-e", script],
                         capture_output=True, text=True)
    if out.returncode:
        sys.exit("node could not evaluate cron.js:\n" + out.stderr.strip())
    return json.loads(out.stdout)


def postgres(cases: list[tuple[str, str]]) -> list:
    rows = " union all ".join(
        f"select {i} as i, workflow.cron_matches_local("
        f"{expr!r}, timestamp {stamp!r}) as m"
        for i, (expr, stamp) in enumerate(cases))
    out = subprocess.run(shlex.split(PSQL) + ["-tAc", f"select i, m from ({rows}) q order by i"],
                         capture_output=True, text=True)
    if out.returncode:
        sys.exit(f"psql failed (P8_PSQL={PSQL!r}):\n" + out.stderr.strip())
    return [line.split("|")[1] == "t" for line in out.stdout.strip().splitlines()]


def main() -> int:
    cases = [(e, s) for e in EXPRESSIONS for s in STAMPS]
    js, sql = javascript(cases), postgres(cases)
    if not (len(js) == len(sql) == len(cases)):
        sys.exit(f"expected {len(cases)} answers, got {len(js)} from node and {len(sql)} from psql")

    disagreements = [(cases[i], js[i], sql[i]) for i in range(len(cases)) if js[i] is not sql[i]]
    print(f"{len(cases)} (expression, local time) pairs "
          f"across {len(EXPRESSIONS)} expressions and {len(STAMPS)} timestamps")
    if not disagreements:
        print("cron.js agrees with workflow.cron_matches_local on every pair.")
        return 0
    print(f"\n{len(disagreements)} disagreement(s):")
    for (expr, stamp), got, want in disagreements:
        print(f"  {expr:18} {stamp}   cron.js={got!r}  database={want!r}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
