# IS THE COMPILED HALF BEHIND THE SCHEMA? One home, four call sites.
#
# The extension SQL and percolate_parser.so ship as separate files and drift
# apart independently, so between a parser change and the next image every
# compiled assertion fails for a reason that is not this commit's. PACKAGING
# §"One version, two files, and the window between them" is the argument; this
# file is the question that window turns on, asked once.
#
# TWO WAYS TO BE BEHIND, and until REM-139 only the first was ever asked:
#
#   1  A DIFFERENT RELEASE.  percolate_parser 0.1.6 under a percolate 0.2.0
#      schema. pg_extension can see this, and the four call sites below all
#      asked exactly this and nothing else.
#
#   2  A DIFFERENT COMMIT OF THE SAME RELEASE.  A parser change does not bump
#      percolate_parser's version, so a .so compiled yesterday and one compiled
#      this morning both answer 0.2.0. pg_extension cannot see this, and it is
#      the state dev/reload.sh is in every day of an unreleased version.
#
# WHAT (2) COST, because this guard exists on an incident and not a risk --
# our bar for a new check. dev/tests/query/11-graph-algorithms.sql's
# own header records three sessions in one day reading `without as_of the
# expired edge was still traversed` as a defect in the graph (0b7af9f), and it
# happened a fourth time on 2026-09-12: the .so in p8-dev-db was dated
# 2026-09-11T12:00:20Z and `2d54769`, which fixed that very traversal, landed
# ten hours after it. Both halves said 0.2.0, so every deferral in query/15 was
# refused as illegal by the anti-mute guards -- working exactly as designed --
# and query/11 and query/15 reported "a guarantee the specs make is no longer
# held" on a database built from origin/main minutes earlier.
#
# THE REMEDY THOSE THREE SESSIONS CHOSE IS THE PART WORTH READING TWICE. They
# added `-- requires-parser: 0.2.0` to query/11, and parser_at_least 0.2.0 is
# satisfied by a 0.2.0 .so compiled from any commit. The fix was written in the
# shape of the defect: a version test deployed to catch what a version test
# cannot see. That is why this is a file rather than a fifth copy.
#
# CI COULD NOT HAVE FOUND IT, which is why it survived a day. check.yml's
# `parser` job compiles the crate and `database` needs it, so there the
# artifact matches the source by construction -- the one place that compiles
# fresh is the one place that needs no staleness guard. CI green, every
# reload.sh database red, and CI's greenness is what licensed reading the local
# red as a spec defect.
#
# WHAT THIS ASKS INSTEAD: the artifact's own date against its source's. The
# .so's mtime in the container, and the newest commit touching
# extension/percolate_parser/ in the tree under test. Neither is a label.
#
# AN MTIME IS EVIDENCE AND NOT A PROMISE -- a COPY can reset it and a touch can
# lie -- and it says the artifact is older than its source, never what changed
# in it. dev/currency.sh diffs SQL bodies out of pg_proc; a LANGUAGE c body is
# in the .so and pg_proc holds only a symbol name, so the compiled half has no
# equivalent of that check. What an mtime does have is the property the version
# string provably lacks: it MOVES when the artifact is rebuilt. Closing the
# rest needs provenance on the artifact -- a sidecar beside the .so, or an
# image label -- and not public.percolate_build, which dev/build-image.sh
# writes into a database that dev/reload.sh then drops.
#
# UNKNOWN IS NEITHER CURRENT NOR BEHIND. A DSN run cannot stat the .so and a
# shallow clone has no commit for the path. Both leave the verdict `unknown`,
# and every caller treats that as "fall back to the version comparison" rather
# than inventing a verdict -- which is what stops this turning a real red green
# anywhere the evidence is missing.
#
# Reads CONTAINER and DSN from the caller's environment, as its callers already
# define them. Sets three variables and memoises, because a suite asks per file.

# An epoch as something a person can compare to a commit date. Two spellings
# because `-r` is BSD and `-d @` is GNU, and this runs on both.
parser_iso_utc() {
    [ -n "${1:-}" ] || { echo "an unknown date"; return 0; }
    date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || echo "epoch $1"
}

PARSER_DRIFT=          # unset, then `yes`, `no` or `unknown`
PARSER_SO_AT=
PARSER_SRC_AT=

parser_artifact_behind_source() {
    if [ -z "$PARSER_DRIFT" ]; then
        PARSER_DRIFT=unknown
        # THE TREE UNDER TEST, not the tree this file sits in -- they are the
        # same today, and the distinction is what lets a worktree measure itself.
        _pc_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
        PARSER_SRC_AT=$(git -C "$_pc_root" log -1 --format=%ct \
                            -- extension/percolate_parser/ 2>/dev/null || true)
        # Only the container path can stat the file the server actually loaded.
        if [ -z "${DSN:-}" ] && [ -n "${CONTAINER:-}" ]; then
            PARSER_SO_AT=$(docker exec "${CONTAINER}" sh -c \
                'stat -c %Y "$(pg_config --pkglibdir)/percolate_parser.so"' 2>/dev/null || true)
        fi
        case "${PARSER_SO_AT:-x}${PARSER_SRC_AT:-x}" in
            *[!0-9]*) ;;   # either missing, or not a number: stays unknown
            *) if [ "$PARSER_SRC_AT" -gt "$PARSER_SO_AT" ]
                   then PARSER_DRIFT=yes
                   else PARSER_DRIFT=no
               fi ;;
        esac
    fi
    [ "$PARSER_DRIFT" = yes ]
}

# The sentence every caller prints, so the four do not word it four ways.
parser_drift_note() {
    echo "both halves report the same version, and the .so ($(parser_iso_utc "$PARSER_SO_AT"))"
    echo "is older than the newest commit in extension/percolate_parser/"
    echo "($(parser_iso_utc "$PARSER_SRC_AT")), so the version cannot show the lag."
}

# THE CALL SITES, named because a rule with one home and four readers is only
# one rule while every reader is listed:
#
#   dev/tests/run.sh   parser_behind()            -- is any deferral legal
#                      the `-- requires-parser:`  -- stand a whole file down
#                      run_sql()                  -- carry the verdict into SQL
#                                                    as percolate.parser_behind
#   dev/check.sh       db_deferrals_gone()        -- the anti-mute gate: the
#                                                    halves agree and something
#                                                    still deferred
#
# THE FOURTH IS WHY THIS FILE EXISTS. Three were fixed in run.sh and the fourth
# was missed, and `dev/check.sh`'s gate caught the change on its own first full
# run -- "percolate and percolate_parser are both 0.2.0 -- they agree -- and the
# suite still deferred." It was right to: it guards run 34685340252, where a
# PARSER_DIST install reported landing a 0.2.0 .so, left pg_extension at 0.1.6,
# deferred every compiled assertion and passed without them. A gate that refuses
# a green that checked nothing has to keep refusing it; what it needed was
# the same two measures, not a weaker condition.
