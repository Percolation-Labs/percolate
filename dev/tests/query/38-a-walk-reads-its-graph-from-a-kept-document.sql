-- A WALK READS ITS GRAPH FROM A KEPT DOCUMENT (REM-1199).
--
-- A walk's graph (terms, postings, neighbours over its scope) is the same on every step of every run, and building
-- it was most of a walk's cost. aiq.walk_index keeps it as a document; aiq.walk_graph reads that document while the
-- links are as they were when it was kept, and builds otherwise. What is held: the kept graph is the built one, it is
-- what a walk reads (a marked copy comes back), a changed link or a run as of an earlier time is never served the
-- kept one, and search never finds it.

\set ON_ERROR_STOP on

begin;

do $$
declare
    org  uuid := (select id from rbac.orgs order by id limit 1);
    inp  jsonb := '{"nodes": "walk_cache_fixture", "prefix": "wc/"}';
    v    jsonb;
    v_uri text;
    kept jsonb;
    mark jsonb := '{"marked": true}';
    e    uuid;
begin
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    select 'walk_cache_fixture', gen_random_uuid(), org, 'public', 'wc/' || n from generate_series(1, 4) n;
    insert into aiq.node_keys (node_id, entity_type, key, kind, org_id)
    select id, 'walk_cache_fixture', summary, 'canonical', org from aiq.nodes where entity_type = 'walk_cache_fixture';
    insert into aiq.relation_types (src_type, relation, dst_type, description) values
        ('walk_cache_fixture', 'walk_next', 'walk_cache_fixture', 'query/38 fixture')
    on conflict do nothing;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance, valid_from)
    select a.id, b.id, 'walk_next', org, '{}', now() - interval '1 day'
      from aiq.nodes a join aiq.nodes b on b.entity_type = a.entity_type
                                       and b.summary = 'wc/' || (substr(a.summary, 4)::int + 1)
     where a.entity_type = 'walk_cache_fixture';
    if not exists (select 1 from content.channels where name = 'walk-graphs') then
        -- in the shared org, where register_text looks for a channel a caller with no org names
        insert into content.channels (name, kind, org_id, visibility)
        values ('walk-graphs', 'manual', rbac.shared_org_id(), 'public');
    end if;

    perform aiq.walk_index(inp);
    v := aiq.walk_graph_version(aiq.walk_keys(inp));
    v_uri := aiq.walk_graph_uri(inp, v);
    select metadata->'walk_graph' into kept from content.resources where uri = v_uri;
    if kept is distinct from aiq.walk_graph_build(inp, now()) then
        raise exception 'the kept graph is not the built one: %', kept;
    end if;
    if (select count(*) from jsonb_object_keys(kept->'beside')) is distinct from 4::bigint then
        raise exception 'the fixture graph has no neighbours: %', kept;
    end if;
    -- Search never finds it: its one chunk indexes to no words.
    if exists (select 1 from content.resource_chunks c join content.resources r on r.id = c.resource_id
                where r.uri = v_uri and c.search_tsv is distinct from ''::tsvector) then
        raise exception 'the kept graph''s chunk is searchable';
    end if;

    -- The kept document is what a walk reads: mark it, and the mark comes back.
    update content.resources set metadata = jsonb_set(metadata, '{walk_graph}', mark) where uri = v_uri;
    if aiq.walk_graph(inp, now()) is distinct from mark then
        raise exception 'walk_graph built the graph although a current one was kept';
    end if;
    -- A run as of a time before the links were made is never served it.
    if aiq.walk_graph(inp, now() - interval '2 days') is not distinct from mark then
        raise exception 'a run as of before the links was served the kept graph';
    end if;
    -- A changed link names another version: the marked document is no longer read.
    select id into e from aiq.edges where relation = 'walk_next'
       and src_id in (select id from aiq.nodes where entity_type = 'walk_cache_fixture') limit 1;
    update aiq.edges set valid_to = now() where id = e;
    if aiq.walk_graph(inp, now()) is not distinct from mark then
        raise exception 'a graph kept for links that have since changed was read';
    end if;
    if aiq.walk_graph(inp, now()) is distinct from aiq.walk_graph_build(inp, now()) then
        raise exception 'after a link changed, walk_graph is not the built graph';
    end if;
    raise notice 'query/38: a walk reads its graph from a kept document while its links are unchanged, and never after';
end $$;

rollback;
