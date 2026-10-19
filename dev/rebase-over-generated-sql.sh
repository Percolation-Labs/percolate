#!/usr/bin/env bash
# A rebase of a spec branch over a moved main runs to the end, and every commit
# it leaves has generated SQL that matches its own specs (REM-992).
#
# In a scratch clone of this tree, with the merge driver registered:
#
#   base -- main:   appends a comment to the END of workflow-engine/schema.sql
#        \- branch: two commits, each prepending a comment to the START of
#                   user-rbac/schema.sql, the spec build-sql.py concatenates
#                   right after it
#
# The two changes land on adjacent lines of percolate--<v>.sql and of every
# upgrade script, so each pick conflicts in dozens of generated files and in no
# spec. A plain `git rebase` with the driver registered stops at the second pick
# with "Your local changes ... would be overwritten"; dev/rebase.sh runs to the
# end. PLAIN=1 runs the plain rebase, to watch this fail.
#
#     dev/rebase-over-generated-sql.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
. "$ROOT/dev/lib/python.sh"
PY="$(percolate_python)" || exit 2
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAILED: $*"; exit 1; }

# Unset, because a pre-push hook exports GIT_DIR, and it beats -C and cwd.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
git clone -q --no-hardlinks "$ROOT" "$WORK/r"
cd "$WORK/r"
# The tree under test, not HEAD's: the script, the driver and the generator as
# they are now.
cp "$ROOT/dev/rebase.sh" "$ROOT/dev/merge-generated-sql.sh" dev/
cp "$ROOT/extension/percolate/build-sql.py" extension/percolate/build-sql.py
git add -A dev extension/percolate/build-sql.py
git -c user.name=t -c user.email=t@t commit -qm base --allow-empty
git config user.name t; git config user.email t@t
git config merge.percolate-sql.name "regenerate the extension SQL"
git config merge.percolate-sql.driver "dev/merge-generated-sql.sh %A %O %B %P"
gen() { PY="$PY" "$PY" extension/percolate/build-sql.py >/dev/null; git add -A extension/percolate/sql; }

git switch -qc moved
echo "-- main moved" >> specs/workflow-engine/schema.sql
gen; git commit -qam "main moves"

git switch -q -
git switch -qc spec-branch
for n in 1 2; do
    { echo "-- branch commit $n"; cat specs/user-rbac/schema.sql; } > "$WORK/s"
    mv "$WORK/s" specs/user-rbac/schema.sql
    gen; git commit -qam "branch commit $n"
done

if [ -n "${PLAIN:-}" ]; then cmd=(git rebase moved); else cmd=(dev/rebase.sh moved); fi
out=$("${cmd[@]}" 2>&1) || { echo "$out" | grep -v "^hint" | head -20; fail "the rebase stopped"; }
[ -z "$(git status --porcelain)" ] || { git status --short | head; fail "the rebase left the tree dirty"; }
for c in $(git rev-list --reverse moved..HEAD); do
    git checkout -q "$c"
    "$PY" extension/percolate/build-sql.py --check >/dev/null 2>&1 \
        || fail "commit $(git log -1 --format='%h %s' "$c"): its generated SQL does not match its specs"
done
echo "ok    a two-commit spec branch rebased over a moved main, and build-sql --check passes at each commit"
