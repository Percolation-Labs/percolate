-- IDENTITY AND NULLABILITY: the gate.
--
--     psql "$DSN" -f specs/identity/checks.sql
--
-- Four assertions over the catalogue. Exits nonzero, so it is a gate rather
-- than a report. Like surface.sql, each failure names the promise it breaks
-- rather than only the object.
--
-- Check 3 is the one that carries the policy. It does not decide what a NULL
-- means -- it refuses to let the schema stay silent about it.
\set ON_ERROR_STOP on
\pset pager off

create temporary view p8_tables as
select n.nspname as sch, c.relname as tbl, c.oid
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where c.relkind in ('r','p')
  and n.nspname in ('aiq','rbac','workflow','content','agentic','percolate');

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
where n.nspname in ('aiq','rbac','workflow','content','agentic','percolate','selfmodel')
  -- COMMENTS STRIPPED FIRST. The unstripped version matched the note that
  -- documents this very fix -- `md5(...)::uuid` written in prose inside the
  -- function that had already been corrected. A source-scanning check that
  -- cannot tell code from commentary reports the remedy as the defect.
  and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~ 'md5\s*\([^)]*\)\s*::\s*uuid'
order by 1;

do $$
declare v1 int; v2 int; v3 int; v4 int;
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
     where n.nspname in ('aiq','rbac','workflow','content','agentic','percolate','selfmodel')
       and regexp_replace(p.prosrc, '--[^\n]*', '', 'g')
           ~ 'md5\s*\([^)]*\)\s*::\s*uuid';

    raise notice '';
    raise notice 'IDENTITY: % tables undeclared, % keys disagreeing with their kind, % undeclared/disagreeing nulls, % hash casts',
        v1, v2, v3, v4;

    if v1 + v2 + v3 + v4 > 0 then
        raise exception
            'IDENTITY POLICY NOT MET: % findings. specs/identity/spec.md says '
            'why each one costs something, and §8 says the order to fix them in.',
            v1 + v2 + v3 + v4;
    end if;
    raise notice 'IDENTITY POLICY MET';
end $$;
