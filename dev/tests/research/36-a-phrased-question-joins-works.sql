-- Coalescing (specs/build-knit-dream/coalescing.md §5, graph.md §7): a question minted from a phrasing joins claims
-- in different works that share no frame. One phrasing is one question however it is spaced or cased, and anything
-- that is not one polar sentence is refused. An agent's stance lands proposed and the writer's own lands confirmed.
-- A stance needs a readable revision, a real occurrence and yes, no or depends. claims.question_web shows a question
-- answered from two works, never a private work's answer to a stranger, never an unknown stance, and nothing answered
-- from one work. A stance is withdrawn only by whoever made it or the work's owner, by a later row.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000c0aa1', 'coalesce-writer@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000c0bb2', 'coalesce-second@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000c0cc3', 'coalesce-stranger@example.test', 'active');
insert into rbac.roles (name, description) values ('rp-coalesce-lister', 'may list research (test)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('rp-coalesce-lister', 'research', 'list') on conflict do nothing;
insert into rbac.user_roles (user_id, role) values
    ('00000000-0000-4000-8000-0000000c0aa1', 'rp-coalesce-lister'),
    ('00000000-0000-4000-8000-0000000c0bb2', 'rp-coalesce-lister');
insert into rbac.api_keys (id, user_id, label, key_hash, scopes) values
    ('00000000-0000-4000-8000-0000000c0dd4', '00000000-0000-4000-8000-0000000c0cc3', 'coalescer', 'coalesce-k1',
     '{research:select,research:insert}');

create temporary table ids (k text primary key, v text) on commit drop;
grant all on ids to authenticated;

-- Two writers, two listed works with no frame in common, and one private draft.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000c0aa1"}';
set local role authenticated;
do $$
declare base jsonb := '{"schema_version": "0.1", "edges": [],
        "sources": [{"id": "S1", "title": "A study", "url": "https://example.com/s", "origin": "Study"}]}';
begin
    insert into ids values ('a', research.submit_package(base || '{"title": "Drafting with a model", "visibility": "listed",
        "claims": [{"id": "A1", "kind": "Inference", "text": "Replacing the draft changes which ideas a writer reaches.", "source_ids": ["S1"]},
                   {"id": "A2", "kind": "Inference", "text": "The trial lasted a month.", "source_ids": ["S1"]}]}', null, 'rp-co-a')->>'revision_id');
    insert into ids values ('p', research.submit_package(base || '{"title": "A private draft", "visibility": "private",
        "claims": [{"id": "P1", "kind": "Inference", "text": "Checking early removes the feeling of understanding.", "source_ids": ["S1"]}]}', null, 'rp-co-p')->>'revision_id');
end $$;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000c0bb2"}';
do $$
declare base jsonb := '{"schema_version": "0.1", "edges": [],
        "sources": [{"id": "S1", "title": "A craft", "url": "https://example.com/c", "origin": "Craft"}]}';
begin
    insert into ids values ('b', research.submit_package(base || '{"title": "Two hundred omelettes", "visibility": "listed",
        "claims": [{"id": "B1", "kind": "Judgement", "text": "Long practice leaves a judgement no answer key supplies.", "source_ids": ["S1"]}]}', null, 'rp-co-b')->>'revision_id');
end $$;

-- An agent poses the question and proposes stances on both listed works.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000c0cc3", "api_key_id": "00000000-0000-4000-8000-0000000c0dd4"}';
do $$
declare
    q  uuid;
    q2 uuid;
    a  uuid := (select v::uuid from ids where k = 'a');
    b  uuid := (select v::uuid from ids where k = 'b');
    p  uuid := (select v::uuid from ids where k = 'p');
begin
    q := claims.pose_question('Does handing work to AI weaken the person''s own thinking?');
    q2 := claims.pose_question('  does handing   work to AI weaken the person''s own THINKING? ');
    assert q = q2, 'one phrasing is one question, however it is spaced or cased';
    insert into ids values ('q', q::text);
    begin
        perform claims.pose_question('AI weakens thinking.');
        raise exception 'a statement was minted as a question';
    exception when check_violation then null;
    end;
    begin
        perform claims.pose_question('Why?');
        raise exception 'a fragment was minted as a question';
    exception when check_violation then null;
    end;

    perform claims.propose_answer(a, 'A1', q, 'yes', 0.82::real);
    perform claims.propose_answer(b, 'B1', q, 'depends', 0.61::real);
    begin
        perform claims.propose_answer(p, 'P1', q, 'yes');
        raise exception 'a stance was proposed on a revision the agent cannot read';
    exception when no_data_found then null;
    end;
    begin
        perform claims.propose_answer(a, 'A9', q, 'yes');
        raise exception 'a stance was proposed on a claim that is not in the revision';
    exception when foreign_key_violation then null;
    end;
    begin
        perform claims.propose_answer(a, 'A1', q, 'unknown');
        raise exception 'unknown was accepted as a stance';
    exception when check_violation then null;
    end;
    begin
        perform claims.propose_answer(a, 'A1', gen_random_uuid(), 'yes');
        raise exception 'a stance was proposed on a question that does not exist';
    exception when no_data_found then null;
    end;
end $$;
reset role;

-- As the tables' owner: what was written, and that nothing was rewritten.
do $$
declare q uuid := (select v::uuid from ids where k = 'q');
begin
    assert (select phrasing from claims.questions where id = q) = 'Does handing work to AI weaken the person''s own thinking?'
       and (select subject from claims.questions where id = q) is null,
        'a phrased question keeps its words and has no frame';
    assert (select array_agg(claim_key || '/' || stance || '/' || status || '/' || p order by claim_key)
              from claims.answered where question_id = q) = '{A1/yes/proposed/0.82,B1/depends/proposed/0.61}',
        'an agent''s stances land proposed with the judge''s probability: '
        || (select array_agg(claim_key || '/' || stance || '/' || status) from claims.answered where question_id = q)::text;
    assert (select bool_and(t.actor_kind = 'agent') from claims.answered a join claims.tx t on t.id = a.tx where a.question_id = q),
        'and the transaction names the agent';
    begin
        insert into claims.questions (key, tx) values ('q:nothing', (select min(id) from claims.tx));
        raise exception 'a question with neither frame nor phrasing was stored';
    exception when check_violation then null;
    end;
end $$;

-- The writer confirms their own stance; the second writer's stays proposed.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000c0aa1"}';
set local role authenticated;
do $$
declare q uuid := (select v::uuid from ids where k = 'q');
begin
    perform claims.propose_answer((select v::uuid from ids where k = 'a'), 'A1', q, 'yes');
    perform claims.propose_answer((select v::uuid from ids where k = 'p'), 'P1', q, 'yes');
end $$;
reset role;
do $$
declare q uuid := (select v::uuid from ids where k = 'q');
begin
    assert (select status from claims.answered where question_id = q and claim_key = 'A1' order by id desc limit 1) = 'confirmed',
        'the writer''s own stance, made as a person, lands confirmed';
end $$;

-- A stranger reads the web: two listed works join, the private answer is invisible.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000c0bb2"}';
set local role authenticated;
do $$
declare
    q uuid := (select v::uuid from ids where k = 'q');
    w record;
begin
    select * into w from claims.question_web() where question = q;
    assert w.works = 2, 'a question answered from two works is in the web: ' || coalesce(w::text, 'nothing');
    assert (select array_agg(e->>'claim_key' || '/' || (e->>'stance') || '/' || (e->>'status') order by e->>'claim_key')
              from jsonb_array_elements(w.answers) e) = '{A1/yes/confirmed,B1/depends/proposed}',
        'with one answer per claim, the latest: ' || w.answers::text;
    assert not exists (select 1 from claims.question_web() x, jsonb_array_elements(x.answers) e where e->>'claim_key' = 'P1'),
        'a private work''s answer is never shown to anybody else';
    assert not exists (select 1 from claims.question_web(now(), 3) where question = q), 'and nothing short of p_min_works';
    assert not exists (select 1 from claims.question_web() x where x.phrasing is null),
        'a question whose answers are all unknown is not in the web';
    begin
        perform claims.withdraw_answer((select v::uuid from ids where k = 'a'), 'A1', q);
        raise exception 'a stranger withdrew the writer''s stance';
    exception when insufficient_privilege then null;
    end;
    perform claims.withdraw_answer((select v::uuid from ids where k = 'b'), 'B1', q);
    assert not exists (select 1 from claims.question_web() where question = q),
        'the work''s owner withdraws a stance on their work, and a question left with one work leaves the web';
    assert exists (select 1 from claims.question_web(now() - interval '1 hour', 1) where question = q) = false,
        'an as-of read before anything was said finds nothing';
end $$;
reset role;

do $$
declare q uuid := (select v::uuid from ids where k = 'q');
begin
    assert (select count(*) from claims.answered where question_id = q and claim_key = 'B1') = 2
       and (select op from claims.answered where question_id = q and claim_key = 'B1' order by id desc limit 1) = 'retract',
        'a withdrawal is a later row and the earlier one stays';
end $$;

rollback;
