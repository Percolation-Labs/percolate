#!/usr/bin/env python3
"""The size of the extension is a number somebody wrote down, not a side effect.

    python3 dev/the-schema-has-a-budget.py

specs/budget.toml holds the totals; this refuses a tree that disagrees with
them. It is the one check in dev/check.sh that asks HOW MANY rather than whether
a statement is well formed, and it exists because nothing did: 52 tables became
117 in fourteen days, none was ever dropped, and every gate was green throughout
because each addition was locally correct.

TWO-SIDED, which is the part that makes it a ratchet rather than a ceiling.
Growing the schema fails until the number is raised in the same commit, where a
reviewer sees a one-line diff and can ask what it replaced. SHRINKING it fails
too, until the number is lowered -- otherwise the first deletion buys headroom
for an addition nobody argued for, and the budget drifts above the tree exactly
the way a ceiling does.

It is not a limit and it refuses nothing on grounds of size. A limit gets raised
on the way past. A declaration has to be walked through, and the walking is the
tax.

Counted over the spec files in build-sql.py's ORDER, read rather than restated,
so a proposal held out of ORDER costs nothing until it ships.
"""
from __future__ import annotations
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SPECS = ROOT / "specs"
BUDGET = SPECS / "budget.toml"

KINDS = {
    "tables":    r"^\s*create table if not exists\s+([a-z_]+\.[a-z_]+)",
    "views":     r"^\s*create (?:or replace )?(?:materialized )?view\s+([a-z_]+\.[a-z_]+)",
    "functions": r"^\s*create or replace function\s+([a-z_]+\.[a-z_]+)",
}


def shipped_files() -> list[str]:
    src = (ROOT / "extension/percolate/build-sql.py").read_text(encoding="utf-8")
    body = src[src.index("ORDER = ["):]
    return re.findall(r'\(\s*"([^"]+\.sql)"', body[:body.index("\n]")]) + ["identity/closing.sql"]


def counted() -> dict[str, int]:
    texts = []
    for rel in shipped_files():
        path = SPECS / rel
        if not path.exists():
            raise SystemExit(f"build-sql.py's ORDER names specs/{rel}, which does not exist")
        texts.append(path.read_text(encoding="utf-8", errors="replace"))
    out = {}
    for kind, pattern in KINDS.items():
        seen: set[str] = set()
        for t in texts:
            seen |= {m.group(1).lower() for m in re.finditer(pattern, t, re.I | re.M)}
        out[kind] = len(seen)
    return out


def declared() -> dict[str, int]:
    # Deliberately not a TOML parser: this file has one section of three
    # integers, and a dependency for that is a dependency to install in CI.
    text = BUDGET.read_text(encoding="utf-8")
    return {k: int(v) for k, v in re.findall(r"^([a-z]+)\s*=\s*(\d+)\s*$", text, re.M)}


def main() -> int:
    want, have = declared(), counted()
    missing = [k for k in KINDS if k not in want]
    if missing:
        print(f"specs/budget.toml declares no {', '.join(missing)}")
        return 1

    print("  " + " · ".join(f"{k} {have[k]}" for k in ("tables", "views", "functions"))
          + "  (declared: " + ", ".join(str(want[k]) for k in ("tables", "views", "functions")) + ")")

    drift = [(k, want[k], have[k]) for k in KINDS if want[k] != have[k]]
    if not drift:
        return 0

    grew = [d for d in drift if d[2] > d[1]]
    print("\nTHE SCHEMA IS NOT THE SIZE specs/budget.toml SAYS IT IS.\n")
    for kind, w, h in drift:
        verb = "added" if h > w else "removed"
        print(f"  {kind}: declared {w}, this tree has {h} — {abs(h - w)} {verb}")

    if grew:
        print("\nRaise the number in specs/budget.toml in THIS commit, and say in the commit\n"
              "message what the addition replaces or why nothing does. Before you do, ask\n"
              "what already holds this and whether it is core at all: those are the two\n"
              "questions this number exists to make somebody\n"
              "answer out loud.")
    else:
        print("\nLower the number in specs/budget.toml in this commit. A budget left above the\n"
              "tree is headroom for an addition nobody argued for, which is what this check\n"
              "is for.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
