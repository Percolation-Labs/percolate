-- A WIDE LEAD OPENS ITS TOP TARGETS BY RANK, AND UNDER TOPK ITS TARGETS ARE JUDGED WHATEVER ITS OWN P.
--
-- walk.open_whole_topk (off by default): under walk.open_whole, a lead with more than open_whole unread targets has
-- each target judged on its own line, and opens as single-target leads its k best targets by that P, whatever the P,
-- besides those clearing walk.gate. The per-target judge ranks well and scores low: on QASPER a buried paragraph was
-- judged 2nd of its lead's 39 targets at P .35, which the gate alone never opens.
--
-- The graph: wo/1, the only seed, holds term w, shared with twelve messages (wo/20..wo/31), and term n, shared with
-- one (wo/40). Nothing is beside or near anything. What is held:
--   1. term:w at P .9 is open and wide (12 targets > open_whole 10). Its targets are judged: wo/25 .4, wo/30 .35,
--      wo/22 .2, the rest .1, none at the gate. With open_whole_topk 3 the walk reads wo/25, wo/30 and wo/22 through
--      one:<doc> leads; with the gate alone it reads none of them through a lead.
--   2. Under walk.travel topk the target step judges the targets of a wide lead that is open only by rank: term:w at
--      P .3, the round's best, is open, so aiq.walk_target_requests lists its twelve targets once the run is online.
--      (Offline, the replay supplies verdicts and the step returns nothing, as walk.sql says.)
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

create temp table fo(n int, terms text[]);
insert into fo values (1, '{w,n}'), (40, '{n}');
insert into fo select n, '{w}' from generate_series(20, 31) n;

do $$
declare
    org uuid := (select id from rbac.orgs order by id limit 1);
    ch  uuid;
    res uuid;
    v   jsonb;
begin
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    select 'walk_onek', gen_random_uuid(), org, 'public', 'wo/' || n from fo;
    insert into aiq.node_keys (node_id, entity_type, key, kind, org_id)
    select id, 'walk_onek', summary, 'canonical', org from aiq.nodes where entity_type = 'walk_onek';
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    select distinct 'walk_onek_tag', gen_random_uuid(), org, 'public', t from fo, unnest(terms) t;
    insert into aiq.relation_types (src_type, relation, dst_type, description) values
        ('walk_onek', 'walk_tagged', 'walk_onek_tag', 'query/63 fixture'),
        ('walk_onek', 'walk_next', 'walk_onek', 'query/63 fixture'),
        ('walk_onek', 'walk_nearest', 'walk_onek', 'query/63 fixture')
    on conflict do nothing;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select i.id, tg.id, 'walk_tagged', org, '{}'
      from fo join aiq.nodes i on i.entity_type = 'walk_onek' and i.summary = 'wo/' || fo.n
      cross join unnest(fo.terms) t
      join aiq.nodes tg on tg.entity_type = 'walk_onek_tag' and tg.summary = t;
    insert into content.channels (name, kind, org_id, visibility) values ('walk-onek', 'manual', org, 'public')
    returning id into ch;
    for v in select * from jsonb_array_elements(jsonb_build_array(
            jsonb_build_object('uri', 'walk-onek:rank', 'verdicts',
                jsonb_build_object('term:w', 0.9, 'term:n', 0.2, 'X|root|wo/25', 0.4, 'X|root|wo/30', 0.35, 'X|root|wo/22', 0.2)
                || (select jsonb_object_agg('X|root|wo/' || n, 0.1) from generate_series(20, 31) n where n not in (22, 25, 30))),
            jsonb_build_object('uri', 'walk-onek:topk', 'verdicts', jsonb_build_object('term:w', 0.3, 'term:n', 0.2)))) loop
        insert into content.resources (channel_id, uri, title, org_id, visibility)
        values (ch, v->>'uri', v->>'uri', org, 'public') returning id into res;
        insert into content.resource_chunks (resource_id, ordinal, content)
        values (res, 0, jsonb_build_object('model', 'stand-in', 'task', aiq.walk_task(), 'verdicts', v->'verdicts')::text);
    end loop;
end $$;

select aiq.install_walk_workflow('walk_onek_run', 'jev', 3);

do $$
declare
    inp jsonb := jsonb_build_object(
        'nodes', 'walk_onek', 'prefix', 'wo/', 'question', jsonb_build_object('text', 'the question'),
        'search', to_jsonb(array['wo/1']), 'offline', true,
        'settings', jsonb_build_object('stack', false, 'describe', 'source', 'order', 'p', 'wave', 20, 'seeds', 1,
                                       'per_wave', 1, 'expand_all', false, 'waves', 2, 'open_whole', 10));
    rank_ jsonb := jsonb_set(inp, '{replay}', to_jsonb((select id from content.resources where uri = 'walk-onek:rank')));
    r     uuid;
    got   text;
    n     int;
begin
    -- 1. by rank: the wide lead's top 3 targets open, wo/30 (2nd, P .35) among them; the gate alone opens none
    r := workflow.start_workflow('walk_onek_run', jsonb_set(rank_, '{settings,open_whole_topk}', '3'));
    if (select status from workflow.runs where id = r) is distinct from 'succeeded' then
        raise exception 'the top-k walk did not finish';
    end if;
    select string_agg(doc, ',' order by doc) into got from aiq.walk_reads(r) where via like 'one:%';
    if got is distinct from 'wo/22,wo/25,wo/30' then
        raise exception 'with open_whole_topk 3 the wide lead opened % through one: leads, not wo/22, wo/25, wo/30', got;
    end if;
    r := workflow.start_workflow('walk_onek_run', rank_);
    select count(*) into n from aiq.walk_reads(r) where via like 'one:%';
    if n <> 0 then
        raise exception 'with the gate alone the wide lead opened % targets under .5', n;
    end if;
    -- 2. under topk, term:w (P .3, the round's best) is open by rank, so its targets go to the target step
    r := workflow.start_workflow('walk_onek_run', jsonb_set(jsonb_set(inp, '{replay}',
             to_jsonb((select id from content.resources where uri = 'walk-onek:topk'))), '{settings,travel}', '"topk"'));
    update workflow.runs set input = jsonb_set(input, '{offline}', 'false') where id = r;
    select coalesce(sum(jsonb_array_length(keys)), 0) into n from aiq.walk_target_requests(r);
    if n is distinct from 12 then
        raise exception 'under topk the target step listed % targets of term:w (P .3, open by rank), not 12', n;
    end if;
    raise notice 'query/63: a wide lead opens its top targets by rank, and under topk its targets are judged whatever its P';
end $$;

rollback;
