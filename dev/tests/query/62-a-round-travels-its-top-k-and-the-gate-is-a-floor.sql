-- A ROUND TRAVELS ITS TOP K, THE GATE IS A FLOOR, AND A TRAVEL LANDS AT MOST travel_cap TARGETS.
--
-- walk.travel topk (off by default) opens each round's walk.topk highest-P judged clues whatever their P, plus every
-- clue at P >= walk.gate, and keeps them open until travelled. walk.travel_cap lands at most n of a travelled clue's
-- unread targets, best search rank first. On chain-like questions the right lead scores about .3, so the gate alone
-- travels nothing.
--
-- The graph: wt/1, the only seed, holds four terms a1..a4, each shared with one other message (wt/3..wt/6), and a
-- term b shared with twelve (wt/20..wt/31). No message sits beside another and none is near another, so wt/1's round
-- is exactly term:a1..a4 and term:b, and a clue's verdict is all that decides it. What is held:
--   1. every P under the gate: gate travels nothing; topk travels exactly the top 3 (a1, a2, a3), never a4;
--   2. four clues at P >= .5: topk travels all four, the fourth through the floor although it ranks 4th;
--   3. a clue to twelve targets under travel_cap 10 lands the ten with the best search rank, in rank order (the two
--      search never ranks are left unread); without the cap it lands all twelve.
--   4. under topk the open clues are travelled highest P first whatever walk.order says: wp/1 holds term c (six targets,
--      P .95) and d1..d4 (one target each, P .6). topk reads c's targets before any d's; the gate under per_target,
--      .6/1 against .95/6, reads the d's first (ledger 5.32: the round's best lead never travelled).
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

create temp table fx(n int, terms text[]);
insert into fx values (1, '{a1,a2,a3,a4,b}'), (3, '{a1}'), (4, '{a2}'), (5, '{a3}'), (6, '{a4}');
insert into fx select n, '{b}' from generate_series(20, 31) n;

do $$
declare
    org uuid := (select id from rbac.orgs order by id limit 1);
    ch  uuid;
    res uuid;
    v   jsonb;
begin
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    select 'walk_topk', gen_random_uuid(), org, 'public', 'wt/' || n from fx;
    insert into aiq.node_keys (node_id, entity_type, key, kind, org_id)
    select id, 'walk_topk', summary, 'canonical', org from aiq.nodes where entity_type = 'walk_topk';
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    select distinct 'walk_topk_tag', gen_random_uuid(), org, 'public', t from fx, unnest(terms) t;
    insert into aiq.relation_types (src_type, relation, dst_type, description) values
        ('walk_topk', 'walk_tagged', 'walk_topk_tag', 'query/62 fixture'),
        ('walk_topk', 'walk_next', 'walk_topk', 'query/62 fixture'),
        ('walk_topk', 'walk_nearest', 'walk_topk', 'query/62 fixture')
    on conflict do nothing;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select i.id, tg.id, 'walk_tagged', org, '{}'
      from fx join aiq.nodes i on i.entity_type = 'walk_topk' and i.summary = 'wt/' || fx.n
      cross join unnest(fx.terms) t
      join aiq.nodes tg on tg.entity_type = 'walk_topk_tag' and tg.summary = t;
    insert into content.channels (name, kind, org_id, visibility) values ('walk-topk', 'manual', org, 'public')
    returning id into ch;
    for v in select * from jsonb_array_elements(jsonb_build_array(
            jsonb_build_object('uri', 'walk-topk:low', 'verdicts',
                               jsonb_build_object('term:a1', 0.3, 'term:a2', 0.25, 'term:a3', 0.2, 'term:a4', 0.1)),
            jsonb_build_object('uri', 'walk-topk:high', 'verdicts',
                               jsonb_build_object('term:a1', 0.9, 'term:a2', 0.8, 'term:a3', 0.7, 'term:a4', 0.6)),
            jsonb_build_object('uri', 'walk-topk:wide', 'verdicts', jsonb_build_object('term:b', 0.9)))) loop
        insert into content.resources (channel_id, uri, title, org_id, visibility)
        values (ch, v->>'uri', v->>'uri', org, 'public') returning id into res;
        insert into content.resource_chunks (resource_id, ordinal, content)
        values (res, 0, jsonb_build_object('model', 'stand-in', 'task', aiq.walk_task(), 'verdicts', v->'verdicts')::text);
    end loop;
end $$;

create temp table fp(n int, terms text[]);
insert into fp values (1, '{c,d1,d2,d3,d4}'), (50, '{d1}'), (51, '{d2}'), (52, '{d3}'), (53, '{d4}');
insert into fp select n, '{c}' from generate_series(40, 45) n;

do $$
declare
    org uuid := (select id from rbac.orgs order by id limit 1);
    res uuid;
begin
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    select 'walk_topk', gen_random_uuid(), org, 'public', 'wp/' || n from fp;
    insert into aiq.node_keys (node_id, entity_type, key, kind, org_id)
    select id, 'walk_topk', summary, 'canonical', org from aiq.nodes where entity_type = 'walk_topk' and summary like 'wp/%';
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    select distinct 'walk_topk_tag', gen_random_uuid(), org, 'public', t from fp, unnest(terms) t;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select i.id, tg.id, 'walk_tagged', org, '{}'
      from fp join aiq.nodes i on i.entity_type = 'walk_topk' and i.summary = 'wp/' || fp.n
      cross join unnest(fp.terms) t
      join aiq.nodes tg on tg.entity_type = 'walk_topk_tag' and tg.summary = t;
    insert into content.resources (channel_id, uri, title, org_id, visibility)
    values ((select id from content.channels where name = 'walk-topk'), 'walk-topk:order', 'walk-topk:order', org, 'public')
    returning id into res;
    insert into content.resource_chunks (resource_id, ordinal, content)
    values (res, 0, jsonb_build_object('model', 'stand-in', 'task', aiq.walk_task(), 'verdicts',
            jsonb_build_object('term:c', 0.95, 'term:d1', 0.6, 'term:d2', 0.6, 'term:d3', 0.6, 'term:d4', 0.6))::text);
end $$;

select aiq.install_walk_workflow('walk_topk_run', 'jev', 3);

create temp table query62 (name text, run uuid);

-- Search ranks wt/31 down to wt/22 first, then the a-messages; wt/20 and wt/21 it never ranks.
do $$
declare
    inp jsonb := jsonb_build_object(
        'nodes', 'walk_topk', 'prefix', 'wt/', 'question', jsonb_build_object('text', 'the question'),
        'search', to_jsonb(array['wt/1'] || array(select 'wt/' || n from generate_series(31, 22, -1) n)
                           || array['wt/3', 'wt/4', 'wt/5', 'wt/6']),
        'offline', true,
        'settings', jsonb_build_object('stack', false, 'describe', 'source', 'order', 'p', 'wave', 20, 'seeds', 1,
                                       'per_wave', 1, 'expand_all', false, 'waves', 2));
    rp  jsonb := jsonb_build_object('low', (select id from content.resources where uri = 'walk-topk:low'),
                                    'high', (select id from content.resources where uri = 'walk-topk:high'),
                                    'wide', (select id from content.resources where uri = 'walk-topk:wide'));
    r   uuid;
    k   text;
begin
    for k, r in select x.name, workflow.start_workflow('walk_topk_run', x.i) from (values
            ('low gate', jsonb_set(inp, '{replay}', rp->'low')),
            ('low topk', jsonb_set(jsonb_set(inp, '{replay}', rp->'low'), '{settings,travel}', '"topk"')),
            ('high topk', jsonb_set(jsonb_set(inp, '{replay}', rp->'high'), '{settings,travel}', '"topk"')),
            ('wide cap', jsonb_set(jsonb_set(inp, '{replay}', rp->'wide'), '{settings,travel_cap}', '10')),
            ('wide whole', jsonb_set(inp, '{replay}', rp->'wide'))) x(name, i) loop
        if (select status from workflow.runs where id = r) is distinct from 'succeeded' then
            raise exception '% did not finish: %', k, (select string_agg(step_key || ' ' || status || ' '
                || coalesce(error::text, ''), '; ') from workflow.tasks where run_id = r and status not in ('succeeded', 'skipped'));
        end if;
        insert into query62 values (k, r);
    end loop;
end $$;

do $$
declare
    inp jsonb := jsonb_build_object(
        'nodes', 'walk_topk', 'prefix', 'wp/', 'question', jsonb_build_object('text', 'the question'),
        'search', to_jsonb(array['wp/1'] || array(select 'wp/' || n from generate_series(40, 45) n)
                           || array['wp/50', 'wp/51', 'wp/52', 'wp/53']),
        'offline', true, 'replay', (select id from content.resources where uri = 'walk-topk:order'),
        'settings', jsonb_build_object('stack', false, 'describe', 'source', 'order', 'per_target', 'wave', 20,
                                       'seeds', 1, 'per_wave', 1, 'expand_all', false, 'waves', 2));
    r uuid;
    k text;
begin
    for k, r in select x.name, workflow.start_workflow('walk_topk_run', x.i) from (values
            ('order topk', jsonb_set(inp, '{settings,travel}', '"topk"')),
            ('order gate', inp)) x(name, i) loop
        if (select status from workflow.runs where id = r) is distinct from 'succeeded' then
            raise exception '% did not finish', k;
        end if;
        insert into query62 values (k, r);
    end loop;
end $$;

create temp view query62_travels as
select q.name, t->>'key' as key, t->'land' as land, w.o as wave
  from query62 q, jsonb_array_elements(aiq.walk_state(q.run)->'waves') with ordinality w(v, o),
       jsonb_array_elements(coalesce(w.v->'travels', '[]'::jsonb)) t;

do $$
declare got text;
begin
    -- 1. Under the gate nothing at P < .5 travels; under topk the round's top 3 do, and the 4th never.
    if exists (select 1 from query62_travels where name = 'low gate') then
        raise exception 'the gate travelled clues under .5: %', (select string_agg(key, ',') from query62_travels where name = 'low gate');
    end if;
    select string_agg(key, ',' order by key) into got from query62_travels where name = 'low topk';
    if got is distinct from 'term:a1,term:a2,term:a3' then
        raise exception 'topk travelled % where the round''s top 3 are a1, a2, a3', got;
    end if;
    -- 2. The floor: a4 ranks 4th, and at P .6 it travels anyway.
    select string_agg(key, ',' order by key) into got from query62_travels where name = 'high topk';
    if got is distinct from 'term:a1,term:a2,term:a3,term:a4' then
        raise exception 'with four clues at P >= .5 topk travelled %, not all four', got;
    end if;
    -- 3. The cap: the ten best-ranked of b's twelve targets, in search order; whole, all twelve.
    select land::text into got from query62_travels where name = 'wide cap' and key = 'term:b';
    if got is distinct from (select jsonb_agg('wt/' || n order by n desc)::text from generate_series(31, 22, -1) n) then
        raise exception 'under travel_cap 10 term:b landed %', got;
    end if;
    if (select jsonb_array_length(land) from query62_travels where name = 'wide whole' and key = 'term:b') is distinct from 12 then
        raise exception 'without the cap term:b landed % targets, not 12',
            (select jsonb_array_length(land) from query62_travels where name = 'wide whole' and key = 'term:b');
    end if;
    -- 4. Highest P first under topk: c's six targets (P .95) are read before any d (P .6, one target each); the gate
    --    under per_target reads the d's first.
    if (select min(rd.ord) filter (where rd.doc between 'wp/40' and 'wp/45') < min(rd.ord) filter (where rd.doc between 'wp/50' and 'wp/53')
          from query62 q, aiq.walk_reads(q.run) rd where q.name = 'order topk') is distinct from true then
        raise exception 'under topk the d leads (P .6, one target) travelled before c (P .95, six targets): %',
            (select string_agg(rd.doc, ',' order by rd.wave, rd.ord) from query62 q, aiq.walk_reads(q.run) rd where q.name = 'order topk');
    end if;
    if (select min(rd.ord) filter (where rd.doc between 'wp/50' and 'wp/53') < min(rd.ord) filter (where rd.doc between 'wp/40' and 'wp/45')
          from query62 q, aiq.walk_reads(q.run) rd where q.name = 'order gate') is distinct from true then
        raise exception 'under the gate with per_target, c travelled before the d leads: %',
            (select string_agg(rd.doc, ',' order by rd.wave, rd.ord) from query62 q, aiq.walk_reads(q.run) rd where q.name = 'order gate');
    end if;
    raise notice 'query/62: a round travels its top 3 under the gate, the gate is a floor, a travel lands at most travel_cap, and topk travels highest P first';
end $$;

rollback;
