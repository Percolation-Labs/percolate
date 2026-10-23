-- SEARCH LEADS EXPANDS ONE HOP, AND ONLY ALONG LINKS IT MAY COUNT (REM-1144, ai-query-layer/tripartite-search.md §2).
--
-- query/27 holds who may see a lead. This holds what a lead IS: which resources each layer contributes, which link
-- a hop may follow, how a memory's scope narrows every layer, and what the taxonomy writers refuse. Four-dimensional
-- vectors in demo-quad-a make every rank decidable by hand.
--
--   memory r1: R1 [1,0,0,0]  R2 [0,1,0,0]  R3 [0,0,1,0]      memory r2: R4 [1,0,0,0]
--   tags:      A (root) [0,0,1,0], B (child of A) [0,0,0,1]; B's dual "Where does the user work today?" [0,0,0,1]
--   links:     R3 -> A p 0.9   R4 -> A p 0.9   R2 -> B p 0.4   R2 -> the dual p 0.8   R1 -> B p NULL

\set ON_ERROR_STOP on

begin;

create temp table ids (name text primary key, id uuid) on commit drop;
grant select on ids to authenticated;
-- A fixture id by name, refusing a name that is not there, so no assertion below can pass on a missing row.
create function pg_temp.id(p_name text) returns uuid language plpgsql volatile as $$
declare v uuid;
begin
    select id into v from ids where name = p_name;
    if v is null then raise exception 'no fixture named %', p_name; end if;
    return v;
end $$;

do $$
declare v jsonb; r text; n int := 0; vecs jsonb := '[]';
begin
    insert into content.channels (name, kind, visibility) values ('test-leads', 'manual', 'public');
    foreach r in array array['R1:r1:[1,0,0,0]', 'R2:r1:[0,1,0,0]', 'R3:r1:[0,0,1,0]', 'R4:r2:[1,0,0,0]'] loop
        v := content.register_text('test-leads', split_part(r, ':', 1),
                                   jsonb_build_array(jsonb_build_object('content', 'leads fixture ' || split_part(r, ':', 1))),
                                   split_part(r, ':', 1), null, null,
                                   jsonb_build_object('agent', 'test-leads', 'run', split_part(r, ':', 2)));
        insert into ids values (split_part(r, ':', 1), (v->>'resource_id')::uuid);
        vecs := vecs || jsonb_build_array(jsonb_build_object(
            'chunk_id', (select c.id from content.resource_chunks c where c.resource_id = (v->>'resource_id')::uuid),
            'embedding', split_part(r, ':', 3)::jsonb));
    end loop;
    perform aiq.record_embeddings('demo-quad-a', vecs);

    v := claims.put_taxonomy('test-leads', '1', '[
        {"key": "b", "label": "B", "path": "A > B", "parent": "a",
         "questions": ["Where does the user work today?"]},
        {"key": "a", "label": "A", "path": "A", "questions": ["What did the user eat for lunch?"]}]'::jsonb);
    if (v->>'tags')::int <> 2 then
        raise exception 'put_taxonomy installed % tags, not 2 (a child listed before its parent)', v->>'tags';
    end if;
    insert into ids select 'A', id from claims.tags where source = 'test-leads' and key = 'a';
    insert into ids select 'B', id from claims.tags where source = 'test-leads' and key = 'b';
    insert into ids select 'Qwork', question_id from claims.tag_questions where tag_id = pg_temp.id('B');
    insert into ids select 'Qlunch', question_id from claims.tag_questions where tag_id = pg_temp.id('A');
    if (select parent_id from claims.tags where id = pg_temp.id('B'))
       is distinct from pg_temp.id('A') then
        raise exception 'B''s parent is not A';
    end if;

    -- A new taxonomy waits for its vectors through the source workflow, tags as well as questions.
    if jsonb_array_length(aiq.texts_to_embed('tags', 'demo-quad-a')) < 2 then
        raise exception 'the tags source does not offer the new tags to embed';
    end if;
    if not exists (select 1 from workflow.current_definition('embed_sources') d,
                          jsonb_array_elements(d.spec->'steps') s where s->'input'->>'source' = 'tags') then
        raise exception 'the source embedding workflow does not embed tags';
    end if;

    perform aiq.record_embeddings('demo-quad-a', jsonb_build_array(
        jsonb_build_object('chunk_id', pg_temp.id('A'), 'embedding', '[0,0,1,0]'::jsonb),
        jsonb_build_object('chunk_id', pg_temp.id('B'), 'embedding', '[0,0,0,1]'::jsonb),
        jsonb_build_object('chunk_id', pg_temp.id('Qwork'), 'embedding', '[0,0,0,1]'::jsonb),
        jsonb_build_object('chunk_id', pg_temp.id('Qlunch'), 'embedding', '[0,1,0,0]'::jsonb)));
    perform claims.link_resources('test', jsonb_build_array(
        jsonb_build_object('resource_id', pg_temp.id('R3'), 'tag_id', pg_temp.id('A'), 'p', 0.9),
        jsonb_build_object('resource_id', pg_temp.id('R4'), 'tag_id', pg_temp.id('A'), 'p', 0.9),
        jsonb_build_object('resource_id', pg_temp.id('R2'), 'tag_id', pg_temp.id('B'), 'p', 0.4),
        jsonb_build_object('resource_id', pg_temp.id('R2'), 'question_id', pg_temp.id('Qwork'), 'p', 0.8),
        jsonb_build_object('resource_id', pg_temp.id('R1'), 'tag_id', pg_temp.id('B'))));
    raise notice 'query/28: two memories, a two-level taxonomy with duals, and five links';
end $$;

-- The leads one call returns, as resource names in rank order.
create function pg_temp.leads(p_vector text, p_layers text, p_tags jsonb default null, p_questions jsonb default null,
                              p_min_p real default 0.5, p_run text default 'r1') returns text
language sql as $$
    select coalesce(string_agg(i.name, ' ' order by l.rank), '')
      from claims.search_leads('leads fixture', p_vector::vector, 'demo-quad-a',
                               jsonb_build_object('agent', 'test-leads', 'run', p_run),
                               p_layers => p_layers::text[], p_budget => 10, p_min_p => p_min_p,
                               p_tags => p_tags, p_questions => p_questions) l
      join ids i on i.id = l.resource_id;
$$;

do $$
declare
    a jsonb := jsonb_build_array(jsonb_build_object('id', pg_temp.id('A')));
    b jsonb := jsonb_build_array(jsonb_build_object('id', pg_temp.id('B')));
    q jsonb := jsonb_build_array(jsonb_build_object('id', pg_temp.id('Qwork')));
    got text;
    want text;
begin
    -- Documents alone: every resource of the memory, nearest first, and none of the other memory's.
    got := pg_temp.leads('[1,0,0,0]', '{documents}');
    if got not like 'R1 %' or got like '%R4%' or array_length(string_to_array(got, ' '), 1) <> 3 then
        raise exception 'documents alone gave "%": R1 first, three resources, none from memory r2', got;
    end if;

    -- A tag hop reaches exactly the resources linked at or above the floor, inside the scope.
    got := pg_temp.leads('[1,0,0,0]', '{tags}', a);
    if got <> 'R3' then raise exception 'tag A led to "%", not R3 (R4 is another memory''s)', got; end if;
    got := pg_temp.leads('[1,0,0,0]', '{tags}', a, p_run => 'r2');
    if got <> 'R4' then raise exception 'tag A in memory r2 led to "%", not R4', got; end if;

    -- Below the floor a link is not followed; lowering the floor follows it. A link with no p is certain.
    got := pg_temp.leads('[1,0,0,0]', '{tags}', b);
    if got <> 'R1' then raise exception 'tag B led to "%": only R1 (p NULL is certain; R2 at 0.4 is below 0.5)', got; end if;
    got := pg_temp.leads('[1,0,0,0]', '{tags}', b, p_min_p => 0.3);
    if got <> 'R1 R2' then raise exception 'tag B at floor 0.3 led to "%", not "R1 R2"', got; end if;

    -- A question hop, and the path a lead carries back.
    got := pg_temp.leads('[1,0,0,0]', '{questions}', null, q);
    if got <> 'R2' then raise exception 'the dual led to "%", not R2', got; end if;
    if (select l.path->0->>'via' from claims.search_leads('x', '[1,0,0,0]', 'demo-quad-a',
            '{"agent": "test-leads", "run": "r1"}', p_layers => '{questions}', p_questions => q) l) is distinct from 'question' then
        raise exception 'a question lead does not say it came through a question';
    end if;

    -- Without chosen tags, the nearest tag by vector is the hit: [0,0,1,0] is tag A, which leads to R3.
    got := pg_temp.leads('[0,0,1,0]', '{tags}');
    if got not like 'R3%' then raise exception 'the nearest tag to [0,0,1,0] led to "%", not R3 first', got; end if;

    -- Fused: a direct hit's path is empty, a hop's names its hop, and every layer's resource is in the list.
    want := (select string_agg(x, ' ' order by x) from unnest(string_to_array(
             pg_temp.leads('[1,0,0,0]', '{documents,tags,questions}', a, q), ' ')) x);
    if want <> 'R1 R2 R3' then raise exception 'the fused list holds "%", not R1, R2 and R3', want; end if;
    if (select l.path from claims.search_leads('x', '[1,0,0,0]', 'demo-quad-a', '{"agent": "test-leads", "run": "r1"}',
            p_tags => a, p_questions => q) l where l.resource_id = pg_temp.id('R1'))
       is distinct from '[]'::jsonb then
        raise exception 'R1 is the nearest document, so its path is empty';
    end if;

    -- What it refuses.
    begin
        perform claims.search_leads('x', '[1,0,0,0]', 'demo-quad-a', p_stores => '{brews}');
        raise exception 'search_leads searched brews, which no link reaches yet';
    exception when feature_not_supported then null;
    end;
    begin
        perform claims.search_leads('x', '[1,0,0,0]', 'demo-quad-a', p_layers => '{claims}');
        raise exception 'search_leads accepted a layer it does not have';
    exception when check_violation then null;
    end;
    raise notice 'query/28: each layer, the floor, the scope, the path and the refusals hold';
end $$;

-- The taxonomy writers.
do $$
declare v jsonb; before uuid;
begin
    before := pg_temp.id('B');
    v := claims.put_taxonomy('test-leads', '1', '[{"key": "b", "label": "B", "path": "A > B", "parent": "a"},
                                                   {"key": "a", "label": "A", "path": "A"}]'::jsonb);
    if (select id from claims.tags where source = 'test-leads' and key = 'b') is distinct from before then
        raise exception 'putting a taxonomy again gave a tag a new id';
    end if;
    begin
        perform claims.put_taxonomy('test-cycle', '1', '[{"key": "x", "label": "X", "path": "X", "parent": "y"},
                                                         {"key": "y", "label": "Y", "path": "Y", "parent": "x"}]'::jsonb);
        raise exception 'a taxonomy whose parents form a cycle was installed';
    exception when check_violation then null;
    end;
    begin
        perform claims.put_taxonomy('test-orphan', '1', '[{"key": "x", "label": "X", "path": "X", "parent": "nobody"}]'::jsonb);
        raise exception 'a tag naming a parent outside its taxonomy was installed';
    exception when foreign_key_violation then null;
    end;
    raise notice 'query/28: a taxonomy is put idempotently and its hierarchy stays a tree';
end $$;

-- A retired dual stops making its question readable; training records it with its own tx.
set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","orgs":["a0000000-0000-0000-0000-00000000000b"]}';
do $$
begin
    if not exists (select 1 from claims.questions where id = pg_temp.id('Qlunch')) then
        raise exception 'a live dual''s question is not readable';
    end if;
end $$;
reset role;
reset request.jwt.claims;
select claims.train_dual(pg_temp.id('A'), pg_temp.id('Qlunch'), 0, true,
                         'retired in query/28');
set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","orgs":["a0000000-0000-0000-0000-00000000000b"]}';
do $$
begin
    if exists (select 1 from claims.questions where id = pg_temp.id('Qlunch')) then
        raise exception 'a retired dual''s question is still readable through the dual';
    end if;
    raise notice 'query/28: a retired dual no longer makes its question readable';
end $$;
reset role;
reset request.jwt.claims;

rollback;
