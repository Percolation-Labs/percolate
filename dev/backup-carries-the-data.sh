#!/usr/bin/env bash
# Would a backup of this database contain anything?
#
#     CONTAINER=p8-ci dev/backup-carries-the-data.sh
#
# `pg_dump` DOES NOT DUMP THE DATA OF AN EXTENSION'S TABLES. It writes `CREATE
# EXTENSION percolate` and stops, on the reasoning that an extension recreates
# its own contents -- correct for a vocabulary, catastrophic for a table holding
# somebody's users. pg_extension_config_dump() is the escape hatch, and
# `specs/contract/schema.sql` §4 registers every table whose rows are the
# deployment's.
#
# WHAT THIS ASSERTS, and it is deliberately the derived half rather than the
# list: on a FROM-ZERO install, every table belonging to the extension that is
# EMPTY holds no rows of its own, so any row it ever holds came from the
# deployment -- and it must therefore be registered. A table added next month
# without a registration fails here on the day it is added, which is the only
# moment anybody could reasonably be expected to notice.
#
# It is a bare install rather than $DB on purpose: "empty" is only meaningful
# before seeds and before use, and that is exactly the state in which shipped
# rows are already present and deployment rows cannot be.
#
# WHY IT IS A GATE AND NOT A NOTE. Measured before any of this existed: 52
# tables belonged to the extension, two were registered, and a pg_dump of a
# seeded database emitted COPY for neither rbac.users, workflow.definitions,
# agentic.agents, aiq.nodes nor content.resources. Every backup this collection
# has ever produced contained the schema and nothing else. That is an incident,
# not a risk.
set -euo pipefail
cd "$(dirname "$0")/.."

CONTAINER="${CONTAINER:-p8-dev-db}"
BARE="${BARE:-p8bare_check}"
SU="${SUPERUSER:-p8}"

docker exec -i "$CONTAINER" psql -U "$SU" -d postgres -q \
    -c "drop database if exists $BARE (force);" -c "create database $BARE;" >/dev/null 2>&1

# No dev/init seeds, no pg_cron: the image's superuser step, the extension and
# nothing else.
docker cp dev/image-init/00-superuser.sql "$CONTAINER:/tmp/00-superuser.sql" >/dev/null
docker exec -i "$CONTAINER" psql -U "$SU" -d "$BARE" -v ON_ERROR_STOP=1 -q >/dev/null 2>&1 <<'SQL'
\i /tmp/00-superuser.sql
set role app_owner;
create extension percolate cascade;
reset role;
SQL

out=$(docker exec "$CONTAINER" psql -U "$SU" -d "$BARE" -v ON_ERROR_STOP=1 -tAc "
do \$\$
declare
    r record; n bigint; missing text := ''; total int := 0; registered int := 0;
    unclassified text := '';
begin
    for r in
        select nn.nspname as s, c.relname as t, c.oid, k.kind,
               (c.oid = any (coalesce((select extconfig from pg_extension
                                        where extname='percolate'), '{}'))) as is_reg
          from pg_depend d
          join pg_class c on c.oid = d.objid
          join pg_namespace nn on nn.oid = c.relnamespace
          join pg_extension x on x.oid = d.refobjid
          left join percolate.table_kinds k
                 on k.schema_name = nn.nspname and k.table_name = c.relname
         where d.deptype = 'e' and x.extname = 'percolate' and c.relkind = 'r'
         order by 1, 2
    loop
        total := total + 1;
        if r.is_reg then registered := registered + 1; end if;
        execute format('select count(*) from %I.%I', r.s, r.t) into n;
        -- Empty on a from-zero install: every row it will ever hold is the
        -- deployment's, so pg_dump has to be told to carry them.
        if n = 0 and not r.is_reg then
            missing := missing || '  ' || r.s || '.' || r.t || E'\n';
        end if;
        -- AND THE ONES THAT ARE NOT EMPTY, which is where this gate was blind.
        --
        -- The rule above only ever asked about EMPTY tables, so a table holding
        -- the extension's rows AND the deployment's was never examined -- and
        -- two of them were unregistered. content.channels seeds uploads and
        -- workflow_artifacts, so it is never empty, and pg_dump carried every
        -- content.resources row and none of the channels they reference.
        -- workflow.definitions seeds the shipped workflows, so it is never
        -- empty either, and workflow.runs IS registered and has a foreign key
        -- to it: a dump held the runs and not the definitions they name.
        -- Measured on a live install -- 6 definitions, 4 channels, and 0 COPY
        -- lines for either.
        --
        -- So the second question, and it uses no list: every table belonging to
        -- the extension is either REGISTERED (the deployment writes here) or
        -- declared vocabulary in percolate.table_kinds (the extension owns
        -- every row). Both facts the extension already records, and the pair is
        -- exhaustive by construction -- a table that is neither has not been
        -- classified, and an unclassified table is the one nobody thought about.
        -- On the tree this was written against it named exactly two, and both
        -- were real.
        if not r.is_reg and coalesce(r.kind, 'x') <> 'vocabulary' then
            unclassified := unclassified || '  ' || r.s || '.' || r.t
                         || ' (kind=' || coalesce(r.kind, 'undeclared') || ')' || E'\n';
        end if;
    end loop;

    if missing <> '' then
        raise exception E'these tables belong to the extension, are EMPTY on a from-zero install, and are not registered with pg_extension_config_dump() -- so every row a deployment ever puts in them is silently absent from every pg_dump:\n\n%\nRegister them in specs/contract/schema.sql section 4.', missing;
    end if;
    if unclassified <> '' then
        raise exception E'these tables belong to the extension, are not registered with pg_extension_config_dump(), and are not declared kind=''vocabulary'' -- so nobody has said whose rows they hold, and pg_dump is silently dropping them:\n\n%\nEither register them in specs/contract/schema.sql section 4 (the deployment writes here) or declare them a vocabulary in specs/identity/declarations.sql (the extension owns every row).', unclassified;
    end if;
    raise notice 'backup: % of % extension tables registered; every table a deployment writes to is carried by pg_dump, and every one that is not is a declared vocabulary', registered, total;
end \$\$;" 2>&1) || { echo "$out" | sed 's/^/  /' >&2; exit 1; }

docker exec -i "$CONTAINER" psql -U "$SU" -d postgres -q \
    -c "drop database if exists $BARE (force);" >/dev/null 2>&1
echo "${out#NOTICE:  }"
