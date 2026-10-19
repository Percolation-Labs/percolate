#!/usr/bin/env bash
# Refuse a test file that CI does not run and does not say why.
#
# ci.yml names every test file it runs, one step each, because the step's name
# and comment are the only record of what guarantee the file protects. The cost
# of that is that a file nobody adds to the list is a file nobody runs, and
# nothing noticed: eleven of thirty-nine were named nowhere, including the
# tests REM-62 (the suggestion contract) and REM-69 (one config) were closed on.
# Six of those eleven failed with no node on the PATH -- a skip or an error,
# either way a green job would never have said so.
#
# So the list stays, and this makes it complete. Every tests/test_*.py is either
# named on a non-comment line of ci.yml, or declared on a line of the form
#
#     # not run here: test_x.py -- the reason, naming what stops it
#
# and not both. A name in either place that is not a file is refused as well,
# so a renamed test cannot leave a step running nothing.
#
#     dev/check-tests-run.sh [path/to/ci.yml]
set -euo pipefail
cd "$(dirname "$0")/.."

WF=${1:-.github/workflows/ci.yml}
[ -f "$WF" ] || { echo "no workflow at $WF" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

(cd tests && ls test_*.py) | sort -u >"$tmp/files"
# Comments mention test files in prose ("test_api_probe.py rides along"), and a
# mention is not a run, so only non-comment lines count.
grep -v '^[[:space:]]*#' "$WF" | grep -o 'test_[A-Za-z0-9_]*\.py' | sort -u >"$tmp/run" || true
# The reason is required: a marker with nothing after `--` excludes nothing.
sed -n 's/^[[:space:]]*# not run here: \(test_[A-Za-z0-9_]*\.py\) -- [^[:space:]].*$/\1/p' "$WF" \
    | sort -u >"$tmp/excluded"

fail=0
while read -r t; do
    echo "::error file=tests/$t::tests/$t is run by no step in $WF. Add a step, or declare it: # not run here: $t -- <reason>"
    fail=1
done < <(sort -u "$tmp/run" "$tmp/excluded" | comm -13 - "$tmp/files")

while read -r t; do
    echo "::error file=$WF::$WF names $t, and tests/$t does not exist."
    fail=1
done < <(sort -u "$tmp/run" "$tmp/excluded" | comm -23 - "$tmp/files")

while read -r t; do
    echo "::error file=$WF::$t is both run and declared not run in $WF. Delete its '# not run here' line."
    fail=1
done < <(comm -12 "$tmp/run" "$tmp/excluded")

[ "$fail" -eq 0 ] || exit 1
echo "$(wc -l <"$tmp/files" | tr -d ' ') test files: $(wc -l <"$tmp/run" | tr -d ' ') run, $(wc -l <"$tmp/excluded" | tr -d ' ') declared not run"
