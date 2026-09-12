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

# AND NO DOCUMENT MAY TELL A READER TO PULL A TAG THAT IS NOT THE LATEST
# PUBLISHED ONE. README.md's Deployment block showed four services on
# `percolationlabs/percolate-core:0.1.1` -- a version that was YANKED -- while
# 0.1.8 was on Docker Hub. Nothing here was asking: this file checked the number
# the tree is about to spend, and `check-releases.sh` audits the ones already
# spent, and neither looked at what the prose tells somebody to run. Copying
# somebody a compose block that pulls a yanked image is the most direct way this
# repository can waste a reader's afternoon.
#
# THE LATEST TAG, NOT $VERSION. They are the same only at a release. An
# unreleased tree is legitimately ahead of what anybody can pull -- the case the
# block above exists for -- and a README pinned to it would send readers to a
# `docker pull` that 404s. get-percolate's versions.toml splits exactly these
# two facts, `[published]` and `[requires]`, for the same reason.
#
# Written as a check rather than as a rule in CONTRIBUTING, because a rule
# cannot make anybody look. This one names the file and the line.
LATEST=$(git tag --list 'v*' | sed 's/^v//' \
         | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
if [ -n "$LATEST" ]; then
    # EXCLUDING THIS FILE, because the paragraph above quotes the pin it was
    # written for and a check that fails on its own explanation is a check
    # somebody deletes. Nothing else is excluded: a changelog entry naming an
    # old version does not name it as an image to pull.
    STALE=$(git grep -n -E 'percolationlabs/percolate-core:[0-9]+\.[0-9]+\.[0-9]+' \
            -- . ':!dev/check-version.sh' 2>/dev/null | grep -v ":$LATEST" || true)
    if [ -n "$STALE" ]; then
        printf '%s\n' "$STALE" | sed 's/^/    /' >&2
        cat >&2 <<MSG
error: the lines above pin a percolate-core image that is not $LATEST, the
       latest published version. A reader copies these.

  If one of them is deliberately historical, say so in the same line in words
  rather than in a number -- this check reads tags, not intent.
MSG
        exit 1
    fi
    echo "every percolate-core image pin in the tree is $LATEST -- ok"
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
