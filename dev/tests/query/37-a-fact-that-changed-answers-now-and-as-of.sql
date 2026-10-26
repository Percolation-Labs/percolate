-- A FACT THAT CHANGED ANSWERS NOW, AND AS OF EARLIER (REM-1213).
--
-- The walkthrough's time step, without the walk: three messages a walk read
-- as evidence for one question, two saying the budget is $150 and a later one
-- raising it to $160. Each lands through aiq.upsert_graph as an edge from the
-- question to the document, holding from when it was said; the last one ends
-- the earlier ones' edges at its own moment through aiq.close_edge. Then one
-- query, through aiq.edge_is_current, gives $160 now and $150 as of a moment
-- between the two. dev/examples/muddling-through/blocks/60-time.sh is the
-- same landing on BEAM 1M:22:knowledge_update:1.
--
-- WHAT WOULD MAKE IT FAIL. Drop valid_from from the context and every edge
-- holds from the write, and close_edge refuses to end it in 2024. Skip the
-- close and now gives all three.

\set ON_ERROR_STOP on

begin;
set local role app_owner;
insert into content.channels (name, kind, org_id, visibility)
    values ('rem1213', 'manual', rbac.shared_org_id(), 'public') on conflict do nothing;
insert into content.resources (id, channel_id, external_id, uri, title, status, org_id, visibility, metadata)
select x.id::uuid, c.id, x.uri, x.uri, x.uri, 'ready', rbac.shared_org_id(), 'public', x.metadata::jsonb
  from content.channels c, (values
    ('00000000-0000-4000-8000-000000121300', 'question:rem1213', '{}'),
    ('00000000-0000-4000-8000-000000121301', 'rem1213/671', '{"said_at": "2024-08-12T00:11:11Z", "said": "$150"}'),
    ('00000000-0000-4000-8000-000000121302', 'rem1213/675', '{"said_at": "2024-08-12T00:11:15Z", "said": "$150"}'),
    ('00000000-0000-4000-8000-000000121303', 'rem1213/688', '{"said_at": "2024-08-12T00:11:28Z", "said": "$160"}')
  ) x(id, uri, metadata)
 where c.name = 'rem1213';
select aiq.register_graph_vocabulary('[{"relation":"answered_in"}]') \g /dev/null

create temp view evidence as
select r.id, r.uri as doc, (r.metadata->>'said_at')::timestamptz as said_at
  from content.resources r where r.uri like 'rem1213/%';
grant select on evidence to worker;

create function pg_temp.answer(p_at timestamptz) returns text language sql as $$
    select coalesce(string_agg(x.metadata->>'said', ',' order by x.metadata->>'said_at'), '')
      from aiq.nodes q
      join aiq.edges a on a.src_id = q.id and a.relation = 'answered_in'
                      and aiq.edge_is_current(a.valid_from, a.valid_to, p_at)
      join aiq.nodes d on d.id = a.dst_id
      join content.resources x on x.id = d.entity_id
     where q.entity_type = 'document' and q.entity_id = '00000000-0000-4000-8000-000000121300'
$$;
reset role;

-- 1. The worker lands each piece from when it was said, then the last ends the earlier ones.
set local role worker;
select aiq.upsert_graph(
         jsonb_build_object('nodes', jsonb_build_array(jsonb_build_object('k', 'document', 'n', 'question:rem1213'),
                                                       jsonb_build_object('k', 'document', 'n', e.doc)),
                            'edges', '[{"s": 0, "t": 1, "r": "answered_in"}]'::jsonb),
         jsonb_build_object('resource_id', e.id, 'valid_from', e.said_at, 'agent', 'walk'))
  from evidence e order by e.said_at \g /dev/null
select aiq.close_edge(jsonb_build_object('resource_id', e.id, 'relation', 'answered_in'), l.said_at,
                      jsonb_build_object('resource_id', l.id, 'agent', 'walk'))
  from evidence e, (select * from evidence order by said_at desc limit 1) l
 where e.id <> l.id \g /dev/null
reset role;
set local role app_owner;

-- 2. Now the budget is $160; between the two it was $150; before either, nothing had been said.
do $$
declare now_ text := pg_temp.answer(now());
        mid   text := pg_temp.answer('2024-08-12T00:11:20Z');
        early text := pg_temp.answer('2024-08-12T00:11:00Z');
begin
    if now_ is distinct from '$160' then
        raise exception 'now the answer should be $160 alone, got "%"', now_;
    end if;
    if mid is distinct from '$150,$150' then
        raise exception 'as of 00:11:20 the answer should be the two $150 messages, got "%"', mid;
    end if;
    if early is distinct from '' then
        raise exception 'before anything was said nothing should answer, got "%"', early;
    end if;
end $$;

-- 3. The ended edges say which message ended them.
do $$
declare n int;
begin
    select count(*) into n
      from aiq.edges a
     where a.relation = 'answered_in' and a.valid_to = '2024-08-12T00:11:28Z'
       and a.provenance->'closed'->>'resource_id' = '00000000-0000-4000-8000-000000121303';
    if n is distinct from 2 then
        raise exception 'the two $150 edges should end at 00:11:28, closed by /688, got %', n;
    end if;
end $$;

rollback;
