#!/usr/bin/env bash
# The git merge driver for extension/percolate/sql/*.sql.
#
# REGISTER IT ONCE PER CLONE (git will not let a repository do this itself, for
# the same reason it will not arm a hook):
#
#     git config merge.percolate-sql.name  "regenerate the extension SQL"
#     git config merge.percolate-sql.driver "dev/merge-generated-sql.sh %A %O %B %P"
#
# WHAT IT IS FOR. extension/percolate/sql/ is generated from specs/ and tracked
# on purpose (.gitignore:22 has the reason; PACKAGING.md has the decision). The
# cost nobody wrote down is what a MERGE of it means: `check.yml` runs on
# pull_request, so CI tests the merge of a branch with main -- and the moment
# main takes anything touching specs/, the merge holds newer specs beside older
# generated SQL and `build-sql.py --check` fails. Correctly: they really do
# disagree. The only resolution is ever "merge main and run the generator".
#
# Measured in one session, on eight branches: three rounds of that, main having
# taken twelve merges in the window. Every round is merge, regenerate, resolve
# N conflicts in files nobody reads, commit, push, wait. And in round three one
# branch had a GENUINE conflict in surface.sql sitting inside eight mechanical
# ones -- which is the real cost, because an author who has learned that
# conflicts here are mechanical stops reading them.
#
# WHAT IT DOES. Nothing clever: the merged tree already has both sides' specs/
# resolved by the time a file-level driver runs, so the correct content of the
# generated file is whatever the generator produces from them. It runs
# build-sql.py and takes the result. There is no textual merge to get wrong.
#
# IT DEGRADES HONESTLY, and that was measured rather than assumed: with neither
# config key set, git falls back to its default merge -- today's conflicts,
# resolved by hand, exit 1 -- and never a silent wrong merge. With the driver
# registered, the same reproduction goes from 8 conflicts to 1, the 1 being the
# genuine conflict in the spec file that a person has to read. Numbers and the
# one trap (`.name` without `.driver` is fatal, not a fallback) are in
# .gitattributes beside the attribute.
#
# And if the generator fails here for any reason, this exits non-zero, which
# git reports as an unresolved conflict: the author is told, rather than handed
# a file that looks merged.
#
# IT DOES NOT PAPER OVER DRIFT. `build-sql.py --check` still compares the
# committed artifact against specs/ in the tree. This makes them agree after a
# merge by regenerating, which is the only state in which they should agree.
#
# AND IT ONLY FIRES ON A CONFLICT, which is the honest limit of the approach and
# was found by using it. A merge driver is invoked for a path git could not
# resolve by itself; when the generated files merge CLEANLY -- both sides
# touched different regions -- the driver never runs, and the textually-merged
# artifact can still disagree with the merged specs. `build-sql.py --check`
# catches it, correctly, and the author still regenerates by hand.
#
# Measured on this branch: merging an origin/main that had moved produced exit
# 0 and zero conflicts, and then the tree gate went red on `The generated SQL
# matches the specs it came from`. So this removes the hand-resolution of
# conflicts and does not remove the regenerate-after-merge step.
#
# AND `--check` IS NOT THE WHOLE OF THAT STEP EITHER, which is the larger
# version of the same caveat and is not mine: run `dev/upgrade-converges.sh`
# after merging too. `--check`, `--tree`, the workflow suite and `surface.sql`
# all ask their question of ONE database, so a clean merge of two schema
# changes can leave every one of them green and still diverge on upgrade.
# Measured by p8-subsystems-75 on REM-109: `create table if not exists
# workflow.queue_config` is a no-op on an existing database, so a new column
# default reached fresh installs only -- a fifth copy of a number, created by
# the commit that deleted the other four, and invisible to all four green
# checks. That is still
# the larger half of the cost gone -- resolving eight files is the part nobody
# can do usefully; running one command is the part anybody can -- but the
# ticket's framing of "merge without hand-resolving" is only true of the
# conflict case, and a `post-merge` hook would be the shape that closes the
# rest.
set -euo pipefail

CURRENT="$1"   # %A -- our version, and the file git expects the result in
: "${2:-}"     # %O -- the ancestor, unused: the answer is not in it
: "${3:-}"     # %B -- their version, likewise
TARGET="${4:-the generated SQL}"  # %P -- the real pathname

cd "$(dirname "$0")/.."

# The interpreter question has one home (REM-92/#82), and a merge driver runs in
# whatever environment the merge did -- often not a login shell.
. "$PWD/dev/lib/python.sh"
PY="$(percolate_python)" || {
    echo "merge-generated-sql: no interpreter that can import yaml; leaving $TARGET conflicted" >&2
    exit 1
}

"$PY" extension/percolate/build-sql.py >/dev/null 2>&1 || {
    echo "merge-generated-sql: build-sql.py failed; leaving $TARGET conflicted" >&2
    exit 1
}

# The generator writes every file under extension/percolate/sql/ in place. Git
# asked for the result of ONE of them, in $CURRENT -- which for a driver is a
# temporary file, not the worktree path -- so copy the freshly generated one
# over it. %P is the path relative to the repository root.
if [ -f "$TARGET" ]; then
    cp "$TARGET" "$CURRENT"
else
    echo "merge-generated-sql: the generator did not write $TARGET" >&2
    exit 1
fi
