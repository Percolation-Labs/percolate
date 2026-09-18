#!/usr/bin/env bash
# Build the database CI builds, on this machine.
#
#     dev/ci-database.sh            # into container p8-ci, database p8ci
#     CONTAINER=p8-mine dev/ci-database.sh
#
# Then `CONTAINER=p8-ci DB=p8ci dev/check.sh` asks the same questions CI asks, of
# the same database CI asks them of. Those two commands ARE the CI job -- the
# workflow runs this file and then that one, so there is no third description of
# the build to fall behind these two.
#
# WHY IT IS A FILE AND NOT WORKFLOW YAML. It was workflow YAML, and the cost was
# a day. The published contract went stale in CI and nowhere else; `--check`
# against a `dev/reload.sh` database said "is current" on every machine anybody
# tried, so the investigation went to pg_cron -- the one visible difference
# between the two builds -- and stayed there. The actual cause was one row that
# the test suite inserts, and it was reachable in about ten minutes ONCE the CI
# database could be built locally. Reproducing it required hand-copying eight
# steps out of a workflow file into a terminal, which is why nobody had.
#
# HOW IT DIFFERS FROM dev/reload.sh, deliberately and in ways that matter:
#
#   * a container of its OWN, from the newest PUBLISHED image, rather than the
#     compose stack you are already using. Nothing here disturbs whatever you
#     were poking at in psql, and several sessions can each have one.
#   * pg_cron INSTALLED. reload.sh skips it because cron.database_name binds the
#     worker to a single database and a scratch database cannot have it; this
#     script owns its container, so it points cron at its own database and
#     workflow/03 can actually run. That difference is a whole class of
#     CI-only failure -- `web_anon holds write privileges: cron.job_run_details`
#     was one, invisible on every developer machine.
#   * the extension DROPPED and recreated from this tree, over the image's
#     published one. The image supplies the compiled parser and the roles; the
#     SQL under test is yours.
#
# WHAT IT DOES NOT DO. It does not BUILD the parser -- a pgrx toolchain is
# minutes and this script is seconds. It will INSTALL one it is handed, through
# PARSER_DIST (see the block above the extension install), which is how
# .github/workflows/check.yml now tests the pair without every developer paying
# for the toolchain: its `parser` job compiles the crate and this script takes
# the artefact. dev/build-image.sh writes the same three files into dev/dist, so
#
#     REBUILD_PARSER=1 dev/build-image.sh && PARSER_DIST=dev/dist dev/ci-database.sh
#
# is the local form of what CI does. With PARSER_DIST unset nothing changes and
# the image's own .so is used, which is what every local run did before and is
# still right for asking "does this schema work on the published parser".
set -euo pipefail
cd "$(dirname "$0")/.."

CONTAINER="${CONTAINER:-p8-ci}"
DB="${DB:-p8ci}"
# $PY, the same override dev/check.sh honours. Hard-coding `python3` cost two
# sessions an hour each on one afternoon: on a machine where `python3` is
# uv-managed, `python3 -m pip install` cannot write to it, so the preflight
# below failed and this script exited 1 -- AFTER creating the container. Both
# sessions were left with a database holding the IMAGE's extension rather than
# the tree's, one of them measured a baseline against it, and the other reached
# for a PATH shim instead of an override that should have existed. Two copies of
# the same fact (which interpreter to use) with only one of them configurable.
# One picker, in dev/lib/python.sh, rather than the install-or-explain block
# that used to live below: the "install pyyaml into it" step moved in there, so
# a runner still gets the cheap answer and a laptop gets a venv instead of an
# error. Three scripts asking this question three ways is what that file ends.
. "$(cd "$(dirname "$0")" && pwd)/lib/python.sh"
PY="$(percolate_python)" || exit 1

V=$(sed -n "s/^default_version = '\(.*\)'/\1/p" extension/percolate/percolate.control)
[ -n "$V" ] || { echo "percolate.control has no default_version" >&2; exit 1; }

# The newest PUBLISHED image, not the version the tree declares -- a bumped,
# untagged tree is a state the release process deliberately produces, and asking
# for `:19-$V` breaks on every push until the release that creates it exists.
PUB=$(git tag --list 'v*' | sed 's/^v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
      | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
if [ -n "${IMAGE:-}" ]; then
    # THE PARSER, WHEN THE BRANCH IS THE PARSER. The header says this script
    # does not build one, which left a branch that changes
    # extension/percolate_parser/ with no way to ask these gates about its own
    # compiled code: the published image carries the .so from the last release.
    # So the image is overridable, and
    #
    #     TAG=percolate-postgres:mine dev/build-image.sh
    #     IMAGE=percolate-postgres:mine CONTAINER=p8-mine DB=p8mine dev/ci-database.sh
    #
    # is the pair -- this tree's parser under this tree's schema -- in two
    # commands rather than none. CI passes nothing and gets the published
    # image, which is the run it is meant to be reporting on.
    echo "tree is $V, on $IMAGE (an image override; CI uses the published one)"
else
    IMAGE="percolationlabs/percolate-postgres:19-${PUB:-}"
    [ -n "$PUB" ] || IMAGE="percolationlabs/percolate-postgres:19"
    [ "$PUB" = "$V" ] && echo "tree is $V, which is published" \
                      || echo "tree is $V (unreleased); testing its SQL on the ${PUB:-mutable :19} image"
fi

# EVERYTHING THE TREE CAN GET WRONG, BEFORE ANYTHING DOCKER CAN. This block used
# to sit after the readiness loop, and the ordering was the defect rather than
# the commands: a machine that cannot install PyYAML got a running container and
# a created database first, then `exit 1`. That leaves the worst possible state
# -- a container that looks ready and holds the IMAGE's published extension, not
# this tree's -- and it reports failure while doing so, so anyone who reads the
# container instead of the exit code measures the wrong extension. One session
# did exactly that and discarded the baseline; another nearly filed it as a
# regression.
#
# Generating the SQL needs no database, so it belongs on this side of the line.
# Failing here costs nothing and leaves nothing behind.
#
# `$PY -m pip`, never bare `pip`. The two are not the same command: `pip` is a
# script that may be absent (a Homebrew python3 ships none on PATH) or may
# belong to a DIFFERENT interpreter, so the install lands where build-sql.py
# cannot see it. Measured: bare `pip` exited 127 with `pip: command not found`,
# this script stopped having copied nothing into the container, and the database
# it reported was one nobody had installed the tree's extension into.
#
# And the fallback is FATAL when it fails, which it was not before: `|| pip
# install` with the script under `set -e` still let a 127 through as the last
# statement's status in some shells, and a build step that cannot install its
# own build dependency must not continue as though it had.
"$PY" extension/percolate/build-sql.py >/dev/null

docker rm -f -v "$CONTAINER" >/dev/null 2>&1 || true
# POSTGRES_DB is the TEST database, not `postgres`: the image bootstraps into
# POSTGRES_DB, and pg_cron refuses `create extension` in any database other than
# the one cron.database_name names, so the two settings have to agree or the
# init script dies and the container never becomes ready.
docker run -d --name "$CONTAINER" \
    -e POSTGRES_USER=p8 -e POSTGRES_PASSWORD=p8 -e POSTGRES_DB="$DB" \
    "$IMAGE" postgres -c shared_preload_libraries=pg_cron -c "cron.database_name=$DB" >/dev/null

# OVER TCP, and it is the whole point of this loop. The official entrypoint runs
# its init phase against a TEMPORARY server started with listen_addresses='' --
# reachable on the unix socket and nowhere else. `docker exec psql` with no -h
# uses that socket, so a readiness check written that way passed WHILE init was
# still running, and the next step got `FATAL: the database system is shutting
# down` as init handed over to the real server. A check satisfied by the server
# being torn down is worse than none.
echo -n "waiting for $DB"
for _ in $(seq 1 90); do
    docker exec -e PGPASSWORD=p8 "$CONTAINER" \
        psql -h 127.0.0.1 -U p8 -d "$DB" -tAc \
        "select 1 from pg_extension where extname='percolate'" 2>/dev/null \
        | grep -q 1 && { echo; break; }
    echo -n "."; sleep 1
done

# `python3 -m pip`, never bare `pip`. The two are not the same command: `pip`
# is a script that may be absent (a Homebrew python3 ships none on PATH) or may
# belong to a DIFFERENT interpreter than the `python3` on the next line, so the
# install lands where build-sql.py cannot see it. Measured here: bare `pip`
# exited 127 with `pip: command not found`, this script stopped at line 85
# having copied nothing into the container, and the database it reported was one
# nobody had installed the tree's extension into.
#
# And the fallback is FATAL when it fails, which it was not before: `|| pip
# install` with the script under `set -e` still let a 127 through as the last
# statement's status in some shells, and a build step that cannot install its
# own build dependency must not continue as though it had.

# THE COMPILED HALF, WHEN SOMEBODY HAS BUILT ONE. This script's header says it
# does not build the parser, and it still does not -- but it will INSTALL one it
# is handed, which is what lets CI test the pair without every developer paying
# for a pgrx toolchain.
#
# PARSER_DIST names a directory holding what `cargo pgrx package` produced:
# percolate_parser.so, percolate_parser--<version>.sql and the control file.
# dev/build-image.sh writes exactly that into dev/dist, and .github's parser job
# uploads the same three as an artifact. Unset, nothing here changes and the
# image's own .so is used, which is the behaviour every local run has today.
#
# BEFORE the install block below, because `create extension percolate cascade`
# creates percolate_parser as a dependency and takes whatever default_version
# the control file in the container names at that moment. Copying afterwards
# would leave the old extension row pointing at a new .so -- the two halves
# disagreeing in the one direction nothing detects, since dev/tests/run.sh reads
# the VERSION to decide what to defer.
if [ -n "${PARSER_DIST:-}" ]; then
    [ -d "$PARSER_DIST" ] || { echo "PARSER_DIST=$PARSER_DIST is not a directory" >&2; exit 1; }
    PV=$(sed -n "s/^default_version = '\(.*\)'/\1/p" "$PARSER_DIST/percolate_parser.control")
    [ -n "$PV" ] || { echo "no default_version in $PARSER_DIST/percolate_parser.control" >&2; exit 1; }
    [ -f "$PARSER_DIST/percolate_parser--$PV.sql" ] || {
        echo "$PARSER_DIST has no percolate_parser--$PV.sql for the version its control names" >&2
        exit 1; }
    [ -f "$PARSER_DIST/percolate_parser.so" ] || {
        echo "$PARSER_DIST has no percolate_parser.so" >&2; exit 1; }
    docker cp "$PARSER_DIST/percolate_parser.so" \
              "$CONTAINER:/usr/lib/postgresql/19/lib/" >/dev/null
    # The old script is REMOVED, not left beside the new one. Two installable
    # versions of an extension is not an error Postgres reports -- it is an
    # offer, and build-image.sh carries the same rm for the same reason.
    docker exec "$CONTAINER" bash -c \
        'rm -f /usr/share/postgresql/19/extension/percolate_parser--*.sql'
    docker cp "$PARSER_DIST/percolate_parser--$PV.sql" \
              "$CONTAINER:/usr/share/postgresql/19/extension/" >/dev/null
    # And the upgrade paths to it, committed rather than built (write-upgrades.py, REM-192), so the
    # image under test offers what a released one will.
    for up in extension/percolate_parser/sql/percolate_parser--*--"$PV".sql; do
        [ -e "$up" ] && docker cp "$up" "$CONTAINER:/usr/share/postgresql/19/extension/" >/dev/null
    done
    docker cp "$PARSER_DIST/percolate_parser.control" \
              "$CONTAINER:/usr/share/postgresql/19/extension/" >/dev/null
    POFFERED=$(docker exec "$CONTAINER" psql -U p8 -d postgres -tAc \
        "select default_version from pg_available_extensions where name='percolate_parser'")
    [ "$POFFERED" = "$PV" ] || {
        echo "image offers percolate_parser $POFFERED after the copy, dist is $PV" >&2; exit 1; }
    echo "==> percolate_parser $PV installed from $PARSER_DIST (the image's was replaced)"
fi

# The control file goes in WITH the script. `create extension percolate`
# installs whatever default_version the IMAGE's control file names, so copying
# only the script installs the image's version and reports a green run against
# code you did not write. reload.sh learned this the expensive way.
docker cp "extension/percolate/sql/percolate--$V.sql" \
          "$CONTAINER:/usr/share/postgresql/19/extension/" >/dev/null
docker cp extension/percolate/percolate.control \
          "$CONTAINER:/usr/share/postgresql/19/extension/" >/dev/null
OFFERED=$(docker exec "$CONTAINER" psql -U p8 -d postgres -tAc \
    "select default_version from pg_available_extensions where name='percolate'")
[ "$OFFERED" = "$V" ] || { echo "image offers percolate $OFFERED, tree is $V" >&2; exit 1; }

# The superuser step is the image's own file, from THIS tree: the published
# image ran its older copy at initdb, and a tree that adds a grant needs it run
# again. Then `set role app_owner`, without which none of it holds: an
# extension creates its objects as whoever runs it, so a superuser here leaves
# every RLS policy inert while reporting success.
docker cp dev/image-init/00-superuser.sql "$CONTAINER:/tmp/00-superuser.sql" >/dev/null
docker exec -i "$CONTAINER" psql -U p8 -d "$DB" -v ON_ERROR_STOP=1 -q <<'SQL'
drop extension if exists percolate cascade;
-- AND THE PARSER, which `drop ... cascade` above does NOT take: cascade drops
-- what depends on percolate, and percolate_parser is what percolate depends ON.
-- The image installs it at initdb, so without this line `create extension
-- percolate cascade` below finds it already present and leaves it at the
-- image's version -- whatever was just copied into the extension directory.
-- Measured: run 34685340252 reported `percolate_parser 0.2.0 installed from
-- ...`, pg_available_extensions offered 0.2.0, and pg_extension still said
-- 0.1.6, so every compiled assertion deferred and dev/check.sh passed without
-- them. Recreated unconditionally by the cascade below, at whatever the control
-- file in the container names -- the image's own when PARSER_DIST is unset,
-- which is exactly what every run did before.
drop extension if exists percolate_parser cascade;
\i /tmp/00-superuser.sql
create extension if not exists pg_cron;
set role app_owner;
create extension percolate cascade;
reset role;

-- THE CLOCK'S HISTORY STARTS HERE. The image scheduled the tick at initdb, so
-- pg_cron was firing every minute while the lines above dropped and recreated
-- the extension, and a tick that lands in that gap fails: "could not open
-- relation with OID 17182 / compilation of PL/pgSQL function tick", measured
-- at 20:57:00.35 on 2026-09-11 against an install that finished at
-- 20:57:01.16, with every tick after it succeeding. workflow/03 counts the
-- tick's failures over the last 15 minutes, so each build turned the suite red
-- for a quarter of an hour. Runs from before this install are not about this
-- build; the test's window stays as it is.
delete from cron.job_run_details;
SQL

for f in dev/init/0[2-9]-*.sql; do
    [ -e "$f" ] || continue
    docker cp "$f" "$CONTAINER:/tmp/$(basename "$f")" >/dev/null
    docker exec "$CONTAINER" psql -U p8 -d "$DB" -v ON_ERROR_STOP=1 -q -f "/tmp/$(basename "$f")"
done

echo
echo "$DB is the database CI builds. Ask it what CI asks:"
echo "    CONTAINER=$CONTAINER DB=$DB dev/check.sh"
