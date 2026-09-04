-- THE BATCH J2 FANS OUT OVER, and nothing else.
--
--     docker exec -i p8-experiment-pg19 psql -U p8 -d p8journey -v ON_ERROR_STOP=1 \
--         < dev/tests/journeys/materials-j2.sql
--
-- Same split as materials.sql: this holds what the cast acts ON. The workflow,
-- the registered row source, the plugin and the agent are all things a person
-- does, so J2 does them.
--
-- WHY A TABLE RATHER THAN PROSE. J1's material is five documents with content
-- worth reading, because J1 is about retrieval. J2 is about doing the same
-- thing forty times: what a matrix fans out over, what a template substitutes
-- per row, and what a gate decides when some of them fail. So the rows are
-- deliberately dull and deliberately UNEVEN -- the interesting question is
-- never "did it process one", it is "what did it do about the ones that are
-- not like the others".
--
-- THREE THINGS IN HERE ARE DESIGNED TO FAIL, and they are the point:
--
--   * two applications carry `site_ref = null`. A template that substitutes a
--     null into a query is the difference between a child that errors and a
--     child that quietly does the wrong thing, and the matrix gate is what
--     decides whether the successor runs anyway.
--   * one carries a site_ref with a quote in it (`o'brien-yard`). A template
--     is a VALUE, not SQL text -- workflow-engine/schema.sql says so and
--     dev/tests/workflow/13 asserts it -- and this is the row that finds out.
--   * one is `withdrawn`, which the row source must exclude. A fan-out whose
--     source returns rows nobody wanted is a fan-out that costs money to
--     discover.
--
-- GRANTED TO NOBODY, for the reason materials.sql states at length: a table
-- granted to an application role and carrying no policy is exactly the defect
-- dev/tests/rbac/05 enumerates for.

\set ON_ERROR_STOP on

do $$
begin
    if to_regclass('workflow.step_functions') is null then
        raise exception
            'this database has no workflow engine, so the J2 batch would be '
            'unusable. Build a journey database the way '
            'dev/tests/journeys/README.md says: dev/reload.sh p8journey';
    end if;
end $$;

set role app_owner;

create schema if not exists journey;

drop table if exists journey.applications cascade;
create table journey.applications (
    ref         text primary key,
    site_ref    text,                 -- NULL on two rows, on purpose
    kind        text not null,
    status      text not null,        -- one is 'withdrawn'
    received_on date not null
);

-- Thirty-eight ordinary rows plus the four that are not, which is the shape a
-- real batch has: the awkward cases are a handful, they are never at the front,
-- and a fan-out tested on the first three rows finds none of them.
insert into journey.applications (ref, site_ref, kind, status, received_on)
select
    'PA/2026/' || lpad(n::text, 4, '0'),
    case n when 17 then null
           when 31 then null
           when 24 then 'o''brien-yard'
           else 'site-' || lpad(n::text, 3, '0') end,
    (array['householder','full','listed-building','advertisement'])[1 + (n % 4)],
    case n when 9 then 'withdrawn' else 'valid' end,
    date '2026-09-01' + (n % 5)
from generate_series(1, 42) n;

-- The batch asserts its own shape, because a journey that fans out over rows
-- which turned out to be uniform proves nothing about a gate -- the failure
-- meta/postmortems/2026-09-04-query-layer-at-scale.md §2 calls being degenerate
-- in the dimension the thing under test depends on.
do $$
declare v_null int; v_quote int; v_withdrawn int; v_kinds int;
begin
    select count(*) filter (where site_ref is null),
           count(*) filter (where site_ref like '%''%'),
           count(*) filter (where status = 'withdrawn'),
           count(distinct kind)
      into v_null, v_quote, v_withdrawn, v_kinds
      from journey.applications;
    if v_null <> 2 or v_quote <> 1 or v_withdrawn <> 1 or v_kinds < 4 then
        raise exception
            'the J2 batch is not the shape its journey assumes: % null site_refs '
            '(want 2), % quoted (want 1), % withdrawn (want 1), % kinds (want 4+). '
            'Every act about gates and quoting reads a uniform batch as a pass.',
            v_null, v_quote, v_withdrawn, v_kinds;
    end if;
end $$;

revoke all on schema journey from public;
revoke all on all tables in schema journey from public;

do $$
declare v_leaked text;
begin
    select string_agg(c.relname, ', ') into v_leaked
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'journey'
       and (has_table_privilege('authenticated', c.oid, 'select')
            or has_table_privilege('web_anon', c.oid, 'select'));
    if v_leaked is not null then
        raise exception
            'journey materials are readable by an application role (%) -- a '
            'policy-less table on the read surface is the defect '
            'dev/tests/rbac/05 exists to find', v_leaked;
    end if;
end $$;

reset role;

\echo ''
select count(*) as applications,
       count(*) filter (where site_ref is null) as no_site_ref,
       count(*) filter (where status = 'withdrawn') as withdrawn
from journey.applications;
\echo 'No workflow, row source, plugin or agent was created. Those are the journey.'
