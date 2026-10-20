-- A claim is embedded when its revision is projected, and a question when it is posed (REM-662, specs/claims/graph.md
-- §5 *Did you mean*). Saving a package queues a run of `embed_sources` in the save's own transaction and calls no
-- model; the worker drains it later with `op: embed` over the source by name -- aiq.texts_to_embed for the rows the
-- space lacks, aiq.record_embeddings for the vectors -- and then claims.candidates over the freshly saved package
-- answers with no vector passed. With no default model, a save still projects, queues nothing, and says so.
--
-- THE WORKER IS PLAYED HERE, as `worker`, through the calls percolate-core's embed_source makes: claim_task,
-- texts_to_embed, record_embeddings, complete_task. Only the model is a stub: each vector is three numbers read off
-- the text (does it speak of memory, of time, of lensing), so the distances are exact and B1 is A1's neighbour
-- because their words say so. percolate-core tests/test_embed_source.py holds the worker's own loop.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000662a1', 'emb-a@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000662b1', 'emb-b@example.test', 'active');
insert into rbac.roles (name, description) values ('rp-emb-lister', 'may list and read research (test)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values
    ('rp-emb-lister', 'research', 'list'), ('rp-emb-lister', 'research', 'select') on conflict do nothing;
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000000662a1', 'rp-emb-lister'),
                                                   ('00000000-0000-4000-8000-0000000662b1', 'rp-emb-lister');

-- The default model is this test's own, served "in process" (fastembed) so nothing could call a provider, and
-- registered as app_owner so its space carries the read policy (research/35 says why that matters).
update aiq.embedding_models set is_default = false where is_default;
set local role app_owner;
insert into aiq.embedding_models (name, dim, provider, endpoint, is_default, notes)
values ('emb-test-3d', 3, 'fastembed', 'stub/emb-test-3d', true, 'three dimensions, every vector a stub below');
select aiq.register_embedding_space('emb-test-3d');
reset role;

-- The shipped workflow, reinstalled on a queue of this test's own, so no other task is claimed by mistake and no
-- fixture task waiting on `ingest` stands in for this one.
select aiq.install_source_embed_workflow(array['claims', 'questions'], 'embed_sources', 't_emb_662');

create temporary table ids (k text primary key, v text) on commit drop;
grant all on ids to authenticated, worker;

-- The stub model: [memory, time, lensing], each 1 when the text speaks of it, with a small constant so no vector is
-- zero. Cosine distance between A1 and B1 (both memory and time) is 0; to C1 (lensing) it is about 1.
create function pg_temp.stub_vector(p_text text) returns jsonb language sql immutable as $$
    select jsonb_build_array((p_text ~* 'memor')::int + 0.01, (p_text ~* 'time|when')::int + 0.01,
                             (p_text ~* 'lens|matter')::int + 0.01);
$$;

-- What the worker does with one claimed task: the rows the space lacks, a vector each, written back as `worker`.
create function pg_temp.drain(p_queue text) returns int language plpgsql as $$
declare
    t      workflow.tasks;
    v_rows jsonb;
    v_n    int := 0;
    v_tot  int := 0;
begin
    loop
        select * into t from workflow.claim_task(p_queue, 'emb-stub-worker');
        exit when t.id is null;
        loop
            v_rows := aiq.texts_to_embed(t.input->>'source', 'emb-test-3d', 2);
            exit when jsonb_array_length(v_rows) = 0;
            v_n := aiq.record_embeddings('emb-test-3d',
                       (select jsonb_agg(jsonb_build_object('chunk_id', r->>'chunk_id',
                                                            'embedding', pg_temp.stub_vector(r->>'content')))
                          from jsonb_array_elements(v_rows) r));
            v_tot := v_tot + v_n;
        end loop;
        perform workflow.complete_task(t.id, jsonb_build_object('result', jsonb_build_object('embedded', v_tot)),
                                       'emb-stub-worker');
    end loop;
    return v_tot;
end;
$$;
grant execute on function pg_temp.drain(text), pg_temp.stub_vector(text) to worker;

-- Two writers save. Neither save embeds anything.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000662a1"}';
set local role authenticated;
do $$
begin
    insert into ids values ('ra', research.submit_package('{"schema_version": "0.1", "title": "Emb A", "visibility": "listed", "edges": [],
        "claims": [{"id": "A1", "kind": "Inference", "text": "Agent memory has to record when each fact became true.", "source_ids": ["S1"]},
                   {"id": "A2", "kind": "Inference", "text": "Gravitational lensing traces total matter.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "S", "url": "https://example.com/ea", "origin": "EA"}]}', null, 'rp-emb-a')->>'revision_id');
end $$;
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000662b1"}';
set local role authenticated;
do $$
begin
    insert into ids values ('rb', research.submit_package('{"schema_version": "0.1", "title": "Emb B", "visibility": "listed", "edges": [],
        "claims": [{"id": "B1", "kind": "Inference", "text": "A memory store must keep the time a fact held.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "S", "url": "https://example.com/eb", "origin": "EB"}]}', null, 'rp-emb-b')->>'revision_id');
end $$;
reset role;
reset request.jwt.claims;

-- 1. The saves queued the work and did none of it: one waiting run covers both, a task per source, and the space is
--    still empty. So the claim is not yet askable, and says why by name.
do $$
declare
    v_def uuid := (workflow.current_definition('embed_sources')).id;
begin
    assert (select count(*) from workflow.runs where workflow_def_id = v_def) = 1,
        'two saves while a run waits start one run, not two';
    assert (select array_agg(t.input->>'source' order by t.step_key) from workflow.tasks t
              join workflow.runs r on r.id = t.run_id where r.workflow_def_id = v_def and t.status = 'ready')
           = array['claims', 'questions'],
        'the run waits on the queue with one `op: embed` task per source, named, and no model in it';
    assert (select count(*) from aiq."emb_emb_test_3d") = 0, 'a save writes no vector';
    assert (select count(*) from jsonb_array_elements(aiq.texts_to_embed('claims', 'emb-test-3d', 500))) = 3,
        'the three saved claims are what the space lacks';
end $$;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000662a1"}';
set local role authenticated;
do $$
begin
    perform claims.candidates((select v::uuid from ids where k = 'ra'), 'A1', 0.5);
    raise exception 'candidates answered before anything was embedded';
exception when no_data_found then
    if sqlerrm not like '%has no vector%' then
        raise exception 'refused for the wrong reason: %', sqlerrm;
    end if;
end $$;
-- Only the worker may read a source's text for embedding, or write a vector.
do $$
begin
    begin
        perform aiq.texts_to_embed('claims', 'emb-test-3d', 5);
        raise exception 'a person read texts_to_embed';
    exception when insufficient_privilege then null;
    end;
    begin
        perform aiq.record_embeddings('emb-test-3d', '[]');
        raise exception 'a person wrote vectors';
    exception when insufficient_privilege then null;
    end;
end $$;
reset role;
reset request.jwt.claims;

-- 2. The worker drains the queue: every claim gets a vector, the run succeeds, and nothing is left to embed.
set local role worker;
insert into ids select 'drain1', pg_temp.drain('t_emb_662');
reset role;
do $$
declare
    v_def uuid := (workflow.current_definition('embed_sources')).id;
    v_n   text := (select v from ids where k = 'drain1');
begin
    assert v_n = '3', 'the drain embedded the three claims, and there was no question yet: ' || v_n;
    assert (select status from workflow.runs where workflow_def_id = v_def) = 'succeeded', 'the run finished';
    assert (select jsonb_array_length(aiq.texts_to_embed('claims', 'emb-test-3d', 500))) = 0, 'nothing is left';
    assert (select array_agg(source || ':' || missing order by source) from aiq.source_embedding_status())
           = array['claims:0', 'questions:0'], 'status says the sources are embedded: '
           || (select array_agg(source || ':' || missing) from aiq.source_embedding_status())::text;
end $$;

-- 3. The freshly saved package is askable with no vector passed: A1's neighbour is B1, another writer's claim, and
--    the lensing claim in A1's own work is excluded as its own work, not ranked.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000662a1"}';
set local role authenticated;
do $$
declare
    r record;
begin
    select array_agg(c.claim_key order by c.distance) ks, min(c.distance) d into r
      from claims.candidates((select v::uuid from ids where k = 'ra'), 'A1', 0.5) c;
    assert r.ks = array['B1'], 'A1''s neighbour is B1: ' || coalesce(r.ks::text, 'none');
    assert r.d < 0.01, 'at the distance the stub puts them: ' || r.d;
end $$;

-- 4. A question is embedded the same way: posing it queues a run, the worker drains the `questions` source, and the
--    question is in the space.
do $$
begin
    insert into ids values ('q', claims.pose_question('Does agent memory need to record when a fact became true?'));
end $$;
reset role;
reset request.jwt.claims;
do $$
declare
    v_def uuid := (workflow.current_definition('embed_sources')).id;
begin
    assert (select count(*) from workflow.runs where workflow_def_id = v_def and status = 'running') = 1,
        'posing a question queued a second run, because the first had finished';
    assert (select array_agg(r->>'chunk_id') from jsonb_array_elements(aiq.texts_to_embed('questions', 'emb-test-3d', 500)) r)
           = array[(select v from ids where k = 'q')], 'the posed question is what the questions space lacks';
end $$;
set local role worker;
insert into ids select 'drain2', pg_temp.drain('t_emb_662');
reset role;
do $$
declare
    v_n text := (select v from ids where k = 'drain2');
begin
    assert v_n = '1', 'the drain embedded the one question: ' || v_n;
    assert exists (select 1 from aiq."emb_emb_test_3d" where chunk_id = (select v::uuid from ids where k = 'q')),
        'the question has a vector in the default space';
end $$;

-- 5. A deployment with no embedding model still projects revisions, queues nothing, and says so.
update aiq.embedding_models set is_default = false where is_default;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000662b1"}';
set local role authenticated;
do $$
begin
    insert into ids values ('rc', research.submit_package('{"schema_version": "0.1", "title": "Emb C", "visibility": "listed", "edges": [],
        "claims": [{"id": "C1", "kind": "Inference", "text": "Memory without time cannot answer about the past.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "S", "url": "https://example.com/ec", "origin": "EC"}]}', null, 'rp-emb-c')->>'revision_id');
end $$;
reset role;
reset request.jwt.claims;
do $$
declare
    v_def uuid := (workflow.current_definition('embed_sources')).id;
    v_q   jsonb;
begin
    assert exists (select 1 from research.claims where revision_id = (select v::uuid from ids where k = 'rc')),
        'the revision was projected';
    assert exists (select 1 from claims.expresses where revision_id = (select v::uuid from ids where k = 'rc')),
        'and its claims linked';
    assert (select count(*) from workflow.runs where workflow_def_id = v_def) = 2,
        'no run was queued for it: there is nothing to embed with';
    v_q := aiq.queue_source_embedding('a test');
    assert v_q->>'queued' = 'false' and v_q->>'reason' = 'no default embedding model',
        'the queue says why it did not queue: ' || v_q::text;
    assert (select model is null from aiq.source_embedding_status() where source = 'claims'),
        'status names no model';
end $$;

rollback;
