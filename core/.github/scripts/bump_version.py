#!/usr/bin/env python3
"""Bump the version in the two files that carry it, and report the result.

Two files, because there are two. `pyproject.toml` is what PyPI publishes;
`percolate_core/__init__.py` is what `percolate --version` prints and what both
FastAPI apps put in their OpenAPI title. They drifted once already -- 0.1.3
went out reporting 0.1.2 -- which is the argument for doing this here rather
than in a shell one-liner in the workflow: a regex that silently matches
nothing looks exactly like a regex that had nothing to do.

Reads with tomllib so the current version comes from a parser rather than a
pattern, then writes with a targeted replace so comments and formatting survive.
"""
import os
import pathlib
import re
import sys
import tomllib

ROOT = pathlib.Path(__file__).resolve().parents[2]
PYPROJECT = ROOT / "pyproject.toml"
INIT = ROOT / "percolate_core" / "__init__.py"


def fail(msg: str) -> None:
    print(f"::error::{msg}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    part = sys.argv[1] if len(sys.argv) > 1 else "minor"
    if part not in ("major", "minor", "patch"):
        fail(f"unknown bump {part!r} -- expected major, minor or patch")

    current = tomllib.loads(PYPROJECT.read_text())["project"]["version"]
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", current)
    if not m:
        fail(f"version {current!r} is not plain major.minor.patch -- bump it by hand")
    major, minor, patch = (int(g) for g in m.groups())

    if part == "major":
        major, minor, patch = major + 1, 0, 0
    elif part == "minor":
        minor, patch = minor + 1, 0
    else:
        patch += 1
    new = f"{major}.{minor}.{patch}"

    # pyproject: replace the [project] version, and only it. Anchored on the
    # exact current string so a stray `version = "1"` elsewhere cannot be hit.
    text = PYPROJECT.read_text()
    old_line = f'version = "{current}"'
    if text.count(old_line) != 1:
        fail(f"expected exactly one {old_line!r} in pyproject.toml, found {text.count(old_line)}")
    PYPROJECT.write_text(text.replace(old_line, f'version = "{new}"', 1))

    # __init__.py: whatever it currently says, which is not necessarily what
    # pyproject said. Rewriting rather than replacing a known value is what
    # makes this self-healing when the two have already drifted.
    text = INIT.read_text()
    text, n = re.subn(
        r'^__version__ = "[^"]*"$', f'__version__ = "{new}"', text, count=1, flags=re.M
    )
    if n != 1:
        fail(f"no __version__ assignment found in {INIT.relative_to(ROOT)}")
    INIT.write_text(text)

    print(f"{current} -> {new}")
    if out := os.environ.get("GITHUB_OUTPUT"):
        with open(out, "a") as fh:
            fh.write(f"previous={current}\nversion={new}\n")


if __name__ == "__main__":
    main()
