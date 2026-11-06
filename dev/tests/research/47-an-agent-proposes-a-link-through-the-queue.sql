-- A person's agent proposes a fact-to-question link through the judgement queue (REM-1324). The agent connected over
-- MCP had read claims.facts_to_link through the read-only query tool and had no way to write what it chose. A link
-- is now a judgement, kind 'link': claims.queue_link_judgements queues one per unlinked fact the caller may read,
-- claim_judgement shows the fact, what was said behind it and its candidate questions, and complete_judgement with
-- {"decision":"link"} proposes it through claims.propose_bears_on, as the judge.
--
-- THE CASE IS READ THROUGH THE FACT, NOT ITS NODES. Maya's notes say Postgres prefers DuckDB: two public tool rows,
-- a private fact. Leo may read both tools and the question, and must see no case for her fact. A policy that fell
-- back to the subject-node rule the other kinds use, or to the fact's nodes, would show it to him, and §2 raises.
--
-- WHAT WOULD MAKE IT FAIL. Read a link case through its nodes and §2 raises; let a verdict name a link nobody
-- proposed and §4 raises; let a decided none be queued again and §5 raises. One transaction, rolled back.

\set ON_ERROR_STOP on

\set maya '''00000000-0000-4000-8000-0000000132a1'''
\set leo  '''00000000-0000-4000-8000-0000000132b1'''
\set as_maya 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-0000000132a1"}''; set local role authenticated;'
\set as_mayas_agent 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-0000000132a1","api_key_id":"00000000-0000-4000-8000-0000000132e1"}''; set local role authenticated;'
\set as_leo  'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-0000000132b1"}''; set local role authenticated;'

begin;
set local role app_owner;
insert into rbac.users (id, email, status) values (:maya, 'rem1324-maya@example.test', 'active'),
                                                  (:leo, 'rem1324-leo@example.test', 'active');
insert into rbac.roles (name, description) values ('rp-rem1324', 'may list, read and write research (test)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values
    ('rp-rem1324', 'research', 'list'), ('rp-rem1324', 'research', 'select'), ('rp-rem1324', 'research', 'insert')
    on conflict do nothing;
insert into rbac.user_roles (user_id, role) values (:maya, 'rp-rem1324'), (:leo, 'rp-rem1324');
insert into rbac.api_keys (id, user_id, label, key_hash, scopes) values
    ('00000000-0000-4000-8000-0000000132e1', :maya, 'mayas agent', 'rem1324-k1', '{research:select,research:insert}');
insert into aiq.embedding_models (name, dim, provider, endpoint, is_default, notes)
values ('rem1324-3d', 3, 'openai', 'https://example.invalid/v1/embeddings', false, 'every vector written by hand below');
select aiq.register_embedding_space('rem1324-3d') \g /dev/null
insert into content.channels (name, kind, org_id, visibility)
    values ('rem1324', 'manual', rbac.shared_org_id(), 'public') on conflict do nothing;
insert into content.resources (id, channel_id, external_id, uri, title, status, org_id, visibility, owner_id)
select '00000000-0000-4000-8000-0000000132d1'::uuid, c.id, 'maya-notes', 'memo://rem1324/maya', 'Maya''s notes',
       'ready', rbac.shared_org_id(), 'private', :maya
  from content.channels c where c.name = 'rem1324';
insert into content.resource_chunks (resource_id, ordinal, content) values
    ('00000000-0000-4000-8000-0000000132d1', 0, 'Maya, 3 March: Postgres rem1324 should hand the scans to DuckDB rem1324.');
create table public.rem1324_tool (id uuid primary key default gen_random_uuid(), name text not null, org_id uuid);
select aiq.register_entity_table('rem1324_tool', 'public.rem1324_tool', 'n.name', 'n.name', 'n.org_id') \g /dev/null
insert into public.rem1324_tool (name) values ('Postgres rem1324'), ('DuckDB rem1324');
select aiq.register_graph_vocabulary('[{"relation":"rem1324_prefers"}]') \g /dev/null
-- A public fact, reference data with no memory behind it.
select aiq.upsert_graph('{"nodes":[{"k":"soft","n":"Priya rem1324"},{"k":"soft","n":"Arrow rem1324"}],
                          "edges":[{"s":0,"t":1,"r":"rem1324_prefers"}]}', '{"agent":"gazetteer"}') \g /dev/null
reset role;
-- Maya's notes say something about two public tools: the nodes are public, the fact is hers.
set local role worker;
select aiq.upsert_graph('{"nodes":[{"k":"rem1324_tool","n":"Postgres rem1324"},{"k":"rem1324_tool","n":"DuckDB rem1324"}],
                          "edges":[{"s":0,"t":1,"r":"rem1324_prefers"}]}',
                        '{"agent":"coach","resource_id":"00000000-0000-4000-8000-0000000132d1"}') \g /dev/null
reset role;

create temporary table ids (k text primary key, v uuid) on commit drop;
grant all on ids to authenticated;
insert into ids
select case when f.content like 'Priya rem1324%' then 'pub' else 'priv' end, f.id
  from claims.fact_texts f where f.relation = 'rem1324_prefers';

-- A question Maya's own listed work answers, so it is readable to both.
:as_maya
do $$
declare
    q uuid := claims.pose_question('Should the rem1324 analytics move off Postgres?');
    r uuid := (research.submit_package('{"schema_version": "0.1", "title": "Warehouse", "visibility": "listed", "edges": [],
                   "claims": [{"id": "C1", "kind": "Inference", "text": "A column store answers the aggregates faster.", "source_ids": ["S1"]}],
                   "sources": [{"id": "S1", "title": "S", "url": "https://example.com/rem1324", "origin": "W"}]}', null, 'rp-rem1324')->>'revision_id')::uuid;
begin
    perform claims.propose_answer(r, 'C1', q, 'yes');
    insert into ids values ('q', q);
end $$;
reset role;
reset request.jwt.claims;
insert into aiq."emb_rem1324_3d" (chunk_id, embedding) values
    ((select v from ids where k = 'q'), '[1,0,0]'), ((select v from ids where k = 'pub'), '[1,0.1,0]'),
    ((select v from ids where k = 'priv'), '[1,0,0.1]');
do $$
begin
    assert (select count(*) from ids) = 3, 'two facts and a question';
    assert claims.question_readable((select v from ids where k = 'q')) is not false, 'the question exists';
end $$;

-- 1. Leo queues first: only the fact he may read gets a case. Maya then queues hers; the public one is live already.
:as_leo
do $$
begin
    assert claims.queue_link_judgements('rem1324-3d') = 1, 'Leo queues a case for the public fact alone';
    assert not exists (select 1 from aiq.judgements where kind = 'link' and subject_node_id = (select v from ids where k = 'priv')),
        'and none for Maya''s fact, which he cannot read';
end $$;
:as_maya
do $$
begin
    assert claims.queue_link_judgements('rem1324-3d') = 1, 'Maya queues her own fact; the public one already waits';
    assert claims.queue_link_judgements('rem1324-3d') = 0, 'and queueing again adds nothing';
    assert (select count(*) from aiq.judgements where kind = 'link') = 2, 'Maya sees both cases';
end $$;
reset role;
insert into ids select 'priv_case', id from aiq.judgements where kind = 'link' and subject_node_id = (select v from ids where k = 'priv');

-- 2. THE POLICY. Leo can read both tools the private fact names and the question, and sees no case for it: not in
-- the table, not in the list, not by id.
:as_leo
do $$
declare v_case uuid := (select v from ids where k = 'priv_case');
begin
    assert claims.question_readable((select v from ids where k = 'q')), 'Leo can read the question';
    assert (select count(*) from aiq.nodes where entity_type = 'rem1324_tool') = 2,
        'and both tool nodes the private fact names';
    assert (select array_agg(subject_node_id) from aiq.judgements where kind = 'link')
           = array[(select v from ids where k = 'pub')],
        'Leo sees the public fact''s case and not Maya''s: a case is read through its fact, not its nodes';
    assert (select count(*) from jsonb_array_elements(aiq.list_judgements()) x where x->>'kind' = 'link') = 1,
        'list_judgements shows him one link case';
    begin
        perform aiq.claim_judgement(null, v_case);
        raise exception 'Leo claimed the case for a fact he cannot read';
    exception when others then
        if sqlerrm not like '%is not open to you%' then raise; end if;
    end;
end $$;

-- 3. Maya's agent claims her case: the fact, what was said behind it, when it began to hold, and the question.
:as_mayas_agent
do $$
declare c jsonb;
begin
    c := aiq.claim_judgement(array['link'], (select id from aiq.judgements
                                               where kind = 'link' and subject_node_id = (select v from ids where k = 'priv')));
    assert c->>'kind' = 'link', 'a link case: ' || c::text;
    assert c->'evidence'->'said' @> '[{"said": "Maya, 3 March: Postgres rem1324 should hand the scans to DuckDB rem1324."}]',
        'the agent reads the sentence behind the fact: ' || (c->'evidence')::text;
    assert c->'evidence'->>'valid_from' is not null, 'and when it began to hold';
    assert c->'evidence'->'candidates'->0->>'question_id' = (select v::text from ids where k = 'q'),
        'and the question nearest it';
    assert c->>'how_to_decide' like '%"decision":"link"%', 'and how to decide it';
end $$;

-- 4. A verdict written straight onto the row names a link nobody proposed, and is refused; a target that is not a
-- candidate is refused; the agent's link lands proposed, with its confidence and reason, recorded on the case.
:as_mayas_agent
do $$
declare j uuid := (select id from aiq.judgements where kind = 'link' and subject_node_id = (select v from ids where k = 'priv'));
        r jsonb;
begin
    begin
        update aiq.judgements set status = 'decided', reason = 'x', tier = 'agent',
               verdict = jsonb_build_object('decision', 'link', 'target', (select v from ids where k = 'q'))
         where id = j;
        raise exception 'a link verdict was written with no proposal behind it';
    exception when others then
        if sqlerrm not like '%names the proposal%' then raise; end if;
    end;
    begin
        perform aiq.complete_judgement(j, jsonb_build_object('decision', 'link', 'target', gen_random_uuid()), 'x');
        raise exception 'a link to a question that is not a candidate was accepted';
    exception when others then
        if sqlerrm not like '%candidate questions%' then raise; end if;
    end;
    r := aiq.complete_judgement(j, jsonb_build_object('decision', 'link', 'target', (select v from ids where k = 'q'),
                                                      'confidence', 0.8),
                                'Her notes: "Postgres rem1324 should hand the scans to DuckDB rem1324."');
    assert r->>'status' = 'decided' and r->>'tier' = 'agent', 'decided, at tier agent: ' || r::text;
    assert (select status from claims.bears_on where edge_id = (select v from ids where k = 'priv')) = 'proposed'
       and (select round(p::numeric, 2) from claims.bears_on where edge_id = (select v from ids where k = 'priv')) = 0.80,
        'the link lands proposed, with the agent''s confidence as p';
    assert (select result->'bears_on_ids'->>0 from aiq.judgements where id = j)
           = (select id::text from claims.bears_on where edge_id = (select v from ids where k = 'priv')),
        'and the case records the link it wrote';
    assert (select array_agg(content) from claims.facts_on_question((select v from ids where k = 'q')))
           = '{"Postgres rem1324 rem1324 prefers DuckDB rem1324"}', 'Maya reads it from the question';
end $$;

-- 5. A case decided none is not queued again.
:as_maya
do $$
declare j uuid;
begin
    j := (aiq.claim_judgement(array['link'], (select id from aiq.judgements
                                               where kind = 'link' and subject_node_id = (select v from ids where k = 'pub')))->>'id')::uuid;
    perform aiq.complete_judgement(j, '{"decision": "none"}', 'Who prefers Arrow says nothing about leaving Postgres.');
    assert claims.queue_link_judgements('rem1324-3d') = 0, 'a fact decided none is not put to a judge again';
end $$;

reset role;
do $$ begin raise notice 'research/47: an agent proposes a link through the queue, and a private fact''s case stays private'; end $$;
rollback;
