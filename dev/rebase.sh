#!/usr/bin/env bash
# Rebase the current branch onto <upstream>, regenerating the extension SQL at
# every commit, so the rebase runs to the end and each commit's generated SQL
# matches its own specs (REM-992).
#
#     dev/rebase.sh origin/main
#
# WHY NOT THE MERGE DRIVER. merge=percolate-sql runs build-sql.py from the
# worktree, but a rebase pick is merged in memory (merge-ort) before anything is
# checked out, so the worktree still holds the previous commit's specs: the
# driver generates from the wrong specs, and it rewrites every generated file,
# so the next pick refuses with "Your local changes ... would be overwritten".
# Here the driver is switched off for the rebase (driver=true keeps our side
# and reports no conflict), and --exec regenerates and amends after each pick,
# from that pick's own specs. A real conflict in a spec still stops the rebase,
# where a person has to read it.
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: dev/rebase.sh <upstream> [rebase args...]" >&2; exit 2; }
cd "$(dirname "$0")/.."
. "$PWD/dev/lib/python.sh"
PY="$(percolate_python)" || exit 2
exec git -c merge.percolate-sql.driver=true rebase "$@" --exec \
    "'$PY' extension/percolate/build-sql.py >/dev/null && git add -A extension/percolate/sql && { git diff --cached --quiet || git commit -q --amend --no-edit --no-verify; }"
