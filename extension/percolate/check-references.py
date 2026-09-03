#!/usr/bin/env python3
"""Every function this collection tells you to call must exist.

    python3 extension/percolate/check-references.py

THE FAILURE THIS EXISTS FOR is a remedy that does not work, printed at the
moment somebody is already stuck. Twice now:

  * the snapshot ceiling error told an operator to run
    `aiq.graph_snapshot(true, relations => array[...])`. Those are not the
    parameter names -- it is `p_relations` -- so the advice failed with
    "function does not exist".

  * the slot-exhaustion error told them to "release one with select
    aiq.graph_snapshot_drop()". Only the compiled `p8_graph_snapshot_drop`
    was ever defined; the `aiq.` wrapper every document named did not exist.
    `graph-algorithms.md` named it twice as well, and the one test that
    exercised it called the compiled function directly -- so the tree agreed
    with itself everywhere except where it counted.

Both are the same shape: a string that reads like code, is never executed, and
is therefore never wrong until a user copies it. Nothing type-checks the inside
of an error message, so this does.

Deliberately static -- it reads the generated extension script and the pgrx
sources, never a database. It runs in CI on every push, where there is no
Postgres, and it costs a second.

WHAT IT DOES NOT COVER, so the pass is not read as more than it means: prose in
`specs/*.md` may name objects that do not exist yet, and should be able to --
`trace-field`, `pools.sql` and `connectors.sql` are all specified-not-shipped by
decision (see build-sql.py's NOT_SHIPPED). This checks only what SHIPPED CODE
tells a caller to run.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCHEMAS = ("aiq", "workflow", "rbac", "content", "agentic", "wm")

# `select foo.bar(` / `call foo.bar(` / `perform foo.bar(` -- the spellings a
# message uses when it is telling somebody what to type. A bare mention like
# "aiq.related is the ranked answer" is prose about a function, not an
# instruction to run one, and is not matched on purpose.
CALL = re.compile(
    r"\b(?:select|call|perform)\s+((?:" + "|".join(SCHEMAS) + r")\.[a-z_][a-z0-9_]*)\s*\("
)


def defined_names(gen_sql: str, rust: str) -> set:
    """Everything the shipped extension actually creates."""
    names = set()
    for m in re.finditer(
        r"^create (?:or replace )?(?:function|view|table|materialized view)\s+"
        r"([a-z_]+)\.([a-z_][a-z0-9_]*)",
        gen_sql, re.M):
        names.add(f"{m.group(1)}.{m.group(2)}")
    # The compiled half, which lives in `public` and is named unqualified.
    for m in re.finditer(r"#\[pg_extern\][^\n]*\n(?:#\[[^\n]*\]\n)*\s*fn\s+([a-z_0-9]+)", rust):
        names.add(m.group(1))
    return names


def main() -> int:
    gen = sorted(ROOT.glob("extension/percolate/sql/percolate--*.sql"))
    if not gen:
        print("no generated extension script -- run build-sql.py first", file=sys.stderr)
        return 1
    gen_sql = gen[-1].read_text()
    rust_files = sorted(ROOT.glob("extension/percolate_parser/src/*.rs"))
    rust = "\n".join(p.read_text() for p in rust_files)

    defined = defined_names(gen_sql, rust)
    bad = []

    def scan(label, text):
        for i, line in enumerate(text.splitlines(), 1):
            for m in CALL.finditer(line):
                if m.group(1) not in defined:
                    bad.append((m.group(1), f"{label}:{i}", line.strip()[:100]))

    scan(gen[-1].relative_to(ROOT).as_posix(), gen_sql)
    for p in rust_files:
        scan(p.relative_to(ROOT).as_posix(), p.read_text())

    if bad:
        print(f"{len(bad)} reference(s) to a function this extension does not define:\n",
              file=sys.stderr)
        for name, where, line in bad:
            print(f"  {name}\n      {where}\n      {line}\n", file=sys.stderr)
        print("Each of these is a caller being told to run something that does not "
              "exist. Define it, or correct the reference.", file=sys.stderr)
        return 1

    print(f"every function named in shipped code exists "
          f"({len(defined)} defined, {len(rust_files)} rust sources scanned)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
