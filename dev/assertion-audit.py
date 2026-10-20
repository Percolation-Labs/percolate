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
written to catch. From the workflow engine's review (4 September):

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
    #
    # THE LOOKAHEAD IS THE SAME MISTAKE THE OTHER WAY. DDL says `if exists` and
    # `if not exists` too -- `drop policy if exists owner_reads on fleet.vessels`
    # -- and the scan ran from there to the next `then`, reporting three
    # `create policy ... using (owner_id = (select rbac.current_user_id()))`
    # lines in query/16 as assertions (REM-984). A DDL clause is followed by a
    # NAME; a plpgsql condition `if exists (select ...)` by a parenthesis, so the
    # name is what tells them apart, and every real condition is still scanned.
    for m in re.finditer(r"(?<!end )\b(?:els)?if\b(?!\s+(?:not\s+)?exists\s+[a-z_\"])(.*?)\bthen\b",
                         s, re.S | re.I):
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


# THE SAME DEFECT, SPELT OVER TWO STATEMENTS, which is how it survived the first
# version of this file and how one more instance landed the day after that
# version shipped:
#
#     select machine_weight into v_w from aiq.graph_vocabulary where relation = 'x';
#     if v_w <> 0.2::real then raise exception '...'; end if;
#
# No row means SELECT INTO leaves v_w NULL -- plpgsql does not raise
# NO_DATA_FOUND for a plain SELECT INTO -- so `v_w <> 0.2` is NULL and the raise
# never fires. Identical consequence to the inline form, invisible to a scan that
# only looks inside `if ... then`, and the more common spelling in this suite by
# a wide margin: thirteen live instances against sixteen inline ones.
#
# THE PATTERN THAT IS CORRECT, and it is already in the suite -- dev/tests/rbac/03
# guards with an explicit `is null` first and then compares. So a variable is
# cleared by any of: `if v is null then`, `if v is not null`, a coalesce() around
# it, or `is distinct from`. Anything else that compares it two-valuedly before
# one of those is a check that passes when its subject is missing.
SELECT_INTO = re.compile(
    r"\bselect\b[^;]*?\binto\s+(?:strict\s+)?([a-z_][a-z0-9_]*)\b[^;]*;", re.I | re.S)


def two_step_findings(raw: str, s: str) -> list[tuple[int, str]]:
    out: list[tuple[int, str]] = []
    for m in SELECT_INTO.finditer(s):
        # `select ... into strict` raises NO_DATA_FOUND itself, so the absent
        # case is already an error and nothing here can be silenced by it.
        if re.search(r"\binto\s+strict\b", m.group(0), re.I):
            continue
        # count(...) without GROUP BY is 0 over an empty set, never NULL, and it
        # is the commonest spelling of `select ... into` in this suite by a long
        # way -- 107 of the 120 the first draft of this pass reported. Flagging
        # them would have made the audit unreadable, which is the failure mode
        # that matters most for a lint. max/min/sum/array_agg are NOT excluded:
        # every one of those does return NULL over an empty set.
        head = m.group(0)
        sel = head[head.lower().index("select") + 6: head.lower().rindex(" into")].strip().lower()
        if sel.startswith("count"):
            continue
        # NO `from`, NO MISSING ROW. `select length(...) into v_768;` is an
        # expression, not a query over rows -- it returns exactly one row by
        # construction, so nothing about it can be silenced by an absent one.
        # This class is about a row that is not there; a select with no FROM
        # cannot have one. (Checked after `into`, because the FROM of a
        # SUBQUERY inside the select list -- `(select ... from generate_series)`
        # -- is not this statement's FROM and does not make it a row query.)
        if not re.search(r"\bfrom\b", head[head.lower().rindex(" into"):], re.I):
            continue
        var = m.group(1)
        # Only as far as the next SELECT INTO of the same variable: past that
        # point the value being compared is a different one.
        rest = s[m.end():]
        nxt = re.search(rf"\bselect\b[^;]*?\binto\s+(?:strict\s+)?{re.escape(var)}\b", rest, re.I | re.S)
        window = rest[:nxt.start()] if nxt else rest
        # Cleared the moment the absent case is named.
        guard = re.search(rf"\b{re.escape(var)}\s+is\s+(not\s+)?null\b"
                          rf"|coalesce\s*\(\s*{re.escape(var)}\b"
                          rf"|\b{re.escape(var)}\s+is\s+(not\s+)?distinct\s+from\b", window, re.I)
        limit = guard.start() if guard else len(window)
        for c in re.finditer(rf"\b(?:els)?if\b[^;]*?\b{re.escape(var)}\s*({OPS})\s*(?!=)", window[:limit], re.I | re.S):
            at = m.end() + c.start()
            line = raw[:at].count("\n") + 1
            out.append((line, f"{c.group(1)}  {var} -- compared with no `{var} is null` "
                              f"guard after `select ... into {var}`"))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="exit non-zero if any assertion can be silenced by a missing row")
    a = ap.parse_args()

    files = sorted(TESTS.rglob("*.sql"))
    total = 0
    for f in files:
        raw = f.read_text()
        hits = sorted(set(findings_in(f) + two_step_findings(raw, strip_noise(raw))))
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
