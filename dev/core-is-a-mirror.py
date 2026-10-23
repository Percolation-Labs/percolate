#!/usr/bin/env python3
"""core/ changes only by a mirror of a percolate-core release (REM-1153).

    dev/core-is-a-mirror.py --check            # refuse a commit on this branch that edits core/ by hand
    dev/core-is-a-mirror.py --check --base X   # against another ref

core/ is percolate-core's tree, copied in by the train's mirror leg as one
commit titled "core: mirror percolate-core <version>". The next mirror replaces
the whole directory, so an edit made here is erased with no error. That
happened on 23 Oct: REM-1123 added a confidence field to decide_judgement in
core/, the 0.2.10 mirror erased it five hours later, and production shipped
without it. CI and the train were green throughout.

So a commit between the base and HEAD that touches core/ must be a mirror
commit. Merge commits are skipped: they bring in main's commits, which are
graded when they land. The base is $CHANGED_BASE, else origin/main, as for
dev/generated-output.py.
"""
import argparse
import os
import subprocess
import sys

MIRROR = "core: mirror percolate-core "


def git(*args):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    return subprocess.run(["git", *args], capture_output=True, text=True, check=True, env=env).stdout


def offences(base):
    since = git("merge-base", base, "HEAD").strip()
    rows = git("log", "--no-merges", "--format=%h %s", f"{since}..HEAD", "--", "core").splitlines()
    return [r for r in rows if not r.split(" ", 1)[1].startswith(MIRROR)]


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--check", action="store_true")
    p.add_argument("--base", default=os.environ.get("CHANGED_BASE") or "origin/main",
                   help="what --check compares against ($CHANGED_BASE, else origin/main)")
    args = p.parse_args()
    if not args.check:
        p.error("pass --check")
    bad = offences(args.base)
    if bad:
        print("core/ is a mirror of percolate-core, and the next mirror erases an edit made here. These commits "
              "edit it by hand; port them to percolate-core first, then drop them from this branch:", file=sys.stderr)
        for row in bad:
            print(f"  {row}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
