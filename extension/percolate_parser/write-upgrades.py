#!/usr/bin/env python3
"""percolate_parser's upgrade scripts: one `percolate_parser--<old>--<VERSION>.sql` per released version.

    python3 extension/percolate_parser/write-upgrades.py                       # write them
    python3 extension/percolate_parser/write-upgrades.py --check               # refuse stale or missing ones
    python3 extension/percolate_parser/write-upgrades.py --surface <pgrx.sql>  # record pgrx's SQL, then write
    python3 extension/percolate_parser/write-upgrades.py --check-surface <pgrx.sql>

WHY, and it was measured rather than supposed (REM-192). Every release shipped only
`percolate_parser--<v>.sql`. A database that installed 0.2.0 and then took the 0.2.1 image
updated `percolate` through its upgrade script and kept `percolate_parser` at 0.2.0 over the
0.2.1 `.so`, with no path forward: `pg_extension_update_paths` had no row, and
`drop extension percolate_parser` is refused because `percolate` depends on it.

THE SAME DESIGN AS `extension/percolate/build-sql.py`, on purpose, so the two extensions that
release as one number also upgrade by one rule: the upgrade script is the body replayed. For the
parser the body is pgrx's own SQL, recorded in `sql/surface.sql` with its comments stripped
(pgrx writes `-- src/lib.rs:622` above each function, which moves on every Rust edit and says
nothing about the database), and replayed with every `CREATE FUNCTION` made
`CREATE OR REPLACE FUNCTION`. The grant block pgrx emits is already idempotent.

WHAT A REPLAY CANNOT EXPRESS, and Postgres says so rather than half-applying: a function whose
return type changed ("cannot change return type of existing function"), a parameter renamed or a
default removed. A function REMOVED from the crate is the silent case -- the replay leaves it in
place. Each of those is a hand-written hop, `migrations/<from>--<to>.sql` (a `drop function`),
prepended to every script whose old version is at or before `<from>`, oldest first -- the rule
build-sql.py uses for `specs/migrations/`.

On 2026-09-14 the pgrx SQL of every released image, 0.1.1 to 0.2.3, normalized to the same
27 statements, so no hop exists yet. `--check-surface` is what keeps that true: CI's parser job
compares what pgrx just produced with `sql/surface.sql`, and a changed surface fails there,
naming this script, instead of shipping upgrade scripts for a surface that no longer exists.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = ROOT / "extension/percolate_parser"
CONTROL = HERE / "percolate_parser.control"
SQL_DIR = HERE / "sql"
SURFACE = SQL_DIR / "surface.sql"
MIGRATIONS = HERE / "migrations"
ME = pathlib.Path(__file__).resolve().relative_to(ROOT)

SURFACE_HEADER = f"""-- percolate_parser's SQL surface: what `cargo pgrx package` generates, comments stripped.
-- RECORDED by {ME} --surface <pgrx.sql>; CI's parser job refuses a build whose pgrx output
-- differs. Every percolate_parser--<old>--<version>.sql is this, replayed.
"""


def fail(msg: str) -> "None":
    print(msg, file=sys.stderr)
    raise SystemExit(1)


def key(v: str) -> list[int]:
    return [int(n) for n in v.split(".")]


def version() -> str:
    m = re.search(r"^default_version = '([^']+)'", CONTROL.read_text(), re.M)
    if not m:
        fail(f"{CONTROL.relative_to(ROOT)}: no default_version")
    return m.group(1)


def released_versions(current: str) -> list[str]:
    """Every published version from the tags, as build-sql.py reads them; none without git."""
    try:
        out = subprocess.run(["git", "-C", str(ROOT), "tag", "--list", "v*"],
                             capture_output=True, text=True, timeout=10)
    except Exception:
        return []
    if out.returncode != 0:
        return []
    if not out.stdout.split():
        fail("this clone has no v* tags, so the released versions the upgrade scripts "
             "start from are unknown (a shallow clone fetches none). Run:\n"
             "  git fetch --tags --unshallow    # or: git fetch --tags")
    tags = {t.lstrip("v") for t in out.stdout.split()}
    return sorted((v for v in tags if re.fullmatch(r"\d+\.\d+\.\d+", v) and key(v) < key(current)), key=key)


def normalized(sql: str) -> str:
    """pgrx's SQL without its comments or blank-line runs: the part a database can see."""
    sql = re.sub(r"/\*.*?\*/", "", sql, flags=re.S)
    lines = []
    for line in sql.splitlines():
        if line.strip().startswith("--"):
            continue
        line = re.sub(r"[ \t]+", " ", line.rstrip())
        if not line.strip() and (not lines or not lines[-1]):
            continue
        lines.append(line if line.strip() else "")
    return "\n".join(lines).strip() + "\n"


def body(surface: str) -> str:
    """The surface, replayable. Anything but a function is refused rather than guessed at."""
    kinds = {m.group(2).upper() for m in re.finditer(r"^\s*CREATE\s+(OR\s+REPLACE\s+)?(\w+)", surface, re.M | re.I)}
    if kinds - {"FUNCTION"}:
        fail(f"sql/surface.sql creates {', '.join(sorted(kinds - {'FUNCTION'}))}, which a replay cannot "
             f"converge. Extend {ME} for it deliberately, or write a migrations/ hop.")
    return re.sub(r"^(\s*)CREATE\s+FUNCTION\b", r"\1CREATE OR REPLACE FUNCTION", surface, flags=re.M | re.I)


def hops() -> list[tuple[str, str, pathlib.Path]]:
    found = []
    for p in sorted(MIGRATIONS.glob("*--*.sql")) if MIGRATIONS.exists() else []:
        m = re.fullmatch(r"(\d+\.\d+\.\d+)--(\d+\.\d+\.\d+)\.sql", p.name)
        if not m:
            fail(f"{p.relative_to(ROOT)}: a hop is named <from>--<to>.sql")
        found.append((m.group(1), m.group(2), p))
    return sorted(found, key=lambda h: key(h[0]))


def script(old: str, new: str, replay: str) -> str:
    parts = [f"-- percolate_parser {old} -> {new}. GENERATED by {ME}; do not edit.\n"]
    for frm, to, path in hops():
        if key(frm) >= key(old) and key(to) <= key(new):
            parts.append(f"\n-- hop {frm} -> {to}: {path.relative_to(ROOT)}\n{path.read_text()}")
    parts.append(f"\n-- the surface of {new}, replayed\n{replay}")
    return "".join(parts)


def expected() -> dict[pathlib.Path, str]:
    if not SURFACE.exists():
        fail(f"{SURFACE.relative_to(ROOT)} is missing -- record it: {ME} --surface <pgrx.sql>")
    new = version()
    replay = body(normalized(SURFACE.read_text()))
    return {SQL_DIR / f"percolate_parser--{old}--{new}.sql": script(old, new, replay)
            for old in released_versions(new)}


def stale(want: dict[pathlib.Path, str]) -> list[pathlib.Path]:
    return sorted(p for p in SQL_DIR.glob("percolate_parser--*--*.sql") if p not in want)


def write() -> None:
    want = expected()
    for p in stale(want):
        p.unlink()
        print(f"removed {p.name}: an upgrade path to a version this tree no longer ships")
    for p, text in want.items():
        p.write_text(text)
    print(f"wrote {len(want)} parser upgrade script(s) to {version()}")


def check() -> None:
    want = expected()
    problems = [f"{p.name} is missing" for p in want if not p.exists()]
    problems += [f"{p.name} does not match sql/surface.sql" for p, t in want.items() if p.exists() and p.read_text() != t]
    problems += [f"{p.name} leads to a version this tree does not ship" for p in stale(want)]
    if problems:
        fail("STALE parser upgrade scripts:\n  " + "\n  ".join(problems) + f"\nrun: python3 {ME}")
    print(f"{len(want)} parser upgrade script(s) to {version()} match sql/surface.sql -- ok")


def record(pgrx: pathlib.Path) -> None:
    SQL_DIR.mkdir(parents=True, exist_ok=True)
    SURFACE.write_text(SURFACE_HEADER + "\n" + normalized(pgrx.read_text()))
    print(f"recorded {SURFACE.relative_to(ROOT)} from {pgrx}")


def check_surface(pgrx: pathlib.Path) -> None:
    if not SURFACE.exists() or normalized(SURFACE.read_text()) != normalized(pgrx.read_text()):
        fail(f"percolate_parser's SQL surface changed: {pgrx} is not {SURFACE.relative_to(ROOT)}.\n"
             f"Record it and regenerate the upgrade scripts: python3 {ME} --surface {pgrx}\n"
             f"If a function was removed, or changed its return type, parameters or defaults, add a hop "
             f"in {MIGRATIONS.relative_to(ROOT)}/ -- a replay cannot express it.")
    print(f"{pgrx.name} matches {SURFACE.relative_to(ROOT)} -- ok")


def main(argv: list[str]) -> None:
    if not argv:
        write()
    elif argv == ["--check"]:
        check()
    elif len(argv) == 2 and argv[0] == "--surface":
        record(pathlib.Path(argv[1]))
        write()
    elif len(argv) == 2 and argv[0] == "--check-surface":
        check_surface(pathlib.Path(argv[1]))
    else:
        fail(__doc__.split("\n\n")[1])


if __name__ == "__main__":
    main(sys.argv[1:])
