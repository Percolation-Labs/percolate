-- same_as between claims (REM-478, specs/claims/graph.md §5 and §9): it names an occurrence on each side, quotes a
-- span from each that its occurrence says, and records the slots compared; an agent proposes it and a person
-- confirms it; the other side's owner may dispute and do nothing else; an identity set never includes a proposed or
-- disputed edge or a claim the caller cannot read; and nothing is inherited, because a claim keeps its own
-- occurrences.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000478a1', 'same-a@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000478b1', 'same-b@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000478c1', 'same-stranger@example.test', 'active');
insert into rbac.roles (name, description) values ('rp-same-lister', 'may list research (test)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('rp-same-lister', 'research', 'list') on conflict do nothing;
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000000478a1', 'rp-same-lister'),
                                                   ('00000000-0000-4000-8000-0000000478b1', 'rp-same-lister');
insert into rbac.api_keys (id, user_id, label, key_hash, scopes) values
    ('00000000-0000-4000-8000-0000000478d1', '00000000-0000-4000-8000-0000000478a1', 'agent', 'same-k1',
     '{packages:read-own,packages:create-private}');

create temporary table ids (k text primary key, v text) on commit drop;
grant all on ids to authenticated;

-- The slots a proposal records for both sides.
create temporary table j (v jsonb) on commit drop;
grant all on j to authenticated;
insert into j values ('{"src": "Copies inflate confidence", "dst": "copies inflate confidence",
    "slots": {"src": {"subject": "counting copies", "predicate": "inflates", "object": "confidence", "scope": "readers", "polarity": "positive", "modality": "asserted"},
              "dst": {"subject": "counting copies", "predicate": "inflates", "object": "confidence", "scope": "readers", "polarity": "positive", "modality": "asserted"}}}');

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000478a1"}';
set local role authenticated;
do $$
begin
    insert into ids values ('wa', research.submit_package('{"schema_version": "0.1", "title": "Same A", "visibility": "listed", "edges": [],
        "claims": [{"id": "A1", "kind": "Inference", "text": "Copies inflate confidence without adding evidence.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "S", "url": "https://example.com/a", "origin": "A"}]}', null, 'rp-same-a')->>'revision_id');
    insert into ids values ('wp', research.submit_package('{"schema_version": "0.1", "title": "Same private", "visibility": "private", "edges": [],
        "claims": [{"id": "P1", "kind": "Inference", "text": "Copies inflate confidence, privately noted.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "S", "url": "https://example.com/p", "origin": "P"}]}', null, 'rp-same-p')->>'revision_id');
end $$;
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000478b1"}';
set local role authenticated;
do $$
begin
    insert into ids values ('wb', research.submit_package('{"schema_version": "0.1", "title": "Same B", "visibility": "listed", "edges": [],
        "claims": [{"id": "B1", "kind": "Inference", "text": "Counting copies inflates confidence: copies inflate confidence and add nothing.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "S", "url": "https://example.com/b", "origin": "B"}]}', null, 'rp-same-b')->>'revision_id');
end $$;
reset role;
insert into ids select 'a1', claim_id::text from claims.expresses where revision_id = (select v::uuid from ids where k = 'wa');
insert into ids select 'b1', claim_id::text from claims.expresses where revision_id = (select v::uuid from ids where k = 'wb');
insert into ids select 'p1', claim_id::text from claims.expresses where revision_id = (select v::uuid from ids where k = 'wp');

-- 1. A's agent proposes; what a proposal must carry is refused without it.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000478a1", "api_key_id": "00000000-0000-4000-8000-0000000478d1"}';
set local role authenticated;
do $$
declare
    wa uuid := (select v::uuid from ids where k = 'wa');
    wb uuid := (select v::uuid from ids where k = 'wb');
    sp jsonb := (select v from j);
    r  bigint;
begin
    begin
        perform claims.assert_relation('A1', 'same_as', 'B1', wa, wb, null, sp - 'dst');
        raise exception 'same_as without a span from the other side';
    exception when check_violation then null;
    end;
    begin
        perform claims.assert_relation('A1', 'same_as', 'B1', wa, wb, null, sp || '{"src": "Words A1 never says"}');
        raise exception 'same_as quoting words the occurrence does not say';
    exception when check_violation then null;
    end;
    begin
        perform claims.assert_relation('A1', 'same_as', 'B1', wa, wb, null, sp #- '{slots,dst,modality}');
        raise exception 'same_as without every compared slot';
    exception when check_violation then null;
    end;
    r := claims.assert_relation('A1', 'same_as', 'B1', wa, wb, null, sp, 'the publishing agent''s proposal');
    assert (select status from claims.relations where id = r) = 'proposed', 'an agent''s same_as is proposed';
    insert into ids values ('r', r::text);
end $$;
reset role;

-- 2. A proposed edge extends no identity set; a person confirms it and then it does, for anybody who can read both.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000478c1"}';
set local role authenticated;
do $$ begin
    assert claims.claim((select v::uuid from ids where k = 'a1'))->'identity_set' = to_jsonb(array[(select v::uuid from ids where k = 'a1')]),
        'a proposed same_as extends no identity set';
end $$;
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000478a1"}';
set local role authenticated;
do $$ begin
    perform claims.restate_relation((select v::bigint from ids where k = 'r'), 'confirmed', false, 'I read both');
    -- And A confirms a same_as from the private work too.
    perform claims.assert_relation('P1', 'same_as', 'A1', (select v::uuid from ids where k = 'wp'), (select v::uuid from ids where k = 'wa'),
        null, (select v from j) || '{"src": "Copies inflate confidence", "dst": "Copies inflate confidence"}');
end $$;
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000478c1"}';
set local role authenticated;
do $$
declare
    a1 uuid := (select v::uuid from ids where k = 'a1');
    b1 uuid := (select v::uuid from ids where k = 'b1');
    c jsonb := claims.claim(a1);
begin
    assert c->'identity_set' @> to_jsonb(array[b1]), 'a confirmed same_as joins the set: ' || c::text;
    assert not c->'identity_set' @> to_jsonb(array[(select v::uuid from ids where k = 'p1')]),
        'but never a claim the caller cannot read';
    assert jsonb_array_length(c->'occurrences') = 1 and c->'occurrences'->0->>'claim_key' = 'A1',
        'nothing is inherited: A1 keeps its own occurrence, and B1''s record stays with B1';
end $$;
reset role;

-- 3. The other side disputes, and may do nothing else.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000478b1"}';
set local role authenticated;
do $$
declare r bigint := (select v::bigint from ids where k = 'r');
begin
    begin
        perform claims.restate_relation(r, 'confirmed');
        raise exception 'the other side confirmed somebody else''s same_as';
    exception when insufficient_privilege then null;
    end;
    begin
        perform claims.restate_relation(r, null, true);
        raise exception 'the other side retracted somebody else''s same_as';
    exception when insufficient_privilege then null;
    end;
    perform claims.restate_relation(r, 'disputed', false, 'B1 is scoped to readers, A1 is not');
end $$;
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000478c1"}';
set local role authenticated;
do $$
declare a1 uuid := (select v::uuid from ids where k = 'a1');
begin
    assert not claims.claim(a1)->'identity_set' @> to_jsonb(array[(select v::uuid from ids where k = 'b1')]),
        'a disputed same_as leaves the set';
    assert (select array_agg(status order by row_id) from claims.history(a1) where predicate = 'same_as')
         = '{proposed,confirmed,disputed}', 'and the history keeps every statement';
    begin
        perform claims.restate_relation((select v::bigint from ids where k = 'r'), 'disputed');
        raise exception 'a stranger disputed a same_as';
    exception when no_data_found then null;
    end;
end $$;

rollback;
