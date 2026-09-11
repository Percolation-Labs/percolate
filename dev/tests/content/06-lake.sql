-- p8ql LAKE: planned in Postgres as the caller, compiled to a lake work step,
-- and never executed here. What running the plan does is e2e-lake.py §7.
\set ON_ERROR_STOP on
begin;
set local role app_owner;
insert into rbac.users(id,email) values
 ('a1a1a1a1-0000-4000-8000-00000000a116','alice-lake06@test.invalid'),
 ('b0b0b0b0-0000-4000-8000-0000000000b6','bob-lake06@test.invalid') on conflict(id) do nothing;
insert into rbac.user_roles(user_id,role) values
 ('a1a1a1a1-0000-4000-8000-00000000a116','admin'),
 ('b0b0b0b0-0000-4000-8000-0000000000b6','admin') on conflict do nothing;
insert into rbac.orgs(id,slug,name) values
 ('a0000000-0000-4000-8000-0000000000a6','lake06-a','Lake06 A'),
 ('b0000000-0000-4000-8000-0000000000b6','lake06-b','Lake06 B') on conflict(id) do nothing;
insert into rbac.org_members(org_id,user_id,role) values
 ('a0000000-0000-4000-8000-0000000000a6','a1a1a1a1-0000-4000-8000-00000000a116','admin'),
 ('b0000000-0000-4000-8000-0000000000b6','b0b0b0b0-0000-4000-8000-0000000000b6','admin') on conflict do nothing;
insert into content.datasets(name, org_id, owner_id, visibility, bucket, prefix, format, table_ref,
                             columns, row_count, embeddings, geometry)
values ('l06_sales', 'a0000000-0000-4000-8000-0000000000a6', 'a1a1a1a1-0000-4000-8000-00000000a116',
        'org', 'lake', 'lake/a0000000-0000-4000-8000-0000000000a6/l06_sales', 'parquet', null,
        '[{"name":"region","type":"VARCHAR"},{"name":"amount","type":"DOUBLE"}]', 12, '{}', '{}'),
       ('l06_sites', 'a0000000-0000-4000-8000-0000000000a6', 'a1a1a1a1-0000-4000-8000-00000000a116',
        'org', 'lake', 'iceberg/x', 'iceberg', 'o_a0000000000040008000000000000a6.l06_sites',
        '[{"name":"geom","type":"BLOB"}]', 3, '{}', '{"geom":{"encoding":"wkb","crs":"OGC:CRS84"}}'),
       ('l06_payroll', 'b0000000-0000-4000-8000-0000000000b6', 'b0b0b0b0-0000-4000-8000-0000000000b6',
        'private', 'lake', 'lake/b0000000-0000-4000-8000-0000000000b6/l06_payroll', 'parquet', null,
        '[{"name":"salary","type":"DOUBLE"}]', 1, '{}', '{}');

-- The parser half is the published .so until an image is built from this
-- tree (check.yml says so on every parser PR), so the sections that need LAKE
-- in the PARSER run only where the installed one has it -- and say loudly when
-- they did not, as workflow/10 does for batch_size. The SQL half runs anyway.
select coalesce((aiq_parse('LAKE FROM x select 1')->>'ok')::boolean, false) as lake_parser \gset
\if :lake_parser
\else
\echo 'content/06-lake: the installed parser predates LAKE -- §1, §2, §5 and §6 SKIPPED; rebuild it (dev/build-image.sh) to run them'
\endif

-- §1. The parser: the statement survives verbatim, the datasets are a list.
\if :lake_parser
do $$ declare p jsonb; begin
 p := aiq_parse($q$LAKE FROM l06_sales, l06_sites select region, count(*) from l06_sales where region <> 'O''Neil, Ltd' group by 1$q$);
 if p->>'mode' is distinct from 'LAKE' or p->'sources' is distinct from '["l06_sales","l06_sites"]'::jsonb then
  raise exception 'LAKE did not parse into its dataset list: %', p; end if;
 if p->>'arg' is distinct from $q$select region, count(*) from l06_sales where region <> 'O''Neil, Ltd' group by 1$q$ then
  raise exception 'the LAKE statement was changed on the way through: %', p->>'arg'; end if;
 if (p->>'limit')::int is distinct from 1000 then raise exception 'the row cap is not in the plan: %', p; end if;
end $$;
\endif

-- §2. Planned as the caller. Alice's org reads both of hers; Bob's name is
-- unresolved for her -- reported, not raised, and not distinguishable from a
-- name that does not exist.
set local role authenticated;
set local request.jwt.claims = '{"sub":"a1a1a1a1-0000-4000-8000-00000000a116"}';
\if :lake_parser
do $$ declare r jsonb; begin
 r := aiq.query('LAKE FROM l06_sales, l06_payroll, l06_nothing select * from l06_sales');
 if r->>'mode' is distinct from 'LAKE' or (r->>'executed')::boolean is distinct from false then raise exception 'not a LAKE plan: %', r; end if;
 if jsonb_array_length(r->'datasets') is distinct from 1 or r->'datasets'->0->>'name' is distinct from 'l06_sales' then
  raise exception 'Alice''s plan resolved the wrong datasets: %', r->'datasets'; end if;
 if r->'unresolved' is distinct from '["l06_payroll","l06_nothing"]'::jsonb then
  raise exception 'another tenant''s dataset and a missing one must both be unresolved, alike: %', r->'unresolved'; end if;
 if r->'datasets'->0 ? 'bucket' or r->'datasets'->0 ? 'prefix' then
  raise exception 'a plan must not carry storage locations: %', r->'datasets'->0; end if;
 if r->'rows' is distinct from '[]'::jsonb then raise exception 'Postgres executed a LAKE query'; end if;
end $$;
\endif

-- §3. SCHEMA "lake" is the caller's own list, with columns.
do $$ declare a jsonb; b jsonb; begin
 a := aiq.query('SCHEMA "lake"')->'schema'->'doc'->'datasets';
 if not exists (select 1 from jsonb_array_elements(a->'datasets') d where d->>'name' = 'l06_sites'
                and d->'geometry'->'geom'->>'crs' = 'OGC:CRS84') then
  raise exception 'Alice''s SCHEMA "lake" is missing her dataset or its CRS: %', a; end if;
 if exists (select 1 from jsonb_array_elements(a->'datasets') d where d->>'name' = 'l06_payroll') then
  raise exception 'SCHEMA "lake" showed Alice another tenant''s dataset'; end if;
 perform set_config('request.jwt.claims', '{"sub":"b0b0b0b0-0000-4000-8000-0000000000b6"}', true);
 b := aiq.query('SCHEMA "lake" FROM l06')->'schema'->'doc'->'datasets';
 if (select array_agg(d->>'name') from jsonb_array_elements(b->'datasets') d) is distinct from array['l06_payroll'] then
  raise exception 'Bob''s SCHEMA "lake" FROM l06 should be his one dataset: %', b; end if;
end $$;

-- §4. dataset_uri refuses to hand an Iceberg table out as a glob.
set local request.jwt.claims = '{"sub":"a1a1a1a1-0000-4000-8000-00000000a116"}';
do $$ begin
 if content.dataset_uri('l06_sites') is distinct from 'iceberg:o_a0000000000040008000000000000a6.l06_sites' then
  raise exception 'dataset_uri of an iceberg dataset: %', content.dataset_uri('l06_sites'); end if;
end $$;

\if :lake_parser
-- §5. The compiler. A LAKE p8ql step IS the hand-written lake work step --
-- the same diff test 09-embed-sugar.sql holds embed: to.
do $$ declare sugar jsonb; by_hand jsonb; bad jsonb; begin
 sugar := p8_compile_workflow($y$
name: l06
steps:
  - id: totals
    p8ql: 'LAKE FROM l06_sales select region, sum(amount) from l06_sales group by 1'
$y$)->'workflow'->'spec'->'steps'->0;
 by_hand := p8_compile_workflow($y$
name: l06
steps:
  - id: totals
    work: true
    queue: lake
    input: {op: query, p8ql: 'LAKE FROM l06_sales select region, sum(amount) from l06_sales group by 1'}
$y$)->'workflow'->'spec'->'steps'->0;
 if sugar is distinct from by_hand then
  raise exception 'LAKE sugar and the hand-written step differ: % vs %', sugar, by_hand; end if;
 if sugar->>'kind' is distinct from 'work' or sugar->>'queue' is distinct from 'lake' then
  raise exception 'a LAKE step must be lake work: %', sugar; end if;
 -- A non-LAKE p8ql step is untouched: still in-database.
 if p8_compile_workflow($y$
name: l06b
steps:
  - id: q
    p8ql: 'LOOKUP "acme"'
$y$)->'workflow'->'spec'->'steps'->0->>'kind' is distinct from 'sql' then
  raise exception 'an ordinary p8ql step stopped compiling to sql'; end if;
 bad := p8_compile_workflow($y$
name: l06c
steps:
  - id: q
    p8ql: 'LAKE FROM l06_sales select * from l06_sales where region = ''{{run.region}}'''
$y$);
 if (bad->>'ok')::boolean is distinct from false or coalesce(bad->>'error', '') not like '%cannot carry a {{template}}%' then
  raise exception 'a template in a LAKE query must be refused at compile: %', bad; end if;
end $$;

-- §6. The grammar the query tool reads names the mode, and its example parses.
do $$ declare d jsonb; begin
 d := aiq.query('SCHEMA "p8ql"')->'schema'->'doc';
 if not exists (select 1 from jsonb_array_elements(d->'declared'->'modes') m where m->>'mode' = 'LAKE') then
  raise exception 'SCHEMA "p8ql" does not declare LAKE'; end if;
end $$;
\endif

rollback;
\echo 'content/06-lake: LAKE plans as the caller, compiles to lake work, and never runs in Postgres'
