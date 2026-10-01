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
. "$HERE/lib/extension-schemas.sh"

VERSION=$(sed -n "s/^default_version = '\(.*\)'/\1/p" extension/percolate/percolate.control)
[ -n "$VERSION" ] || { echo "no default_version in percolate.control" >&2; exit 1; }

# FROM=self: THE BODY REPLAYED ONTO THIS VERSION ITSELF, and it is the upgrade
# every other gate here cannot see. An upgrade script is the whole body plus the
# migration hops that start at or after the old version; the body is replayed
# onto whatever the previous release left. While default_version equals the
# newest tag there is no script from that tag, so nothing ever replays the
# CURRENT body onto a database already at the CURRENT schema -- and that is
# exactly what the next bump's first hop does. It failed the first time anybody
# bumped past 0.2.0: `drop function if exists content.resolve_file(uuid)` sits in
# the body in front of its own `create or replace`, and on 0.2.0 the view
# workflow.v_artifacts depends on it. 0.1.6 -> 0.2.0 ran it on a database where
# nothing did, so every gate that starts from an older tag was green.
#
# The script is what build-sql.py's upgrade_script() writes for an upgrade from
# this version -- asked of that function rather than assembled here, so the two
# cannot disagree about what a replay is -- and the target is named
# "<version>-replay" because ALTER EXTENSION needs a version to go to and an
# update path is found by filename alone; no base script is needed for it.
SELF=
if [ "${FROM:-}" = self ]; then
    SELF=1
    FROM=$VERSION
fi

# The release a user upgrading today would be coming from: the newest tag below
# this tree's version. Read from the tags rather than written down, same source
# build-sql.py's upgrade scripts and check.yml's upgrade gates both use.
FROM="${FROM:-$(git tag --list 'v*' | sed 's/^v//' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | grep -v "^$VERSION$" \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)}"
if [ -z "$FROM" ]; then
    echo "nothing published below $VERSION -- there is no upgrade to check yet."
    exit 0
fi

NEW_SQL="extension/percolate/sql/percolate--$VERSION.sql"
if [ -n "$SELF" ]; then
    TO="$VERSION-replay"
    UPG_SQL=$(mktemp)
    UPG_NAME="percolate--$VERSION--$TO.sql"
    check_files=("$NEW_SQL")
else
    TO=$VERSION
    UPG_SQL="extension/percolate/sql/percolate--$FROM--$VERSION.sql"
    UPG_NAME=$(basename "$UPG_SQL")
    check_files=("$NEW_SQL" "$UPG_SQL")
fi
for f in "${check_files[@]}"; do
    [ -f "$f" ] || { echo "missing $f -- run extension/percolate/build-sql.py" >&2; exit 1; }
done

# ...and PRESENT is not the same as CURRENT. This used to check only that the
# files existed, so editing a spec and running this compared two databases built
# from the previous generation of the scripts -- and reported DIVERGED for a
# difference already fixed, or CONVERGES for one not yet generated. Both are
# worse than a failure, because both look like an answer. `--check` is the
# door build-sql.py already had; it costs nothing and the run below costs
# minutes, so it goes first.
# THE FOURTH SCRIPT TO ASK WHICH INTERPRETER, and #82 consolidated three of
# them into dev/lib/python.sh and missed this one. A bare `python3` here is the
# same defect that file exists for: on a machine whose python3 is uv-managed
# with no PyYAML, this gate exits 1 saying "the generated extension scripts are
# behind specs/" on a tree where they are not -- a red about the machine,
# wearing the words of a red about the tree, which is the worse of the two
# because the message names a remedy that will not help. It survived #82
# because CI's python3 has PyYAML, so the only machine it fails on is a laptop.
. "$(dirname "${BASH_SOURCE[0]}")/lib/python.sh"
PY="$(percolate_python)" || exit 2
"$PY" extension/percolate/build-sql.py --check >/dev/null || {
    echo "the generated extension scripts are behind specs/ -- run: $PY extension/percolate/build-sql.py" >&2
    exit 1; }

# The OLD schema comes from the TAG, never from this tree's copy of that
# filename. Getting that wrong is how the first run of this check reported a
# clean upgrade: the tree's `percolate--<old>.sql` had already been rewritten by
# the very edit under test, so it installed the fixed schema and then "upgraded"
# it to itself.
#
# FROM=self is the one exception, and it is not the mistake above: the version
# under test has no tag yet, and installing this tree's script and then
# replaying this tree's body onto it is the question being asked.
OLD_SQL=$(mktemp)
REPLAY_TMP=${SELF:+$UPG_SQL}
trap 'rm -f "$OLD_SQL" ${REPLAY_TMP:+"$REPLAY_TMP"}' EXIT
if [ -n "$SELF" ]; then
    cp "$NEW_SQL" "$OLD_SQL"
    "$PY" - "$VERSION" "$NEW_SQL" > "$UPG_SQL" <<'PYEOF'
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("build_sql", "extension/percolate/build-sql.py")
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)
version, body = sys.argv[1], pathlib.Path(sys.argv[2]).read_text()
sys.stdout.write(b.upgrade_script(version, body, b.migration_hops(b.released_versions())))
PYEOF
    chmod 644 "$UPG_SQL"
else
    git show "v$FROM:extension/percolate/sql/percolate--$FROM.sql" > "$OLD_SQL" 2>/dev/null \
        || { echo "cannot read percolate--$FROM.sql from tag v$FROM" >&2; exit 1; }
fi

if [ -n "$SELF" ]; then
    echo "==> comparing a fresh $VERSION against $VERSION with its own upgrade body replayed onto it"
else
    echo "==> comparing a fresh $VERSION against $FROM upgraded to $VERSION"
fi

# Both databases get the image's own superuser step, so the only difference
# between them is the one this file measures.
docker cp dev/image-init/00-superuser.sql "$CONTAINER:/tmp/00-superuser.sql" >/dev/null

# THROUGH CREATE EXTENSION, BOTH OF THEM, and not `psql -f` of the scripts,
# which is how this used to build them. A raw load creates the same objects and
# records none of them as the extension's, so pg_depend is empty and
# percolate.extension_schemas() -- which every gate now reads instead of a
# typed list of schemas -- answers nothing; this check would have compared two
# empty sets and reported CONVERGES. It is also not what an upgrader does: they
# run ALTER EXTENSION UPDATE, which is what the second database now does too.
# The files go into the extension directory the way dev/upgrade-from-every-
# release.sh puts them there, the old one from the tag.
# Asked of the container, not spelled with a major version (it was 19's path
# while the image was 19, and wrong the day it became 18).
EXT="$(docker exec "$CONTAINER" pg_config --sharedir)/extension"
chmod 644 "$OLD_SQL"   # mktemp makes it 0600 and docker cp keeps the mode
docker cp "$OLD_SQL" "$CONTAINER:$EXT/percolate--$FROM.sql" >/dev/null
docker cp "$NEW_SQL" "$CONTAINER:$EXT/" >/dev/null
docker cp "$UPG_SQL" "$CONTAINER:$EXT/$UPG_NAME" >/dev/null
docker cp extension/percolate/percolate.control "$CONTAINER:$EXT/" >/dev/null

mk() {
    docker exec -i "$CONTAINER" psql -U p8 -d postgres -q \
        -c "set client_min_messages = warning;" \
        -c "drop database if exists $1;" -c "create database $1;" >/dev/null 2>&1
    docker exec "$CONTAINER" psql -U p8 -d "$1" -v ON_ERROR_STOP=1 -q \
        -f /tmp/00-superuser.sql >/dev/null
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
                   -c "set role app_owner;" -c "$2" 2>&1); then
        echo "==> FAILED in $1: $2" >&2
        echo "$out" | grep -E '(ERROR|FATAL)' | tail -5 >&2
        return 1
    fi
}

mk p8conv_fresh
mk p8conv_upg
load p8conv_fresh "create extension percolate version '$VERSION'"
load p8conv_upg   "create extension percolate version '$FROM'"
load p8conv_upg   "alter extension percolate update to '$TO'"

# EVERY AXIS A REPLAY CAN GET WRONG, not just the ones that have gone wrong.
#
# `acl` and `proacl` are the reason this file exists and are the two nothing
# else compares -- currency.sh diffs bodies, security mode and search_path, and
# a preserved grant is none of those. Policies carry their USING clause because
# a policy that was edited rather than dropped-and-recreated keeps the old
# predicate. Columns carry their default, constraints their definition.
#
# OVER EVERY SCHEMA THE DATABASE SAYS IS THE EXTENSION'S, passed in as $1 from
# dev/lib/extension-schemas.sh, and asked of each database separately. The eight
# lists this replaced each named five schemas and none named percolate, so
# percolate.apply_package -- which reached real databases with a NULL ACL --
# was a function this check had never looked at. The schema names are compared
# too, so a schema one database has and the other does not is a difference even
# when it is empty.
snap() {
    local S=$1
    printf '%s' "
select 'sch '||s from $S x(s)
union all
select 'fn  '||n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')'
       ||' acl='||coalesce(p.proacl::text,'DEFAULT')||' secdef='||p.prosecdef
       ||' cfg='||coalesce(array_to_string(p.proconfig,','),'-')||' md5='||md5(p.prosrc)
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname in $S
union all
select 'pol '||schemaname||'.'||tablename||'.'||policyname||' '||cmd
       ||' '||coalesce(qual,'-')||' '||coalesce(with_check,'-')
  from pg_policies where schemaname in $S
union all
select 'col '||table_schema||'.'||table_name||'.'||column_name||' '||data_type
       ||' null='||is_nullable||' def='||coalesce(column_default,'-')
  from information_schema.columns
 where table_schema in $S
union all
select 'con '||n.nspname||'.'||c.conname||' '||pg_get_constraintdef(c.oid)
  from pg_constraint c join pg_namespace n on n.oid=c.connamespace
 where n.nspname in $S
union all
select 'idx '||schemaname||'.'||indexname||' '||indexdef
  from pg_indexes where schemaname in $S
union all
-- relkind is the char type rather than text, and concatenating it is ambiguous
-- in PG19 (operator is not unique ... could not choose a best candidate), so it
-- is cast. NO BACKTICKS ANYWHERE IN THIS STRING: SNAP is a double-quoted shell
-- literal, so a backtick in a SQL comment is command substitution -- the first
-- version of this line tried to run 'char' as a program and exited 127.
select 'rel '||n.nspname||'.'||c.relname||' kind='||c.relkind::text
       ||' owner='||pg_get_userbyid(c.relowner)||' rls='||c.relrowsecurity
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
 where n.nspname in $S
   and c.relkind in ('r','v','m')
union all
select 'acl '||table_schema||'.'||table_name||' '||grantee||' '||privilege_type
  from information_schema.role_table_grants
 where table_schema in $S
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
   and n.nspname in $S
union all
-- THE VOCABULARY ROWS, added because everything above describes OBJECTS and a
-- seed row is not one (REM-68). Extension-owned vocabulary was inserted with
-- 'on conflict do nothing', so a corrected is_terminal, inverse_label or table
-- kind reached a fresh install and never reached a database that upgraded --
-- and this script said CONVERGES, because it compared the table and not what
-- was in it. A check blind to the difference cannot report the difference.
--
-- WHICH TABLES, DERIVED TWICE OVER RATHER THAN LISTED, because a list here
-- would be a third copy of a decision the extension already records.
--
--   * pg_extension.extconfig is exactly the set specs/contract/schema.sql §4
--     marks as the DEPLOYMENT's rows, one pg_extension_config_dump() call per
--     table. Not being in it is what makes a table's rows the extension's.
--   * percolate.table_kinds.kind = 'vocabulary' is the extension's own
--     classification of what a table HOLDS -- twenty of them say it.
--
-- Both are needed. extconfig alone pulls in content.channels and
-- workflow.definitions, which are entity tables keyed by uuidv7() with
-- created_at defaults: their seeded rows can never hash equal between two
-- databases created at different moments, so they would make this section
-- permanently red and teach everyone to ignore it. A vocabulary is keyed by
-- what it means -- a state name, a relation, a provider -- so the same
-- vocabulary IS the same bytes, which is what makes the comparison sound.
--
-- Hashed per table rather than emitted per row: the diff has to NAME the table
-- whose contents moved, and a vocabulary is small enough that the hash is the
-- whole answer.
--
-- EVERY COLUMN EXCEPT THE CLOCK. registered_at timestamptz default now() and
-- its siblings record WHEN a row was written, and the two databases here are
-- written seconds apart by construction -- so comparing them would make this
-- section permanently red over a difference that is not a difference. Measured
-- rather than assumed: with select * all five vocabularies differed, and the
-- whole of it was one trailing timestamp per row.
--
-- The columns are chosen by their DEFAULT rather than by name or type, so a
-- vocabulary that genuinely carries a meaningful date is still compared; only
-- one defaulted to a clock read is dropped. A default is a short mechanical
-- expression, which is what makes matching on its text sound here.
select 'voc '||tbl||' '||md5(x::text)
  from (select n.nspname||'.'||c.relname as tbl
          from pg_depend d
          join pg_class c on c.oid = d.objid
          join pg_namespace n on n.oid = c.relnamespace
          join percolate.table_kinds k
            on k.schema_name = n.nspname and k.table_name = c.relname
         where d.classid = 'pg_class'::regclass and d.deptype = 'e'
           and c.relkind = 'r'
           and n.nspname in $S
           and k.kind = 'vocabulary'
           and not exists (select 1 from pg_extension e
                            where c.oid = any(e.extconfig))) t,
       lateral (select string_agg(quote_ident(a.attname), ', ' order by a.attnum) as cols
                  from pg_attribute a
                  left join pg_attrdef ad
                         on ad.adrelid = a.attrelid and ad.adnum = a.attnum
                 where a.attrelid = t.tbl::regclass
                   and a.attnum > 0 and not a.attisdropped
                   and coalesce(pg_get_expr(ad.adbin, ad.adrelid), '')
                       !~* 'now[(][)]|current_timestamp|clock_timestamp') cc,
       -- ORDERED BY EVERY COMPARED COLUMN, not by the first one. ORDER BY 1
       -- is ambiguous the moment two rows share it -- percolate.table_kinds is
       -- keyed (schema_name, table_name), so ordering by schema_name alone
       -- leaves the row order to the heap, and a fresh install and an upgraded
       -- one hand it back differently. That reported percolate.table_kinds as
       -- DIVERGED over two byte-identical tables, which is a check crying wolf
       -- rather than a defect.
       lateral query_to_xml(format('select %s from %s order by %s',
                                   cc.cols, tbl, cc.cols),
                            true, true, '') as x
order by 1;"
}

fresh=$(mktemp); upg=$(mktemp)
trap 'rm -f "$OLD_SQL" "$fresh" "$upg" ${REPLAY_TMP:+"$REPLAY_TMP"}' EXIT
S_FRESH=$(ext_schemas docker exec -i "$CONTAINER" psql -U p8 -d p8conv_fresh)
S_UPG=$(ext_schemas docker exec -i "$CONTAINER" psql -U p8 -d p8conv_upg)
docker exec -i "$CONTAINER" psql -U p8 -d p8conv_fresh -tAc "$(snap "$S_FRESH")" > "$fresh"
docker exec -i "$CONTAINER" psql -U p8 -d p8conv_upg   -tAc "$(snap "$S_UPG")" > "$upg"

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
