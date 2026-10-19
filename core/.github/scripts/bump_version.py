#!/usr/bin/env python3
"""Bump the version in the two files that carry it, and report the result.

    bump_version.py patch|minor|major     move the tree's version by one part
    bump_version.py release <part>        decide the number a release publishes

Two files, because there are two. `pyproject.toml` is what PyPI publishes;
`percolate_core/__init__.py` is what `percolate --version` prints and what both
FastAPI apps put in their OpenAPI title. They drifted once already -- 0.1.3
went out reporting 0.1.2 -- which is the argument for doing this here rather
than in a shell one-liner in the workflow: a regex that silently matches
nothing looks exactly like a regex that had nothing to do.

`release` counts from the LATEST TAG, not from the tree, because after a release
the tree is one patch past it on purpose (`after_release.py`). So a `minor`
release after v0.1.12 is 0.2.0 whether the tree says 0.1.12 or 0.1.13. The
tree's own number wins only when it is already that far or further and has no
tag -- which is also how a release that died between its bump and its tag is
retried: dispatch the same bump again, and it publishes the number already in
the tree rather than burning another. Bumping PAST an untagged number that is
already on PyPI is refused, because that is half a release being abandoned.

Reads with tomllib so the current version comes from a parser rather than a
pattern, then writes with a targeted replace so comments and formatting survive.
"""
import os
import pathlib
import re
import subprocess
import sys
import tomllib
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
PYPROJECT = ROOT / "pyproject.toml"
INIT = ROOT / "percolate_core" / "__init__.py"


def fail(msg: str) -> None:
    print(f"::error::{msg}", file=sys.stderr)
    raise SystemExit(1)


def parse(version: str) -> tuple[int, int, int] | None:
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", version)
    return tuple(int(g) for g in m.groups()) if m else None


def bumped(version: str, part: str) -> str:
    if part not in ("major", "minor", "patch"):
        fail(f"unknown bump {part!r} -- expected major, minor or patch")
    parts = parse(version)
    if not parts:
        fail(f"version {version!r} is not plain major.minor.patch -- bump it by hand")
    major, minor, patch = parts
    if part == "major":
        major, minor, patch = major + 1, 0, 0
    elif part == "minor":
        minor, patch = minor + 1, 0
    else:
        patch += 1
    return f"{major}.{minor}.{patch}"


def read_version() -> str:
    return tomllib.loads(PYPROJECT.read_text())["project"]["version"]


def write_version(current: str, new: str) -> None:
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


def latest_tag() -> str | None:
    tags = subprocess.run(
        ["git", "tag", "--list", "v*"], cwd=ROOT, check=True, capture_output=True, text=True
    ).stdout.split()
    versions = [t[1:] for t in tags if parse(t[1:])]
    return max(versions, key=parse) if versions else None


def is_tagged(version: str) -> bool:
    return subprocess.run(
        ["git", "rev-parse", "-q", "--verify", f"refs/tags/v{version}"],
        cwd=ROOT, capture_output=True,
    ).returncode == 0


def on_pypi(version: str) -> bool:
    url = f"https://pypi.org/pypi/percolate-core/{version}/json"
    try:
        with urllib.request.urlopen(url, timeout=20):
            return True
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return False
        fail(f"PyPI answered {e.code} for {version} -- cannot tell whether it is half-published")
    except urllib.error.URLError as e:
        fail(f"could not reach PyPI to ask about {version}: {e.reason}")


def emit(**outputs: str) -> None:
    if out := os.environ.get("GITHUB_OUTPUT"):
        with open(out, "a") as fh:
            fh.writelines(f"{k}={v}\n" for k, v in outputs.items())


def release(part: str) -> None:
    current = read_version()
    if not parse(current):
        fail(f"version {current!r} is not plain major.minor.patch -- bump it by hand")
    latest = latest_tag()
    target = bumped(latest or current, part)
    untagged = not is_tagged(current)

    if untagged and parse(current) >= parse(target):
        print(f"::notice::{current} is in the tree and untagged, and a {part} bump from "
              f"v{latest} is {target} -- publishing {current} rather than bumping")
        emit(previous=latest or "", version=current, mode="as-is")
        return

    if untagged and latest and parse(current) > parse(latest) and on_pypi(current):
        fail(f"{current} is on PyPI and has no tag: a release of it did not finish. "
             f"Dispatch the bump that gives {current} to finish it, rather than "
             f"publishing {target} past it.")
    write_version(current, target)
    print(f"{current} -> {target}")
    emit(previous=latest or "", version=target, mode="bumped")


def main() -> None:
    args = sys.argv[1:] or ["minor"]
    if args[0] == "release":
        release(args[1] if len(args) > 1 else "minor")
        return
    current = read_version()
    new = bumped(current, args[0])
    write_version(current, new)
    print(f"{current} -> {new}")
    emit(previous=current, version=new)


if __name__ == "__main__":
    main()
