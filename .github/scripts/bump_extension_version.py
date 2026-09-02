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

    print(f"{current} -> {new}")
    if out := os.environ.get("GITHUB_OUTPUT"):
        with open(out, "a") as fh:
            fh.write(f"previous={current}\nversion={new}\n")


if __name__ == "__main__":
    main()
