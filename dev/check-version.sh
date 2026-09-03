#!/usr/bin/env bash
# Refuse a tree that still carries a version somebody already published.
#
# `percolate.control` said 0.1.1, the tag v0.1.1 existed, and the tree had
# moved well past it -- two parser fixes and a missing wrapper -- so "0.1.1"
# named two different pieces of software depending on where you got it. Every
# downstream check that compares versions was, correctly, satisfied. Nothing
# was lying; the number simply was not being moved.
#
# The rule is one line: a version that has a tag is SPENT. Either HEAD is that
# tag, or the number has to move before anything else is published under it.
#
#     dev/check-version.sh          # CI gate, and cheap enough to run by hand
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n "s/^default_version = '\(.*\)'/\1/p" extension/percolate/percolate.control)
[ -n "$VERSION" ] || { echo "no default_version in percolate.control" >&2; exit 2; }
TAG="v$VERSION"

if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "version $VERSION is unreleased (no tag $TAG) -- ok"
    exit 0
fi

# Compare the COMMIT, not the ref name: a tag can be moved, and being "on" a
# tag that was re-pointed after the release is the same problem in a costume.
if [ "$(git rev-parse HEAD)" = "$(git rev-parse "$TAG^{commit}")" ]; then
    echo "version $VERSION is released and HEAD is exactly $TAG -- ok"
    exit 0
fi

AHEAD=$(git rev-list --count "$TAG..HEAD" 2>/dev/null || echo "?")
cat >&2 <<MSG
error: this tree is version $VERSION, which was already published as $TAG,
       and HEAD is $AHEAD commit(s) past it.

  Whatever is built here would be a second, different $VERSION. Bump
  default_version in extension/percolate/percolate.control (and the parser's
  control file and Cargo.toml with it -- install.sh refuses a release whose
  two extensions disagree) before publishing.

  Changes since $TAG:
$(git log --oneline "$TAG..HEAD" 2>/dev/null | sed 's/^/    /' | head -15)
MSG
exit 1
