#!/usr/bin/env python3
"""Refuse an environment whose packages are not the lock's (REM-1151).

    installed_is_locked.py <requirements.txt from `uv export --locked`>

The image and CI both install `uv export` output, so a test run and an image
of one commit hold the same versions by construction. This is what makes that
a fact rather than a hope: every pin in the export whose marker applies here is
installed at exactly that version. A pip that quietly resolved something else
-- an extra install step, a cache, a requirement added outside the lock --
fails here with the package named, instead of shipping.

Exits 0 with a count, or 1 naming every package that differs or is missing.
"""
import importlib.metadata
import re
import sys

from packaging.markers import Marker

PIN = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)==([^\s;\\]+)\s*(?:;\s*([^\\]+?))?\s*\\?$")


def pins(path: str) -> list[tuple[str, str]]:
    out = []
    for line in open(path):
        m = PIN.match(line.strip())
        if not m:
            continue
        name, version, marker = m.groups()
        if marker and not Marker(marker).evaluate():
            continue
        out.append((name, version))
    return out


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: installed_is_locked.py <requirements.txt>")
    wanted = pins(sys.argv[1])
    if not wanted:
        raise SystemExit(f"{sys.argv[1]} has no pins -- not a `uv export` file")
    wrong = []
    for name, version in wanted:
        try:
            have = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            have = None
        if have != version:
            wrong.append(f"  {name}: the lock says {version}, installed {have or 'nothing'}")
    if wrong:
        print("installed packages are not the lock's:", *wrong, sep="\n", file=sys.stderr)
        raise SystemExit(1)
    print(f"{len(wanted)} packages installed at the lock's versions")


if __name__ == "__main__":
    main()
