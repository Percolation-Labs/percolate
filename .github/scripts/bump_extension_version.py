#!/usr/bin/env python3
"""Bump the extension version everywhere Postgres and cargo look for it.

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

ROOT = pathlib.Path(__file__).resolve().parents[2]
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


def sub_once(path: pathlib.Path, pattern: str, repl: str) -> None:
    text = path.read_text()
    new, n = re.subn(pattern, repl, text, count=1, flags=re.M)
    if n != 1:
        fail(f"{path.relative_to(ROOT)}: expected one match for {pattern!r}, found {n}")
    path.write_text(new)


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

    sub_once(CONTROL, r"^default_version = '.*'", f"default_version = '{new}'")
    sub_once(PARSER_CONTROL, r"^default_version = '.*'", f"default_version = '{new}'")
    sub_once(CARGO, r'^version = ".*"', f'version = "{new}"')
    sub_once(CARGO_LOCK, r'^(name = "percolate_parser"\nversion = )"[^"]*"',
             rf'\g<1>"{new}"')
    sub_once(CONTRACT, r'^  "extension": "[^"]*",$', f'  "extension": "{new}",')
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
    txt = K8S_MANIFEST.read_text()
    swapped, n = re.subn(
        r"^(\s*(?:mountPath|subPath):.*?)percolate--[0-9]+\.[0-9]+\.[0-9]+\.sql",
        lambda m: f"{m.group(1)}percolate--{new}.sql", txt, flags=re.M)
    if n == 0:
        fail(f"{K8S_MANIFEST.relative_to(ROOT)}: no mountPath/subPath naming "
             "percolate--<version>.sql -- the manifest changed shape and this bump "
             "would leave it stale")
    K8S_MANIFEST.write_text(swapped)
    print(f"  {K8S_MANIFEST.relative_to(ROOT)}: {n} mount reference(s) -> {new}")

    # Regenerate under the new name, then drop the old artifact. In that order:
    # if the build fails the tree still holds a valid, installable extension.
    old_sql = SQL_DIR / f"percolate--{current}.sql"
    subprocess.run(
        [sys.executable, str(ROOT / "extension/percolate/build-sql.py")],
        check=True, cwd=ROOT,
    )
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
    stale = sorted(
        p for p in SQL_DIR.glob("percolate--*--*.sql")
        if not p.name.endswith(f"--{new}.sql")
    )
    for p in stale:
        p.unlink()
        print(f"  removed {p.name}: an upgrade path to a version this tree no longer ships")

    print(f"{current} -> {new}")
    if out := os.environ.get("GITHUB_OUTPUT"):
        with open(out, "a") as fh:
            fh.write(f"previous={current}\nversion={new}\n")


if __name__ == "__main__":
    main()
