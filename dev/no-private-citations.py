#!/usr/bin/env python3
"""No line this branch adds points a reader at a repository they cannot open (REM-1080).

    dev/no-private-citations.py --check        # lines added since $CHANGED_BASE (default origin/main)
    dev/no-private-citations.py --all          # every line in the tree: the backlog, as a count

This repository was cut out of a private one, and it still says "see
meta/postmortems/..." or "specs/claims/graph.md" in hundreds of places that an
outside reader cannot follow. The backlog is a decision (which prose becomes
public); a NEW citation is just a slip, and this refuses it.

A citation is one of:
  * a path whose first segment is a top-level directory only the private tree
    has (meta/, board/, applications/, research-notes/, experiments/,
    scenarios/, k8s/, packages/, site/, output/, demo/);
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
SKIP = re.compile(r"^extension/percolate/sql/.*\.sql$|\.lock$|^dev/no-private-citations\.py$|^core/")


def git(*args):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    return subprocess.run(["git", *args], capture_output=True, text=True, check=True, env=env).stdout


def tracked():
    return set(git("ls-files").splitlines())


def hits(line, files):
    found = [m.group(0) for m in PRIVATE_PATH.finditer(line)]
    found += [m.group(1) for m in PROSE_SPEC.finditer(line) if m.group(1) not in files]
    found += [m.group(0) for m in PRIVATE_REPO.finditer(line)]
    return found


def added_lines(base):
    """(file, line number, text) for every line the diff from the merge base adds."""
    out, path, n = [], None, 0
    for raw in git("diff", "--unified=0", "--no-color", "--diff-filter=AM", f"{base}...HEAD").splitlines():
        if raw.startswith("+++ "):
            path = raw[6:] if raw.startswith("+++ b/") else None
        elif raw.startswith("@@"):
            n = int(re.search(r"\+(\d+)", raw).group(1))
        elif raw.startswith("+") and path:
            out.append((path, n, raw[1:]))
            n += 1
    return out


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--check"
    files = tracked()
    if mode == "--all":
        total = 0
        for path in sorted(files):
            if SKIP.search(path):
                continue
            try:
                text = open(path, encoding="utf-8").read()
            except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
                continue
            total += sum(len(hits(line, files)) for line in text.splitlines())
        print(f"{total} citations of private material in the tree (the backlog; --check refuses new ones)")
        return 0
    base = os.environ.get("CHANGED_BASE") or "origin/main"
    bad = [(p, n, h) for p, n, text in added_lines(base) if not SKIP.search(p) for h in hits(text, files)]
    for p, n, h in bad:
        print(f"  {p}:{n}: {h}")
    if bad:
        print(f"{len(bad)} new citation(s) of private material since {base}. An outside reader cannot open "
              "them: say the point in a sentence, or cite something in this tree.")
        return 1
    print(f"no new citation of private material since {base}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
