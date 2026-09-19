-- Comparative relations (REM-479, comparison-and-trust.md *Stance labels*, specs/claims/graph.md §6): a reader
-- compares two works they may read, which need not be theirs; each stance's requirements are enforced by the write
-- function; an agent proposes and a person confirms; the reader who asserted a label may restate it; and a work the
-- reader may not read cannot be compared.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000479a1', 'cmp-a@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000479b1', 'cmp-b@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000479c1', 'cmp-reader@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000479d1', 'cmp-stranger@example.test', 'active');
insert into rbac.roles (name, description) values ('rp-cmp-lister', 'may list research (test)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('rp-cmp-lister', 'research', 'list') on conflict do nothing;
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000000479a1', 'rp-cmp-lister'),
                                                   ('00000000-0000-4000-8000-0000000479b1', 'rp-cmp-lister');
insert into rbac.api_keys (id, user_id, label, key_hash, scopes) values
    ('00000000-0000-4000-8000-0000000479e1', '00000000-0000-4000-8000-0000000479c1', 'agent', 'cmp-k1',
     '{packages:read-own,packages:create-private}');

create temporary table ids (k text primary key, v text) on commit drop;
grant all on ids to authenticated;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000479a1"}';
set local role authenticated;
do $$ begin
    insert into ids values ('wa', research.submit_package('{"schema_version": "0.1", "title": "Compare A", "visibility": "listed", "edges": [],
        "claims": [{"id": "A1", "kind": "Inference", "text": "Access raised build success.", "source_ids": ["S1"]},
                   {"id": "A2", "kind": "Inference", "text": "Output rose.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "Trial", "origin": "https://doi.org/10.5555/Hawthorn.2024", "url": ""}]}', null, 'rp-cmp-a')->>'revision_id');
    insert into ids values ('wp', research.submit_package('{"schema_version": "0.1", "title": "Compare private", "visibility": "private", "edges": [],
        "claims": [{"id": "P1", "kind": "Inference", "text": "Private.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "S", "origin": "Notes", "url": ""}]}', null, 'rp-cmp-p')->>'revision_id');
end $$;
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000479b1"}';
set local role authenticated;
do $$ begin
    insert into ids values ('wb', research.submit_package('{"schema_version": "0.1", "title": "Compare B", "visibility": "listed", "edges": [],
        "claims": [{"id": "B1", "kind": "Inference", "text": "Access lowered build success.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "Trial again", "origin": "10.5555/hawthorn.2024", "url": ""}]}', null, 'rp-cmp-b')->>'revision_id');
end $$;
reset role;

-- 1. A reader who owns neither work labels pairs from them.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000479c1"}';
set local role authenticated;
do $$
declare
    wa uuid := (select v::uuid from ids where k = 'wa');
    wb uuid := (select v::uuid from ids where k = 'wb');
    same_q jsonb := '{"frame_match": {"subject": "same", "outcome": "same", "evidence_type": "same", "population": "overlaps", "period": "same"},
                      "src": "Access raised build success", "dst": "Access lowered build success"}';
    every jsonb := '{"frame_match": {"subject": "same", "outcome": "same", "evidence_type": "same", "population": "overlaps", "period": "same",
                                     "setting": "same", "comparator": "same"},
                     "src": "Access raised build success", "dst": "Access lowered build success"}';
    bad record;
    r bigint;
begin
    for bad in select * from (values
        ('agrees without spans',             'agrees',               same_q - 'dst'),
        ('agrees on another question',       'agrees',               same_q #- '{frame_match,outcome}'),
        ('contradicts with an unchecked slot','contradicts',         same_q),
        ('different_scope with no differing slot', 'different_scope', same_q),
        ('same_source_opposite on an origin one side lacks', 'same_source_opposite', same_q || '{"shared_origin": "Another study"}'),
        ('a slot with an unknown value',     'agrees',               same_q || '{"frame_match": {"subject": "similar"}}')
    ) t(what, pred, spans) loop
        begin
            perform claims.assert_relation('A1', bad.pred, 'B1', wa, wb, null, bad.spans);
            raise exception 'accepted: %', bad.what;
        exception when check_violation then null;
        end;
    end loop;
    begin
        perform claims.assert_relation('A1', 'agrees', 'A2', wa, wa, null, same_q);
        raise exception 'a pair from one work was compared';
    exception when check_violation then null;
    end;
    begin
        perform claims.assert_relation('A1', 'agrees', 'P1', wa, (select v::uuid from ids where k = 'wp'), null, same_q);
        raise exception 'a private work was compared by a reader who cannot read it';
    exception when no_data_found then null;
    end;

    r := claims.assert_relation('A1', 'contradicts', 'B1', wa, wb, null, every, 'opposite directions, one question');
    assert (select status from claims.relations where id = r) = 'confirmed', 'a person''s label is confirmed';
    perform claims.assert_relation('A1', 'different_scope', 'B1', wa, wb, null, same_q || '{"frame_match": {"population": "differs"}}');
    perform claims.assert_relation('A1', 'same_source_opposite', 'B1', wa, wb, null, same_q || '{"shared_origin": "doi:10.5555/HAWTHORN.2024"}');
    perform claims.assert_relation('A2', 'qualifies', 'B1', wa, wb);
    perform claims.restate_relation(r, 'disputed', false, 'on a second reading');
    insert into ids values ('r', r::text);
end $$;
reset role;

-- 2. The reader's agent proposes, and cannot confirm.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000479c1", "api_key_id": "00000000-0000-4000-8000-0000000479e1"}';
set local role authenticated;
do $$
declare r bigint;
begin
    r := claims.assert_relation('A2', 'agrees', 'B1', (select v::uuid from ids where k = 'wa'), (select v::uuid from ids where k = 'wb'),
        null, '{"frame_match": {"subject": "same", "outcome": "same", "evidence_type": "same", "population": "same", "period": "same"},
                "src": "Output rose", "dst": "Access lowered build success"}');
    assert (select status from claims.relations where id = r) = 'proposed', 'an agent''s label is a proposal';
    begin
        perform claims.restate_relation(r, 'confirmed');
        raise exception 'an agent confirmed a label';
    exception when insufficient_privilege then null;
    end;
end $$;
reset role;

-- 3. Anybody may read the labels on listed works; nobody else may restate them.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000479d1"}';
set local role authenticated;
do $$
declare b1 uuid := (select claim_id from claims.expresses where revision_id = (select v::uuid from ids where k = 'wb') and claim_key = 'B1');
begin
    assert (select array_agg(predicate || '/' || status order by predicate) from claims.relations_at(b1) where predicate <> 'qualifies')
         = '{agrees/proposed,contradicts/disputed,different_scope/confirmed,same_source_opposite/confirmed}',
        'the stranger reads each label as it stands: ' ||
        (select array_agg(predicate || '/' || status order by predicate) from claims.relations_at(b1))::text;
    begin
        perform claims.restate_relation((select v::bigint from ids where k = 'r'), 'confirmed');
        raise exception 'a stranger restated a reader''s label';
    exception when no_data_found then null;
    end;
end $$;

rollback;
