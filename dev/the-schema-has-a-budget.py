#!/usr/bin/env python3
"""The size of the extension is a number somebody wrote down, not a side effect.

    python3 dev/the-schema-has-a-budget.py            # the gate
    python3 dev/the-schema-has-a-budget.py --fold     # move every declaration into budget.toml's totals
    python3 dev/the-schema-has-a-budget.py --fold --at v0.2.31   # only those a release shipped (the train's fold)

specs/budget.toml holds the settled totals, and each change declares its own additions BY NAME in a file of
its own, specs/budget.d/<branch>.toml. This refuses a tree whose specs disagree with the totals plus every
declaration, and a branch that adds or removes a table, view or function it did not name.

WHY A FILE PER CHANGE (REM-1142). The totals used to be the only declaration, so every PR that added a
function raised the same line of budget.toml. Two PRs raising it from the same base to the same value merge
with no conflict -- git sees one identical edit -- and one increment is lost, which turns main red for
whoever merges next. It happened three times in two days (#234 and #240, #235 and #241, #260 and #253).
A declaration nobody else writes cannot collide: two branches that each add a function merge in either
order and the sum is right. So a branch no longer edits the totals; --fold does, once, for everybody.

TWO-SIDED, which is the part that makes it a ratchet rather than a ceiling. Growing the schema fails until
the addition is declared, where a reviewer sees it and can ask what it replaced. SHRINKING it fails too,
until the removal is declared -- otherwise the first deletion buys headroom for an addition nobody argued
for. It is not a limit and refuses nothing on grounds of size: a declaration has to be walked through, and
the walking is the tax.

Counted over the spec files in build-sql.py's ORDER, read rather than restated, so a proposal held out of
ORDER costs nothing until it ships. The branch's own changes are read against the merge base with
$CHANGED_BASE (else origin/main), the base dev/generated-output.py uses; without git, only the totals are
checked.
"""
from __future__ import annotations

import argparse
import os
import pathlib
import re
import subprocess
import sys
import tomllib

ROOT = pathlib.Path(__file__).resolve().parent.parent
KINDS = {
    "tables":    r"^\s*create table if not exists\s+([a-z_]+\.[a-z_]+)",
    "views":     r"^\s*create (?:or replace )?(?:materialized )?view\s+([a-z_]+\.[a-z_]+)",
    "functions": r"^\s*create or replace function\s+([a-z_]+\.[a-z_]+)",
}
NAME = re.compile(r"^[a-z_]+\.[a-z_]+$")
EXAMPLE = """\
    why = "what it adds, and what it replaces or why nothing does"

    [added]
    functions = ["claims.settle"]

    [removed]
    tables = ["claims.old_thing"]"""


class Tree:
    """The files the gate reads, from the working tree or from a git revision."""

    def __init__(self, root: pathlib.Path, rev: str | None = None):
        self.root, self.rev = root, rev

    def read(self, rel: str) -> str | None:
        if self.rev is None:
            p = self.root / rel
            return p.read_text(encoding="utf-8", errors="replace") if p.exists() else None
        r = subprocess.run(["git", "-C", str(self.root), "show", f"{self.rev}:{rel}"],
                           capture_output=True, text=True, errors="replace")
        return r.stdout if r.returncode == 0 else None

    def declarations(self) -> dict[str, str]:
        """{specs/budget.d/<name>.toml: text}"""
        if self.rev is None:
            d = self.root / "specs/budget.d"
            return {f"specs/budget.d/{p.name}": p.read_text(encoding="utf-8")
                    for p in sorted(d.glob("*.toml"))} if d.is_dir() else {}
        r = subprocess.run(["git", "-C", str(self.root), "ls-tree", "--name-only", f"{self.rev}:specs/budget.d"],
                           capture_output=True, text=True)
        names = [n for n in r.stdout.split() if n.endswith(".toml")] if r.returncode == 0 else []
        return {f"specs/budget.d/{n}": self.read(f"specs/budget.d/{n}") or "" for n in names}

    def objects(self) -> dict[str, set[str]]:
        src = self.read("extension/percolate/build-sql.py")
        if src is None:
            raise SystemExit("extension/percolate/build-sql.py is missing")
        body = src[src.index("ORDER = ["):]
        files = re.findall(r'\(\s*"([^"]+\.sql)"', body[:body.index("\n]")]) + ["identity/closing.sql"]
        texts = []
        for rel in files:
            t = self.read(f"specs/{rel}")
            if t is None:
                raise SystemExit(f"build-sql.py's ORDER names specs/{rel}, which does not exist")
            texts.append(t)
        return {k: {m.group(1).lower() for t in texts for m in re.finditer(p, t, re.I | re.M)}
                for k, p in KINDS.items()}

    def totals(self) -> dict[str, int]:
        text = self.read("specs/budget.toml") or ""
        # Not tomllib: the file is one section of three integers and has always been read so.
        return {k: int(v) for k, v in re.findall(r"^([a-z]+)\s*=\s*(\d+)\s*$", text, re.M)}


def parse_declaration(path: str, text: str, errors: list[str]) -> dict[str, dict[str, list[str]]]:
    """{'added': {kind: [names]}, 'removed': {...}}, with every fault appended to errors by file."""
    try:
        doc = tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        errors.append(f"{path}: not TOML ({e})")
        return {"added": {}, "removed": {}}
    if not str(doc.get("why", "")).strip():
        errors.append(f"{path}: says nothing in `why` -- what the addition replaces, or why nothing does, is the point")
    out: dict[str, dict[str, list[str]]] = {}
    for side in ("added", "removed"):
        out[side] = {}
        for kind, names in doc.get(side, {}).items():
            if kind not in KINDS:
                errors.append(f"{path}: [{side}] {kind} is not one of {', '.join(KINDS)}")
                continue
            bad = [n for n in names if not isinstance(n, str) or not NAME.match(n.lower())]
            if bad:
                errors.append(f"{path}: [{side}] {kind} names {bad}, not schema.name")
            out[side][kind] = [n.lower() for n in names if isinstance(n, str)]
    for k in set(doc) - {"why", "added", "removed"}:
        errors.append(f"{path}: unknown key {k!r}")
    if not any(out["added"].values()) and not any(out["removed"].values()):
        errors.append(f"{path}: declares nothing; delete it")
    return out


def summed(decls: dict[str, dict]) -> dict[str, int]:
    return {k: sum(len(d["added"].get(k, [])) - len(d["removed"].get(k, [])) for d in decls.values()) for k in KINDS}


def merge_base(root: pathlib.Path, base: str) -> str | None:
    r = subprocess.run(["git", "-C", str(root), "merge-base", base, "HEAD"], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def fold(root: pathlib.Path, at: str | None) -> int:
    tree, errors = Tree(root), []
    decls = {p: parse_declaration(p, t, errors) for p, t in tree.declarations().items()}
    if at is not None:
        # The train folds what the release shipped: a declaration merged after the tag stays for the next one.
        shipped = Tree(root, at).declarations()
        decls = {p: d for p, d in decls.items() if p in shipped}
    if errors:
        print("\n".join(errors))
        return 1
    if not decls:
        print("nothing to fold")
        return 0
    totals, delta = tree.totals(), summed(decls)
    path = root / "specs/budget.toml"
    text = path.read_text(encoding="utf-8")
    for k in KINDS:
        text = re.sub(rf"^({k}\s*=\s*)\d+\s*$", lambda m, k=k: f"{m.group(1)}{totals[k] + delta[k]}", text, flags=re.M)
    path.write_text(text, encoding="utf-8")
    for p in decls:
        (root / p).unlink()
    print(f"folded {len(decls)} declaration(s): "
          + ", ".join(f"{k} {totals[k]} -> {totals[k] + delta[k]}" for k in KINDS))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(ROOT), help="the tree to check (a test passes its own)")
    ap.add_argument("--base", default=os.environ.get("CHANGED_BASE") or "origin/main",
                    help="what the branch is compared against ($CHANGED_BASE, else origin/main)")
    ap.add_argument("--fold", action="store_true", help="move every declaration into budget.toml and delete it")
    ap.add_argument("--at", help="with --fold: only the declarations present at this git revision (a release tag)")
    a = ap.parse_args()
    root = pathlib.Path(a.root).resolve()
    if a.fold:
        return fold(root, a.at)

    tree, errors = Tree(root), []
    totals = tree.totals()
    missing = [k for k in KINDS if k not in totals]
    if missing:
        print(f"specs/budget.toml declares no {', '.join(missing)}")
        return 1
    texts = tree.declarations()
    decls = {p: parse_declaration(p, t, errors) for p, t in texts.items()}
    have = tree.objects()
    want = {k: totals[k] + summed(decls)[k] for k in KINDS}

    print("  " + " · ".join(f"{k} {len(have[k])}" for k in KINDS)
          + "  (budget.toml " + ", ".join(str(totals[k]) for k in KINDS)
          + f" + {len(decls)} declaration(s) = " + ", ".join(str(want[k]) for k in KINDS) + ")")

    # 1. The totals plus every declaration in the tree describe the tree. This is the half that survives any
    #    merge order: declarations are separate files, so a merge keeps all of them.
    for k in KINDS:
        if len(have[k]) != want[k]:
            errors.append(f"{k}: budget.toml plus the declarations say {want[k]}, this tree has {len(have[k])}")

    # 2. What THIS branch changed, by name, against the merge base.
    mb = merge_base(root, a.base)
    if mb is None:
        print(f"  (no merge base with {a.base}: the branch's own changes are not named, only the totals checked)")
    else:
        base = Tree(root, mb)
        base_have, base_totals, base_texts = base.objects(), base.totals(), base.declarations()
        mine = {p: d for p, d in decls.items() if texts[p] != base_texts.get(p)}
        for k in KINDS:
            added, removed = have[k] - base_have[k], base_have[k] - have[k]
            said_added = {n for d in mine.values() for n in d["added"].get(k, [])}
            said_removed = {n for d in mine.values() for n in d["removed"].get(k, [])}
            for n in sorted(added - said_added):
                errors.append(f"{k}: this branch adds {n} and no specs/budget.d file of its own declares it")
            for n in sorted(removed - said_removed):
                errors.append(f"{k}: this branch removes {n} and no specs/budget.d file of its own declares it")
            for n in sorted(said_added - added):
                errors.append(f"{k}: a declaration adds {n}, which this branch does not add")
            for n in sorted(said_removed - removed):
                errors.append(f"{k}: a declaration removes {n}, which this branch does not remove")
        # 3. The totals are the fold's, not a branch's: a change to them must be exactly the declarations the
        #    same change deleted. Raising them by hand is the shared counter this replaced.
        folded = summed({p: parse_declaration(p, t, []) for p, t in base_texts.items() if p not in texts})
        for k in KINDS:
            if totals[k] - base_totals.get(k, 0) != folded[k]:
                errors.append(f"{k}: specs/budget.toml's total moved {base_totals.get(k, 0)} -> {totals[k]}; a branch "
                              f"declares in specs/budget.d instead (only --fold moves the totals)")

    if not errors:
        return 0
    print("\nTHE SCHEMA IS NOT THE SIZE ITS DECLARATIONS SAY.\n")
    for e in errors:
        print(f"  {e}")
    print("\nDeclare this branch's additions and removals by name in a file only this branch writes,\n"
          "specs/budget.d/<your-branch>.toml, and leave specs/budget.toml's totals alone:\n\n"
          f"{EXAMPLE}\n\n"
          "Before you add, ask what already holds this and whether it is core at all: those are the\n"
          "two questions the declaration exists to make somebody answer out loud.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
