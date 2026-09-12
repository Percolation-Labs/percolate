# THE ONE ANSWER TO "WHICH CONTAINER DOES A DESTRUCTIVE DEV COMMAND TARGET",
# sourced by every script that drops or recreates a database (REM-131).
#
# It is a file rather than three lines in reload.sh for the reason
# dev/lib/python.sh is a file: the question has more than one asker, and a
# predicate copied to the second asker is how the two stop agreeing. Today the
# askers are reload.sh (guarded) and check.sh --reload (not yet -- see the note
# at the bottom, which is the sibling this file exists to make a one-liner).
#
# WHAT WENT WRONG. `CONTAINER=${CONTAINER:-p8-dev-db}` followed by a line
# ANNOUNCING the target is not the same as asking about it. Six sessions share
# this Docker daemon; measured 2026-09-12, ten running percolate-postgres
# containers, and a 15 MB database was created inside `p8-dev-db` by a session
# that did not own it, noticed only by reading the log line afterwards.

# Names of every running percolate-postgres container, one per line, sorted.
#
# WHY NOT `docker ps --filter ancestor=percolationlabs/percolate-postgres`,
# which is the obvious way to write this: it returns ZERO. Tagged variants are
# separate ancestors and the bare repository name matches none of them --
# measured on a daemon running :19, :19-0.1.6 and :19-showcase, where the
# filter found 0 and the match below found 10. A guard written the obvious way
# would have existed, reported nothing, and passed every bare call through:
# meta/postmortems/README.md's "a check that cannot distinguish pass from fail",
# which that file calls its largest recurring class by a distance.
percolate_containers() {
    docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null \
        | awk -F'\t' '$2 ~ /percolate-postgres/ {print $1}' | sort
}

# Refuse a destructive command whose target was not named, unless the running
# set is EXACTLY the default. Callers pass the default name and the command
# line to suggest. Returns 0 to proceed; exits 2 itself when it refuses,
# because every caller so far wants to stop.
#
# EXACTLY, not "more than one". A count-based test proceeds when the single
# running container is somebody else's under a different name, and then fails
# three lines later with a message about the wrong container rather than about
# the ambiguity. Asked as a set, that case refuses for the right reason.
#
# The one-stack machine keeps working with no new ceremony, which is a
# requirement rather than a nicety: the documented invocations are all bare --
# dev/tests/journeys/README.md says `dev/reload.sh p8journey`,
# dev/tests/content/e2e-lake.py says `dev/reload.sh scratch_lake`,
# dev/contract-export.py prints `dev/reload.sh <db>`. A guard that refused
# whenever the default was not provably this session's would break all three on
# a clean checkout, which is worse than the defect it closes.
require_named_container() {
    default=$1; suggest=$2
    running=$(percolate_containers)
    [ "$running" = "$default" ] && return 0
    {
        echo "${suggest%% *}: CONTAINER is unset and the target is ambiguous."
        echo "This drops and recreates a database. Name the container:"
        echo
        echo "    CONTAINER=<name> $suggest"
        echo
        if [ -z "$running" ]; then
            echo "No percolate-postgres container is running. Start one:"
            echo "    dev/stacks.sh up dev"
        else
            echo "Running percolate-postgres containers:"
            printf '    %s\n' $running
        fi
    } >&2
    exit 2
}

# THE SIBLING, NAMED RATHER THAN FIXED HERE. `dev/check.sh:66` is
# `CONTAINER="${CONTAINER:-p8-dev-db}"` and then exports it, so `check.sh
# --reload` with no CONTAINER drops and recreates p8-dev-db exactly as the
# direct call used to -- and reload.sh's guard cannot see it, because by then
# CONTAINER is set. REM-131 scoped check.sh out on the grounds that it "already
# does the right thing"; it does the same thing one layer up, and exporting is
# what hides it.
#
# Not changed in that commit because check.sh's default is load-bearing for
# every other gate and the decision belongs with whoever owns the runner. The
# adoption is one line after `--reload` is parsed:
#
#     [ "$RELOAD" = 1 ] && [ -z "${CONTAINER:-}" ] \
#         && require_named_container p8-dev-db "dev/check.sh --reload"
#
# Recorded here rather than in a comment in check.sh so that the fix and the
# predicate live together, which is the whole argument for this file.
#
# AND THE SECOND HARM, WHICH IS WORSE THAN A DATABASE IN THE WRONG PLACE: a
# GATE reading the wrong one. Measured by p8-subsystems-ae on 2026-09-12 --
# `dev/tests/query/11-graph-algorithms.sql` and `15-edge-currency.sql` fail
# against the shared `p8dev` and pass against a database built fresh from
# `origin/main` (11 defers on parser 0.1.5, 15 passes). A day of six sessions
# reloading into one instance drifted it, and `check.sh` unset points there.
#
# So an unnamed container does not only misplace a write -- it makes the full
# gate go red about the machine, which is how a run stops being believed. The
# remedy that session reached for was `CONTAINER=<their own> dev/check.sh`
# rather than `--no-verify`, which is this predicate arrived at from the other
# end. Somebody should rebuild `p8dev`; nobody has, because rebuilding a shared
# database under five sessions is the defect rather than the fix.
#
# AND THE HOOK READS IT TOO, IN THE ONE TREE ANYBODY PUSHES FROM. `#88` changed
# `dev/githooks/pre-push` to `exec "$HERE/check.sh" --tree` -- no database at
# all -- and that is what `origin/main` carries. But `core.hooksPath` is a path
# into the WORKING TREE, and the shared checkout at
# `/Users/sirsh/code/p8-subsystems` is 121 commits behind with `8aa1a85` absent
# from its history, so its working copy still says `--reload`. Measured:
#
#     tail -1 dev/githooks/pre-push          -> exec "$HERE/check.sh" --reload
#     git show origin/main:...  | tail -1    -> exec "$HERE/check.sh" --tree
#     git merge-base --is-ancestor 8aa1a85 HEAD -> false
#
# Corroborated by the gate count in that session's push output: 22, not ten.
# `--tree` cannot produce 22, and "Every guarantee the specs make still holds"
# is a database gate.
#
# So **a push from the shared checkout still rebuilds `p8dev`** -- the fix for
# that shipped this afternoon and has not reached the only tree where the harm
# occurs, and cannot, because nothing pulls it. Eleven worktrees carry the fix;
# the twelfth tree, the one everybody pushes from by habit, carries the version
# it replaced. That makes this file's argument concrete twice over: the default
# container, and the hook that reads it, are both stale there.
