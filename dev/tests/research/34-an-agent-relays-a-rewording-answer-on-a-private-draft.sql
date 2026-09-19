-- A connected agent records the answer its person gave in conversation, same claim or new, on a private draft
-- (REM-622, specs/claims/graph.md §5). The transaction names the agent and its credential, which
-- claims.rewording_answers shows the owner and nobody else; the owner reverses the agent's answer with later rows,
-- and both stay in the history. On a revision others can read the agent is refused, and the refusal names what would
-- allow it; the owner still answers there.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000622a1', 'relay-owner@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000622b1', 'relay-stranger@example.test', 'active');
insert into rbac.api_keys (id, user_id, label, key_hash, scopes) values
    ('00000000-0000-4000-8000-0000000622c1', '00000000-0000-4000-8000-0000000622a1', 'agent', 'relay-k1',
     '{packages:read-own,packages:create-private}');

create temporary table ids (k text primary key, v text) on commit drop;
grant all on ids to authenticated;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000622a1"}';
set local role authenticated;
do $$
declare
    doc jsonb := '{"schema_version": "0.1", "title": "Relay", "visibility": "private", "edges": [],
        "sources": [{"id": "S1", "title": "S", "origin": "Notes", "url": ""}]}';
    r1 uuid; r2 uuid;
begin
    r1 := (research.submit_package(doc || '{"claims": [
        {"id": "C1", "kind": "Inference", "text": "Quinces are hard.", "source_ids": ["S1"]},
        {"id": "C2", "kind": "Inference", "text": "Quinces are yellow.", "source_ids": ["S1"]},
        {"id": "C3", "kind": "Inference", "text": "Quinces smell sweet.", "source_ids": ["S1"]}]}', null, 'rp-relay')->>'revision_id')::uuid;
    r2 := (research.revise_package('rp-relay', doc || '{"claims": [
        {"id": "C1", "kind": "Inference", "text": "Quinces are hard until cooked.", "source_ids": ["S1"]},
        {"id": "C2", "kind": "Inference", "text": "Ripe quinces are golden.", "source_ids": ["S1"]},
        {"id": "C3", "kind": "Inference", "text": "Quinces smell of honey.", "source_ids": ["S1"]}]}', 'draft-1')->>'revision_id')::uuid;
    insert into ids values ('r2', r2::text);
end $$;
reset role;
insert into ids select 'old_' || lower(e.claim_key), e.claim_id::text from claims.expresses e
 where e.revision_id = (select v::uuid from ids where k = 'r2');

-- The agent relays the person's answers on the private draft: C1 is the same claim, C2 a new one that supersedes it.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000622a1", "api_key_id": "00000000-0000-4000-8000-0000000622c1"}';
set local role authenticated;
do $$
declare
    r2 uuid := (select v::uuid from ids where k = 'r2');
    fresh uuid;
begin
    assert claims.answer_rewording(r2, 'C1', 'same') = (select v::uuid from ids where k = 'old_c1'),
        'an agent records same on a private draft';
    fresh := claims.answer_rewording(r2, 'C2', 'new', true);
    assert fresh <> (select v::uuid from ids where k = 'old_c2'), 'and new, which mints a claim';
    assert (select array_agg(claim_key || '/' || answer || '/' || actor_kind || '/' || credential_id order by n)
              from claims.rewording_answers(r2) with ordinality as a(claim_key, answer, at, actor_kind, credential_id, reverses_agent, n))
         = array['C1/same/agent/00000000-0000-4000-8000-0000000622c1', 'C2/new/agent/00000000-0000-4000-8000-0000000622c1'],
        'the answers name the agent and the connection it used';
    begin
        perform claims.answer_rewording(r2, 'C1', 'new');
        raise exception 'an agent answered a rewording twice';
    exception when check_violation then null;
    end;
    insert into ids values ('agent_c2', fresh::text);
end $$;
reset role;

do $$
begin
    assert (select actor_kind from claims.tx t join claims.expresses e on e.tx = t.id
             where e.revision_id = (select v::uuid from ids where k = 'r2') and e.claim_key = 'C1' and e.status = 'confirmed')
         = 'agent', 'the confirming row''s transaction is the agent''s';
    assert exists (select 1 from claims.relations where src = (select v::uuid from ids where k = 'agent_c2')
                    and predicate = 'supersedes' and status = 'proposed'),
        'an agent''s supersedes is a proposal';
end $$;

-- A stranger sees none of it.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000622b1"}';
set local role authenticated;
do $$ begin
    assert not exists (select 1 from claims.rewording_answers((select v::uuid from ids where k = 'r2'))),
        'a stranger reads no answers';
end $$;
reset role;

-- The person reverses both: C2 was the same claim after all, and C1 a new one.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000622a1"}';
set local role authenticated;
do $$
declare
    r2 uuid := (select v::uuid from ids where k = 'r2');
begin
    assert claims.answer_rewording(r2, 'C2', 'same') = (select v::uuid from ids where k = 'old_c2'),
        'the person reverses the agent''s new to same';
    assert claims.answer_rewording(r2, 'C1', 'new') <> (select v::uuid from ids where k = 'old_c1'),
        'and its same to new';
    assert (select array_agg(claim_key || '/' || answer || '/' || actor_kind || '/' || reverses_agent order by n)
              from claims.rewording_answers(r2) with ordinality as a(claim_key, answer, at, actor_kind, credential_id, reverses_agent, n))
         = array['C1/same/agent/false', 'C2/new/agent/false', 'C2/same/person/true', 'C1/new/person/true'],
        'the history keeps the agent''s answers and the person''s reversals';
    begin
        perform claims.answer_rewording(r2, 'C2', 'new');
        raise exception 'the person''s own answer was answered again';
    exception when check_violation then null;
    end;
end $$;
reset role;

do $$
declare
    r2 uuid := (select v::uuid from ids where k = 'r2');
    old_c2 uuid := (select v::uuid from ids where k = 'old_c2');
    agent_c2 uuid := (select v::uuid from ids where k = 'agent_c2');
begin
    assert (select claim_id::text || '/' || status || '/' || op from claims.expresses
             where revision_id = r2 and claim_key = 'C2' order by id desc limit 1) = old_c2 || '/confirmed/assert',
        'C2 now expresses its first claim, confirmed';
    assert exists (select 1 from claims.expresses where revision_id = r2 and claim_key = 'C2' and claim_id = agent_c2
                    and op = 'retract'), 'the agent''s link is retracted, not deleted';
    assert (select op from claims.relations where src = agent_c2 and predicate = 'supersedes' order by id desc limit 1)
         = 'retract', 'and its supersedes proposal is retracted';
end $$;

-- Once r2 can be read by others, the agent is refused C3, and told what would allow it; the person answers.
insert into research.exposures (revision_id, work_id, exposed_by)
select v.id, v.work_id, '00000000-0000-4000-8000-0000000622a1' from research.revisions v
 where v.id = (select v::uuid from ids where k = 'r2');
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000622a1", "api_key_id": "00000000-0000-4000-8000-0000000622c1"}';
set local role authenticated;
do $$
declare hint text; detail text; msg text;
begin
    perform claims.answer_rewording((select v::uuid from ids where k = 'r2'), 'C3', 'same');
    raise exception 'an agent answered a rewording on a listed revision';
exception when insufficient_privilege then
    get stacked diagnostics hint = pg_exception_hint, detail = pg_exception_detail, msg = message_text;
    assert hint = 'human_only', format('the reason code stays human_only, got %s', hint);
    assert msg like '%only on a private draft%', format('the message names the condition, got %s', msg);
    assert detail like '%private draft%' and detail like '%research:publish%',
        format('the detail names what would allow it, got %s', detail);
end $$;
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000622a1"}';
set local role authenticated;
do $$ begin
    assert claims.answer_rewording((select v::uuid from ids where k = 'r2'), 'C3', 'same') = (select v::uuid from ids where k = 'old_c3'),
        'the person answers on a listed revision';
end $$;
reset role;

rollback;
