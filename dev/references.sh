#!/usr/bin/env bash
# Does every version and path this repository NAMES for the extension resolve?
#
#   ./dev/references.sh
#
# A different question from surface.sql (does a declared capability exist in
# the database) and currency.sh (is it current): whether a filename or a
# version one file writes down is the one another file ships.
#
# MOVED FROM THE PRIVATE TREE (REM-1080). This repository's check.sh said
# check-references.py "is section 5 of dev/references.sh now", and that file
# was left behind at the cut, so nothing here ran it, and nothing asked whether
# the two control files agree. The sections about the private tree's k8s
# manifests, core image pins and sibling-repo symlinks stayed there; these are
# the three that are about the extension alone.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
cd "$REPO"
. dev/lib/python.sh
PY="${PY:-$(percolate_python)}" || exit 2

VERSION=$(sed -n "s/^default_version = '\(.*\)'/\1/p" extension/percolate/percolate.control)
[ -n "$VERSION" ] || { echo "no default_version in percolate.control" >&2; exit 1; }
echo "extension version: $VERSION"

fail=0
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=1; }
ok()  { printf '  \033[32mok\033[0m    %s\n' "$*"; }

# 1. Both extensions carry the one number. The 0.2.10 and 0.2.11 releases both
# failed at get-percolate's manifest check ("missing release asset:
# percolate_parser--<v>.sql") because percolate.control was bumped by hand and
# percolate_parser.control was not.
PARSER_VERSION=$(sed -n "s/^default_version = '\(.*\)'/\1/p" extension/percolate_parser/percolate_parser.control)
if [ "$PARSER_VERSION" = "$VERSION" ]; then
    ok "both extensions are $VERSION"
else
    bad "percolate.control says $VERSION and percolate_parser.control says $PARSER_VERSION: move both with .github/scripts/bump_extension_version.py, never by hand"
fi

# 2. Every reference used as a PATH into the extension's sql directory
# resolves. A release renames the script (default_version is its filename), so
# a consumer still asking for the old name dies on a missing file, later.
# Only references used as paths: a bare `percolate--0.1.0.sql` in prose is
# usually history.
missing=0
while IFS=: read -r file _ match; do
    path="extension/percolate/sql/$(basename "$match")"
    if [ ! -f "$path" ]; then
        bad "$file names $path, which does not exist"
        missing=1
    fi
done < <(git grep -n -o -E 'extension/percolate/sql/percolate--[0-9]+\.[0-9]+\.[0-9]+\.sql' -- . || true)
[ "$missing" = 0 ] && ok "every extension/percolate/sql/... path resolves"

# 3. Every function shipped code tells somebody to call exists: a remedy
# printed in an error message is never executed, so nothing else checks it.
if out=$("$PY" extension/percolate/check-references.py 2>&1); then
    ok "$(printf '%s\n' "$out" | tail -1)"
else
    printf '%s\n' "$out" | sed 's/^/        /'
    bad "a function named in shipped code does not exist (extension/percolate/check-references.py)"
fi

[ "$fail" = 0 ] && echo "references: consistent" || echo "references: INCONSISTENT"
exit "$fail"
