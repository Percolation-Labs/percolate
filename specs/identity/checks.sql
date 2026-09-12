-- IDENTITY AND NULLABILITY: the gate.
--
--     psql "$DSN" -f specs/identity/checks.sql
--
-- Five assertions over the catalogue. Exits nonzero, so it is a gate rather
-- than a report. Like surface.sql, each failure names the promise it breaks
-- rather than only the object.
--
-- Check 3 is the one that carries the policy. It does not decide what a NULL
-- means -- it refuses to let the schema stay silent about it.
--
-- Check 5 is the one case where the policy DID decide, so the check is an
-- equality rather than a question: spec.md §4 ruled that the shared tier is a
-- row, so no org_id anywhere may be nullable.
\set ON_ERROR_STOP on
\pset pager off

-- Every schema is percolate.extension_schemas(), read from pg_depend, rather
-- than the list of six this file carried five times (REM-45).
create temporary view p8_tables as
select n.nspname as sch, c.relname as tbl, c.oid
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where c.relkind in ('r','p')
  and n.nspname in (select percolate.extension_schemas());

\echo ''
\echo '=== 1. EVERY TABLE DECLARES WHAT KIND OF THING IT IS ==='
\echo '    entity needs a surrogate uuid; vocabulary is keyed by its term;'
\echo '    junction by its foreign keys; a log by a monotonic bigint. The'
\echo '    first draft of this check demanded a uuid everywhere and fired on'
\echo '    twenty correct designs, which is how a gate gets switched off.'
\echo '    percolate.table_kind_proposal will guess; you still declare.'
select t.sch, t.tbl, p.proposed_kind as proposal
from p8_tables t
left join percolate.table_kinds k on k.schema_name = t.sch and k.table_name = t.tbl
left join percolate.table_kind_proposal p on p.schema_name = t.sch and p.table_name = t.tbl
where k.kind is null
order by 1, 2;

\echo ''
\echo '=== 2. THE PRIMARY KEY MATCHES THE DECLARED KIND ==='
with pk as (
    select t.sch, t.tbl, t.oid,
           array_agg(a.attname::text order by a.attnum) as cols,
           array_agg(format_type(a.atttypid, null) order by a.attnum) as types,
           bool_and(exists (select 1 from pg_constraint fk
                            where fk.conrelid = t.oid and fk.contype = 'f'
                              and a.attnum = any(fk.conkey))) as all_fk
    from p8_tables t
    join pg_index x on x.indrelid = t.oid and x.indisprimary
    join pg_attribute a on a.attrelid = t.oid and a.attnum = any(x.indkey::int[])
    group by t.sch, t.tbl, t.oid)
select pk.sch, pk.tbl, k.kind, pk.cols, pk.types,
       case
         when k.kind = 'entity'
              and not (pk.cols = array['id']::text[] and pk.types = array['uuid']::text[])
              then 'an entity is referenced by other rows and its natural key may change: it needs a surrogate id uuid'
         when k.kind = 'entity'
              and exists (select 1 from pg_attrdef d
                          where d.adrelid = pk.oid
                            and pg_get_expr(d.adbin, d.adrelid) ~ 'gen_random_uuid|uuidv4')
              then 'random v4 primary key: uuidv7() is time-ordered and PG19 ships it'
         when k.kind = 'junction' and not coalesce(pk.all_fk, false)
              then 'declared a junction but its key is not made only of foreign keys'
         when k.kind = 'log' and not (pk.types[1] ~ 'int')
              then 'declared a log but its key is not a monotonic integer'
       end as problem
from pk
join percolate.table_kinds k on k.schema_name = pk.sch and k.table_name = pk.tbl
where case
        when k.kind = 'entity' then
             not (pk.cols = array['id']::text[] and pk.types = array['uuid']::text[])
             or exists (select 1 from pg_attrdef d where d.adrelid = pk.oid
                        and pg_get_expr(d.adbin, d.adrelid) ~ 'gen_random_uuid|uuidv4')
        when k.kind = 'junction' then not coalesce(pk.all_fk, false)
        when k.kind = 'log' then not (pk.types[1] ~ 'int')
        else false end
order by 1, 2;

\echo ''
\echo '=== 3. EVERY UNIQUE INDEX OVER A NULLABLE COLUMN DECLARES ITS INTENT ==='
\echo '    A NULL that means a VALUE needs NULLS NOT DISTINCT; one that means'
\echo '    an ABSENCE needs NULLS DISTINCT. Undeclared is the failure: nobody,'
\echo '    human or agent, can tell them apart from the schema.'
with u as (
    select t.sch, t.tbl, i.relname as idx, a.attname as col, x.indnullsnotdistinct as nnd
    from p8_tables t
    join pg_index x on x.indrelid = t.oid and x.indisunique
    join pg_class i on i.oid = x.indexrelid
    join pg_attribute a on a.attrelid = t.oid and a.attnum = any(x.indkey::int[])
                       and not a.attnotnull)
select u.sch, u.tbl, u.idx, u.col,
       case when m.means is null then 'undeclared -- add a percolate.null_means row'
            when m.means = 'value'   and not u.nnd
                 then 'declared a VALUE but the index is NULLS DISTINCT, so it constrains nothing for that value'
            when m.means = 'absence' and u.nnd
                 then 'declared an ABSENCE but the index is NULLS NOT DISTINCT, so two rows that are both simply unknown collide'
       end as problem
from u
left join percolate.null_means m
       on m.schema_name = u.sch and m.table_name = u.tbl and m.column_name = u.col
where m.means is null
   or (m.means = 'value' and not u.nnd)
   or (m.means = 'absence' and u.nnd)
order by 1, 2, 3, 4;

\echo ''
\echo '=== 4. NO DERIVED-ID FUNCTION IS A BARE HASH CAST ==='
\echo '    md5(x)::uuid produces version 0, which is not a UUID version and'
\echo '    will not compare equal to a correctly generated v5.'
select n.nspname || '.' || p.proname as fn
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
-- `selfmodel` by name as well: it is the self-model application's schema, not
-- the extension's, and it derives ids too, so a database carrying it is held to
-- the same rule. Absent, it matches nothing.
where (n.nspname in (select percolate.extension_schemas()) or n.nspname = 'selfmodel')
  -- COMMENTS STRIPPED FIRST. The unstripped version matched the note that
  -- documents this very fix -- `md5(...)::uuid` written in prose inside the
  -- function that had already been corrected. A source-scanning check that
  -- cannot tell code from commentary reports the remedy as the defect.
  and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~ 'md5\s*\([^)]*\)\s*::\s*uuid'
order by 1;

\echo ''
\echo '=== 4b. NOR IS A GENERATED COLUMN, AND A SOURCE SCAN CANNOT SEE ONE ==='
\echo '    4 reads pg_proc. aiq.db_objects.id was added as md5(ident)::uuid two'
\echo '    days after the rule, in a GENERATED COLUMN, and passed (REM-58).'
\echo '    No regex here: a generated expression is one mechanical expression,'
\echo '    so naming md5 at all is the finding.'
select c.relnamespace::regnamespace || '.' || c.relname || '.' || a.attname as col,
       pg_get_expr(d.adbin, d.adrelid) as expression
  from pg_attrdef d
  join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
  join pg_class c on c.oid = d.adrelid
  join pg_namespace n on n.oid = c.relnamespace
 where a.attgenerated <> ''
   and (n.nspname in (select percolate.extension_schemas()) or n.nspname = 'selfmodel')
   and pg_get_expr(d.adbin, d.adrelid) ilike '%md5%'
 order by 1;

\echo ''
\echo '=== 4c. AND THE ROWS THEMSELVES CARRY VERSION 5 ==='
\echo '    The exact form of the same question, and the one nothing can hide'
\echo '    from: whatever the expression looks like, a derived id that is not'
\echo '    version 5 is not the value a client recomputing it would get.'
\echo '    Reads data rather than source, so it needs no pattern at all.'
do $$
declare r record; v int; bad text[] := '{}';
begin
    for r in
        select c.relnamespace::regnamespace::text as sch, c.relname as tbl, a.attname as col
          from pg_attribute a
          join pg_class c on c.oid = a.attrelid
          join pg_namespace n on n.oid = c.relnamespace
         where a.attgenerated <> '' and a.atttypid = 'uuid'::regtype
           and (n.nspname in (select percolate.extension_schemas())
                or n.nspname = 'selfmodel')
    loop
        -- One row is enough: the expression is the same for all of them.
        execute format(
            'select uuid_extract_version(%I) from %I.%I where %I is not null limit 1',
            r.col, r.sch, r.tbl, r.col) into v;
        if v is not null and v <> 5 then
            bad := bad || format('%s.%s.%s holds version %s', r.sch, r.tbl, r.col, v);
        end if;
    end loop;
    if array_length(bad, 1) > 0 then
        raise warning 'derived ids that are not v5: %', array_to_string(bad, ', ');
    else
        raise notice 'every generated uuid column with rows in it holds version 5';
    end if;
end $$;

\echo ''
\echo '=== 5. NO org_id IS NULLABLE, AND EVERY ONE DEFAULTS TO THE SHARED ORG ==='
\echo '    spec.md §4: the shared tier is a ROW (rbac.shared_org_id()), not a'
\echo '    NULL. This is the check that makes a seventeenth org_id column'
\echo '    impossible to add and forget -- fourteen of them get it from'
\echo '    rbac.add_scope_columns(), two ask for it by hand, and a new one'
\echo '    that does neither shows up here rather than in a duplicate row.'
\echo '    Fix: select rbac.adopt_shared_org(''<schema>.<table>'');'
select n.nspname as sch, c.relname as tbl,
       case when not a.attnotnull then 'nullable'
            else 'default is ' || coalesce(pg_get_expr(d.adbin, d.adrelid), 'absent')
       end as finding
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
join pg_attribute a on a.attrelid = c.oid and a.attname = 'org_id'
                   and not a.attisdropped
left join pg_attrdef d on d.adrelid = c.oid and d.adnum = a.attnum
where c.relkind in ('r','p')
  and n.nspname in (select percolate.extension_schemas())
  -- rbac.org_members is the one table whose org_id is the tenancy itself
  -- rather than a scope on a row: it has always been NOT NULL, it must NOT
  -- default to the shared org (org_members_not_shared forbids that row), and a
  -- membership with no org is not a thing.
  and not (n.nspname = 'rbac' and c.relname = 'org_members')
  and (not a.attnotnull
       or coalesce(pg_get_expr(d.adbin, d.adrelid), '') !~ 'shared_org_id')
order by 1, 2;

do $$
declare v1 int; v2 int; v3 int; v4 int; v5 int;
begin
    select count(*) into v1 from p8_tables t
     left join percolate.table_kinds k on k.schema_name = t.sch and k.table_name = t.tbl
     where k.kind is null;

    with pk as (
        select t.sch, t.tbl, t.oid,
               array_agg(a.attname::text order by a.attnum) as cols,
               array_agg(format_type(a.atttypid, null) order by a.attnum) as types,
               bool_and(exists (select 1 from pg_constraint fk
                                where fk.conrelid = t.oid and fk.contype = 'f'
                                  and a.attnum = any(fk.conkey))) as all_fk
        from p8_tables t
        join pg_index x on x.indrelid = t.oid and x.indisprimary
        join pg_attribute a on a.attrelid = t.oid and a.attnum = any(x.indkey::int[])
        group by t.sch, t.tbl, t.oid)
    select count(*) into v2 from pk
      join percolate.table_kinds k on k.schema_name = pk.sch and k.table_name = pk.tbl
     where case
             when k.kind = 'entity' then
                  not (pk.cols = array['id']::text[] and pk.types = array['uuid']::text[])
                  or exists (select 1 from pg_attrdef d where d.adrelid = pk.oid
                             and pg_get_expr(d.adbin, d.adrelid) ~ 'gen_random_uuid|uuidv4')
             when k.kind = 'junction' then not coalesce(pk.all_fk, false)
             when k.kind = 'log' then not (pk.types[1] ~ 'int')
             else false end;

    with u as (
        select t.sch, t.tbl, a.attname::text as col, x.indnullsnotdistinct as nnd
        from p8_tables t
        join pg_index x on x.indrelid = t.oid and x.indisunique
        join pg_attribute a on a.attrelid = t.oid and a.attnum = any(x.indkey::int[])
                           and not a.attnotnull)
    select count(*) into v3 from u
     left join percolate.null_means m
            on m.schema_name = u.sch and m.table_name = u.tbl and m.column_name = u.col
     where m.means is null or (m.means = 'value' and not u.nnd)
        or (m.means = 'absence' and u.nnd);

    select count(*) into v4 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname in (select percolate.extension_schemas()) or n.nspname = 'selfmodel')
       and regexp_replace(p.prosrc, '--[^\n]*', '', 'g')
           ~ 'md5\s*\([^)]*\)\s*::\s*uuid';

    -- 4b counts into the same verdict: a generated column deriving an id is
    -- the same defect as a function doing it, and was invisible only because
    -- the query above cannot see one.
    v4 := v4 + (select count(*)
                  from pg_attrdef d
                  join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
                  join pg_class c on c.oid = d.adrelid
                  join pg_namespace n on n.oid = c.relnamespace
                 where a.attgenerated <> ''
                   and (n.nspname in (select percolate.extension_schemas())
                        or n.nspname = 'selfmodel')
                   and pg_get_expr(d.adbin, d.adrelid) ilike '%md5%');

    select count(*) into v5
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      join pg_attribute a on a.attrelid = c.oid and a.attname = 'org_id'
                         and not a.attisdropped
      left join pg_attrdef d on d.adrelid = c.oid and d.adnum = a.attnum
     where c.relkind in ('r','p')
       and n.nspname in (select percolate.extension_schemas())
       and not (n.nspname = 'rbac' and c.relname = 'org_members')
       and (not a.attnotnull
            or coalesce(pg_get_expr(d.adbin, d.adrelid), '') !~ 'shared_org_id');

    raise notice '';
    raise notice 'IDENTITY: % tables undeclared, % keys disagreeing with their kind, % undeclared/disagreeing nulls, % hash casts, % org_id columns still nullable or undefaulted',
        v1, v2, v3, v4, v5;

    if v1 + v2 + v3 + v4 + v5 > 0 then
        raise exception
            'IDENTITY POLICY NOT MET: % findings. specs/identity/spec.md says '
            'why each one costs something, and §8 says the order to fix them in.',
            v1 + v2 + v3 + v4 + v5;
    end if;
    raise notice 'IDENTITY POLICY MET';
end $$;
