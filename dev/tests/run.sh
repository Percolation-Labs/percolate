#!/usr/bin/env bash
# Run every test in the three surfaces, in order, against a live database.
#
#   ./run.sh                          # against the compose stack
#   DB=p8reload ./run.sh              # against what dev/reload.sh just built
#   DSN="postgres://…" ./run.sh       # against anything else
#   ./run.sh query                    # one surface
#   REQUIRE_ALL=1 ./run.sh            # and refuse to skip anything (CI)
#
# A FILE MAY DECLARE WHAT IT NEEDS, with `-- requires: <extension>` on its
# first lines, and is SKIPPED where that extension is absent. Exactly one file
# uses it -- `workflow/03-cron-tick.sql` needs pg_cron, whose worker is bound
# to one database by `cron.database_name`, so it cannot pass against the
# scratch database `dev/reload.sh` builds.
#
# That made the two commands this file's header, `suite.yml`'s "if billing runs
# out" fallback and `githooks/pre-push` all name into a run that ALWAYS ends
# red, and the hook had grown a grep to filter the known failure back out --
# which is a hook with a known red in it wearing a disguise. A skip that says
# so is honest; a suite that cannot go green is not.
#
# `REQUIRE_ALL=1` turns a skip back into a failure, and CI sets it. That is the
# half that keeps this from becoming the "green because it looked nowhere"
# failure the rest of this collection keeps finding: locally the file is
# skipped and named, in CI it must run.
#
# DB exists because the two halves of the inner loop did not compose. reload.sh
# builds `p8reload` by default and this file only ever asked `p8experiment`, so
# testing the edit you just made meant either reloading over the stack's own
# database or having psql on the host for DSN -- and the container has one.
#
# Runs EVERY file and exits nonzero at the end if any failed, so it works as a
# CI gate alongside ../../surface.sql. It does not stop at the first failure,
# and that is the useful behaviour rather than a compromise: one broken
# guarantee usually breaks several, and a run that stops at the first tells you
# how many surfaces are red only after you have fixed one and run it again.
# (This header used to say "exits nonzero on the first failure", which is what
# the code did before the loop learned to carry `failed` to the end.)
#
# The two are complementary and neither replaces the other:
# surface.sql asks "does every promised capability EXIST"; this asks "does it
# still BEHAVE the way the spec promised".
set -euo pipefail

CONTAINER="${CONTAINER:-p8-experiment-pg19}"
DB="${DB:-p8experiment}"
DSN="${DSN:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The order is deliberate: RBAC first, because if row-level security is not
# actually on, every later assertion about who-sees-what is meaningless.
# `content` follows the two it depends on -- it writes the corpus `query`
# reads and starts the runs `workflow` executes -- and `agentic` runs last: it
# binds the others rather than adding a concern of its own, so a failure there
# is worth reading only once they are green.
SURFACES=("${@:-rbac query workflow content agentic}")

# DSN is the ONE path that needs a psql on the host; the other two borrow the
# container's. Checked once, here, because the alternative is what it did
# before: `psql: command not found` printed once per file, thirteen identical
# lines that look like thirteen broken tests and say nothing about the fix. The
# message names DB= rather than telling anyone to install anything, because on
# a machine without psql that is the answer and it is two lines up in this
# file's own header.
if [ -n "$DSN" ] && ! command -v psql >/dev/null 2>&1; then
    echo "DSN is set but there is no psql on this host." >&2
    echo "  Use the container's instead:  DB=<database> $0 ${*:-}" >&2
    echo "  ...or install one:            brew install libpq && brew link --force libpq" >&2
    exit 1
fi

run_sql() {
    if [ -n "$DSN" ]; then
        psql "$DSN" -v ON_ERROR_STOP=1 -q -f "$1"
    else
        docker exec -i "$CONTAINER" psql -U p8 -d "$DB" -v ON_ERROR_STOP=1 -q < "$1"
    fi
}

# WHAT IS UNDER TEST, before anything is asserted about it.
#
# This banner exists because a run of this suite once failed on two parser bugs
# that were already fixed in the tree: the .so under it had been compiled
# before the fix and silently reused. Every minute spent after that was spent
# reading correct source looking for a defect. A failure now opens with the
# commit the artifact was built from, so the first question -- "is this a bug
# or an old binary" -- is answered before the first assertion runs.
#
# Tolerant of a database that predates the provenance table: an older build
# reports nothing rather than making this script fail on a banner.
banner() {
    local sql="select string_agg(component || ' ' || version || ' @ ' ||
                    coalesce(commit_sha,'?') || ' (' ||
                    coalesce(built_at::date::text,'?') || ')', E'\n  ')
                 from public.percolate_build"
    local out
    if [ -n "$DSN" ]; then
        out=$(psql "$DSN" -tAc "$sql" 2>/dev/null || true)
    else
        out=$(docker exec -i "$CONTAINER" psql -U p8 -d "$DB" -tAc "$sql" 2>/dev/null || true)
    fi
    if [ -n "$out" ]; then
        echo "under test:"
        echo "  $out"
    else
        echo "under test: this build records no provenance (percolate_build is empty)"
    fi
}
banner

# Is <extension> installed on the database under test? Asked once per name and
# cached, because the answer cannot change mid-run.
have_ext() {
    local ext="$1"
    local sql="select 1 from pg_extension where extname = '$ext'"
    if [ -n "$DSN" ]; then
        psql "$DSN" -tAc "$sql" 2>/dev/null | grep -q 1
    else
        docker exec -i "$CONTAINER" psql -U p8 -d "$DB" -tAc "$sql" 2>/dev/null | grep -q 1
    fi
}

failed=0
skipped=0
skipped_names=""
for surface in ${SURFACES[@]}; do
    [ -d "$HERE/$surface" ] || { echo "no such surface: $surface" >&2; exit 2; }
    echo
    echo "=== ${surface} ==============================================="
    for f in "$HERE/$surface"/*.sql; do
        [ -e "$f" ] || continue
        printf '  %-34s ' "$(basename "$f")"
        need=$(sed -n 's/^-- requires:[[:space:]]*//p' "$f" | head -1)
        if [ -n "$need" ] && ! have_ext "$need"; then
            if [ -n "${REQUIRE_ALL:-}" ]; then
                echo "FAILED"
                echo "      $need is not installed on $DB, and REQUIRE_ALL is set."
                failed=1
            else
                echo "skipped (needs $need)"
                skipped=$((skipped + 1))
                skipped_names="$skipped_names $surface/$(basename "$f")"
            fi
            continue
        fi
        if out=$(run_sql "$f" 2>&1); then
            echo "ok"
            echo "$out" | grep '^NOTICE:' | sed 's/^NOTICE:  /      /' || true
        else
            echo "FAILED"
            echo "$out" | sed 's/^/      /'
            failed=1
        fi
    done
done

echo
if [ "$skipped" -ne 0 ]; then
    # Named, every time, and never folded into the pass line. A skip is a
    # guarantee nobody checked, and the run that hides one is the run that
    # reports green for something it never looked at.
    echo "$skipped file(s) skipped for a missing extension:$skipped_names"
    echo "  (REQUIRE_ALL=1 makes this a failure -- .github/workflows/suite.yml sets it)"
fi
if [ "$failed" -ne 0 ]; then
    echo "FAILED -- a guarantee the specs make is no longer held."
    exit 1
fi
echo "All surfaces passed."
