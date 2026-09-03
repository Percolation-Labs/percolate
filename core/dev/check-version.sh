#!/usr/bin/env bash
# Refuse a tree that still carries a version somebody already published.
#
# pyproject said 0.1.6, PyPI had 0.1.6, and they were different software: main
# carried `percolate auth` and `percolate sample`, which the published wheel
# and the published image did not have. Three documentation pages told readers
# to run `percolate sample load` as their first step after install, and no
# shipped artifact could. Nothing was broken -- the number simply had not moved
# since the release that spent it.
#
# The rule is one line: a version that has a tag is SPENT.
#
#     dev/check-version.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' pyproject.toml | head -1)
[ -n "$VERSION" ] || { echo "no version in pyproject.toml" >&2; exit 2; }
# The number lives in pyproject and is MIRRORED into the package, because
# `percolate version`, the Content Server's FastAPI title and the agent API all
# read `percolate_core.__version__` rather than package metadata. A bump that
# moves only one of them ships a build that misreports itself -- which happened:
# pyproject went to 0.1.7 while __init__ stayed at 0.1.6, so every service would
# have announced the version it was not.
MIRROR=$(sed -n 's/^__version__ = "\(.*\)"/\1/p' percolate_core/__init__.py | head -1)
if [ "$MIRROR" != "$VERSION" ]; then
    echo "error: pyproject.toml says $VERSION, percolate_core/__init__.py says ${MIRROR:-nothing}." >&2
    echo "       Both move together -- the package attribute is what the running" >&2
    echo "       services report, not the metadata." >&2
    exit 1
fi

TAG="v$VERSION"

if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "version $VERSION is unreleased (no tag $TAG) -- ok"
    exit 0
fi

if [ "$(git rev-parse HEAD)" = "$(git rev-parse "$TAG^{commit}")" ]; then
    echo "version $VERSION is released and HEAD is exactly $TAG -- ok"
    exit 0
fi

AHEAD=$(git rev-list --count "$TAG..HEAD" 2>/dev/null || echo "?")
cat >&2 <<MSG
error: this tree is version $VERSION, which was already published as $TAG,
       and HEAD is $AHEAD commit(s) past it.

  A wheel built here would be a second, different $VERSION. Bump the version in
  pyproject.toml before publishing.

  Changes since $TAG:
$(git log --oneline "$TAG..HEAD" 2>/dev/null | sed 's/^/    /' | head -15)
MSG
exit 1
