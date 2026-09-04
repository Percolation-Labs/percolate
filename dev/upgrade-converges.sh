#!/usr/bin/env bash
# Does UPGRADING land in the same place as INSTALLING FRESH?
#
#   ./dev/upgrade-converges.sh                 # against the compose stack
#   FROM=0.1.2 ./dev/upgrade-converges.sh      # from a specific published tag
#
# The third question in this family, and it is not either of the other two.
# `../surface.sql` asks whether a declared capability EXISTS. `currency.sh` asks
# whether a live database is running what the specs SAY. This asks whether the
# two ways of GETTING to this version agree -- because `percolate--<old>--<new>.sql`
# is the whole schema replayed, and a replay converges only for statements that
# can be applied twice.
#
# WHY IT EXISTS, and it is not hypothetical. build-sql.py enforces idempotency
# for things that CREATE: `create table if not exists`, `create or replace
# view/function/trigger`, a policy dropped before it is created. It enforces
# nothing about things that REMOVE, and a replay is structurally bad at those:
#
#   * `create or replace function` PRESERVES the existing ACL. So deleting a
#     `grant ... to web_anon` from the schema corrects a fresh install and
#     leaves every existing database exactly as it was.
#
# That is not a worked example. It is what happened: the fix that took
# `rbac.request_password_reset` away from `web_anon` -- an anonymous account
# takeover, since the function takes the reset token as an argument -- was
# written as a deleted grant line. A fresh install was correct. Every database
# that actually HAD the vulnerability upgraded and kept it, and every check in
# this repository passed, because they all compare a database to the specs and
# the specs said the right thing.
#
# The same hole is open for anything else a replay cannot express by omission:
# a policy that is deleted rather than renamed, a dropped column, a constraint
# that is removed, a function whose signature changed without a `drop function
# if exists` in front of it. This compares the two databases OBJECT BY OBJECT
# and reports every difference, so the class is covered rather than the one
# instance of it that was found the hard way.
#
# `spec.md`'s claim was "verified once by diffing an upgraded database against a
# fresh install of the same version: 629 objects, identical" -- true, and a
# measurement somebody took by hand on one afternoon. This is that measurement,
# runnable.
set -euo pipefail

CONTAINER="${CONTAINER:-p8-experiment-pg19}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
cd "$REPO"

VERSION=$(sed -n "s/^default_version = '\(.*\)'/\1/p" extension/percolate/percolate.control)
[ -n "$VERSION" ] || { echo "no default_version in percolate.control" >&2; exit 1; }

# The release a user upgrading today would be coming from: the newest tag below
# this tree's version. Read from the tags rather than written down, same source
# build-sql.py's upgrade scripts and suite.yml's upgrade job both use.
FROM="${FROM:-$(git tag --list 'v*' | sed 's/^v//' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | grep -v "^$VERSION$" \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)}"
if [ -z "$FROM" ]; then
    echo "nothing published below $VERSION -- there is no upgrade to check yet."
    exit 0
fi

NEW_SQL="extension/percolate/sql/percolate--$VERSION.sql"
UPG_SQL="extension/percolate/sql/percolate--$FROM--$VERSION.sql"
for f in "$NEW_SQL" "$UPG_SQL"; do
    [ -f "$f" ] || { echo "missing $f -- run extension/percolate/build-sql.py" >&2; exit 1; }
done

# ...and PRESENT is not the same as CURRENT. This used to check only that the
# files existed, so editing a spec and running this compared two databases built
# from the previous generation of the scripts -- and reported DIVERGED for a
# difference already fixed, or CONVERGES for one not yet generated. Both are
# worse than a failure, because both look like an answer. `--check` is the
# door build-sql.py already had; it costs nothing and the run below costs
# minutes, so it goes first.
python3 extension/percolate/build-sql.py --check >/dev/null || {
    echo "the generated extension scripts are behind specs/ -- run: python3 extension/percolate/build-sql.py" >&2
    exit 1; }

# The OLD schema comes from the TAG, never from this tree's copy of that
# filename. Getting that wrong is how the first run of this check reported a
# clean upgrade: the tree's `percolate--<old>.sql` had already been rewritten by
# the very edit under test, so it installed the fixed schema and then "upgraded"
# it to itself.
OLD_SQL=$(mktemp)
trap 'rm -f "$OLD_SQL"' EXIT
git show "v$FROM:extension/percolate/sql/percolate--$FROM.sql" > "$OLD_SQL" 2>/dev/null \
    || { echo "cannot read percolate--$FROM.sql from tag v$FROM" >&2; exit 1; }

echo "==> comparing a fresh $VERSION against $FROM upgraded to $VERSION"

mk() {
    docker exec -i "$CONTAINER" psql -U p8 -d postgres -q \
        -c "set client_min_messages = warning;" \
        -c "drop database if exists $1;" -c "create database $1;" >/dev/null 2>&1
    docker exec -i "$CONTAINER" psql -U p8 -d "$1" -q >/dev/null <<SQL
create extension if not exists pgcrypto;
create extension if not exists pg_trgm;
create extension if not exists vector;
create extension if not exists percolate_parser;
grant create on database $1 to app_owner;
grant create, usage on schema public to app_owner;
SQL
}
# `client_min_messages = warning` because the schema is deliberately loud --
# every subsystem raises a notice from its own load-time self-check, and three
# full installs of it bury the one thing this script is here to print. Errors
# and warnings still come through, and ON_ERROR_STOP still stops.
# A FAILED LOAD SAYS WHAT WENT WRONG. It used to be `>/dev/null 2>&1` with
# `set -e` doing the rest, so a script that could not build either database
# exited 3 having printed only its own header -- no error, no statement, no
# hint that the failure was in the LOAD rather than in the comparison this file
# exists to make. Measured while adding the scope columns: the fresh install
# failed on `column d.owner_id does not exist` and this reported nothing at all,
# which cost a bisect that the error message would have ended immediately.
#
# The output is captured rather than passed through because a clean load is
# thousands of lines of NOTICE; only a failure is worth printing.
load() {
    local out
    if ! out=$(docker exec -i "$CONTAINER" psql -U p8 -d "$1" -v ON_ERROR_STOP=1 -q \
                   -c "set client_min_messages = warning;" \
                   -c "set role app_owner;" -f - < "$2" 2>&1); then
        echo "==> FAILED to load $2 into $1:" >&2
        echo "$out" | grep -E '^psql.*(ERROR|FATAL)' | tail -5 >&2
        return 1
    fi
}

mk p8conv_fresh
mk p8conv_upg
load p8conv_fresh "$NEW_SQL"
load p8conv_upg   "$OLD_SQL"
load p8conv_upg   "$UPG_SQL"

# EVERY AXIS A REPLAY CAN GET WRONG, not just the ones that have gone wrong.
#
# `acl` and `proacl` are the reason this file exists and are the two nothing
# else compares -- currency.sh diffs bodies, security mode and search_path, and
# a preserved grant is none of those. Policies carry their USING clause because
# a policy that was edited rather than dropped-and-recreated keeps the old
# predicate. Columns carry their default, constraints their definition.
SNAP="
select 'fn  '||n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')'
       ||' acl='||coalesce(p.proacl::text,'DEFAULT')||' secdef='||p.prosecdef
       ||' cfg='||coalesce(array_to_string(p.proconfig,','),'-')||' md5='||md5(p.prosrc)
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname in ('rbac','workflow','aiq','content','agentic')
union all
select 'pol '||schemaname||'.'||tablename||'.'||policyname||' '||cmd
       ||' '||coalesce(qual,'-')||' '||coalesce(with_check,'-')
  from pg_policies where schemaname in ('rbac','workflow','aiq','content','agentic')
union all
select 'col '||table_schema||'.'||table_name||'.'||column_name||' '||data_type
       ||' null='||is_nullable||' def='||coalesce(column_default,'-')
  from information_schema.columns
 where table_schema in ('rbac','workflow','aiq','content','agentic')
union all
select 'con '||n.nspname||'.'||c.conname||' '||pg_get_constraintdef(c.oid)
  from pg_constraint c join pg_namespace n on n.oid=c.connamespace
 where n.nspname in ('rbac','workflow','aiq','content','agentic')
union all
select 'idx '||schemaname||'.'||indexname||' '||indexdef
  from pg_indexes where schemaname in ('rbac','workflow','aiq','content','agentic')
union all
-- relkind is the char type rather than text, and concatenating it is ambiguous
-- in PG19 (operator is not unique ... could not choose a best candidate), so it
-- is cast. NO BACKTICKS ANYWHERE IN THIS STRING: SNAP is a double-quoted shell
-- literal, so a backtick in a SQL comment is command substitution -- the first
-- version of this line tried to run 'char' as a program and exited 127.
select 'rel '||n.nspname||'.'||c.relname||' kind='||c.relkind::text
       ||' owner='||pg_get_userbyid(c.relowner)||' rls='||c.relrowsecurity
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
 where n.nspname in ('rbac','workflow','aiq','content','agentic')
   and c.relkind in ('r','v','m')
union all
select 'acl '||table_schema||'.'||table_name||' '||grantee||' '||privilege_type
  from information_schema.role_table_grants
 where table_schema in ('rbac','workflow','aiq','content','agentic')
union all
-- TRIGGERS, added after this script reported 2133 objects unchanged across a
-- commit that ADDED ONE. Everything above describes tables and the functions
-- beside them; nothing described what is WIRED to them, and a trigger is where
-- this collection has found two of its worst bugs -- an autorun that fired on
-- the transition nobody took, and a timer whose delay was stamped by a trigger
-- that could not see the insert. A convergence check blind to them is blind to
-- the class most worth checking.
--
-- tgtype is a bitmask and is rendered rather than compared raw, so a diff says
-- BEFORE/UPD instead of 19.
select 'trg '||n.nspname||'.'||c.relname||'.'||t.tgname
       ||' '||(case when t.tgtype & 1 = 1 then 'ROW' else 'STMT' end)
       ||' '||(case when t.tgtype & 2 > 0 then 'BEFORE'
                    when t.tgtype & 64 > 0 then 'INSTEAD' else 'AFTER' end)
       ||' '||concat_ws('/', case when t.tgtype & 4 > 0 then 'INS' end,
                             case when t.tgtype & 8 > 0 then 'DEL' end,
                             case when t.tgtype & 16 > 0 then 'UPD' end)
       ||' -> '||p.proname
       ||' enabled='||t.tgenabled::text
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  join pg_proc p on p.oid = t.tgfoid
 where not t.tgisinternal
   and n.nspname in ('rbac','workflow','aiq','content','agentic')
order by 1;"

fresh=$(mktemp); upg=$(mktemp)
trap 'rm -f "$OLD_SQL" "$fresh" "$upg"' EXIT
docker exec -i "$CONTAINER" psql -U p8 -d p8conv_fresh -tAc "$SNAP" > "$fresh"
docker exec -i "$CONTAINER" psql -U p8 -d p8conv_upg   -tAc "$SNAP" > "$upg"

docker exec -i "$CONTAINER" psql -U p8 -d postgres -q \
    -c "drop database if exists p8conv_fresh;" -c "drop database if exists p8conv_upg;" >/dev/null

n=$(wc -l < "$fresh" | tr -d ' ')
if diff -q "$fresh" "$upg" >/dev/null; then
    echo "CONVERGES -- $n objects, identical whether installed fresh or upgraded from $FROM."
    exit 0
fi

echo
echo "DIVERGED. The upgrade from $FROM does not produce the same database as a"
echo "fresh $VERSION install. '<' is what a fresh install has; '>' is what an"
echo "upgraded one has instead."
echo
diff "$fresh" "$upg" | sed 's/^/  /'
echo
echo "A line only under '>' is usually something the schema STOPPED saying: a"
echo "revoked grant, a deleted policy, a dropped column. A replay cannot express"
echo "an omission -- state the removal (revoke / drop ... if exists) in the"
echo "schema itself, the way policies and constraints already are."
exit 1
