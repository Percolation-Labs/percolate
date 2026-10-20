#!/usr/bin/env python3
"""An application may FILL core tables. It may not SHAPE them -- and neither may
a spec file that does not own the schema it is writing to.

Written after the self-model twice reached into `aiq` and changed the query
layer's own schema: once creating a view, once adding three columns by ALTER
TABLE. Both worked on the instance they were written against and were absent
from a fresh install, and `upgrade-converges.sh` could not see either, because a
defect present in both arms of a comparison is invisible to that comparison.

The rule is not that applications are untrusted. It is that needing a column on
a core table is a signal the mechanism is general, and both of these were: usage
counters are what any graph wants in order to tell a stale edge from a stale
load-bearing one.

SECOND HALF, added because the first half had a blind spot the size of the
research platform. The rule was enforced over `applications/` only, so
`specs/research-platform/schema.sql` -- a file that owns the `research` schema
-- altered `rbac.permission_kinds` three times and created nine tables in
`rbac` and one in `content`, and this gate stayed green through all of it. A
spec file is not an application, but the failure is identical: a schema grows a
column or a table from somewhere its own directory does not answer for, and
nobody reviewing the owning subsystem ever sees it.

So every directory under `specs/` declares the ONE schema it may shape, and
anything else it shapes is either listed in ALLOWED with a reason or is a
failure. ALLOWED is deliberately a list of exact statements rather than a
per-directory exemption: an exemption grants the next statement too, and the
next statement is the one nobody decided.

    python3 dev/owns-its-schema.py
"""
from __future__ import annotations
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
# Schemas the extension owns. An application may insert into these and may not
# alter their shape.
CORE = ("aiq", "rbac", "workflow", "agentic", "content", "percolate")
# DDL verbs that change shape. `create index` is deliberately absent: an index
# is a performance decision that does not change what the table means, and
# forbidding it would push applications into worse choices.
DDL = re.compile(
    r"\b(alter\s+table|create\s+(?:or\s+replace\s+)?(?:table|view|materialized\s+view)|drop\s+(?:table|view))"
    r"\s+(?:if\s+(?:not\s+)?exists\s+)?(%s)\." % "|".join(CORE),
    re.IGNORECASE)


# The schema each specs/<dir> owns. A directory absent from here shapes nothing
# outside ALLOWED. `migrations/` is the one place destructive cross-schema
# change belongs, so it is exempt by design rather than by omission.
OWNS = {
    "user-rbac": "rbac",
    "workflow-engine": "workflow",
    "ai-query-layer": "aiq",
    "agentic": "agentic",
    "world-model-ingestion": "content",
    "identity": "percolate",
    "contract": "percolate",
    "packages": "percolate",
    "research-platform": "research",
    "claims": "claims",
    "tables": "research",
    "trace-field": "workflow",
}
EXEMPT_DIRS = {"migrations"}

# Statements that shape a schema their directory does not own, each kept
# because somebody decided it and wrote down why. Matched on
# (directory, schema) plus the object, so a NEW table in the same pair still
# fails. Nothing goes in here to make the gate pass.
ALLOWED = {
    ("world-model-ingestion", "aiq.soft_nodes"):
        "graph.sql lands extracted graphs; a soft node is the query layer's "
        "own type and the ingester is its only writer.",
    ("world-model-ingestion", "aiq.lake_nodes"):
        "same, for the lake half.",
    ("world-model-ingestion", "aiq.graph_vocabulary"):
        "the relation vocabulary an extractor may emit, declared where the "
        "extractors are.",
    ("world-model-ingestion", "aiq.graph_accepted_relations"):
        "a read over aiq.graph_vocabulary, which is allowed above; a view "
        "changes no table's meaning and this one has no reader in aiq.",
    ("world-model-ingestion", "aiq.dream_runs"):
        "dream reconciles the graph this file lands, on a schedule, and this is "
        "the log of its runs; written only by dream, here (REM-961).",
    ("world-model-ingestion", "aiq.judgements"):
        "what dream cannot decide waits here for a judge, with the verdict "
        "recorded; its shape belongs with dream. claims/schema.sql adds "
        "challenge rows to it, which inserts and does not reshape (REM-1055).",
    ("world-model-ingestion", "workflow.v_artifacts"):
        "what an ingestion run produced, read off workflow.tasks. The rows are "
        "the ingester's; the table is not reshaped.",

}


# DEBT: the exact statements already in the tree when this gate learned to read
# specs/. Keyed on the normalised statement rather than on the table, because a
# table-keyed exemption frees every LATER statement on that table too -- which
# is how `alter table rbac.permission_kinds add column` would have been free
# forever once `rbac.grants` was listed. Probed: adding a column to an
# already-listed table fails here, and must.
#
# Every line below is a move, not a redesign: the table is a core table and only
# its DDL is in the wrong file.
# The list only shrinks. Nothing is added to it.
DEBT: dict[str, str] = {}
# EMPTY, and it stays empty. It held the twenty-three statements that were in
# the tree when this gate learned to read specs/; all of them have been moved to
# the directory that owns their schema. A new
# entry here is a decision to keep a violation, so it needs the reason beside it
# and an ALLOWED entry is almost always the honest place instead.


def norm(line: str) -> str:
    return " ".join(line.split())[:88]


def owner_of(rel: pathlib.Path) -> str | None:
    return OWNS.get(rel.parts[0]) if rel.parts else None


def scan(root: pathlib.Path, base: pathlib.Path, owner_fn) -> list:
    out = []
    for path in sorted(root.rglob("*.sql")):
        rel = path.relative_to(base)
        if rel.parts and rel.parts[0] in EXEMPT_DIRS:
            continue
        owner = owner_fn(rel)
        for n, line in enumerate(path.read_text().splitlines(), 1):
            if line.lstrip().startswith("--"):
                continue
            m = DDL.search(line)
            if not m:
                continue
            schema = m.group(2).lower()
            if owner is not None and schema == owner:
                continue
            obj = line.strip().split(schema + ".", 1)[-1]
            obj = re.split(r"[^a-z0-9_]", obj.lower(), maxsplit=1)[0]
            if (rel.parts[0], schema + "." + obj) in ALLOWED:
                continue
            if norm(line) in DEBT:
                continue
            out.append((str(path.relative_to(ROOT)), n, line.strip()[:88]))
    return out


def main() -> int:
    # The private tree also scans its applications/ against every core schema;
    # this tree has none, so only specs/ is read here (REM-1080).
    bad = scan(ROOT / "specs", ROOT / "specs", owner_of)

    if not bad:
        print(f"no application and no spec file shapes a schema it does not own "
              f"({', '.join(CORE)})")
        return 0

    print("A CORE SCHEMA IS SHAPED FROM OUTSIDE THE DIRECTORY THAT OWNS IT.\n")
    for path, n, line in bad:
        print(f"  {path}:{n}\n      {line}")
    print("\nAn application may INSERT into these schemas all day, and so may a spec\n"
          "file. Needing to CHANGE their shape means either the mechanism is general\n"
          "-- move the statement into the directory that owns the schema -- or the\n"
          "decision is real and belongs in ALLOWED in this file, with its reason.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
