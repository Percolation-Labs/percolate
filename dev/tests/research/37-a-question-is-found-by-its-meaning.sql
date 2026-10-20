-- A plain-English question finds the question it means (REM-998, specs/claims/schema.sql §10a2). Asked "does agent
-- memory need valid time?", the questions graph matched a question about clinical methods being "valid" in another
-- hospital, because a question had no vector and could be found only by its words. Here a question is a semantic
-- corpus: claims.find_question ranks the readable questions by distance and says which fall inside the caller's
-- floor, with their stances as of a date; claims.stance_changes says what moved an answer between two dates; and
-- claims.questions_to_embed lists what a space still lacks, for the workflow that fills it.
--
-- The vectors are three dimensions and hand-written, so each distance is exact: from [1,0,0], 0.0194 to [1,0.2,0],
-- 0.2929 to [1,1,0] and 1 to [0,1,0]. The memory question sits on the query, the clinical one shares its words and
-- sits far away, and a private question sits nearer than the clinical one, so a horizon that leaked would show.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000998a1', 'qbm-writer@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000998b1', 'qbm-private@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000998c1', 'qbm-reader@example.test', 'active');
insert into rbac.roles (name, description) values ('rp-qbm-lister', 'may list and read research (test)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values
    ('rp-qbm-lister', 'research', 'list'), ('rp-qbm-lister', 'research', 'select') on conflict do nothing;
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000000998a1', 'rp-qbm-lister'),
                                                   ('00000000-0000-4000-8000-0000000998b1', 'rp-qbm-lister'),
                                                   ('00000000-0000-4000-8000-0000000998c1', 'rp-qbm-lister');

-- A model of the test's own, registered as app_owner so its space carries the read policy (as research/35 explains).
set local role app_owner;
insert into aiq.embedding_models (name, dim, provider, endpoint, is_default, notes)
values ('qbm-test-3d', 3, 'fastembed', 'qbm-test-3d', false, 'three dimensions, every vector written by hand below');
select aiq.register_embedding_space('qbm-test-3d');
reset role;

create temporary table ids (k text primary key, v uuid, tx bigint, at timestamptz) on commit drop;
grant all on ids to authenticated;

-- The writer's three listed works answer two questions; the third question is answered only from a private draft.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000998a1"}';
set local role authenticated;
do $$
declare
    pkg  text := '{"schema_version": "0.1", "title": "%s", "visibility": "%s", "edges": [],
                   "claims": [{"id": "C1", "kind": "Inference", "text": "%s", "source_ids": ["S1"]}],
                   "sources": [{"id": "S1", "title": "S", "url": "https://example.com/%s", "origin": "%s"}]}';
    qm   uuid := claims.pose_question('Should an agent''s memory record when each fact became true?');
    qc   uuid := claims.pose_question('Is a clinical method validated in one hospital valid in another?');
    r    uuid;
    a    bigint;
begin
    insert into ids (k, v) values ('qm', qm), ('qc', qc);
    r := (research.submit_package(format(pkg, 'Write time', 'listed', 'Write time is enough for memory.', 'w1', 'w1')::jsonb,
                                  null, 'rp-qbm-w1')->>'revision_id')::uuid;
    a := claims.propose_answer(r, 'C1', qm, 'no');
    insert into ids values ('w1', r, null, null), ('tx:w1', null, (select tx from claims.answered where id = a), '2026-09-08');
    r := (research.submit_package(format(pkg, 'Valid time', 'listed', 'Memory needs the time a fact held.', 'w2', 'w2')::jsonb,
                                  null, 'rp-qbm-w2')->>'revision_id')::uuid;
    a := claims.propose_answer(r, 'C1', qm, 'yes');
    insert into ids values ('w2', r, null, null), ('tx:w2', null, (select tx from claims.answered where id = a), '2026-09-22');
    a := claims.withdraw_answer((select v from ids where k = 'w1'), 'C1', qm);
    insert into ids values ('tx:w1-out', null, (select tx from claims.answered where id = a), '2026-10-14');
    r := (research.submit_package(format(pkg, 'Clinic', 'listed', 'Accuracy drops at a second site.', 'w3', 'w3')::jsonb,
                                  null, 'rp-qbm-w3')->>'revision_id')::uuid;
    a := claims.propose_answer(r, 'C1', qc, 'depends');
    insert into ids values ('w3', r, null, null), ('tx:w3', null, (select tx from claims.answered where id = a), '2026-09-03');
end $$;
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000998b1"}';
set local role authenticated;
do $$
declare
    qp uuid := claims.pose_question('Does an assistant need dated memories to answer about the past?');
    r  uuid := (research.submit_package('{"schema_version": "0.1", "title": "Private", "visibility": "private", "edges": [],
                   "claims": [{"id": "C1", "kind": "Inference", "text": "A private note on dated memory.", "source_ids": ["S1"]}],
                   "sources": [{"id": "S1", "title": "S", "url": "https://example.com/p", "origin": "P"}]}', null, 'rp-qbm-p')->>'revision_id')::uuid;
begin
    perform claims.propose_answer(r, 'C1', qp, 'yes');
    insert into ids (k, v) values ('qp', qp);
end $$;
reset role;

-- The history is dated: each answer's transaction moves to the day given above. claims.tx refuses rewrites, so
-- this fixture step alone runs with triggers off, as the owner.
set local session_replication_role = replica;
update claims.tx t set at = i.at from ids i where i.tx = t.id;
set local session_replication_role = origin;

-- The vectors, written as the space's owner: memory on the query, private just off it, clinical far away.
insert into aiq."emb_qbm_test_3d" (chunk_id, embedding)
select v, case k when 'qm' then '[1,0,0]' when 'qp' then '[1,0.2,0]' when 'qc' then '[0,1,0]' end::vector
  from ids where k in ('qm', 'qp', 'qc');

-- 1. A reader finds the memory question by meaning, first, inside the floor; the clinical one is beyond it.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000998c1"}';
set local role authenticated;
do $$
declare
    qm uuid := (select v from ids where k = 'qm');
    qc uuid := (select v from ids where k = 'qc');
    r  record;
begin
    select array_agg(f.question order by f.distance) qs, array_agg(round(f.distance::numeric, 4) order by f.distance) ds,
           array_agg(f.within order by f.distance) ins
      into r from claims.find_question('[1,0,0]'::vector, 0.5, 5, 'qbm-test-3d') f;
    assert r.qs = array[qm, qc], 'the memory question first, then the clinical one, and not the private one: ' || r.qs::text;
    assert r.ds = '{0.0000,1.0000}', 'the distance is the metric: ' || r.ds::text;
    assert r.ins = '{t,f}', 'within says which are close enough, so "none" is readable off it: ' || r.ins::text;
    -- Today: one yes from one work, the no withdrawn.
    select f.yes, f.no, f.works into r from claims.find_question('[1,0,0]'::vector, 0.5, 1, 'qbm-test-3d') f;
    assert (r.yes, r.no, r.works) = (1, 0, 1), 'today the memory question stands at one yes: ' || r::text;
    -- On 15 September: the no was the only answer.
    select f.yes, f.no, f.works into r
      from claims.find_question('[1,0,0]'::vector, 0.5, 1, 'qbm-test-3d', '2026-09-15T12:00Z') f;
    assert (r.yes, r.no, r.works) = (0, 1, 1), 'as of 15 September it stood at one no: ' || r::text;
    -- And what moved it.
    assert (select array_agg(c.change || ':' || coalesce(c.stance_then, '-') || '>' || coalesce(c.stance_now, '-')
                             order by c.changed_at)
              from claims.stance_changes(qm, '2026-09-15T12:00Z', now()) c) = '{added:->yes,withdrawn:no>-}',
        'stance_changes names the yes that arrived and the no that was withdrawn';
end $$;
reset role;

-- 2. The private question's owner finds it, nearer than the clinical one: the reader above was refused it by the
--    horizon, not by the ranking.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000998b1"}';
set local role authenticated;
do $$
begin
    assert (select array_agg(f.question order by f.distance) from claims.find_question('[1,0,0]'::vector, 0.5, 5, 'qbm-test-3d') f)
           @> array[(select v from ids where k = 'qp')],
        'its owner finds the private question';
end $$;
reset role;

-- 3. Refusals: no floor, no vector, the wrong width.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000998c1"}';
set local role authenticated;
do $$
begin
    begin
        perform claims.find_question('[1,0,0]'::vector, null, 5, 'qbm-test-3d');
        raise exception 'a null floor was accepted';
    exception when check_violation then null;
    end;
    begin
        perform claims.find_question(null, 0.5, 5, 'qbm-test-3d');
        raise exception 'a null vector was accepted';
    exception when check_violation then null;
    end;
    begin
        perform claims.find_question('[1,0]'::vector, 0.5, 5, 'qbm-test-3d');
        raise exception 'a vector of the wrong width was accepted';
    exception when data_exception then null;
    end;
end $$;
reset role;

-- 4. What a space still lacks: once the memory question's vector is gone, it is the one to embed, and the
--    workflow that embeds it fans out over exactly that. Asked as an operator, the run that indexes every question.
reset request.jwt.claims;
delete from aiq."emb_qbm_test_3d" where chunk_id = (select v from ids where k = 'qm');
do $$
begin
    assert (select array_agg(chunk_id) from claims.questions_to_embed('qbm-test-3d'))
           @> array[(select v from ids where k = 'qm')]
       and not (select array_agg(chunk_id) from claims.questions_to_embed('qbm-test-3d'))
           @> array[(select v from ids where k = 'qc')],
        'questions_to_embed lists the unembedded question and not the embedded one';
    -- A model served over HTTP is embedded by an `embed:` matrix of requests. One that runs inside the worker is
    -- a matrix of tasks the worker answers locally (REM-628): no url, in_process, the model id and dimension.
    insert into aiq.embedding_models (name, dim, provider, endpoint, is_default, notes)
    values ('qbm-test-http', 3, 'openai', 'https://example.invalid/v1/embeddings', false, 'defined, never called');
    perform claims.install_question_embed_workflow('qbm-test-http', 'embed_questions_test');
    assert (select spec->'steps'->0->'input'->>'rows' from workflow.definitions where name = 'embed_questions_test')
           like '%claims.questions_to_embed(''qbm-test-http'')%',
        'the installed workflow fans out over questions_to_embed';
    perform claims.install_question_embed_workflow('qbm-test-3d', 'embed_questions_local');
    assert (select spec#>'{steps,0,input,template,input}' from workflow.definitions where name = 'embed_questions_local')
           - 'embed' = '{"in_process": true, "model_id": "qbm-test-3d", "dim": 3, "timeout_ms": 30000}'::jsonb,
        format('an in-worker model compiles to a local task, not a request: %s',
               (select spec#>'{steps,0,input,template,input}' from workflow.definitions where name = 'embed_questions_local'));
    assert (select spec#>>'{steps,0,input,template,input,embed,model}' from workflow.definitions
             where name = 'embed_questions_local') = 'qbm-test-3d',
        'the local task names the model whose space it lands in';
end $$;

rollback;
