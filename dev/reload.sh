#!/usr/bin/env bash
# Reload the schema into the running stack, without building anything.
#
#     dev/stacks.sh reload       # the dev instance's own database, p8dev
#     dev/reload.sh p8dev        # the same thing, spelled out
#     dev/reload.sh scratch_x    # somewhere else in the same container
#
# THE INNER LOOP, and the reason it exists is that the other two paths are for
# other people. Building the image takes minutes and publishing it takes eight;
# neither is what you want after editing a line of SQL, and reaching for one of
# them because it is the documented path is how the dev experience rots.
#
# What this does instead: regenerate the extension SQL from specs/, drop and
# recreate ONE database inside the container that is already running, and
# install into it. About twenty seconds, no build, no pull, no restart, and the
# rest of the stack -- PostgREST, the worker, the MCP server -- keeps running
# against whatever it was already pointed at.
#
# It is deliberately NOT an `ALTER EXTENSION UPDATE`, and the reason is no
# longer the one this comment used to give. It said "pre-1.0 there is no
# in-place upgrade path (PACKAGING.md)"; PACKAGING.md §"in-place upgrade" now
# opens by retracting exactly that, and `.github/workflows/check.yml` upgrades
# a real database with real data from the last release on every run.
#
# What survives is the argument for the INNER LOOP specifically: an update
# converges an existing database, and what you want after editing one line of
# SQL is a database that has never seen the old line at all. A fresh one from
# the current specs is both the stronger check and the faster path, and it is
# fast because the samples in init/ are small on purpose. The upgrade has its
# own test, in CI, where the thing under test is the upgrade rather than the
# edit.
#
# The image only has to be rebuilt when something COMPILED changes -- the
# Dockerfile, pgvector, pg_cron, the parser .so. Editing SQL is not that.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"

DB=${1:-p8dev}
CONTAINER=${CONTAINER:-p8-dev-db}
SUPERUSER=${SUPERUSER:-p8}
# `postgres`, not the served database: you cannot DROP the database you are
# connected to, and this script now recreates the one the dev stack serves
# rather than a scratch copy beside it. One database, one instance.
ADMIN_DB=${ADMIN_DB:-postgres}

docker inspect "$CONTAINER" >/dev/null 2>&1 || {
  echo "no container named $CONTAINER -- start the stack first: dev/stacks.sh up dev" >&2
  exit 1; }

echo "==> regenerating the extension SQL from specs/"
python3 "$ROOT/extension/percolate/build-sql.py" | tail -1

# Into the image's own extension directory, so `create extension percolate`
# finds the version being tested rather than the one the image shipped with.
# Overwriting it inside a running container is fine and is undone by any
# recreate -- which is exactly the property that makes this loop cheap.
VERSION=$(sed -n "s/^default_version = '\(.*\)'/\1/p" "$ROOT/extension/percolate/percolate.control")
echo "==> installing percolate--$VERSION.sql into $CONTAINER"
docker cp "$ROOT/extension/percolate/sql/percolate--$VERSION.sql" \
          "$CONTAINER:/tmp/percolate--$VERSION.sql" >/dev/null
# THE CONTROL FILE GOES WITH IT, and leaving it behind cost a whole afternoon.
# `create extension percolate` installs whatever `default_version` in the
# IMAGE's percolate.control names -- so copying only the script put
# percolate--0.1.1.sql next to a control file still saying 0.1.0, and every
# reload after the version bump silently recreated the database from the script
# the image shipped with. Nothing failed: surface.sql passed, the suites passed,
# and they were passing against code that was two hours old.
#
# It worked before the bump for the worst possible reason -- the version had
# never changed, so the name reload.sh wrote was the name the control asked for.
docker cp "$ROOT/extension/percolate/percolate.control" \
          "$CONTAINER:/tmp/percolate.control" >/dev/null
docker exec "$CONTAINER" sh -c \
  "cp /tmp/percolate--$VERSION.sql /tmp/percolate.control \$(pg_config --sharedir)/extension/"

# And say which version came back, because "it installed" is not the claim --
# the claim is that it installed THIS one.
INSTALLED=$(docker exec -i "$CONTAINER" psql -U "$SUPERUSER" -d "$ADMIN_DB" -tAc \
  "select default_version from pg_available_extensions where name = 'percolate'")
[ "$INSTALLED" = "$VERSION" ] || {
  echo "the container offers percolate $INSTALLED, not $VERSION -- the control file did not land" >&2
  exit 1; }

echo "==> recreating database $DB"
docker exec -i "$CONTAINER" psql -U "$SUPERUSER" -d "$ADMIN_DB" -q \
  -c "drop database if exists $DB (force);" -c "create database $DB;"

# pg_cron IF AND ONLY IF this is the database its worker is pointed at. The
# worker is bound to exactly one database by cron.database_name, so creating
# the extension anywhere else gets you a schema nothing ticks -- but leaving it
# out of the RIGHT database is worse, and used to happen every reload: the
# stack's own database came out of init/ with pg_cron and out of this script
# without it, so `tests/workflow/03-cron-tick.sql` skipped after a reload and
# ran after a recreate. A reload that does not reproduce a fresh install is a
# reload you have to remember a caveat about.
CRON_DB=$(docker exec -i "$CONTAINER" psql -U "$SUPERUSER" -d "$ADMIN_DB" -tAc \
          "show cron.database_name" 2>/dev/null | tr -d ' ')
if [ "$CRON_DB" = "$DB" ]; then
  echo "    (this is cron.database_name, so pg_cron goes in too)"
  docker exec -i "$CONTAINER" psql -U "$SUPERUSER" -d "$DB" -v ON_ERROR_STOP=1 -q \
    -c "create extension if not exists pg_cron"
fi

# Same order as init/.
docker exec -i "$CONTAINER" psql -U "$SUPERUSER" -d "$DB" -v ON_ERROR_STOP=1 -q <<SQL
create extension if not exists pgcrypto;
create extension if not exists pg_trgm;
create extension if not exists vector;
create extension if not exists percolate_parser;
do \$\$ begin execute format('grant create on database %I to app_owner', current_database()); end \$\$;
grant create, usage on schema public to app_owner;
-- bootstrap.sql's grant, for an image built before it (0.2.0)
grant authenticated to api_viewer;
set role app_owner;
create extension percolate cascade;
reset role;
SQL

# THE CLOCK, if this is the database it ticks in. Dropping the database took
# the cron.job rows with it -- they live in the cron schema OF the cron
# database -- and nothing else puts them back, so a reload used to leave a
# stack whose scheduled workflows, stale-task reaper and timer steps silently
# never fired again. Same three jobs, same `scheduler` role, as the image's own
# bootstrap (dev/image-init/00-percolate.sh §5).
if [ "$CRON_DB" = "$DB" ]; then
  docker exec -i "$CONTAINER" psql -U "$SUPERUSER" -d "$DB" -v ON_ERROR_STOP=1 -qtA >/dev/null <<'SQL'
select cron.schedule('workflow-tick',   '* * * * *', 'select workflow.tick()');
select cron.schedule('workflow-reaper', '* * * * *', 'select workflow.reap_stale_tasks()');
select cron.schedule('workflow-timers', '* * * * *', 'select workflow.promote_due_timers()');
update cron.job set username = 'scheduler'
 where jobname in ('workflow-tick','workflow-reaper','workflow-timers');
SQL
  echo "    (clock re-registered: tick, reaper, timers)"
fi

for f in init/0[2-9]-*.sql; do
  [ -e "$f" ] || continue
  docker cp "$f" "$CONTAINER:/tmp/$(basename "$f")" >/dev/null
  # ON_ERROR_STOP and the exit code, not a grep for a line that never matched.
  # This loop used to filter psql's output with `grep -iE '^(ERROR|WARNING)'`,
  # and psql prefixes every diagnostic with `psql:<file>:<line>: ` -- so the
  # anchor matched nothing, ever. Seed failures printed nothing and the loop
  # went on to the next file: the graph sample failed every insert against a
  # new foreign key and `reload.sh` reported a clean build, with only the
  # surface audit two steps later noticing that the sample entity types were
  # missing. A check that can only pass is not a check.
  #
  # AND IT IS NOT A PIPELINE, because both ways of writing it as one are
  # wrong under `set -euo pipefail`, and the file had already been through the
  # first:
  #
  #   `if ! psql | grep; then : ; fi` -- PIPESTATUS is set by the LAST
  #   pipeline, and `:` is one, so the next line read the no-op's status. The
  #   check could only pass. It printed the errors and carried on, and a reload
  #   over broken fixtures still ended with "p8dev is current".
  #
  #   `psql | grep; status=${PIPESTATUS[0]}` -- worse. pipefail makes the
  #   pipeline's status grep's when psql succeeds, and grep returns 1 when it
  #   matches nothing, so `set -e` killed the whole script on the first file
  #   that was CLEAN.
  #
  # Run it, keep the output, then decide. `|| status=$?` is what exempts it
  # from set -e; a bare assignment would not be.
  status=0
  out=$(docker exec -i "$CONTAINER" psql -U "$SUPERUSER" -d "$DB" -q \
        -v ON_ERROR_STOP=1 -f "/tmp/$(basename "$f")" 2>&1) || status=$?
  printf '%s' "$out" | grep -iE 'ERROR|WARNING' || true
  if [ "$status" -ne 0 ]; then
    echo "==> FAILED: init/$(basename "$f") -- see the error above" >&2
    exit 1
  fi
done

echo "==> auditing"
docker cp "$ROOT/surface.sql" "$CONTAINER:/tmp/surface.sql" >/dev/null
# THE EXIT CODE, AND `ERROR:` ANYWHERE ON THE LINE -- the init loop above
# learned this and the audit had not. The filter here was `^ERROR` piped into
# `|| true`: psql prints `psql:/tmp/surface.sql:1057: ERROR: …`, so the pattern
# never matched and the status was discarded, and a reload whose audit failed
# still said "is current". Found when a new function was reachable by
# `authenticated` and undeclared: surface.sql refused it, and reload.sh
# reported success three times in a row.
AUDIT=$(docker exec -i "$CONTAINER" psql -U "$SUPERUSER" -d "$DB" -v ON_ERROR_STOP=1 \
          -f /tmp/surface.sql 2>&1) && AUDIT_OK=1 || AUDIT_OK=0
printf '%s\n' "$AUDIT" \
  | grep -E 'SURFACE (COMPLETE|INCOMPLETE|CLOSED)|ROUND TRIP (COMPLETE|INCOMPLETE)|ERROR:' || true
[ "$AUDIT_OK" = 1 ] || { echo "==> the audit FAILED against $DB -- see above" >&2; exit 1; }

echo
echo "==> $DB is current. Connect with:"
echo "    docker exec -it $CONTAINER psql -U $SUPERUSER -d $DB"
