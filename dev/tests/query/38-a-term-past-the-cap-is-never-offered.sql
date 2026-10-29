-- Tag range without a model (REM-1208): a term held by more messages than the cap is never offered as a clue, however
-- much the decider would like it, and every read a walk makes came by a route it could take: search, the next message,
-- the nearest in meaning, or a term within the cap.
--
-- The article's block (dev/examples/muddling-through/blocks/50) counts BEAM's terms by range and a walk's reads by
-- route. BEAM's text stays out of the tests, so this is a hand-made conversation with the same shape: 'room' is in six
-- messages, 'tiles' in three, 'ladder' in two, and the cap is three. The replay likes 'room' best of all, so a walk
-- that offered it would travel it first. The evidence is 7 (ladder) and 8 (tiles). With two reads a wave and one seed:
-- wave 0 reads 1, which raises ladder, tiles and its next and near leads, but not room; wave 1 travels ladder to 7;
-- wave 2 travels the near lead of 1 to 2 and fills from search; wave 3 travels tiles to 4 and fills from search. With
-- the cap at six the same walk travels room first, which is what shows the cap is the thing that refuses it.

\set ON_ERROR_STOP on

begin;

create temp table fx(n int, sitting text, pos int, terms text[], near int[]);
insert into fx values
 (1,'a',0,'{room,ladder,tiles}','{2}'), (2,'a',1,'{room,paint}','{1}'), (3,'a',2,'{room,paint}','{4}'),
 (4,'a',3,'{room,tiles}','{3}'), (5,'a',4,'{room,budget}','{6}'), (6,'a',5,'{room,budget}','{5}'),
 (7,'a',6,'{ladder,rental}','{8}'), (8,'a',7,'{tiles,grout}','{7}'),
 (11,'b',0,'{risotto}','{12}'), (12,'b',1,'{stock}','{11}'), (13,'b',2,'{parmesan}','{12}'), (14,'b',3,'{bowls}','{13}');

do $$
declare
    org uuid := (select id from rbac.orgs order by id limit 1);
    ch  uuid;
    res uuid;
begin
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    select 'walk_range', gen_random_uuid(), org, 'public', 'wr/' || n from fx;
    insert into aiq.node_keys (node_id, entity_type, key, kind, org_id)
    select id, 'walk_range', summary, 'canonical', org from aiq.nodes where entity_type = 'walk_range';
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    select distinct 'walk_range_tag', gen_random_uuid(), org, 'public', t from fx, unnest(terms) t;
    insert into aiq.relation_types (src_type, relation, dst_type, description) values
        ('walk_range', 'walk_tagged', 'walk_range_tag', 'query/38 fixture'),
        ('walk_range', 'walk_next', 'walk_range', 'query/38 fixture'),
        ('walk_range', 'walk_nearest', 'walk_range', 'query/38 fixture')
    on conflict do nothing;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select i.id, tg.id, 'walk_tagged', org, '{}'
      from fx join aiq.nodes i on i.entity_type = 'walk_range' and i.summary = 'wr/' || fx.n
      cross join unnest(fx.terms) t
      join aiq.nodes tg on tg.entity_type = 'walk_range_tag' and tg.summary = t;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select a.id, b.id, 'walk_next', org, jsonb_build_object('sitting', x.sitting, 'pos', x.pos)
      from fx x join fx y on y.sitting = x.sitting and y.pos = x.pos + 1
      join aiq.nodes a on a.entity_type = 'walk_range' and a.summary = 'wr/' || x.n
      join aiq.nodes b on b.entity_type = 'walk_range' and b.summary = 'wr/' || y.n;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select a.id, b.id, 'walk_nearest', org, jsonb_build_object('rank', 0)
      from fx cross join unnest(fx.near) m
      join aiq.nodes a on a.entity_type = 'walk_range' and a.summary = 'wr/' || fx.n
      join aiq.nodes b on b.entity_type = 'walk_range' and b.summary = 'wr/' || m;
    -- The replay: room above everything, then ladder, the near lead of 1 and tiles; every other lead rejected.
    insert into content.channels (name, kind, org_id, visibility) values ('walk-range', 'manual', org, 'public')
    returning id into ch;
    insert into content.resources (channel_id, uri, title, org_id, visibility)
    values (ch, 'walk-range:replay', 'replay', org, 'public') returning id into res;
    insert into content.resource_chunks (resource_id, ordinal, content)
    select res, 0, jsonb_build_object('model', 'stand-in', 'task', aiq.walk_task(), 'verdicts', (select jsonb_object_agg(k, 0.2) from fx, lateral (values ('next:wr/' || n), ('near:wr/' || n)) v(k))
             || (select jsonb_object_agg('term:' || t, 0.2) from fx, unnest(terms) t)
             || jsonb_build_object('term:room', 0.95, 'term:ladder', 0.9, 'near:wr/1', 0.8, 'term:tiles', 0.7))::text;
end $$;

select aiq.install_walk_workflow('walk_range_3', 'jev', 3);

do $$
declare
    inp jsonb := jsonb_build_object(
        'nodes', 'walk_range', 'prefix', 'wr/',
        'question', jsonb_build_object('text', 'Which of my renovation jobs need a ladder or new tiles?'),
        'search', to_jsonb(array['wr/1','wr/11','wr/12','wr/13','wr/14','wr/2','wr/3','wr/4','wr/5','wr/6','wr/7','wr/8']),
        'replay', (select id from content.resources where uri = 'walk-range:replay'), 'offline', true,
        'settings', jsonb_build_object('stack', false, 'describe', 'source', 'order', 'p', 'wave', 2, 'seeds', 1, 'per_wave', 1, 'cap', 3));
    r uuid;
    got text;
begin
    r := workflow.start_workflow('walk_range_3', inp);
    if (select status from workflow.runs where id = r) is distinct from 'succeeded' then
        raise exception 'the walk did not finish in-database: %', (select string_agg(step_key || ' ' || status || ' '
            || coalesce(error::text, ''), '; ') from workflow.tasks where run_id = r and status not in ('succeeded', 'skipped'));
    end if;
    if exists (select 1 from aiq.walk_clues(r) where key = 'term:room') then
        raise exception 'room is in six messages and the cap is three, yet it was offered: %',
            (select state from aiq.walk_clues(r) where key = 'term:room');
    end if;
    -- Every read came by a route the walk could take, and a term route only through a term within the cap.
    select string_agg(doc || ' ' || via, ', ' order by wave, ord) into got
      from aiq.walk_reads(r)
     where not (via = 'search' or via like 'next:wr/%' or via like 'near:wr/%'
                or (via like 'term:%' and (select count(*) from fx where substr(via, 6) = any (terms)) <= 3));
    if got is not null then
        raise exception 'reads by a route the walk cannot take: %', got;
    end if;
    -- The block's table, by route: reads and how many were evidence.
    select string_agg(route || ' ' || reads || '/' || evidence, '; ' order by route) into got from (
        select case when via = 'search' then 'search' when via like 'next:%' then 'next' when via like 'near:%' then 'near'
                    else 'term ' || (select count(*) from fx where substr(via, 6) = any (terms)) end as route,
               count(*) as reads, count(*) filter (where doc in ('wr/7', 'wr/8')) as evidence
          from aiq.walk_reads(r) group by 1) z;
    if got is distinct from 'near 1/0; search 3/0; term 2 1/1; term 3 1/0' then
        raise exception 'reads by route are % where search, near, ladder (2) and tiles (3) were expected', got;
    end if;
    -- The same walk with the cap at six: room is offered, and travelled first.
    r := workflow.start_workflow('walk_range_3', jsonb_set(inp, '{settings,cap}', '6'));
    if (select state from aiq.walk_clues(r) where key = 'term:room') is distinct from 'travelled'
       or (select via from aiq.walk_reads(r) where wave = 1 order by ord limit 1) is distinct from 'term:room' then
        raise exception 'with the cap at six room was not travelled first: %',
            (select string_agg(wave || ':' || doc || ' ' || via, ', ' order by wave, ord) from aiq.walk_reads(r));
    end if;
    raise notice 'query/38: a term past the cap is never offered, and every read came by a route the walk can take';
end $$;

rollback;
