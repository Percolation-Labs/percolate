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
# WHAT IT DOES NOT DO. It does not build the parser. The image carries a
# compiled .so, so a change under extension/percolate_parser/ is NOT tested by
# anything this script produces -- `parser-tests.yml` covers the crate's own
# tests, and the pair of "this tree's parser against this tree's schema" needs
# dev/build-image.sh. Saying so is the difference between a gap and a lie.
set -euo pipefail
cd "$(dirname "$0")/.."

CONTAINER="${CONTAINER:-p8-ci}"
DB="${DB:-p8ci}"

V=$(sed -n "s/^default_version = '\(.*\)'/\1/p" extension/percolate/percolate.control)
[ -n "$V" ] || { echo "percolate.control has no default_version" >&2; exit 1; }

# The newest PUBLISHED image, not the version the tree declares -- a bumped,
# untagged tree is a state the release process deliberately produces, and asking
# for `:19-$V` breaks on every push until the release that creates it exists.
PUB=$(git tag --list 'v*' | sed 's/^v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
      | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
IMAGE="percolationlabs/percolate-postgres:19-${PUB:-}"
[ -n "$PUB" ] || IMAGE="percolationlabs/percolate-postgres:19"
[ "$PUB" = "$V" ] && echo "tree is $V, which is published" \
                  || echo "tree is $V (unreleased); testing its SQL on the ${PUB:-mutable :19} image"

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
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

python3 -c 'import yaml' 2>/dev/null || pip install --quiet pyyaml
python3 extension/percolate/build-sql.py >/dev/null

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
\i /tmp/00-superuser.sql
create extension if not exists pg_cron;
set role app_owner;
create extension percolate cascade;
reset role;
SQL

for f in dev/init/0[2-9]-*.sql; do
    [ -e "$f" ] || continue
    docker cp "$f" "$CONTAINER:/tmp/$(basename "$f")" >/dev/null
    docker exec "$CONTAINER" psql -U p8 -d "$DB" -v ON_ERROR_STOP=1 -q -f "/tmp/$(basename "$f")"
done

echo
echo "$DB is the database CI builds. Ask it what CI asks:"
echo "    CONTAINER=$CONTAINER DB=$DB dev/check.sh"
