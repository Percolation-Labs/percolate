-- A remembered fact bears on a question (REM-996, specs/claims/schema.sql §10a3). A memory edge ("Priya prefers
-- DuckDB") and a question ("Should the harbour analytics move off Postgres?") are joined by claims.bears_on: a link
-- someone proposed, which a person confirms or rejects, and never a stance. A link is readable only with both of
-- its ends, so a private fact's link is invisible to anyone who cannot read the fact. claims.facts_to_link offers
-- each unlinked fact its nearest questions in one space, shaped as the decider's request, and claims.edge_readable,
-- the definers' copy of aiq.edges' read policy, agrees with that policy for every caller tested here.
--
-- The vectors are three dimensions and hand-written. One transaction, rolled back.

\set ON_ERROR_STOP on

\set maya '''00000000-0000-4000-8000-0000000996a1'''
\set leo  '''00000000-0000-4000-8000-0000000996b1'''
\set as_maya 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-0000000996a1"}''; set local role authenticated;'
\set as_leo  'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-0000000996b1"}''; set local role authenticated;'
\set as_leos_agent 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-0000000996b1","api_key_id":"00000000-0000-4000-8000-0000000996e1"}''; set local role authenticated;'

begin;
set local role app_owner;
insert into rbac.users (id, email, status) values (:maya, 'rem996-maya@example.test', 'active'),
                                                  (:leo, 'rem996-leo@example.test', 'active');
insert into rbac.roles (name, description) values ('rp-rem996', 'may list and read research (test)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values
    ('rp-rem996', 'research', 'list'), ('rp-rem996', 'research', 'select'), ('rp-rem996', 'research', 'insert')
    on conflict do nothing;
insert into rbac.user_roles (user_id, role) values (:maya, 'rp-rem996'), (:leo, 'rp-rem996');
insert into rbac.api_keys (id, user_id, label, key_hash, scopes) values
    ('00000000-0000-4000-8000-0000000996e1', :leo, 'leos agent', 'rem996-k1', '{research:select,research:insert}');
insert into aiq.embedding_models (name, dim, provider, endpoint, is_default, notes)
values ('rem996-3d', 3, 'openai', 'https://example.invalid/v1/embeddings', false, 'every vector written by hand below');
select aiq.register_embedding_space('rem996-3d') \g /dev/null
insert into content.channels (name, kind, org_id, visibility)
    values ('rem996', 'manual', rbac.shared_org_id(), 'public') on conflict do nothing;
insert into content.resources (id, channel_id, external_id, uri, title, status, org_id, visibility, owner_id)
select '00000000-0000-4000-8000-0000000996d1'::uuid, c.id, 'maya-notes', 'memo://rem996/maya', 'Maya''s notes',
       'ready', rbac.shared_org_id(), 'private', :maya
  from content.channels c where c.name = 'rem996';
-- Two public typed entities, so a fact between them is hidden by its memory alone, not by its nodes.
create table public.rem996_tool (id uuid primary key default gen_random_uuid(), name text not null, org_id uuid);
select aiq.register_entity_table('rem996_tool', 'public.rem996_tool', 'n.name', 'n.name', 'n.org_id') \g /dev/null
insert into public.rem996_tool (name) values ('Postgres rem996'), ('DuckDB tool rem996');
select aiq.register_graph_vocabulary('[{"relation":"rem996_prefers"}]') \g /dev/null
-- A public fact (reference data, no memory behind it) and a private one read out of Maya's notes.
select aiq.upsert_graph('{"nodes":[{"k":"soft","n":"Priya rem996"},{"k":"soft","n":"DuckDB rem996"}],
                          "edges":[{"s":0,"t":1,"r":"rem996_prefers"}]}', '{"agent":"gazetteer"}') \g /dev/null
reset role;
set local role worker;
select aiq.upsert_graph('{"nodes":[{"k":"soft","n":"Maya rem996"},{"k":"soft","n":"SQLite rem996"}],
                          "edges":[{"s":0,"t":1,"r":"rem996_prefers"}]}',
                        '{"agent":"coach","resource_id":"00000000-0000-4000-8000-0000000996d1"}') \g /dev/null
-- Maya's notes also say something about two public tools: the nodes are public, the fact is hers.
select aiq.upsert_graph('{"nodes":[{"k":"rem996_tool","n":"Postgres rem996"},{"k":"rem996_tool","n":"DuckDB tool rem996"}],
                          "edges":[{"s":0,"t":1,"r":"rem996_prefers"}]}',
                        '{"agent":"coach","resource_id":"00000000-0000-4000-8000-0000000996d1"}') \g /dev/null
reset role;

create temporary table ids (k text primary key, v uuid) on commit drop;
grant all on ids to authenticated;
insert into ids
select case when f.content like 'Priya rem996%' then 'pub' when f.content like 'Postgres rem996%' then 'priv2'
            else 'priv' end, f.id
  from claims.fact_texts f where f.relation = 'rem996_prefers';
do $$
begin
    assert (select count(*) from ids) = 3, 'the three facts read as words, as the owner: '
        || (select string_agg(content, ' | ') from claims.fact_texts where relation = 'rem996_prefers');
end $$;

-- A question Maya's own listed work answers, so it is readable to both.
:as_maya
do $$
declare
    q uuid := claims.pose_question('Should the harbour analytics move off Postgres?');
    r uuid := (research.submit_package('{"schema_version": "0.1", "title": "Warehouse", "visibility": "listed", "edges": [],
                   "claims": [{"id": "C1", "kind": "Inference", "text": "A column store answers the aggregates faster.", "source_ids": ["S1"]}],
                   "sources": [{"id": "S1", "title": "S", "url": "https://example.com/rem996", "origin": "W"}]}', null, 'rp-rem996')->>'revision_id')::uuid;
begin
    perform claims.propose_answer(r, 'C1', q, 'depends');
    insert into ids values ('q', q);
end $$;

-- 1. edge_readable agrees with aiq.edges' policy, as Maya and as Leo.
do $$
begin
    assert (select bool_and(claims.edge_readable(v) = exists (select 1 from aiq.edges e where e.id = ids.v))
              from ids where k in ('pub', 'priv', 'priv2')), 'edge_readable disagrees with the policy for Maya';
    assert claims.edge_readable((select v from ids where k = 'priv')), 'Maya reads her own fact';
end $$;
:as_leo
do $$
begin
    assert (select bool_and(claims.edge_readable(v) = exists (select 1 from aiq.edges e where e.id = ids.v))
              from ids where k in ('pub', 'priv', 'priv2')), 'edge_readable disagrees with the policy for Leo';
    assert not claims.edge_readable((select v from ids where k = 'priv')), 'Leo cannot read Maya''s fact';
    assert not claims.edge_readable((select v from ids where k = 'priv2')),
        'nor her fact about two public tools: its memory hides it, not its nodes';
end $$;

-- 2. Leo's agent proposes the public fact; it lands proposed, with no stance anywhere on the row.
:as_leos_agent
do $$
declare v_link bigint;
begin
    v_link := claims.propose_bears_on((select v from ids where k = 'pub'), (select v from ids where k = 'q'), 0.82);
    assert (select status from claims.bears_on where bears_on.id = v_link) = 'proposed', 'an agent''s link lands proposed';
    begin
        perform claims.propose_bears_on((select v from ids where k = 'priv'), (select v from ids where k = 'q'), 0.9);
        raise exception 'a link was proposed on a fact the proposer cannot read';
    exception when no_data_found then null;
    end;
    begin
        perform claims.review_bears_on((select v from ids where k = 'pub'), (select v from ids where k = 'q'), 'confirmed');
        raise exception 'an agent confirmed a link';
    exception when insufficient_privilege then null;
    end;
end $$;

-- 3. Maya links her private fact and confirms the public one; Leo sees only the public link.
:as_maya
do $$
begin
    perform claims.propose_bears_on((select v from ids where k = 'priv'), (select v from ids where k = 'q'), 0.7);
    perform claims.review_bears_on((select v from ids where k = 'pub'), (select v from ids where k = 'q'), 'confirmed');
    assert (select array_agg(status order by status) from claims.facts_on_question((select v from ids where k = 'q')))
           = '{confirmed,proposed}', 'Maya reads both links from the question, the confirmed one first';
    assert (select phrasing from claims.questions_of_fact((select v from ids where k = 'priv')))
           = 'Should the harbour analytics move off Postgres?', 'and from her fact to its question';
    assert (select depends from claims.questions_of_fact((select v from ids where k = 'pub'))) = 1,
        'a fact''s question comes with its stances';
end $$;
:as_leo
do $$
begin
    assert (select array_agg(content) from claims.facts_on_question((select v from ids where k = 'q')))
           = '{"Priya rem996 rem996 prefers DuckDB rem996"}',
        'Leo sees the public fact''s link and not Maya''s: '
        || coalesce((select array_agg(content)::text from claims.facts_on_question((select v from ids where k = 'q'))), '{}');
    assert (select count(*) from claims.bears_on where edge_id = (select v from ids where k = 'priv')) = 0,
        'the private link is not even a row to Leo';
end $$;

-- 4. A rejection is a later row, and a rejected link drops out of both reads.
:as_maya
do $$
begin
    perform claims.review_bears_on((select v from ids where k = 'priv'), (select v from ids where k = 'q'), 'rejected');
    assert (select count(*) from claims.questions_of_fact((select v from ids where k = 'priv'))) = 0,
        'a rejected link is not read';
    assert (select count(*) from claims.bears_on where edge_id = (select v from ids where k = 'priv')) = 2,
        'and the proposal it rejected is still there';
end $$;
reset role;

-- 5. Candidates: an unlinked fact is offered its nearest question, shaped as the decider's request.
reset request.jwt.claims;
insert into aiq."emb_rem996_3d" (chunk_id, embedding) values
    ((select v from ids where k = 'q'), '[1,0,0]'), ((select v from ids where k = 'pub'), '[1,0.1,0]');
do $$
declare r record;
begin
    -- The public fact is already linked, so nothing is offered; a fresh fact with a vector is.
    assert (select count(*) from claims.facts_to_link('rem996-3d')) = 0, 'a linked fact is not offered again';
    set local role app_owner;
    perform aiq.upsert_graph('{"nodes":[{"k":"soft","n":"Ravi rem996"},{"k":"soft","n":"DuckDB rem996"}],
                               "edges":[{"s":0,"t":1,"r":"rem996_prefers"}]}', '{"agent":"gazetteer"}');
    reset role;
    insert into aiq."emb_rem996_3d" (chunk_id, embedding)
    select f.id, '[0.9,0.2,0]' from claims.fact_texts f where f.content like 'Ravi rem996%';
    select * into r from claims.facts_to_link('rem996-3d');
    assert r.candidates->'q01'->>'id' = (select v::text from ids where k = 'q'), 'its nearest question is the first option';
    assert r.body->>'model' = 'jev-1.13.0' and r.body->'questions'->'bears_on'->'criteria' ? 'none_of_these',
        'the body is the decider''s request, with none of these as an option: ' || r.body::text;
    begin
        perform claims.facts_to_link('rem996-3d', 'nobody');
        raise exception 'an unconfigured decider was offered work';
    exception when no_data_found then null;
    end;
    begin
        perform claims.install_fact_question_workflow('rem996-3d', 'nobody');
        raise exception 'a workflow was installed for an unconfigured decider';
    exception when no_data_found then null;
    end;
    perform claims.install_fact_question_workflow('rem996-3d', 'jev', 'link_facts_rem996');
    assert (select count(*) from workflow.definitions where name = 'link_facts_rem996') = 1, 'the workflow is defined';
end $$;

rollback;
