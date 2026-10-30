-- The scope dev/scale/walks.sh walks: :items documents in sittings of 100, each tagged with two of :tags terms,
-- linked to the next in its sitting and to two nearest neighbours, plus :filler other resources so that every
-- lookup by uri pays for a stack that holds documents (REM-1228). Committed, under the entity type walk_load and
-- the channel walk-load, so the walks see it from their own connections; --clean removes it.
\set ON_ERROR_STOP on

select set_config('walk_load.items', :'items', false), set_config('walk_load.tags', :'tags', false),
       set_config('walk_load.filler', :'filler', false);

begin;

-- edges are never deleted; removing a node removes its edges
delete from aiq.node_keys where entity_type in ('walk_load', 'walk_load_tag');
delete from aiq.nodes where entity_type in ('walk_load', 'walk_load_tag');
delete from content.resources where channel_id = (select id from content.channels where name = 'walk-load');
delete from content.channels where name = 'walk-load';

do $$
declare
    org   uuid := (select id from rbac.orgs order by id limit 1);
    items int  := current_setting('walk_load.items')::int;
    tags  int  := current_setting('walk_load.tags')::int;
    ch    uuid;
    res   uuid;
begin
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    select 'walk_load', gen_random_uuid(), org, 'public', 'wl/' || n from generate_series(1, items) n;
    insert into aiq.node_keys (node_id, entity_type, key, kind, org_id)
    select id, 'walk_load', summary, 'canonical', org from aiq.nodes where entity_type = 'walk_load';
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    select 'walk_load_tag', gen_random_uuid(), org, 'public', 'term' || t from generate_series(1, tags) t;
    insert into aiq.relation_types (src_type, relation, dst_type, description) values
        ('walk_load', 'walk_tagged', 'walk_load_tag', 'dev/scale walks'),
        ('walk_load', 'walk_next', 'walk_load', 'dev/scale walks'),
        ('walk_load', 'walk_nearest', 'walk_load', 'dev/scale walks')
    on conflict do nothing;

    -- two terms each, chosen by hash so a rerun builds the same scope
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select i.id, tg.id, 'walk_tagged', org, '{}'
      from aiq.nodes i
      cross join lateral (values (1 + abs(hashtext(i.summary)) % tags), (1 + abs(hashtext(i.summary || '#')) % tags)) t(n)
      join aiq.nodes tg on tg.entity_type = 'walk_load_tag' and tg.summary = 'term' || t.n
     where i.entity_type = 'walk_load'
    on conflict do nothing;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select a.id, b.id, 'walk_next', org,
           jsonb_build_object('sitting', 's' || ((n - 1) / 100), 'pos', (n - 1) % 100)
      from generate_series(1, items - 1) n
      join aiq.nodes a on a.entity_type = 'walk_load' and a.summary = 'wl/' || n
      join aiq.nodes b on b.entity_type = 'walk_load' and b.summary = 'wl/' || (n + 1)
     where (n - 1) / 100 = n / 100;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select a.id, b.id, 'walk_nearest', org, jsonb_build_object('rank', k.r)
      from generate_series(1, items) n
      cross join lateral (values (0, 1 + abs(hashtext('near' || n)) % items), (1, 1 + abs(hashtext('near#' || n)) % items)) k(r, m)
      join aiq.nodes a on a.entity_type = 'walk_load' and a.summary = 'wl/' || n
      join aiq.nodes b on b.entity_type = 'walk_load' and b.summary = 'wl/' || k.m
     where k.m <> n
    on conflict do nothing;

    -- the replay holds a verdict for a tenth of the terms, so an offline walk judges without a model
    insert into content.channels (name, kind, org_id, visibility) values ('walk-load', 'manual', org, 'public')
    returning id into ch;
    insert into content.resources (channel_id, uri, title, org_id, visibility)
    values (ch, 'walk-load:replay', 'replay', org, 'public') returning id into res;
    insert into content.resource_chunks (resource_id, ordinal, content)
    select res, 0, jsonb_build_object('model', 'stand-in', 'task', aiq.walk_task(),
               'verdicts', jsonb_object_agg('term:term' || t, round((0.1 + (t % 9) / 10.0)::numeric, 1)))::text
      from generate_series(1, tags, 10) t;
    insert into content.resources (channel_id, uri, title, org_id, visibility)
    select ch, 'walk-load:filler/' || i, 'filler ' || i, org, 'public' from generate_series(1, current_setting('walk_load.filler')::int) i;
end $$;

commit;

analyze content.resources;
analyze aiq.edges;
analyze aiq.nodes;

select aiq.install_walk_workflow('walk_load_run', 'jev', 10);

-- keep the scope's graph once, as a stack does after loading links, so every walk reads it rather than building it
select aiq.walk_index(jsonb_build_object('nodes', 'walk_load', 'prefix', 'wl/',
           'replay', (select id from content.resources where uri = 'walk-load:replay'), 'offline', true,
           'settings', jsonb_build_object('stack', false, 'describe', 'source')))->>'uri' as kept_graph;

select (select count(*) from aiq.nodes where entity_type = 'walk_load') as items,
       (select count(*) from aiq.edges e join aiq.nodes n on n.id = e.src_id and n.entity_type = 'walk_load') as edges,
       (select count(*) from content.resources) as resources;
