#!/usr/bin/env python3
"""Every closed vocabulary in this collection, and whether its copies agree.

    dev/vocab-audit.py                 # the audit
    dev/vocab-audit.py --check         # non-zero if any copy disagrees (CI)
    dev/vocab-audit.py --psql '<cmd>'  # also read a LIVE database's catalog

WHY THIS RUNS IN THE DIRECTION IT DOES.

A closed vocabulary in this collection is written down two to four times: a
CHECK constraint or a vocabulary table in `specs/*/*.sql`, a `Literal[...]` in
`percolate-core`, sometimes an `in (...)` list inside a trigger body, and
sometimes a prose list in a `.md`. The database is the only copy that refuses a
bad write, so it is the source of truth, and every other copy is a derivative
that can silently fall behind it.

The obvious tool for this is a registry -- one table (or one file) listing the
vocabularies, checked to make sure each entry still exists. That tool is worth
very little, and this collection has already learned why: a check over a list
asks "does everything I listed exist?" and never "does everything that exists
appear in my list?". `surface.sql` ran green for months while missing thirteen
of fifteen public views. A vocabulary registry would run green in exactly the
same way, because adding a CHECK constraint and adding the line describing it
are two separate acts and only one of them is required to ship.

So there is NO list here. Vocabularies are discovered from the tree (and, with
--psql, from a live catalog), and copies are matched to each other BY THEIR
CONTENTS rather than by a name mapping somebody maintains:

    identical members            -> bound, and agreeing. Nothing to do.
    mostly-shared members        -> DRIFT. This is the finding, and it is the
                                    only thing --check fails on.
    no near neighbour            -> unpaired. Reported, never failed: a
                                    database vocabulary with no Python copy is
                                    usually correct (nothing in Python needs
                                    it), and a Python-only one is a candidate
                                    for a table rather than a defect.

Matching on contents is what stops this file from becoming the next one-way
list. There is nothing to keep up to date: rename a Literal, move it to another
module, add a fourth copy in a new language, and the pairing still works. The
only thing that breaks the pairing is the thing being looked for -- the members
themselves diverging.

WHAT IT CANNOT SEE, stated so a clean run is not read as more than it means:

  * A vocabulary that exists in ONE place only is not drift, and cannot be. If
    `worker/http.py` is the only thing that knows `mode` is sync|async, this
    file reports it as unpaired and moves on. Unpaired is the backlog, not the
    alarm.
  * Values assembled at runtime -- an f-string, a `.format()`, a name built
    from two halves -- are invisible to both extractors.
  * A prose list in a `.md` is not read. Documentation drift is real and is a
    different tool's job.
"""
from __future__ import annotations

import argparse
import ast
import pathlib
import re
import shlex
import subprocess
import sys
from collections import defaultdict

ROOT = pathlib.Path(__file__).resolve().parents[1]

# A pairing is only interesting if the two sides are recognisably the same
# vocabulary. Two unrelated three-word sets sharing one word are not drift and
# reporting them as such is how a check gets ignored. Calibrated against the
# real corpus: the loosest TRUE pairing in this tree is workflow.tasks.status
# vs RunStatus (4 of 9 shared), and the tightest FALSE one is well below that.
NEAR = 0.34

# Single characters and digits are grades, flags and enum-ish noise that collide
# across unrelated vocabularies ('A','B','C' appears as a source tier and as a
# reliability grade). They are real vocabularies; they are just not matchable by
# content, so they are extracted and never paired.
UNMATCHABLE = re.compile(r"^.?$")


class Vocab:
    """One written-down copy of a closed set of strings."""

    def __init__(self, where: str, name: str, values: list[str], origin: str,
                 column: str | None = None):
        self.where = where          # file:line, or a catalog identifier
        self.name = name            # column, symbol or constraint name
        self.values = values
        self.origin = origin        # sql | python | catalog
        # schema.table.column when this copy is a constraint on a real column.
        # Two copies sharing one of these are declarations of the SAME column,
        # which is a stricter relationship than merely looking alike.
        self.column = column

    @property
    def members(self) -> frozenset[str]:
        return frozenset(self.values)

    @property
    def matchable(self) -> bool:
        return len(self.members) >= 2 and not any(
            UNMATCHABLE.match(v) for v in self.members)

    def __repr__(self) -> str:
        return f"{self.origin}:{self.where}:{self.name}"


def jaccard(a: frozenset[str], b: frozenset[str]) -> float:
    return len(a & b) / len(a | b) if (a | b) else 0.0


# ---------------------------------------------------------------------------
# Source 1: the spec SQL -- CHECK constraints and in-body taxonomies
# ---------------------------------------------------------------------------

# `check (col in ('a','b'))`, across lines. Deliberately not anchored to a
# column definition: the same shape appears in ALTER TABLE ... ADD CONSTRAINT,
# which is how three of this collection's vocabularies are actually re-declared.
CHECK_IN = re.compile(r"check\s*\(\s*(\w+)\s+in\s*\(([^)]*)\)", re.I | re.S)

# A taxonomy enforced inside a trigger body rather than by a constraint --
# `if not (new.auth->>'type' in ('none', ...))`. These are invisible to
# pg_constraint, which is why the tree is read even in --psql mode.
BODY_IN = re.compile(
    r"(\w+)\s*->>\s*'(\w+)'\s*\)?\s+in\s*\(([^)]*)\)", re.I | re.S)

# `insert into <schema>.<table> (<col>, ...) values` for a vocabulary TABLE --
# the lifecycle_states / permission_kinds / evidence_classes pattern, where the
# admissible set is rows rather than a constraint.
VOCAB_INSERT = re.compile(
    r"insert\s+into\s+([a-z_]+\.[a-z_]+)\s*\(([^)]*)\)\s*values(.*?)(?:on\s+conflict|;)",
    re.I | re.S)


def strip_comments(text: str) -> str:
    """Remove `--` comments so a vocabulary quoted in prose is not extracted.

    Every one of these files explains its vocabularies at length in comments,
    listing the members inline; extracting those would pair a comment against
    the constraint it describes and report perfect agreement forever.
    """
    return re.sub(r"--[^\n]*", "", text)


def line_of(text: str, pos: int) -> int:
    return text.count("\n", 0, pos) + 1


# Whichever of these most recently preceded a CHECK owns the column it
# constrains. Both spellings matter: this collection re-declares three of its
# vocabularies by ALTER precisely so an existing installation picks the change
# up, which is exactly the case where the two copies can disagree.
OWNER = re.compile(
    r"(?:create\s+table(?:\s+if\s+not\s+exists)?|alter\s+table)\s+([a-z_]+\.[a-z_]+)",
    re.I)


def owning_table(text: str, pos: int) -> str | None:
    last = None
    for m in OWNER.finditer(text, 0, pos):
        last = m.group(1)
    return last


def sql_vocabs() -> list[Vocab]:
    out: list[Vocab] = []
    for path in sorted((ROOT / "specs").rglob("*.sql")):
        rel = path.relative_to(ROOT).as_posix()
        raw = path.read_text()
        text = strip_comments(raw)

        for m in CHECK_IN.finditer(text):
            vals = re.findall(r"'([^']*)'", m.group(2))
            if len(vals) >= 2:
                tbl = owning_table(text, m.start())
                out.append(Vocab(f"{rel}:{line_of(text, m.start())}",
                                 m.group(1), vals, "sql",
                                 column=f"{tbl}.{m.group(1)}" if tbl else None))

        for m in BODY_IN.finditer(text):
            vals = re.findall(r"'([^']*)'", m.group(3))
            if len(vals) >= 2:
                out.append(Vocab(f"{rel}:{line_of(text, m.start())}",
                                 f"{m.group(1)}.{m.group(2)}", vals, "sql"))

        for m in VOCAB_INSERT.finditer(text):
            table, cols, body = m.group(1), m.group(2), m.group(3)
            first = [c.strip() for c in cols.split(",")][0]
            # The first column of a vocabulary table is its key by convention
            # here (state, class, provider, term). Take the leading literal of
            # each VALUES tuple.
            #
            # ONLY WHERE THE TUPLE IS ACTUALLY A ROW OF LITERALS. This pattern
            # targets the lifecycle_states shape -- a seed table whose VALUES
            # are constants -- and `insert into <table> (cols) values (...)` is
            # also every ordinary INSERT, including the ones inside an upsert
            # function. There, the leading literal of each tuple is a JSON KEY
            # (`p_spec->>'name'`), so the extractor harvested one table's column
            # names and another table's column names and reported them as two
            # disagreeing copies of one vocabulary. They are two tables, and
            # neither is a vocabulary.
            #
            # The predicate that matches the intent: every value in the tuple is
            # a bare literal. A tuple containing `->>`, `->`, `::` or a function
            # call is a computed row, which a seed table does not have. Cheaper
            # and more honest than naming the false pair in DISTINCT, which
            # would have to be extended for the next upsert somebody writes.
            computed = re.compile(r"->>|->|::|\w\s*\(")
            vals = [t[0] for t in
                    (re.findall(r"'([^']*)'", row) for row in
                     (r for r in re.findall(r"\(([^()]*(?:\([^()]*\)[^()]*)*)\)", body)
                        if not computed.search(r)))
                    if t]
            if len(vals) >= 2:
                out.append(Vocab(f"{rel}:{line_of(text, m.start())}",
                                 f"{table}.{first}", vals, "sql"))
    return out


# ---------------------------------------------------------------------------
# Source 2: percolate-core -- Literal aliases, annotations, and string tuples
# ---------------------------------------------------------------------------

def _literal_strings(node: ast.AST) -> list[str] | None:
    """The strings of a `Literal["a", "b"]` subscript, or None."""
    if not isinstance(node, ast.Subscript):
        return None
    base = node.value
    name = (base.attr if isinstance(base, ast.Attribute)
            else base.id if isinstance(base, ast.Name) else None)
    if name != "Literal":
        return None
    sl = node.slice
    elts = sl.elts if isinstance(sl, ast.Tuple) else [sl]
    vals = [e.value for e in elts
            if isinstance(e, ast.Constant) and isinstance(e.value, str)]
    return vals if len(vals) == len(elts) else None


def python_vocabs(pkg: pathlib.Path) -> list[Vocab]:
    out: list[Vocab] = []
    for path in sorted(pkg.rglob("*.py")):
        rel = path.relative_to(ROOT).as_posix()
        try:
            tree = ast.parse(path.read_text())
        except SyntaxError:
            continue
        # A field vocabulary is named for the model that carries it. Bare
        # `role` appearing twice in one package is unreadable in a report, and
        # `InboundMessage.role` vs `Message.role` is the whole distinction.
        enclosing: dict[int, str] = {}
        for cls in (n for n in ast.walk(tree) if isinstance(n, ast.ClassDef)):
            for child in ast.walk(cls):
                if hasattr(child, "lineno"):
                    enclosing.setdefault(child.lineno, cls.name)
        for node in ast.walk(tree):
            # `Role = Literal["system", ...]`
            if isinstance(node, ast.Assign):
                vals = _literal_strings(node.value)
                if vals and len(vals) >= 2 and len(node.targets) == 1 \
                        and isinstance(node.targets[0], ast.Name):
                    out.append(Vocab(f"{rel}:{node.lineno}",
                                     node.targets[0].id, vals, "python"))
                    continue
                # `STEP_KINDS = ("sql", "sources", ...)` -- a vocabulary held
                # as data rather than as a type, which is how three of this
                # package's closed sets are actually written.
                tgt = node.targets[0] if len(node.targets) == 1 else None
                if isinstance(tgt, ast.Name) and tgt.id.isupper() \
                        and isinstance(node.value, (ast.Tuple, ast.List, ast.Set)):
                    vals = [e.value for e in node.value.elts
                            if isinstance(e, ast.Constant)
                            and isinstance(e.value, str)]
                    if len(vals) == len(node.value.elts) and len(vals) >= 2:
                        out.append(Vocab(f"{rel}:{node.lineno}", tgt.id, vals,
                                         "python"))
                # `PARSERS = {"markdown": ..., ...}` -- the keys are the set.
                if isinstance(tgt, ast.Name) and tgt.id.isupper() \
                        and isinstance(node.value, ast.Dict):
                    keys = [k.value for k in node.value.keys
                            if isinstance(k, ast.Constant)
                            and isinstance(k.value, str)]
                    if keys and len(keys) == len(node.value.keys) and len(keys) >= 2:
                        out.append(Vocab(f"{rel}:{node.lineno}",
                                         f"{tgt.id}.keys", keys, "python"))
            # `mode: Literal["append", "replace"] = "append"` on a model field
            elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
                vals = _literal_strings(node.annotation)
                if vals and len(vals) >= 2:
                    cls = enclosing.get(node.lineno)
                    name = f"{cls}.{node.target.id}" if cls else node.target.id
                    out.append(Vocab(f"{rel}:{node.lineno}", name, vals, "python"))
    return out


# ---------------------------------------------------------------------------
# Source 3: a live catalog -- what a running database actually admits
# ---------------------------------------------------------------------------

# The published contract, asked for rather than reconstructed. An earlier
# version of this ran its own pg_constraint query here, which was a second copy
# of exactly the thing this file exists to stop -- the audit restating the
# catalog in its own words, free to fall behind it. `percolate.enums()` is the
# database's own answer, and it reaches things no query written here could:
# the auth and paging taxonomies enforced inside a trigger body, which no
# catalog reader can see.
CONTRACT_SQL = """
select coalesce(vocabulary, schema_name||'.'||table_name)||'.'||column_name,
       enforced_by, array_to_string(admits, '')
from percolate.enums() order by 1, 2;
"""

IMPLEMENTED_SQL = """
select t.name, e.key, e.value::text
from percolate.types t, lateral jsonb_each(coalesce(t.implemented,'{}'::jsonb)) e
where e.value = 'false'::jsonb order by 1, 2;
"""


def _psql(psql: str, sql: str) -> list[list[str]]:
    proc = subprocess.run(shlex.split(psql) + ["-At", "-F", "\t", "-c", sql],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        err = proc.stderr.strip()
        if "percolate.enums" in err or "schema \"p8\"" in err:
            raise SystemExit(
                "this database has no percolate schema, so it publishes no contract. "
                "Install a build that includes specs/contract/schema.sql -- "
                "`dev/reload.sh <db>` does it.")
        raise SystemExit(f"psql failed: {err}")
    return [ln.split("\t") for ln in proc.stdout.splitlines() if "\t" in ln]


def catalog_vocabs(psql: str) -> tuple[list[Vocab], list[tuple[str, str]]]:
    """Read what a live database PUBLISHES as its contract.

    Kept optional rather than required because the tree half of `check.yml` is pure Python over
    the tree and is the gate that runs on every push; needing a database would
    move this check into the expensive job, where it would run rarely. But the
    tree and a deployed database are not the same document -- three of four
    local databases in this workspace still admit the pre-`lifecycle_states`
    status words -- so the live read is where release skew becomes visible.
    """
    out = []
    for name, enforced, joined in _psql(psql, CONTRACT_SQL):
        vals = [v for v in joined.split("") if v]
        if len(vals) >= 2:
            # A 'type' vocabulary is not a column of a table, so it carries no
            # `column` identity -- two declarations of one JSON property are not
            # the same relationship as two CHECKs on one column.
            out.append(Vocab(f"contract:{enforced}", name, vals, "catalog",
                             column=name if enforced != "type" else None))
    gaps = [(t, k) for t, k, _ in _psql(psql, IMPLEMENTED_SQL)]
    return out, gaps


# ---------------------------------------------------------------------------
# Pairing
# ---------------------------------------------------------------------------

# Pairs a human has looked at and declared to be two vocabularies rather than
# one, with the reason. This list is SAFE in a way a registry is not: forgetting
# to add to it makes the check louder, never quieter. Nothing is suppressed by
# omission -- a new vocabulary that resembles an old one is reported until
# somebody says why it should not be.
DISTINCT: list[tuple[str, str, str]] = [
    ("agentic.messages.role", "InboundMessage.role",
     "the stored role and the OpenAI-shaped inbound role are two protocols on "
     "purpose (protocol.py header): inbound has 'tool', stored splits it into "
     "tool_call/tool_response and adds 'summary', which is not a turn at all"),
    ("agentic.agents.audience", "InboundMessage.role",
     "share 'user' and 'system' as ordinary English; unrelated vocabularies"),
    ("agentic.skills.audience", "InboundMessage.role",
     "share 'user' and 'system' as ordinary English; unrelated vocabularies"),
]


def declared_distinct(a: list[Vocab], b: list[Vocab]) -> str | None:
    names = {v.column or v.name for v in a} | {v.name for v in a}
    other = {v.column or v.name for v in b} | {v.name for v in b}
    for x, y, why in DISTINCT:
        if (x in names and y in other) or (y in names and x in other):
            return why
    return None


def pair(vocabs: list[Vocab]):
    """Group copies by content.

    Three relationships, and only one of them is a defect:

      AGREE      identical members. Nothing to do.
      NARROWED   one is a strict subset of the other, and they are not
                 declarations of the same column. This is the deliberate
                 pattern -- `workflow.lifecycle_states` holds every status word
                 and each table CHECKs the subset it can actually reach,
                 because "only a task can be `ready`, only an agent run can be
                 `quota_exceeded`". Reported for the record, never failed.
      DRIFT      either the two copies overlap without either containing the
                 other, or they ARE the same column declared twice with
                 different members. A column re-declared by ALTER is how three
                 of this collection's vocabularies are maintained, so a
                 disagreement between two declarations of one column is the
                 highest-confidence finding this file produces.
    """
    matchable = [v for v in vocabs if v.matchable]
    unmatchable = [v for v in vocabs if not v.matchable]

    by_members: dict[frozenset[str], list[Vocab]] = defaultdict(list)
    for v in matchable:
        by_members[v.members].append(v)

    groups = list(by_members.items())
    drift, narrowed = [], []
    paired: set[frozenset[str]] = set()

    all_members = [m for m, _ in groups]

    def siblings(ma: frozenset[str], mb: frozenset[str]) -> bool:
        """Both are strict subsets of one wider vocabulary in this corpus.

        `agentic.runs.status` and `workflow.tasks.status` overlap without
        either containing the other -- one has `quota_exceeded`, the other has
        `ready` and `waiting_external` -- and that is not drift, it is two
        tables each CHECKing the subset of `workflow.lifecycle_states` it can
        actually reach. Without this rule the designed pattern reports as the
        defect it was built to prevent.
        """
        return any(ma < c and mb < c for c in all_members)

    for i, (ma, va) in enumerate(groups):
        for mb, vb in groups[i + 1:]:
            same_column = bool(
                {v.column for v in va if v.column} &
                {v.column for v in vb if v.column})
            subset = ma < mb or mb < ma
            if not same_column and not subset and jaccard(ma, mb) < NEAR:
                continue
            if declared_distinct(va, vb):
                continue
            paired.add(ma)
            paired.add(mb)
            if same_column:
                drift.append((va, vb, ma - mb, mb - ma, True))
            elif subset or siblings(ma, mb):
                narrowed.append((va, vb, ma ^ mb))
            else:
                drift.append((va, vb, ma - mb, mb - ma, False))

    agreeing = [(m, vs) for m, vs in groups if len(vs) > 1]
    unpaired = [vs[0] for m, vs in groups
                if len(vs) == 1 and m not in paired]
    return agreeing, drift, narrowed, unpaired + unmatchable


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Closed vocabularies, and whether their copies agree.")
    ap.add_argument("--check", action="store_true",
                    help="exit non-zero if any two copies of one vocabulary disagree")
    ap.add_argument("--psql",
                    help="a psql command to also read a live catalog through, e.g. "
                         "'docker exec p8-experiment-pg19 psql -U p8 -d p8reload'")
    ap.add_argument("--unpaired", action="store_true",
                    help="also list vocabularies written down exactly once")
    a = ap.parse_args()

    vocabs = sql_vocabs()
    core = ROOT / "percolate-core" / "percolate_core"
    if core.is_dir():
        vocabs += python_vocabs(core)
    ref = ROOT / "specs" / "world-model-ingestion" / "reference"
    if ref.is_dir():
        vocabs += python_vocabs(ref)
    gaps: list[tuple[str, str]] = []
    if a.psql:
        live, gaps = catalog_vocabs(a.psql)
        vocabs += live

    agreeing, drift, narrowed, unpaired = pair(vocabs)

    print(f"{len(vocabs)} written-down vocabularies "
          f"({sum(1 for v in vocabs if v.origin == 'sql')} sql, "
          f"{sum(1 for v in vocabs if v.origin == 'python')} python, "
          f"{sum(1 for v in vocabs if v.origin == 'catalog')} catalog)")
    print(f"{len(agreeing)} have more than one copy and the copies agree")
    print(f"{len(narrowed)} are a deliberate narrowing of a wider vocabulary")
    print(f"{len(unpaired)} are written down once (nothing to disagree with)")

    if drift:
        print(f"\n=== DRIFT: {len(drift)} vocabularies whose copies disagree ===")
        for va, vb, only_a, only_b, same_column in drift:
            print()
            if same_column:
                col = sorted({v.column for v in va + vb if v.column})[0]
                print(f"  ONE COLUMN, DECLARED TWICE, DIFFERENTLY: {col}")
            for v in va + vb:
                print(f"    {v.where:52} {v.name}")
            if only_a:
                print(f"      only in the first:  {', '.join(sorted(only_a))}")
            if only_b:
                print(f"      only in the second: {', '.join(sorted(only_b))}")

    if narrowed:
        print(f"\n=== NARROWED ({len(narrowed)}) -- a subset, which is the pattern ===")
        for va, vb, diff in narrowed:
            names = " / ".join(sorted({v.name for v in va + vb}))
            print(f"  {names}: differs by {', '.join(sorted(diff))}")

    if gaps:
        # Not drift -- both copies agree that the value is admissible. The
        # database admits it and nothing in this collection can execute it, so
        # the write succeeds and the failure lands on a worker, later,
        # somewhere else. Declared in the type's `implemented` map rather than
        # discovered, which is the only difference between this and an
        # outage at 03:00.
        print(f"\n=== ADMITTED BUT NOT IMPLEMENTED ({len(gaps)}) ===")
        for type_name, value in gaps:
            print(f"  {type_name:32} {value}")

    if a.unpaired:
        print(f"\n=== WRITTEN DOWN ONCE ({len(unpaired)}) ===")
        for v in sorted(unpaired, key=lambda v: (v.origin, v.where)):
            print(f"  {v.origin:8} {v.where:52} {v.name}")

    if a.check and drift:
        print(f"\nVOCABULARY DRIFT: {len(drift)} closed set(s) are written down "
              f"more than once and the copies do not agree. Whichever copy is "
              f"wrong, something is choosing a string that another layer will "
              f"refuse.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
