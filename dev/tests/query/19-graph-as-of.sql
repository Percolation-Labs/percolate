-- GRAPH ... AS OF: WHAT HELD AT A PAST TIME, IN THE DIALECT (REM-999).
--
-- "Where did Maya live in March?" was SQL only: aiq.edge_is_current over
-- aiq.edge_periods, or aiq.related's p_as_of. GRAPH walked the edges current
-- now. aiq.graph_neighbors and aiq.graph_walk now take a time, and the dialect
-- passes AS OF to them.
--
-- WHAT WOULD MAKE IT FAIL. Ignore p_at and §1 raises: March reads Lisbon.
-- The dialect half (§3) needs the compiled parser that knows AS OF; on an older
-- .so it says so and defers, as query/16 does.

\set ON_ERROR_STOP on

begin;
set local role app_owner;
select aiq.register_graph_vocabulary('[{"relation":"t999_lives_in"},{"relation":"t999_works_at"}]') \g /dev/null

set local role worker;
select aiq.upsert_graph('{"nodes":[{"k":"person","n":"Maya T999"},{"k":"place","n":"Leeds"},{"k":"place","n":"Lisbon"},{"k":"company","n":"Northwind"}],
                          "edges":[{"s":0,"t":1,"r":"t999_lives_in"},{"s":0,"t":2,"r":"t999_lives_in"},{"s":0,"t":3,"r":"t999_works_at"}]}',
                        '{"agent":"t999"}') \g /dev/null
reset role;
set local role app_owner;

-- Leeds from January to June, Lisbon from June; Northwind throughout.
update aiq.edges e set valid_from = '2026-01-05', valid_to = '2026-06-01'
  from aiq.node_keys k where k.node_id = e.dst_id and k.key = 'place/leeds' and e.relation = 't999_lives_in';
update aiq.edges e set valid_from = '2026-06-01'
  from aiq.node_keys k where k.node_id = e.dst_id and k.key = 'place/lisbon' and e.relation = 't999_lives_in';
update aiq.edges e set valid_from = '2026-01-01'
 where e.relation = 't999_works_at';
select node_id as maya from aiq.lookup('person/maya t999') \gset

-- 1. Depth 1: March reads Leeds and Northwind, now reads Lisbon and Northwind.
select set_config('t999.maya', :'maya', true) \g /dev/null
do $$
declare m uuid := current_setting('t999.maya')::uuid; march text[]; now_ text[];
begin
    select array_agg(key order by key) into march from aiq.graph_neighbors(m, null, 100, '2026-03-01');
    select array_agg(key order by key) into now_  from aiq.graph_neighbors(m, null, 100);
    if march is distinct from '{company/northwind,place/leeds}' then
        raise exception 'as of March, Maya''s neighbours are %, not Leeds and Northwind', march;
    end if;
    if now_ is distinct from '{company/northwind,place/lisbon}' then
        raise exception 'now, Maya''s neighbours are %, not Lisbon and Northwind', now_;
    end if;
    -- Before anything held, nothing.
    if exists (select 1 from aiq.graph_neighbors(m, null, 100, '2025-06-01')) then
        raise exception 'as of 2025, before any fact held, Maya has neighbours';
    end if;
end $$;

-- 2. Deeper walks read the same period.
do $$
declare m uuid := current_setting('t999.maya')::uuid;
begin
    if not exists (select 1 from aiq.graph_walk(m, 2, null, 500, '2026-03-01') where key = 'place/leeds')
       or exists (select 1 from aiq.graph_walk(m, 2, null, 500, '2026-03-01') where key = 'place/lisbon') then
        raise exception 'a depth-2 walk as of March should reach Leeds and not Lisbon';
    end if;
end $$;

-- 3. The dialect: AS OF in P8QL, and a refusal for a time that is not one.
select coalesce((aiq_parse('GRAPH "x" AS OF ''2026-03-01''')->>'ok')::boolean, false) as parser_has_as_of \gset
\if :parser_has_as_of
do $$
declare r jsonb := aiq.query('GRAPH "person/maya t999" AS OF ''2026-03-01''');
begin
    if (select array_agg(x->>'key' order by x->>'key') from jsonb_array_elements(r->'rows') x)
       is distinct from '{company/northwind,place/leeds}' then
        raise exception 'GRAPH ... AS OF March read %', r->'rows';
    end if;
    if r->'plan'->>'as_of' is distinct from '2026-03-01' then
        raise exception 'the plan does not say AS OF: %', r->'plan';
    end if;
    begin
        perform aiq.query('GRAPH "person/maya t999" AS OF ''2026-13-45''');
        raise exception 'AS OF a date that does not exist was accepted';
    exception when raise_exception then
        if sqlerrm not like '%is not a time%' then raise; end if;
    end;
    raise notice 'GRAPH "person/maya t999" AS OF ''2026-03-01'' -> Leeds, Northwind';
end $$;
\else
\echo 'DEFERRED: query/19 §3 GRAPH ... AS OF -- the compiled parser predates AS OF'
\endif

rollback;
