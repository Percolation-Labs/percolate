-- AN EXTRACTED KIND LANDS BARE, WHATEVER PUNCTUATION THE MODEL ADDS (REM-1066).
--
-- gpt-4o answered `pg:/port` for a port about one run in seven, copying the
-- graph schema's old hint ("optionally pg:/lake:/soft: prefixed"), and the
-- lander kept `/port`: the key became `/port/felixstowe`, which matched no row,
-- so dream could not bind it. Now the hint is gone, the schema lists the
-- registered kinds, and the lander strips a slash around the kind.
--
-- WHAT WOULD MAKE IT FAIL. Keep the slash in the lander and §1 raises; put the
-- prefix hint back, or stop listing kinds, and §2 raises.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on
begin;

create function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
    if p_ok is not true then
        raise exception 'an extracted kind lands bare: %', p_what;
    end if;
end $$;

select aiq.register_graph_vocabulary('[{"relation": "ships_via_rem1066"}]') ->> 'relations' as relations;

-- §1. Three spellings of one kind land one node.
select aiq.upsert_graph('{"nodes": [{"k":"person","n":"Ana Rem1066"}, {"k":"pg:/harbour","n":"Felixstowe Rem1066"}],
                          "edges": [{"s":0,"t":1,"r":"ships_via_rem1066"}]}', '{"agent":"rem1066","run_id":"a"}') is not null;
select aiq.upsert_graph('{"nodes": [{"k":"person","n":"Ana Rem1066"}, {"k":"/harbour","n":"Felixstowe Rem1066"}],
                          "edges": [{"s":0,"t":1,"r":"ships_via_rem1066"}]}', '{"agent":"rem1066","run_id":"b"}') is not null;
select aiq.upsert_graph('{"nodes": [{"k":"person","n":"Ana Rem1066"}, {"k":"harbour","n":"Felixstowe Rem1066"}],
                          "edges": [{"s":0,"t":1,"r":"ships_via_rem1066"}]}', '{"agent":"rem1066","run_id":"c"}') is not null;
select pg_temp.check((select array_agg(distinct k.key) from aiq.node_keys k
                        where k.kind = 'canonical' and k.key like '%felixstowe rem1066%') = array['harbour/felixstowe rem1066'],
    '§1: pg:/harbour, /harbour and harbour land one node with the bare kind: '
    || (select string_agg(distinct k.key, ', ') from aiq.node_keys k where k.key like '%felixstowe rem1066%'));
select pg_temp.check((select count(*) from aiq.edges where relation = 'ships_via_rem1066') = 1,
    '§1: and one fact, said three times');

-- §2. The schema the extractor is sent lists the registered kinds and suggests no prefix.
select pg_temp.check(d not like '%pg:%' and d not like '%lake:%'
                     and d like '%person%' and d not like '%soft%',
    '§2: the kind description lists registered kinds and no prefix: ' || d)
  from (select aiq.graph_schema() #>> '{properties,nodes,items,properties,k,description}' as d) s;

rollback;
