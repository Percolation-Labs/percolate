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
# WHAT "ANYTHING ELSE" MEANS, narrowed after this ran red for the wrong reason.
# It used to refuse ANY commit past the tag, and `.github/workflows/check.yml`
# runs it on every push and every PR -- so the moment a release tagged v<x> and
# one more commit landed, this job went red and STAYED red for the whole
# inter-release period, which is nearly all of the time. Only `release.yml`
# bumps, so there was nothing a contributor could do about it either. A gate
# that is red in the normal state is a gate people learn to scroll past, which
# is what `dev/githooks/pre-push` says about a hook with a known red in it.
#
# The defect it exists to catch is narrower than "HEAD moved": it is that
# "0.1.1" names two different pieces of software depending on where you got it.
# That is only true if what SHIPS has changed -- `extension/`, which is the
# control files, the compiled parser's source, and the generated script that a
# database actually runs. A doc commit past a tag makes nothing ambiguous.
#
# So: past the tag AND extension/ differs -> error, the number must move. Past
# the tag with extension/ identical -> fine, and say so rather than staying
# quiet, because "nothing shipped has changed since the release" is the fact
# the reader wants.
#
#     dev/check-version.sh          # CI gate, and cheap enough to run by hand
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n "s/^default_version = '\(.*\)'/\1/p" extension/percolate/percolate.control)
[ -n "$VERSION" ] || { echo "no default_version in percolate.control" >&2; exit 2; }
TAG="v$VERSION"

# ASK THE REMOTE, NOT ONLY THIS CHECKOUT'S TAGS. On 2026-09-18 v0.2.12 was tagged at
# 21:30Z; a branch pushed at 21:38Z from a checkout that had not fetched it passed
# this gate in the pre-push hook ("unreleased (no tag)"), merged 0.2.12-labelled SQL
# that differed from the tag, and CI -- which fetches every tag -- failed on main.
# The same lesson dev/references.sh §3 records: a gate whose answer depends on which
# refs a checkout holds disagrees between CI and a laptop. So fetch this one tag
# first. Offline, or with no such tag, the fetch fails and the local answer stands.
env -u GIT_DIR -u GIT_WORK_TREE git fetch -q --no-tags origin "refs/tags/$TAG:refs/tags/$TAG" 2>/dev/null || true

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

# What actually ships. Not the whole tree: a README past a tag makes no version
# ambiguous, and refusing it is what made this gate permanently red.
CHANGED=$(git diff --name-only "$TAG..HEAD" -- extension/ 2>/dev/null)
if [ -z "$CHANGED" ]; then
    echo "version $VERSION is released and HEAD is $AHEAD commit(s) past $TAG," \
         "but nothing under extension/ has changed -- ok"
    exit 0
fi

cat >&2 <<MSG
error: this tree is version $VERSION, which was already published as $TAG,
       and $(printf '%s\n' "$CHANGED" | wc -l | tr -d ' ') shipped file(s) have changed since
       ($AHEAD commit(s) past the tag).

  Whatever is built here would be a second, different $VERSION. Bump
  default_version in extension/percolate/percolate.control (and the parser's
  control file and Cargo.toml with it -- install.sh refuses a release whose
  two extensions disagree) before publishing. .github/scripts/bump_extension_version.py
  moves all five places at once.

  Shipped files changed since $TAG:
$(printf '%s\n' "$CHANGED" | sed 's/^/    /' | head -15)

  Changes since $TAG:
$(git log --oneline "$TAG..HEAD" 2>/dev/null | sed 's/^/    /' | head -15)
MSG
exit 1
# Fork-PR test for REM-1081: not for merge.
