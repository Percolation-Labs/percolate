#!/usr/bin/env python3
"""Refuse an assertion that passes when its subject is missing.

    dev/assertion-audit.py            # report
    dev/assertion-audit.py --check    # non-zero if any are found

THE SHAPE, AND WHY IT IS WORTH A TOOL.

`failure-modes.md` §7 names the class -- *an assertion that cannot fail* -- and
the workflow suite had ten live instances of one particular spelling of it:

    if (select status from workflow.runs where id = r) <> 'succeeded' then
        raise exception '...';
    end if;

A scalar subquery over a row that is not there returns NULL. `NULL <>
'succeeded'` is NULL. `if NULL then` does not fire. So the check passes exactly
when its subject is **missing**, which is the one state most of them were
written to catch. From postmortems/2026-09-04-workflow-engine-review.md:

    05-faults.sql guarded "the bucket was never consumed" with
    `(select tokens ...) >= 2`. With no bucket row at all it read green -- and
    "no bucket row" is the state that once made rbac.attempt_login refuse every
    user in the collection.

All ten were fixed by hand. That postmortem then lists this file as still open:

    "A lint for the assertion shape. Ten instances were fixed by hand; nothing
     stops the eleventh. The check is a grep -- a scalar subquery on the left of
     <>, = or >= inside an `if ... then` -- and it belongs over dev/tests/**."

Fixing ten by hand and leaving the eleventh unguarded is the trade this
repository keeps refusing everywhere else: `permission_kinds` over a list of
literals, `lifecycle_states` over a hardcoded status word, `rate_limits_tokens_check`
over a corrected function. `challenge-the-process` §1 -- a finding reported is
worth a fraction of a finding fixed, and a finding FIXED is worth a fraction of
one made unreachable.

THE REMEDY, WHICH IS ALWAYS ONE OF TWO.

    is distinct from     -- NULL is distinct from anything, so a missing row
                            fires the assertion instead of silencing it.
    coalesce(..., <x>)   -- when the absent case genuinely has a right answer,
                            name it rather than letting NULL stand in for it.

WHAT IS DELIBERATELY NOT FLAGGED. `count(...)` without GROUP BY returns 0 rather
than NULL for an empty set, so it cannot go three-valued -- and it is the most
common spelling in the suite by a distance. `exists (...)` is already boolean.
Neither is a defect and flagging them would make this the kind of audit people
learn to skim.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
TESTS = ROOT / "dev" / "tests"

# The three-valued operators. `is distinct from` is the remedy and so is
# absent here by construction; `is null` / `is not null` are already total.
OPS = r"(?:<>|!=|>=|<=|=|>|<)"


def strip_noise(sql: str) -> str:
    """Comments and string literals out, positions preserved.

    Replaced with spaces rather than deleted so every offset below still points
    at the real line -- a report naming the wrong line is worse than no report.
    """
    out = list(sql)
    i, n = 0, len(sql)
    while i < n:
        if sql.startswith("--", i):
            j = sql.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
        elif sql[i] == "'":
            j = i + 1
            while j < n:
                if sql[j] == "'":
                    if j + 1 < n and sql[j + 1] == "'":
                        j += 2
                        continue
                    break
                j += 1
            j = min(j + 1, n)
            for k in range(i, j):
                out[k] = " "
            i = j
        else:
            i += 1
    return "".join(out)


def subquery_end(s: str, open_paren: int) -> int:
    """Index just past the `)` matching the `(` at open_paren."""
    depth = 0
    for i in range(open_paren, len(s)):
        if s[i] == "(":
            depth += 1
        elif s[i] == ")":
            depth -= 1
            if depth == 0:
                return i + 1
    return -1


def findings_in(path: pathlib.Path) -> list[tuple[int, str]]:
    raw = path.read_text()
    s = strip_noise(raw)
    out: list[tuple[int, str]] = []

    # Every `if` / `elsif` condition, up to its `then`. plpgsql only -- a bare
    # SQL `case ... when` is not an assertion and does not raise.
    #
    # THE LOOKBEHIND IS LOAD-BEARING. `end if;` contains the word `if`, so
    # without it the scan started at a block's CLOSE and ran forward to the next
    # `then`, dragging every statement in between into what it believed was one
    # condition. It reported two `select count(*) into v ... where user_id =
    # (select id from ...)` lines in rbac/09 as findings: the subquery is in the
    # WHERE of a SELECT INTO, the comparison that follows is against a counted
    # integer, and neither can be silenced by anything. A lint that cries wolf
    # gets skimmed, and a skimmed lint is the thing it was written to replace.
    for m in re.finditer(r"(?<!end )\b(?:els)?if\b(.*?)\bthen\b", s, re.S | re.I):
        cond = m.group(1)
        base = m.start(1)
        for sub in re.finditer(r"\(\s*select\b", cond, re.I):
            start = base + sub.start()
            end = subquery_end(s, start)
            if end < 0:
                continue
            body = s[start:end]
            head = body[body.lower().index("select") + 6:].lstrip().lower()
            # count(...) is total over an empty set; exists is boolean.
            if head.startswith("count") or re.match(r"^\(?\s*exists\b", head):
                continue
            before = s[base:start].rstrip()
            after = s[end:base + len(cond)].lstrip()
            hit = None
            if re.match(rf"^{OPS}", after):
                hit = re.match(rf"^{OPS}", after).group(0)
            elif re.search(rf"{OPS}\s*$", before):
                hit = re.search(rf"{OPS}\s*$", before).group(0).strip()
            if hit:
                line = raw[:start].count("\n") + 1
                snippet = " ".join(raw[start:end + 24].split())[:96]
                out.append((line, f"{hit}  {snippet}"))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="exit non-zero if any assertion can be silenced by a missing row")
    a = ap.parse_args()

    files = sorted(TESTS.rglob("*.sql"))
    total = 0
    for f in files:
        hits = findings_in(f)
        if not hits:
            continue
        total += len(hits)
        rel = f.relative_to(ROOT)
        for line, why in hits:
            print(f"{rel}:{line}: a missing row makes this NULL, and `if NULL then` "
                  f"does not fire\n    {why}")

    if total:
        print(f"\n{total} assertion(s) pass when their subject is absent, across "
              f"{len(files)} test file(s).")
        print("Use `is distinct from`, or coalesce() naming what the absent case "
              "should mean.")
        return 1 if a.check else 0

    print(f"no assertion in {len(files)} test file(s) is silenced by a missing row")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
