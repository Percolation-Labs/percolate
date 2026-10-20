#!/usr/bin/env python3
"""No line in this tree points a reader at a repository they cannot open (REM-1080).

    dev/no-private-citations.py --check        # every line in the tree; refuses any citation

This repository was cut out of a private one, and it said "see
meta/postmortems/..." or "specs/claims/graph.md" in hundreds of places that an
outside reader could not follow. Those were published beside their schema or
replaced with the point itself, until none was left; so this refuses any, not
only a new one.

A citation is one of:
  * a path whose first segment is a top-level directory only the private tree
    has (meta/, board/, applications/, research-notes/, experiments/,
    scenarios/, k8s/, packages/, site/, output/, demo/), unless it is the
    spec-relative name of a file this tree holds (build-sql.py's ORDER says
    `packages/schema.sql` for specs/packages/schema.sql);
  * a prose spec, specs/<dir>/<name>.md, that does not exist in this tree;
  * the name of a private repository: p8-subsystems, percolate-application,
    or a URL into Percolation-Labs/percolate-core.

Card ids (REM-123) are fine: they are opaque, not a path. The generated
extension SQL is skipped, because it is a copy of specs/ and is fixed there,
and so is core/, a mirror of percolate-core, fixed in that repository.
"""
import os
import re
import subprocess
import sys

PRIVATE_DIRS = ("meta", "board", "applications", "research-notes", "experiments",
                "scenarios", "k8s", "packages", "site", "output", "demo")
# A path token starts the line or follows whitespace, a quote, a backtick or a
# bracket -- never `_`, `.`, `/` or a word character, so `dev/packages/x`,
# `my_meta/x` and `.output/` are not citations.
PRIVATE_PATH = re.compile(r"(?:^|(?<=[\s`'\"(\[<]))(?:\.\./)*(?:p8-subsystems/)?("
                          + "|".join(re.escape(d) for d in PRIVATE_DIRS) + r")/[\w.\-/]+")
PROSE_SPEC = re.compile(r"(?<![\w./-])(specs/[\w\-]+(?:/[\w\-]+)*/[\w\-]+\.md)\b")
PRIVATE_REPO = re.compile(r"\bp8-subsystems\b|\bpercolate-application\b|Percolation-Labs/percolate-core\b")
# core/ is a read-only mirror of percolate-core: a citation there is fixed in
# that repository, and refusing it here would only block the next sync.
# The version bump moves numbers in whichever tree it runs in, so it names the
# private tree's kind manifest and a results file as paths it may find there,
# and its test builds both in a scratch repository: code, pointing no reader
# anywhere.
SKIP = re.compile(r"^extension/percolate/sql/.*\.sql$|\.lock$|^dev/no-private-citations\.py$|^core/"
                  r"|^\.github/scripts/(test_)?bump_extension_version\.py$")


def git(*args):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    return subprocess.run(["git", *args], capture_output=True, text=True, check=True, env=env).stdout


def tracked():
    return set(git("ls-files").splitlines())


def hits(line, files):
    found = [m.group(0) for m in PRIVATE_PATH.finditer(line) if f"specs/{m.group(0)}" not in files]
    found += [m.group(1) for m in PROSE_SPEC.finditer(line) if m.group(1) not in files]
    found += [m.group(0) for m in PRIVATE_REPO.finditer(line)]
    return found


def main():
    files = tracked()
    bad = []
    for path in sorted(files):
        if SKIP.search(path):
            continue
        try:
            text = open(path, encoding="utf-8").read()
        except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
            continue
        bad += [(path, n, h) for n, line in enumerate(text.splitlines(), 1) for h in hits(line, files)]
    for p, n, h in bad:
        print(f"  {p}:{n}: {h}")
    if bad:
        print(f"{len(bad)} citation(s) of private material. An outside reader cannot open them: "
              "say the point in a sentence, or cite something in this tree.")
        return 1
    print("no citation of private material in the tree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
