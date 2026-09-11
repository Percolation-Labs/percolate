#!/usr/bin/env bash
# Is the database RUNNING what the specs SAY?
#
# `../surface.sql` asks whether every declared capability EXISTS. That is a
# different question from whether it is CURRENT, and only the first one was
# ever audited -- so a function whose body had fallen behind its spec passed a
# clean surface audit while raising `unhandled mode SCHEMA` at runtime, and the
# six step features missing from the built .so passed it too. Existence is not
# currency, and drift is silent in exactly the direction that matters: the
# database keeps answering, with the old answer.
#
# The method is to let Postgres do the parsing rather than regex the SQL:
# build a pristine database from the committed extension script, then diff
# pg_proc against the target. Anything textual would have to re-implement
# dollar-quoting, and would be wrong about the nested $q$/$f$ tags this schema
# actually uses.
#
#   ./currency.sh                       # against the compose stack
#   TARGET_DB=p8other ./currency.sh
set -euo pipefail

CONTAINER="${CONTAINER:-p8-dev-db}"
TARGET_DB="${TARGET_DB:-p8dev}"
REF_DB="${REF_DB:-p8currency_ref}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read the version rather than restate it, because a bump RENAMES the script --
# percolate.control's default_version is the filename, so a literal here is a
# file-not-found on the first release. build-image.sh and reload.sh already do
# it this way; this line did not, and 0.1.1 broke it.
VERSION=$(sed -n "s/^default_version = '\(.*\)'/\1/p" "$HERE/../extension/percolate/percolate.control")
[ -n "$VERSION" ] || { echo "no default_version in percolate.control" >&2; exit 1; }
SCRIPT="$HERE/../extension/percolate/sql/percolate--$VERSION.sql"
[ -f "$SCRIPT" ] || { echo "missing $SCRIPT -- run extension/percolate/build-sql.py" >&2; exit 1; }

q() { docker exec -i "$CONTAINER" psql -U p8 -d "$1" -tAqc "$2"; }

echo "==> building a pristine reference database from $(basename "$SCRIPT")"
docker exec "$CONTAINER" psql -U p8 -d postgres -q \
    -c "drop database if exists $REF_DB;" -c "create database $REF_DB;" >/dev/null
docker cp "$HERE/image-init/00-superuser.sql" "$CONTAINER:/tmp/00-superuser.sql" >/dev/null
docker exec "$CONTAINER" psql -U p8 -d "$REF_DB" -v ON_ERROR_STOP=1 -q \
    -f /tmp/00-superuser.sql >/dev/null
docker exec -i "$CONTAINER" psql -U p8 -d "$REF_DB" -v ON_ERROR_STOP=1 -q \
    -c "set role app_owner;" -f - < "$SCRIPT" >/dev/null

# The comparable identity of a function is its schema, name, argument types,
# body, security mode and search_path -- not its OID, and not its comments.
# prosecdef and proconfig are in here deliberately: `SECURITY DEFINER` silently
# reverting to INVOKER is a privilege change that a body-only diff would miss,
# and it is exactly what rbac.has_permission's recursion turned on.
#
# EVERY SCHEMA THE EXTENSION CREATES, and `agentic` was missing from this list
# for its whole life -- sixteen shipped functions, the entire conversation
# plane, invisible to the one check whose job is noticing that a body has
# fallen behind its spec. It is the newest of the five and the list was written
# before it existed, which is the ordinary way a hand-maintained enumeration
# goes wrong. Checked against the source of truth with:
#
#     grep -o '^create schema if not exists [a-z_]*' \
#          extension/percolate/sql/percolate--*.sql | sort -u
#
# `tradecraft` and `extract` are NOT shipped (build-sql.py's NOT_SHIPPED) and
# stay in deliberately: a dev database that loaded one by hand should be told
# so, and the reference database never has them, so they can only ever surface
# as ORPHAN -- which is the report those files want.
SNAP="select n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')'
             ||E'\t'||md5(p.prosrc)
             ||E'\t'||p.prosecdef
             ||E'\t'||coalesce(array_to_string(p.proconfig,','),'-')
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('workflow','rbac','aiq','content','agentic','tradecraft','extract')
      order by 1;"

ref=$(q "$REF_DB" "$SNAP")
tgt=$(q "$TARGET_DB" "$SNAP")

echo "==> comparing $TARGET_DB against the specs ($(printf '%s' "$ref" | wc -l | tr -d ' ') functions declared)"
drift=0

# Present in the specs, absent or different in the target.
while IFS=$'\t' read -r sig hash secdef cfg; do
    [ -z "$sig" ] && continue
    line=$(printf '%s\n' "$tgt" | grep -F "$sig"$'\t' || true)
    if [ -z "$line" ]; then
        echo "  MISSING   $sig"; drift=1; continue
    fi
    thash=$(printf '%s' "$line" | cut -f2)
    tsec=$(printf '%s' "$line" | cut -f3)
    tcfg=$(printf '%s' "$line" | cut -f4)
    [ "$thash" != "$hash" ] && { echo "  STALE     $sig -- body differs from the spec"; drift=1; }
    [ "$tsec" != "$secdef" ] && { echo "  SECURITY  $sig -- prosecdef $tsec, spec says $secdef"; drift=1; }
    [ "$tcfg" != "$cfg" ] && { echo "  SEARCHPATH $sig -- '$tcfg', spec says '$cfg'"; drift=1; }
done <<< "$ref"

# Present in the target and not in the specs. Not fatal on its own -- a dev
# stack legitimately carries fixtures -- but reported, because an orphan left
# by a signature change is how the old body keeps answering.
while IFS=$'\t' read -r sig _; do
    [ -z "$sig" ] && continue
    printf '%s\n' "$ref" | grep -qF "$sig"$'\t' || echo "  ORPHAN    $sig -- in the database, not in the specs"
done <<< "$tgt"

docker exec "$CONTAINER" psql -U p8 -d postgres -q -c "drop database if exists $REF_DB;" >/dev/null

echo
if [ "$drift" -ne 0 ]; then
    echo "DRIFTED -- the database is not running what the specs say."
    echo "Reload the changed objects, or rebuild the stack."
    exit 1
fi
echo "CURRENT -- every function in the specs is installed, with the same body,"
echo "security mode and search_path."
