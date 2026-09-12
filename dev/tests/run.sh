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
# That made the two commands this file's header, `check.yml`'s "if billing runs
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
# A FILE MAY ALSO DECLARE THE COMPILED PARSER IT NEEDS, with
# `-- requires-parser: <version>`, and a MIXED file may defer one assertion at a
# time with a notice beginning `DEFERRED:`. Both exist for the window PACKAGING
# calls "where main is red on purpose": the extension SQL and the .so ship as
# separate files, so between a parser change and the next image every compiled
# assertion fails for a reason that is not this commit's.
#
# The polarity is the OPPOSITE of `-- requires:` above and the difference is the
# point. REQUIRE_ALL does not promote these to failures, because CI runs the
# published image deliberately. What bounds them instead is the database: a
# deferral is honoured only while pg_extension says `percolate` and
# `percolate_parser` disagree. When the image catches up they agree, every
# deferral turns back into the assertion it was hiding, and a file declaring a
# parser that is NOT behind fails. Nobody has to remember to remove one.
#
# Prefer the notice to the file-level line wherever a file is not entirely
# compiled: `-- requires-parser:` stands the whole file down, and query/15's
# sections 2 to 5 are pure SQL that would then stop running in CI for a reason
# that has nothing to do with them.
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

# THE DEV INSTANCE, which is what `dev/README.md` documents and what
# `dev/check.sh` defaults to. These read `p8-experiment-pg19` / `p8experiment`,
# a single long-lived container that `dev/stacks.sh` replaced with four named
# instances -- so a bare `dev/tests/run.sh` died on a container that does not
# exist, and the only reason nothing noticed is that every caller passes
# CONTAINER and DB explicitly. Two scripts in one directory defaulting to
# different databases is also how a run grades an instance the caller did not
# mean; check.sh's header records the same hazard for --reload.
CONTAINER="${CONTAINER:-p8-dev-db}"
DB="${DB:-p8dev}"
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

# A FILE MAY ASK FOR A SPEC SCHEMA THE EXTENSION DOES NOT SHIP, with
# `-- loads: <path under specs/>` on its first lines. It arrives at
# /tmp/<basename> for the test to `\i` inside its own rolled-back transaction.
#
# WHY THIS EXISTS. build-sql.py's NOT_SHIPPED holds spec schemas that
# `create extension percolate` deliberately does not contain --
# world-model-ingestion/connectors.sql among them, "UNDECIDED ... ship it once
# it lands bytes in the content plane". Their objects are in no database this
# suite runs against, so nothing here could assert anything about them, and
# REM-82 is what that cost: five grants handing the connector catalogue to
# `web_anon` and to any signed-in caller, sitting in the tree unasserted
# because the table they name does not exist in CI.
#
# A not-shipped file is not an unused one. dev/currency.sh once found
# content.connectors* ORPHAN on a live stack -- "present in the database,
# absent from the specs' own extension script ... loaded by hand" -- and
# sources.md §17 registers 304 sources through it against a running deployment.
# So those grants were live wherever somebody loaded the file, and latent
# everywhere else until it enters ORDER.
#
# The alternative was a grep over the file's text for `web_anon`, which is the
# assertion shape REM-73 has just finished removing from content/01. Loading the
# real file and asking the catalogue is the same question asked exactly:
# Postgres parses the grants, and the test reads has_table_privilege rather than
# the source text that produced them.
#
# ROLLBACK IS THE TEST'S JOB, not this function's. The file is copied in; the
# test wraps its own `\i` in a transaction it rolls back, as
# world-model-ingestion/graph-demo.sql does. A test that committed one of these
# would leave a not-shipped schema behind and make every later run a different
# question.
stage_loads() {
    local f="$1" rel src
    rel=$(sed -n 's/^-- loads:[[:space:]]*//p' "$f" | head -1)
    [ -n "$rel" ] || return 0
    src="$HERE/../../specs/$rel"
    [ -f "$src" ] || { echo "-- loads: names no such file: specs/$rel" >&2; return 1; }
    if [ -z "$DSN" ]; then
        docker cp "$src" "$CONTAINER:/tmp/$(basename "$src")" >/dev/null
    else
        # DSN mode runs psql on this host, so the path the test \i's has to be
        # one this host can see. Copied rather than read in place so the test
        # spells the same /tmp path in both modes.
        cp "$src" "/tmp/$(basename "$src")"
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

    halves_note
}

# THE TWO HALVES, BY VERSION, and the note when they disagree.
#
# percolate_build can be empty, and on the published image it carries no parser
# row at all -- so the banner can be silent about the one drift that makes a
# traversal assertion fail for a reason that is not a defect. The extension
# versions are always there.
#
# ONE HOME, TWO CALL SITES, and the second one is the whole point. The banner
# prints at the top of a run, and `dev/check.sh` shows a failing gate as two
# lines before each failure, six after, and the last twelve of the log --
# so a note hundreds of lines above the first failure reaches CI not at all.
# Measured on run 34661284744, which carried no version line anywhere. The
# footer lands inside that `tail -12`, which is the surface where main's red
# is actually read; the banner stays because a direct run reads from the top.
#
# The long-form explanation of WHY the halves drift is query/11's preamble,
# also once.
halves_note() {
    local vers
    vers=$(db_query "select string_agg(extname || ' ' || extversion, ', ' order by extname)
                       from pg_catalog.pg_extension
                      where extname in ('percolate', 'percolate_parser')")
    [ -n "$vers" ] || return 0
    echo "  $vers"
    db_query "select (select extversion from pg_catalog.pg_extension where extname='percolate')
                   = (select extversion from pg_catalog.pg_extension where extname='percolate_parser')" \
      | grep -q '^t$' && return 0
    echo "  these two disagree: the compiled half and the extension SQL ship as"
    echo "  separate files and drift apart independently, so a traversal assertion"
    echo "  may fail because the .so predates the schema rather than because the"
    echo "  graph is wrong. dev/build-image.sh rebuilds it; a parser release clears it."
}

# One way to ask the database a scalar, whichever of the two connection modes
# this run is using. banner() and have_ext() each had their own copy of the
# if/else, and the third caller is what made it worth naming.
db_query() {
    if [ -n "$DSN" ]; then
        psql "$DSN" -tAc "$1" 2>/dev/null || true
    else
        docker exec -i "$CONTAINER" psql -U p8 -d "$DB" -tAc "$1" 2>/dev/null || true
    fi
}
banner

# Is <extension> installed on the database under test? Asked once per name and
# cached, because the answer cannot change mid-run.
have_ext() {
    db_query "select 1 from pg_extension where extname = '$1'" | grep -q 1
}

# THE TWO HALVES, READ ONCE. Every deferral below is legal only while the
# compiled parser is behind the extension SQL -- which is the normal state
# between a parser change and the next image, and is deliberate (PACKAGING.md,
# "the window where main is red on purpose"). It is not a state a test file
# gets to assume: when the halves agree, a deferral is hiding a real failure,
# and the checks below turn it back into one. That is what stops this becoming
# a permanent mute, which is the only reason a declared failure is safe at all.
PARSER_VER=$(db_query "select extversion from pg_catalog.pg_extension where extname='percolate_parser'")
SCHEMA_VER=$(db_query "select extversion from pg_catalog.pg_extension where extname='percolate'")

parser_behind() {
    [ -n "$PARSER_VER" ] && [ -n "$SCHEMA_VER" ] && [ "$PARSER_VER" != "$SCHEMA_VER" ]
}

# sort -V rather than a numeric compare per component: the versions here are
# plain x.y.z today and this stays right if one ever carries a suffix.
parser_at_least() {
    [ -n "$PARSER_VER" ] || return 1
    [ "$(printf '%s\n%s\n' "$1" "$PARSER_VER" | sort -V | head -1)" = "$1" ]
}

failed=0
skipped=0
skipped_names=""
deferred=0
deferred_names=""
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
        # A FILE MAY DECLARE THE PARSER IT NEEDS. Unlike `-- requires:` above,
        # REQUIRE_ALL does NOT turn this into a failure, because CI runs the
        # published image on purpose and the published image is where the lag
        # lives. The bound is the other way round: the declaration is honoured
        # only while the halves disagree, so it expires by itself on the day the
        # image catches up rather than on the day somebody remembers.
        want=$(sed -n 's/^-- requires-parser:[[:space:]]*//p' "$f" | head -1)
        if [ -n "$want" ] && ! parser_at_least "$want"; then
            if parser_behind; then
                echo "deferred (parser $PARSER_VER, needs $want)"
                deferred=$((deferred + 1))
                deferred_names="$deferred_names $surface/$(basename "$f")"
            else
                echo "FAILED"
                echo "      declares \`-- requires-parser: $want\` and the loaded parser is"
                echo "      $PARSER_VER, with the extension SQL also at $SCHEMA_VER. The halves"
                echo "      agree, so there is no lag to defer to and this declaration is"
                echo "      hiding whatever the file would have said. Remove it, or fix the file."
                failed=1
            fi
            continue
        fi
        if ! out=$(stage_loads "$f" 2>&1); then
            echo "FAILED"
            echo "$out" | sed 's/^/      /'
            failed=1
            continue
        fi
        if out=$(run_sql "$f" 2>&1); then
            # A file with a mixed section -- some assertions SQL, some compiled
            # -- defers the compiled ones one at a time rather than standing
            # down whole. It says so with a notice beginning DEFERRED:, and the
            # count below is what keeps that from being an invisible skip.
            n_def=$(printf '%s\n' "$out" | grep -c '^NOTICE:  DEFERRED:' || true)
            if [ "${n_def:-0}" -gt 0 ] && ! parser_behind; then
                echo "FAILED"
                printf '%s\n' "$out" | grep '^NOTICE:  DEFERRED:' | sed 's/^NOTICE:  /      /'
                echo "      and the halves agree ($PARSER_VER), so nothing here may defer."
                failed=1
                continue
            fi
            if [ "${n_def:-0}" -gt 0 ]; then
                echo "ok ($n_def deferred)"
                deferred=$((deferred + n_def))
                deferred_names="$deferred_names $surface/$(basename "$f")"
            else
                echo "ok"
            fi
            printf '%s\n' "$out" | grep '^NOTICE:' | sed 's/^NOTICE:  /      /' || true
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
    echo "  (REQUIRE_ALL=1 makes this a failure -- dev/check.sh sets it where the database has pg_cron)"
fi
if [ "$deferred" -ne 0 ]; then
    # Named like a skip, and for the same reason: a deferred assertion is a
    # guarantee nobody checked. The difference is that this one says what would
    # make it run, and the run above refuses it the moment that is true.
    echo "$deferred assertion(s)/file(s) deferred to a newer parser:$deferred_names"
    echo "  the compiled half is $PARSER_VER and the extension SQL is $SCHEMA_VER."
    echo "  dev/build-image.sh rebuilds the .so; a parser release clears this."
fi
if [ "$failed" -ne 0 ]; then
    # Repeated here rather than only in the banner: see halves_note's header.
    # A reader of CI sees the last twelve lines of this log and nothing above.
    halves_note
    echo "FAILED -- a guarantee the specs make is no longer held."
    exit 1
fi
echo "All surfaces passed."
