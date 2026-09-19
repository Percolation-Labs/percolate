-- Erasing a work erases its claims (REM-481, specs/claims/graph.md §13): after research.erase_work no occurrence,
-- assertion, claim, origin, question or transaction that only the work supported remains; what another work also
-- rests on survives; and the tombstone is counts, with no text.
--
-- One transaction, rolled back. erase_work is an operator's, so it runs as the tables' owner.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values ('00000000-0000-4000-8000-0000000481a1', 'erase-owner@example.test', 'active');
insert into rbac.roles (name, description) values ('rp-erase-lister', 'may list research (test)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('rp-erase-lister', 'research', 'list') on conflict do nothing;
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000000481a1', 'rp-erase-lister');

create temporary table ids (k text primary key, v text) on commit drop;
grant all on ids to authenticated;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000481a1"}';
set local role authenticated;
do $$
declare x1 uuid; x2 uuid; y uuid;
begin
    x1 := (research.submit_package('{"schema_version": "0.1", "title": "Erase X", "visibility": "listed",
        "claims": [{"id": "C1", "kind": "Inference", "text": "Kvass keeps a week.", "source_ids": ["S1", "S2"],
                    "frame": {"subject": "kvass", "outcome": "shelf life"}},
                   {"id": "C2", "kind": "Inference", "text": "Rye matters.", "source_ids": ["S1"],
                    "frame": {"subject": "xylophagy", "outcome": "only in X"}}],
        "sources": [{"id": "S1", "title": "Shared", "origin": "Zymurgy survey 2024", "url": ""},
                    {"id": "S2", "title": "Only X", "origin": "A notebook only X cites", "url": ""}],
        "edges": [{"source": "C1", "relation": "supports", "target": "C2"}]}', null, 'rp-erase-x')->>'revision_id')::uuid;
    x2 := (research.revise_package('rp-erase-x', '{"schema_version": "0.1", "title": "Erase X", "visibility": "listed",
        "claims": [{"id": "C1", "kind": "Inference", "text": "Kvass keeps a week.", "source_ids": ["S1"],
                    "frame": {"subject": "kvass", "outcome": "shelf life"}},
                   {"id": "C3", "kind": "Inference", "text": "Barley differs.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "Shared", "origin": "Zymurgy survey 2024", "url": ""}],
        "edges": [{"source": "C3", "relation": "qualifies", "target": "C1"}]}', 'draft-1')->>'revision_id')::uuid;
    y := (research.submit_package('{"schema_version": "0.1", "title": "Erase Y", "visibility": "listed",
        "claims": [{"id": "Y1", "kind": "Inference", "text": "Kvass keeps five days.", "source_ids": ["S1"],
                    "frame": {"subject": "Kvass", "outcome": "Shelf life"}},
                   {"id": "Y2", "kind": "Inference", "text": "Cold helps.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "Shared again", "origin": "zymurgy survey, 2024", "url": ""}],
        "edges": [{"source": "Y2", "relation": "supports", "target": "Y1"}]}', null, 'rp-erase-y')->>'revision_id')::uuid;
    -- A relation between the works, asserted from Y about X's C1: it rests on X too, so it goes with X.
    perform claims.assert_relation('Y1', 'qualifies', 'C1', y, x2);
    insert into ids values ('x1', x1::text), ('x2', x2::text), ('y', y::text);
end $$;
reset role;

do $$
declare
    x1 uuid := (select v::uuid from ids where k = 'x1');
    x2 uuid := (select v::uuid from ids where k = 'x2');
    y  uuid := (select v::uuid from ids where k = 'y');
    xs uuid[] := array[x1, x2];
    x_claims uuid[] := (select array_agg(distinct claim_id) from claims.expresses where revision_id = any (array[x1, x2]));
    x_txs bigint[] := (select array_agg(id) from claims.tx where revision_id = any (array[x1, x2]));
    shared_q uuid := (select question_id from claims.answered where evidence = y and claim_key = 'Y1');
    only_x_q uuid := (select question_id from claims.answered where evidence = x1 and claim_key = 'C2');
    y_before bigint[] := array[(select count(*) from claims.expresses where revision_id = y),
                               (select count(*) from claims.relations where evidence = y and evidence2 is null),
                               (select count(*) from claims.cites where revision_id = y)];
    r jsonb;
    t jsonb;
begin
    begin
        perform claims.sweep_erased(xs);
        raise exception 'the sweep ran outside an erasure';
    exception when insufficient_privilege then null;
    end;

    r := research.erase_work('rp-erase-x', 'REM-481 test: the writer asked for it to go');

    assert not exists (select 1 from research.claims where revision_id = any (xs)), 'no occurrence of X remains';
    assert not exists (select 1 from claims.expresses where revision_id = any (xs))
       and not exists (select 1 from claims.frames where revision_id = any (xs))
       and not exists (select 1 from claims.cites where revision_id = any (xs))
       and not exists (select 1 from claims.answered where evidence = any (xs))
       and not exists (select 1 from claims.relations where evidence = any (xs) or evidence2 = any (xs)),
        'no assertion evidenced by X remains, the relation Y asserted about X included';
    assert not exists (select 1 from claims.claims where id = any (x_claims)), 'no claim X minted remains';
    assert not exists (select 1 from claims.tx t where t.id = any (x_txs)
                        and not exists (select 1 from claims.origins o where o.tx = t.id)
                        and not exists (select 1 from claims.questions q where q.tx = t.id)),
        'no transaction X made remains, except one that minted an origin or question another work still names';
    assert not exists (select 1 from claims.origins where key = 'title:a notebook only x cites'), 'an origin only X cited is gone';
    assert exists (select 1 from claims.origins where key = 'title:zymurgy survey 2024'), 'one Y also cites stays';
    assert not exists (select 1 from claims.questions where id = only_x_q), 'a question only X answered is gone';
    assert exists (select 1 from claims.questions where id = shared_q), 'one Y also answers stays';
    assert array[(select count(*) from claims.expresses where revision_id = y),
                 (select count(*) from claims.relations where evidence = y and evidence2 is null),
                 (select count(*) from claims.cites where revision_id = y)] = y_before,
        'Y''s own claims graph is untouched';

    t := (select counts from claims.erasures e join research.erasures r on r.id = e.erasure_id where r.public_id = 'rp-erase-x');
    assert t is not null and r->'claims_graph' = t, 'the tombstone is recorded and returned';
    assert (t->>'occurrences')::int = 4 and (t->>'claims')::int = 3 and (t->>'relations')::int = 3
       and (t->>'origins')::int = 1 and (t->>'questions')::int = 1, 'it counts what went: ' || t::text;
    assert not exists (select 1 from jsonb_each(t) where jsonb_typeof(value) <> 'number'), 'and holds no text';
end $$;

rollback;
