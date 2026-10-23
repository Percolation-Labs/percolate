-- A LEAD IS A RESOURCE THE CALLER MAY READ (REM-1144, ai-query-layer/tripartite-search.md).
--
-- claims.search_leads expands a tag or question hit one hop along its edges in aiq.edges. A tag and its dual
-- questions are shared vocabulary, readable by anyone, so the hop is where another tenant's resource could leak: a
-- tag every tenant can match, linked to a memo only org A may read. This holds that the hop reads the links as the
-- caller, that the private memo never becomes org B's lead, that org B's own resource does, and that the writers
-- refuse a caller who may not write.

\set ON_ERROR_STOP on

begin;

do $$
begin
    if not exists (select 1 from content.resources where id = '22220000-0000-0000-0000-000000000004') then
        raise exception 'the corpus sample is not loaded (dev/init/05-corpus-sample.sql)';
    end if;
end $$;

-- One tag, one dual question, both near the probe vector, linked to org A's memo and to org B's resource.
do $$
declare v jsonb; v_tag uuid; v_q uuid;
begin
    v := claims.put_taxonomy('test-tenancy', '1', '[{"key": "memo", "label": "Memo", "path": "Memo",
                                                     "questions": ["Who wrote the quarterly memo?"]}]'::jsonb);
    if (v->>'tags')::int <> 1 or (v->>'duals')::int <> 1 then
        raise exception 'put_taxonomy installed % rather than one tag with one dual', v;
    end if;
    select id into v_tag from claims.tags where source = 'test-tenancy' and key = 'memo';
    select q.entity_id into v_q from aiq.edges e join aiq.nodes t on t.id = e.src_id join aiq.nodes q on q.id = e.dst_id
     where e.relation = 'dual' and t.entity_type = 'tag' and t.entity_id = v_tag;
    -- The question is a sentence and gets a vector; the tag is a word and is found by it ("memo" in the query).
    perform aiq.record_embeddings('demo-quad-a', jsonb_build_array(
        jsonb_build_object('chunk_id', v_q, 'embedding', '[1,0,0,0]'::jsonb)));
    perform claims.link_resources('test', jsonb_build_array(
        jsonb_build_object('resource_id', '22220000-0000-0000-0000-000000000004', 'tag_id', v_tag, 'p', 0.9),
        jsonb_build_object('resource_id', '22220000-0000-0000-0000-000000000005', 'tag_id', v_tag, 'p', 0.9),
        jsonb_build_object('resource_id', '22220000-0000-0000-0000-000000000004', 'question_id', v_q, 'p', 0.9),
        jsonb_build_object('resource_id', '22220000-0000-0000-0000-000000000005', 'question_id', v_q, 'p', 0.9),
        -- a repeated link in one call is one row, at the higher p
        jsonb_build_object('resource_id', '22220000-0000-0000-0000-000000000005', 'question_id', v_q, 'p', 0.95)));
    if (select e.weight from aiq.edges e join aiq.nodes r on r.id = e.src_id join aiq.nodes q on q.id = e.dst_id
         where e.relation = 'answers' and q.entity_type = 'question' and q.entity_id = v_q
           and r.entity_type = 'document' and r.entity_id = '22220000-0000-0000-0000-000000000005') is distinct from 0.95::real then
        raise exception 'a link named twice in one call did not keep the higher p';
    end if;
    raise notice 'query/27: a tag and its dual link org A''s memo and org B''s resource';
end $$;

set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","orgs":["a0000000-0000-0000-0000-00000000000b"]}';

do $$
declare v_layers text; v_ids uuid[]; v_seen int;
begin
    -- The vocabulary is readable, and so is the dual question, before any of org B's own links are counted.
    if not exists (select 1 from claims.tags where source = 'test-tenancy') then
        raise exception 'org B cannot read a shared tag';
    end if;
    if not exists (select 1 from claims.questions q join aiq.nodes qn on qn.entity_type = 'question' and qn.entity_id = q.id
                    join aiq.edges e on e.dst_id = qn.id and e.relation = 'dual'
                    join aiq.nodes tn on tn.id = e.src_id join claims.tags g on g.id = tn.entity_id
                   where g.source = 'test-tenancy') then
        raise exception 'org B cannot read a tag''s dual question';
    end if;
    select count(*) into v_seen from aiq.edges e join aiq.nodes tn on tn.id = e.dst_id and tn.entity_type = 'tag'
      join claims.tags g on g.id = tn.entity_id
     where e.relation = 'tagged' and g.source = 'test-tenancy';
    if v_seen <> 1 then
        raise exception 'org B reads % tag links; it may read one, to its own resource', v_seen;
    end if;

    foreach v_layers in array array['{tags}', '{questions}', '{documents,tags,questions}'] loop
        select array_agg(resource_id) into v_ids
          from claims.search_leads('quarterly memo', '[1,0,0,0]', 'demo-quad-a', p_layers => v_layers::text[], p_budget => 50);
        if '22220000-0000-0000-0000-000000000004' = any(coalesce(v_ids, '{}')) then
            raise exception 'org A''s private memo is org B''s lead through %', v_layers;
        end if;
        if not ('22220000-0000-0000-0000-000000000005' = any(coalesce(v_ids, '{}'))) then
            raise exception 'org B''s own resource is missing from its leads through % (got %)', v_layers, v_ids;
        end if;
    end loop;

    begin
        perform claims.link_resources('test', jsonb_build_array(jsonb_build_object(
            'resource_id', '22220000-0000-0000-0000-000000000004',
            'tag_id', (select id from claims.tags where source = 'test-tenancy'), 'p', 0.1)));
        raise exception 'org B linked org A''s memo';
    exception when insufficient_privilege then null;
    end;
    begin
        perform claims.put_taxonomy('test-tenancy', '2', '[{"key": "x", "label": "X", "path": "X"}]'::jsonb);
        raise exception 'a signed-in person installed a shared taxonomy';
    exception when insufficient_privilege then null;
    end;
    raise notice 'query/27: the hop reads links as the caller; the memo stays org A''s, and the writers refuse';
end $$;

reset role;
reset request.jwt.claims;

-- A parent is in the same taxonomy: a hierarchy cannot cross sources.
do $$
begin
    begin
        insert into claims.tags (source, source_version, key, label, path, parent_id, tx)
        select 'other', '1', 'child', 'Child', 'Child', g.id, g.tx from claims.tags g where g.source = 'test-tenancy';
        raise exception 'a tag took a parent from another taxonomy';
    exception when foreign_key_violation then null;
    end;
    raise notice 'query/27: a hierarchy stays inside its source and version';
end $$;

rollback;
