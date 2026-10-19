#!/usr/bin/env python3
"""Bump the extension version everywhere Postgres and cargo look for it.

Run by release.yml, twice per release: the tagged version, then the next patch it opens on main (REM-542). A change
does not run it: main already carries an untagged version. By hand only for a minor or major move, or when a
release's last step failed and says so (PACKAGING.md).

The extension is two extensions, and they move as one number. `percolate` is
the schema and `percolate_parser` is the compiled parsers; they are built,
released and installed together, and `install.sh` fetches both from the same
release. Two numbers would mean a compatibility matrix between two things that
have never shipped apart -- the same argument PACKAGING.md makes for one Python
distribution rather than three, applied here.

Four files hold it, because four different tools ask four different questions:

    extension/percolate/percolate.control            what Postgres installs
    extension/percolate_parser/percolate_parser.control   likewise
    extension/percolate_parser/Cargo.toml            what pgrx names the .sql
    extension/percolate/sql/percolate--<v>.sql       the artifact itself

The last one is a filename, not a field: Postgres finds an extension script by
name, so a bump renames the file. build-sql.py writes the new name from the
control file; this script removes the old one, because a sharedir holding both
percolate--0.1.0.sql and percolate--0.2.0.sql is not a bug Postgres reports --
it is two installable versions, one of which nobody meant to ship.
"""
import os
import pathlib
import re
import subprocess
import sys

# PERCOLATE_BUMP_ROOT points the bump at another tree: test_bump_extension_version.py runs it against a
# throwaway repository. Unset, it is this checkout.
ROOT = pathlib.Path(os.environ.get("PERCOLATE_BUMP_ROOT") or pathlib.Path(__file__).resolve().parents[2])
CONTROL = ROOT / "extension/percolate/percolate.control"
PARSER_CONTROL = ROOT / "extension/percolate_parser/percolate_parser.control"
CARGO = ROOT / "extension/percolate_parser/Cargo.toml"
# The FIFTH file carrying the number, and the one that drifted: a kind manifest
# mounts the generated script BY NAME, and the release renames that file. up.sh
# rewrites it with sed at apply time so the cluster works either way, which is
# exactly what let it rot unnoticed -- `dev/references.sh` found it at 0.1.1
# against a control file saying 0.1.2. A real version is kept there rather than
# a placeholder so `kubectl kustomize` alone still renders something
# installable, so the number has to be moved rather than removed.
K8S_MANIFEST = ROOT / "k8s/kind/manifests/postgres.yaml"
# The SIXTH, and it never went through a bump: the lock was committed on
# 2026-09-12 (23a7b7d), six days after Cargo.toml reached 0.2.0, so no run of
# this script has ever met it. Left alone, a bump puts Cargo.toml at the new
# number and the lock's own entry for the crate at the old one, which cargo
# rewrites on the next build -- a dirty tree from a build, and a lock that
# disagrees with its manifest in every commit in between. Only the crate's own
# entry moves; every dependency pin stays exactly as locked.
CARGO_LOCK = ROOT / "extension/percolate_parser/Cargo.lock"
# The SEVENTH: the published contract records the extension version it was
# exported from, and dev/contract-export.py --check compares that field with
# the live database. The 0.2.0 bump (a82d06d) was done by hand and moved it in
# the same commit; this script never did, so a bump it made would land on main
# with CI's database job red on "The published contract is current" over one
# number. Only the field moves -- every enum and type is still checked against
# a real database, so moving it cannot hide a contract change.
CONTRACT = ROOT / "extension/percolate/contract.json"
SQL_DIR = ROOT / "extension/percolate/sql"


def fail(msg: str) -> None:
    print(f"::error::{msg}", file=sys.stderr)
    raise SystemExit(1)


def sub_once(text: str, path: pathlib.Path, pattern: str, repl: str) -> str:
    new, n = re.subn(pattern, repl, text, count=1, flags=re.M)
    if n != 1:
        fail(f"{path.relative_to(ROOT)}: expected one match for {pattern!r}, found {n}")
    return new


# PATHS INTO THE EXTENSION'S SQL DIRECTORY that a page or a script uses, found with
# the same pattern and the same two exclusions as dev/references.sh check 1. So what
# this moves is exactly what that gate refuses to find stale. The 0.2.4 and 0.2.5
# bumps both left `core-below-market-above.html` naming the deleted script, and a
# person renumbered it by hand each time (REM-254). The sql directory itself is the
# artifact, not a reference to it.
REFERENCE_EXCLUDES = (":(exclude)research-notes/results",
                      ":(exclude)applications/percolate-self-model/history.jsonl",
                      ":(exclude)extension/percolate/sql")
# Run inside a pre-push hook, GIT_DIR names the pushing repository and would win over cwd.
GIT_ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
PARSER_SQL_DIR = ROOT / "extension/percolate_parser/sql"


def path_references(current: str) -> list[pathlib.Path]:
    needle = f"extension/percolate/sql/percolate--{current}.sql"
    found = subprocess.run(["git", "grep", "-l", "-F", needle, "--", ".", *REFERENCE_EXCLUDES],
                           cwd=ROOT, env=GIT_ENV, capture_output=True, text=True)
    if found.returncode not in (0, 1):
        fail(f"git grep for {needle} failed: {found.stderr.strip()}")
    return [ROOT / line for line in found.stdout.splitlines() if line]


def builder() -> str:
    """The interpreter the generators run under, asked of dev/lib/python.sh and checked before any write.

    This script used to run build-sql.py under its own interpreter. On a Mac
    that is often one without PyYAML, so a bump rewrote six version fields, died
    in build-sql.py and left the tree half renumbered for a person to finish
    (REM-239). The gates already agree on one answer to "which Python", so the
    bump asks the same helper -- and then asks the answer to import yaml, because
    the helper returns $PY unchecked when it is set.
    """
    found = subprocess.run(["bash", "-c", ". dev/lib/python.sh && percolate_python"],
                           cwd=ROOT, env=GIT_ENV, capture_output=True, text=True)
    py = found.stdout.strip()
    if found.returncode != 0 or not py:
        fail("no interpreter for build-sql.py from dev/lib/python.sh, so nothing was changed: "
             + found.stderr.strip())
    try:
        usable = subprocess.run([py, "-c", "import yaml"], capture_output=True, env=GIT_ENV).returncode == 0
    except OSError:
        usable = False
    if not usable:
        fail(f"{py} cannot import yaml, which build-sql.py needs, so nothing was changed")
    return py


def restore(before: dict[pathlib.Path, bytes], dirs) -> None:
    """Put back exactly what was there: each file as it was, and nothing the failed run added."""
    for d in dirs:
        for p in d.glob("*.sql"):
            if p not in before:
                p.unlink()
    for p, data in before.items():
        if not p.is_file() or p.read_bytes() != data:
            p.write_bytes(data)


def main() -> None:
    part = sys.argv[1] if len(sys.argv) > 1 else "minor"
    if part not in ("major", "minor", "patch"):
        fail(f"unknown bump {part!r} -- expected major, minor or patch")

    m = re.search(r"^default_version = '([^']+)'", CONTROL.read_text(), re.M)
    if not m:
        fail(f"{CONTROL.relative_to(ROOT)}: no default_version")
    current = m.group(1)

    v = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", current)
    if not v:
        fail(f"version {current!r} is not plain major.minor.patch -- bump it by hand")
    major, minor, patch = (int(g) for g in v.groups())
    if part == "major":
        major, minor, patch = major + 1, 0, 0
    elif part == "minor":
        minor, patch = minor + 1, 0
    else:
        patch += 1
    new = f"{major}.{minor}.{patch}"

    # The two extensions are checked, not assumed, to be in step. If they have
    # drifted, the bump would quietly put them back in step at the new number
    # and hide whatever caused the drift.
    pm = re.search(r"^default_version = '([^']+)'", PARSER_CONTROL.read_text(), re.M)
    cm = re.search(r'^version = "([^"]+)"', CARGO.read_text(), re.M)
    if not pm or not cm:
        fail("could not read percolate_parser's version from its control file or Cargo.toml")
    if {pm.group(1), cm.group(1)} != {current}:
        fail(
            f"the two extensions have drifted: percolate {current}, "
            f"percolate_parser {pm.group(1)} (control) / {cm.group(1)} (Cargo.toml). "
            "Put them in step by hand before releasing -- a bump would paper over it."
        )

    py = builder()

    # EVERY EDIT IS PLANNED BEFORE ONE IS MADE (REM-254). Each rule below either
    # matches or refuses, and all of them are asked first, so a refusal leaves
    # the tree exactly as it was rather than half renumbered.
    planned: dict[pathlib.Path, str] = {}

    def plan(path: pathlib.Path, pattern: str, repl: str) -> None:
        planned[path] = sub_once(planned.get(path) or path.read_text(), path, pattern, repl)

    plan(CONTROL, r"^default_version = '.*'", f"default_version = '{new}'")
    plan(PARSER_CONTROL, r"^default_version = '.*'", f"default_version = '{new}'")
    plan(CARGO, r'^version = ".*"', f'version = "{new}"')
    plan(CARGO_LOCK, r'^(name = "percolate_parser"\nversion = )"[^"]*"', rf'\g<1>"{new}"')
    plan(CONTRACT, r'^  "extension": "[^"]*",$', f'  "extension": "{new}",')
    # THE MOUNT LINES ONLY, and the anchor is the whole correctness of this.
    #
    # Two occurrences are meant to move -- `mountPath:` and `subPath:` -- so
    # this is not sub_once. It used to be an unanchored substitution over the
    # whole file, which found a THIRD: a comment recording what the published
    # 0.1.0 image shipped ("percolate--0.1.0.sql at 4,457 lines against 10,429
    # in this repository"). Two releases rewrote that sentence into a claim
    # about 0.1.2 that is false about every number in it.
    #
    # A version in a comment is HISTORY and must not move. dev/references.sh
    # already knows this -- its own header records that the first version of
    # its check flagged that comment and "was wrong to" -- so the two now agree
    # about which references are live: the ones used as paths. Matching
    # `^\s*(mountPath|subPath):` is the same predicate references.sh greps for,
    # which is what keeps the writer and the checker from drifting apart.
    #
    # ONLY WHERE IT EXISTS. Percolation-Labs/percolate holds the extension and
    # not the kind stack, which stays in p8-subsystems and follows the published
    # image, so there is no manifest here to move. A manifest that is present
    # but no longer matches still refuses, as before.
    mounts = None
    if K8S_MANIFEST.exists():
        swapped, mounts = re.subn(
            r"^(\s*(?:mountPath|subPath):.*?)percolate--[0-9]+\.[0-9]+\.[0-9]+\.sql",
            lambda m: f"{m.group(1)}percolate--{new}.sql", K8S_MANIFEST.read_text(), flags=re.M)
        if mounts == 0:
            fail(f"{K8S_MANIFEST.relative_to(ROOT)}: no mountPath/subPath naming "
                 "percolate--<version>.sql -- the manifest changed shape and this bump "
                 "would leave it stale")
        planned[K8S_MANIFEST] = swapped
    old_ref = f"extension/percolate/sql/percolate--{current}.sql"
    new_ref = f"extension/percolate/sql/percolate--{new}.sql"
    references = path_references(current)
    for path in references:
        planned[path] = (planned.get(path) or path.read_text()).replace(old_ref, new_ref)

    # WHAT A FAILURE PUTS BACK: every file about to be edited, and every script in
    # both sql directories, which the generators and the pruning below rewrite
    # and delete. A few megabytes held for the length of one command.
    sql_dirs = (SQL_DIR, PARSER_SQL_DIR)
    before = {p: p.read_bytes() for p in [*planned, *(q for d in sql_dirs for q in d.glob("*.sql"))]
              if p.is_file()}
    try:
        for path, text in planned.items():
            path.write_text(text)
        if mounts is None:
            print(f"  {K8S_MANIFEST.relative_to(ROOT)}: not in this tree, nothing to move")
        else:
            print(f"  {K8S_MANIFEST.relative_to(ROOT)}: {mounts} mount reference(s) -> {new}")
        for path in references:
            print(f"  {path.relative_to(ROOT)}: {old_ref} -> {new_ref}")

        # Regenerate under the new name, then drop the old artifact. In that order:
        # if the build fails, the restore below puts the old artifact's name back.
        old_sql = SQL_DIR / f"percolate--{current}.sql"
        subprocess.run([py, str(ROOT / "extension/percolate/build-sql.py")], check=True, cwd=ROOT)
        new_sql = SQL_DIR / f"percolate--{new}.sql"
        if not new_sql.exists():
            fail(f"build-sql.py did not write {new_sql.name} -- it read a different version")
        if old_sql.exists():
            old_sql.unlink()

        # AND THE UPGRADE SCRIPTS THAT NOW LEAD NOWHERE, which is the same argument
        # as the line above and was missed because it is a different filename shape.
        #
        # Postgres reads the sharedir to answer "what can this extension become".
        # `percolate--0.1.1--0.1.2.sql` declares an update PATH to 0.1.2, and the
        # bump has just deleted `percolate--0.1.2.sql`, the base script for the
        # version that path arrives at. Left behind, the release ships an installed
        # extension one `ALTER EXTENSION percolate UPDATE TO '0.1.2'` away from a
        # version nobody meant to offer -- which is precisely this file's own
        # argument for deleting the old base script, one filename shape along.
        #
        # build-sql.py has just written a direct path from every version that is
        # STILL PUBLISHED (it reads the tags), so nothing that a real database can
        # be sitting at loses its route. Anything targeting a version other than
        # the one being published is by construction a leftover.
        for p in sorted(q for q in SQL_DIR.glob("percolate--*--*.sql") if not q.name.endswith(f"--{new}.sql")):
            p.unlink()
            print(f"  removed {p.name}: an upgrade path to a version this tree no longer ships")

        # AND THE PARSER'S, which moves by the same rule and was never written at all until REM-192:
        # percolate_parser--<old>--<new>.sql for every published version, from the recorded surface.
        # The generator removes its own leftovers, as build-sql.py does.
        subprocess.run([py, str(ROOT / "extension/percolate_parser/write-upgrades.py")], check=True, cwd=ROOT)
    except BaseException:
        restore(before, sql_dirs)
        print("::error::the bump failed after it began writing; every file it touched is back as it was",
              file=sys.stderr)
        raise

    print(f"{current} -> {new}")
    if out := os.environ.get("GITHUB_OUTPUT"):
        with open(out, "a") as fh:
            fh.write(f"previous={current}\nversion={new}\n")


if __name__ == "__main__":
    main()
