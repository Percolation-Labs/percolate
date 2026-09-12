#!/usr/bin/env bash
# Refuse a tree where RELEASES.md does not account for every tag.
#
# A tag is the only durable record of what shipped, and one of them is wrong:
# v0.1.8 points at a tree that says 0.1.7, because the `tag` job took
# `github.sha` rather than the commit that was built. That went unnoticed for
# six days because nothing reads a tag until somebody tries to reproduce a
# release, and there was nowhere a reader could have seen it stated.
#
# release.yml now refuses to tag a tree whose version disagrees, so the defect
# cannot recur. This is the other half: the table stays true, so the next
# reader can trust it rather than re-measuring the tags themselves.
#
#     dev/check-releases.sh
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f RELEASES.md ] || { echo "error: RELEASES.md is missing." >&2; exit 1; }

# Needs the tags. A shallow clone without them passes vacuously, which is the
# failure this script exists to avoid, so say so instead.
if [ -z "$(git tag -l 'v*')" ]; then
    echo "error: no v* tags in this clone -- fetch them (fetch-depth: 0," >&2
    echo "       fetch-tags: true) before running this check." >&2
    exit 2
fi

missing=0
for tag in $(git tag -l 'v*' | sort -V); do
    if ! grep -q "\`$tag\`" RELEASES.md; then
        echo "error: $tag is published and RELEASES.md does not mention it." >&2
        missing=1
    fi
done

# And the other direction: a row naming a commit that is not what the tag
# points at is worse than no row, because it looks checked. v0.1.8 is the
# deliberate exception -- its row states the mismatch rather than hiding it --
# so it is verified by the words, not by the arrow.
for tag in $(git tag -l 'v*' | sort -V); do
    grep -q "\`$tag\`" RELEASES.md || continue
    sha=$(git rev-parse --short "$tag^{commit}")
    tree_version=$(git show "$tag:pyproject.toml" \
        | sed -n 's/^version *= *"\(.*\)"/\1/p' | head -1)
    if [ "v$tree_version" = "$tag" ]; then
        # Self-consistent: the row must name the commit the tag points at.
        if ! grep -q "\`$sha\`" RELEASES.md; then
            echo "error: $tag points at $sha and RELEASES.md does not name it." >&2
            missing=1
        fi
    else
        # Off by one: the row must say so, in the section that explains it.
        if ! grep -q "$tag\` is off by one" RELEASES.md; then
            echo "error: $tag points at $sha, whose tree says $tree_version." >&2
            echo "       RELEASES.md must record that rather than list it as clean." >&2
            missing=1
        fi
    fi
done

[ "$missing" = 0 ] || exit 1
echo "RELEASES.md accounts for every tag ($(git tag -l 'v*' | wc -l | tr -d ' ')) -- ok"
