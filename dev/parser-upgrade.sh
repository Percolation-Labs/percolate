#!/usr/bin/env bash
# Does an installed percolate_parser move to THIS version in place, and land where a fresh install does?
#
#     dev/parser-upgrade.sh
#     PARSER_DIST=parser-dist dev/parser-upgrade.sh   # with the .so this tree compiled
#
# WHY (REM-192). Until this, a release shipped only percolate_parser--<v>.sql. `percolate` moved forward
# through its upgrade script and the parser stayed at whatever version first installed it, over a newer
# .so, with no path: no row in pg_extension_update_paths, and `drop extension percolate_parser` refused
# because percolate depends on it. Every other upgrade gate here asks about `percolate` alone.
#
# So: the newest published image, whose parser is what an upgrader has, with its database exactly as
# initdb left it; this tree's control file and percolate_parser--<prev>--<this>.sql copied in;
# `alter extension percolate_parser update`; then every function the extension owns, compared -- name,
# arguments with defaults, result, volatility, strictness, parallel safety, C symbol, ACL, schema --
# against a fresh install at this version in another database of the same server, made by the image's
# own superuser step. Its script is sql/surface.sql, the recorded pgrx output the upgrade scripts are
# made from, unless PARSER_DIST hands over the SQL pgrx actually produced.
#
# Without PARSER_DIST the release's .so stays in place. That is sound only while the C symbols are the
# release's too, and it is exactly when they are not that `--check-surface` in check.yml's parser job
# fails first, before a database job with this gate in it runs.
set -euo pipefail
cd "$(dirname "$0")/.."

C="${PARSER_UPGRADE_CONTAINER:-${CONTAINER:-p8}-parser-upgrade}"
V=$(sed -n "s/^default_version = '\(.*\)'/\1/p" extension/percolate_parser/percolate_parser.control)
PREV=$(git tag --list 'v*' | sed 's/^v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | grep -v "^$V$" \
       | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
[ -n "$PREV" ] || { echo "nothing published below $V -- no parser upgrade to test yet."; exit 0; }
UP="extension/percolate_parser/sql/percolate_parser--$PREV--$V.sql"
[ -f "$UP" ] || { echo "FAILED: $UP is missing -- run python3 extension/percolate_parser/write-upgrades.py"; exit 1; }
EXT=/usr/share/postgresql/19/extension

cleanup() { docker rm -f -v "$C" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
# Pulled first: a published tag can be rebuilt (19-0.2.20 was, on 1 October), and
# `docker run` would start whatever copy this machine cached.
docker pull -q "percolationlabs/percolate-postgres:19-$PREV" >/dev/null
docker run -d --name "$C" -e POSTGRES_USER=p8 -e POSTGRES_PASSWORD=p8 \
    -e POSTGRES_DB=percolate "percolationlabs/percolate-postgres:19-$PREV" >/dev/null
# TCP, for the reason dev/ci-database.sh spells out on its readiness loop.
for _ in $(seq 1 90); do
    docker exec -e PGPASSWORD=p8 "$C" psql -h 127.0.0.1 -U p8 -d percolate -tAc \
        "select 1 from pg_extension where extname='percolate'" 2>/dev/null | grep -q 1 && break
    sleep 2
done
q() { docker exec -i "$C" psql -U p8 -d "$1" -v ON_ERROR_STOP=1 -qtA "${@:2}"; }

have=$(q percolate -c "select extversion from pg_extension where extname = 'percolate_parser'")
[ "$have" = "$PREV" ] || { echo "FAILED: the $PREV image installed percolate_parser '$have', not $PREV"; exit 1; }

if [ -n "${PARSER_DIST:-}" ]; then
    docker cp "$PARSER_DIST/percolate_parser.so" "$C:/usr/lib/postgresql/19/lib/" >/dev/null
    docker cp "$PARSER_DIST/percolate_parser--$V.sql" "$C:$EXT/" >/dev/null
else
    docker cp extension/percolate_parser/sql/surface.sql "$C:$EXT/percolate_parser--$V.sql" >/dev/null
fi
docker cp extension/percolate_parser/percolate_parser.control "$C:$EXT/" >/dev/null
docker cp "$UP" "$C:$EXT/" >/dev/null

if ! out=$(q percolate -c "alter extension percolate_parser update to '$V'" 2>&1); then
    echo "FAILED: percolate_parser $PREV -> $V: $(echo "$out" | grep -m1 ERROR)"; exit 1
fi
got=$(q percolate -c "select extversion from pg_extension where extname = 'percolate_parser'")
[ "$got" = "$V" ] || { echo "FAILED: after the update percolate_parser is at '$got', not $V"; exit 1; }

q percolate -c "create database parser_fresh" >/dev/null
# The fresh install is the one every new database gets: the image's superuser step, which creates the
# parser at the control file's default_version -- now $V -- and is written in exactly one file.
docker cp dev/image-init/00-superuser.sql "$C:/tmp/00-superuser.sql" >/dev/null
q parser_fresh -f /tmp/00-superuser.sql >/dev/null
fresh_v=$(q parser_fresh -c "select extversion from pg_extension where extname = 'percolate_parser'")
[ "$fresh_v" = "$V" ] || { echo "FAILED: the superuser step installed percolate_parser '$fresh_v', not $V"; exit 1; }

SURFACE="select n.nspname || '.' || p.proname || '(' || pg_get_function_arguments(p.oid) || ') '
               || pg_get_function_result(p.oid) || ' ' || p.provolatile::text || ' strict=' || p.proisstrict::text
               || ' parallel=' || p.proparallel::text || ' ' || p.prosrc || ' ' || coalesce(p.proacl::text, '-')
           from pg_depend d
           join pg_proc p on p.oid = d.objid
           join pg_namespace n on n.oid = p.pronamespace
          where d.classid = 'pg_proc'::regclass and d.refclassid = 'pg_extension'::regclass
            and d.deptype = 'e'
            and d.refobjid = (select oid from pg_extension where extname = 'percolate_parser')
          order by 1"
upgraded=$(q percolate -c "$SURFACE")
fresh=$(q parser_fresh -c "$SURFACE")
n=$(printf '%s\n' "$fresh" | grep -c . || true)
# A comparison of nothing passes, which is the failure a gate must not have.
[ "$n" -gt 0 ] || { echo "FAILED: a fresh percolate_parser $V owns no functions -- nothing was compared"; exit 1; }
if [ "$upgraded" != "$fresh" ]; then
    echo "FAILED: percolate_parser updated $PREV -> $V does not match a fresh install of $V:"
    diff <(printf '%s\n' "$upgraded") <(printf '%s\n' "$fresh") | sed 's/^/    /' || true
    echo "  '<' is the upgraded database, '>' the fresh one. A replay cannot remove or retype a function;"
    echo "  write the hop in extension/percolate_parser/migrations/ (see write-upgrades.py)."
    exit 1
fi
echo "  percolate_parser $PREV -> $V in place: $n functions identical to a fresh install -- ok"
