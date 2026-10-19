#!/usr/bin/env python3
"""Write the tail of a release: the edits every release used to leave by hand.

    python .github/scripts/after_release.py 0.1.12

Run on main after `v<version>` is tagged. Four edits, each one the thing a gate
or a reader trips on when it is missing:

  * every `percolationlabs/percolate-core:<x.y.z>` pin in a tracked file moves to
    <version> -- `dev/check-version.sh` refuses a pin that is not the latest tag;
  * `CHANGELOG.md`'s `## <version> (unreleased)` heading loses the suffix, and
    the `**Not published.**` paragraph under it goes -- both say so themselves;
  * `RELEASES.md` gains the row for `v<version>` and the commit it names --
    `dev/check-releases.sh` refuses a tag with no row;
  * the tree moves one patch past <version>, because a tree still carrying a
    tagged number is refused by `dev/check-version.sh` as soon as anything lands.

0.1.9, 0.1.10 and 0.1.11 each needed these by hand, and every PR in the
repository was red until somebody did them (REM-150).

What it does NOT write is the paragraph saying why <version> exists. The row is
derived from git; the reason is not, so it is reported as owed rather than
invented. Idempotent: a second run changes nothing.
"""
import os
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import bump_version  # noqa: E402

PIN = re.compile(r"(percolationlabs/percolate-core:)(\d+\.\d+\.\d+)")
# This check's own comment quotes the yanked pin it was written for.
PIN_EXEMPT = {"dev/check-version.sh"}


def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=ROOT, check=True, capture_output=True, text=True
    ).stdout.strip()


def pins(version: str) -> list[str]:
    moved = []
    for rel in git("ls-files").splitlines():
        if rel in PIN_EXEMPT:
            continue
        path = ROOT / rel
        try:
            text = path.read_text()
        except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
            continue
        new, n = PIN.subn(lambda m: m.group(1) + version, text)
        if new != text:
            path.write_text(new)
            moved.append(f"{rel} ({n})")
    return moved


def changelog(version: str) -> bool:
    path = ROOT / "CHANGELOG.md"
    if not path.exists():
        return False
    text = path.read_text()
    heading = f"## {version} (unreleased)\n"
    if heading not in text:
        return False
    head, rest = text.split(heading, 1)
    # The notice is the first paragraph of the section when it is there at all.
    body = rest.lstrip("\n")
    if body.startswith("**Not published.**"):
        _, _, body = body.partition("\n\n")
    path.write_text(f"{head}## {version}\n\n{body}")
    return True


def releases(version: str) -> bool:
    path = ROOT / "RELEASES.md"
    tag = f"v{version}"
    text = path.read_text()
    if f"`{tag}`" in text:
        return False
    # The same abbreviation dev/check-releases.sh computes, in the same clone.
    sha = git("rev-parse", "--short", f"{tag}^{{commit}}")
    lines = text.split("\n")
    try:
        start = lines.index("## Published versions")
    except ValueError:
        bump_version.fail("RELEASES.md has no '## Published versions' table to add a row to")
    last = None
    for i in range(start + 1, len(lines)):
        if lines[i].startswith("|"):
            last = i
        elif last is not None:
            break
    if last is None:
        bump_version.fail("RELEASES.md's '## Published versions' has no table")
    lines.insert(last + 1, f"| {version} | `{tag}` | `{sha}` | yes |")
    path.write_text("\n".join(lines))
    return True


def main() -> None:
    if len(sys.argv) != 2 or not bump_version.parse(sys.argv[1]):
        bump_version.fail("usage: after_release.py <major.minor.patch>")
    version = sys.argv[1]
    if subprocess.run(
        ["git", "rev-parse", "-q", "--verify", f"refs/tags/v{version}"],
        cwd=ROOT, capture_output=True,
    ).returncode != 0:
        bump_version.fail(f"v{version} is not tagged -- the tail is written after the tag, not before")

    report = []
    if moved := pins(version):
        report.append(f"- image pins moved to {version}: " + ", ".join(moved))
    if changelog(version):
        report.append(f"- CHANGELOG.md: `## {version}` is no longer marked unreleased")
    owed = releases(version)
    if owed:
        report.append(f"- RELEASES.md: row for `v{version}` written")
    current = bump_version.read_version()
    if current == version:
        nxt = bump_version.bumped(version, "patch")
        bump_version.write_version(current, nxt)
        report.append(f"- the tree opens {nxt}, because {version} is spent")

    lines = report or ["- nothing to write: the tail is already in the tree"]
    if owed:
        lines.append(
            f"\n**Owed, by a person:** the paragraph in RELEASES.md saying why {version} "
            "exists. The row is derived from git; the reason is not."
        )
    out = "\n".join(lines)
    print(out)
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as fh:
            fh.write(f"### The tail of {version}\n\n{out}\n")
    if owed and os.environ.get("GITHUB_ACTIONS"):
        print(f"::warning::RELEASES.md needs the paragraph saying why {version} exists")


if __name__ == "__main__":
    main()
