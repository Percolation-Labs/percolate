# Sourced, not run. The one place a shell gate learns which schemas are the
# percolate extension's.
#
#     . "$(dirname "$0")/lib/extension-schemas.sh"
#     S=$(ext_schemas docker exec -i "$CONTAINER" psql -U p8 -d "$DB")
#     ... where n.nspname in $S ...
#
# `ext_schemas` takes the psql command for one database and prints a SQL
# subquery to put after `in`. On a database that has percolate.extension_schemas()
# (identity/schema.sql, 0.2.0 on) it is a call to that function, which is what
# every gate reads. On an older one -- dev/currency.sh's target is whatever it
# is pointed at -- it is the same pg_depend query inline, below, because the
# function cannot be called where it was never installed and pg_depend has
# recorded extension membership in every Postgres there is.
#
# WHY THIS EXISTS: 25 to 40 hand-typed lists of "the extension's schemas" in
# about seven spellings, none of them complete. upgrade-converges.sh had eight
# copies and none named `percolate`, so no percolate.* object or grant had ever
# been compared across an upgrade
# (REM-45).
#
# TWO REFUSALS, so a gate cannot pass by looking at nothing:
#   * an empty set. A database where nothing belongs to the extension -- a
#     script loaded with psql -f, or no percolate at all -- would give every
#     comparison zero rows on both sides, and zero equals zero.
#   * the function and the inline copy disagreeing. The copy below is a second
#     statement of the function's body, so wherever both exist they are asked
#     and compared, so the copy cannot fall behind without a run saying so.

# shellcheck disable=SC2034  # read by the scripts that source this file
EXT_SCHEMAS_INLINE="(select n.nspname from pg_catalog.pg_depend d
    join pg_catalog.pg_namespace n on n.oid = d.objid
   where d.classid = 'pg_catalog.pg_namespace'::pg_catalog.regclass
     and d.refclassid = 'pg_catalog.pg_extension'::pg_catalog.regclass
     and d.refobjid = (select x.oid from pg_catalog.pg_extension x where x.extname = 'percolate')
     and d.deptype = 'e')"

ext_schemas() {
    local has inline fn
    has=$("$@" -tAc "select to_regprocedure('percolate.extension_schemas()') is not null") || return 1
    inline=$("$@" -tAc "select string_agg(s::text, ',' order by s) from $EXT_SCHEMAS_INLINE x(s)") || return 1
    if [ -z "$inline" ]; then
        echo "ext_schemas: no schema belongs to the percolate extension in this database" \
             "-- was it installed with CREATE EXTENSION? A gate reading an empty set" \
             "compares nothing and passes." >&2
        return 1
    fi
    if [ "$has" = "t" ]; then
        fn=$("$@" -tAc "select string_agg(s::text, ',' order by s) from percolate.extension_schemas() f(s)") || return 1
        if [ "$fn" != "$inline" ]; then
            echo "ext_schemas: percolate.extension_schemas() says {$fn} and the inline" \
                 "copy in dev/lib/extension-schemas.sh says {$inline}. One of them has" \
                 "changed; make them agree." >&2
            return 1
        fi
        echo "(select percolate.extension_schemas())"
    else
        echo "$EXT_SCHEMAS_INLINE"
    fi
}
