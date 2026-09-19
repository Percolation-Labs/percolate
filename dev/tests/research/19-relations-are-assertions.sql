-- Relations are assertions in one vocabulary (REM-474, specs/claims/graph.md §6 and §11): a revision's argument
-- edges answer as relations row for row, a rebuild adds none, a status change and a retraction are new rows, an
-- agent proposes and is refused when it asks for `confirmed`, a comparative or cross-work identity relation waits
-- for the card that builds its requirement, and a stranger neither reads nor writes a private work's relations.
--
-- One transaction, rolled back. Claims are set before each role switch.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000474a1', 'relations-owner@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000474b2', 'relations-stranger@example.test', 'active');

-- The owner's connected agent, holding the scopes a connected agent has.
insert into rbac.api_keys (id, user_id, label, key_hash, scopes) values
    ('00000000-0000-4000-8000-0000000474c1', '00000000-0000-4000-8000-0000000474a1', 'agent', 'relations-k1',
     '{packages:read-own,packages:create-private}');

create temporary table seen (k text primary key, v text) on commit drop;
grant all on seen to authenticated;

-- 1. The owner writes a package whose six edges use every in-package relation.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000474a1"}';
set local role authenticated;
do $$
declare
    doc jsonb := '{"schema_version": "0.1", "title": "A relations test", "visibility": "private",
        "claims": [{"id": "C1", "kind": "Inference", "text": "Pears keep in the cold.", "source_ids": ["S1"]},
                   {"id": "C2", "kind": "Inference", "text": "Cold stores are dear.", "source_ids": ["S1"]},
                   {"id": "C3", "kind": "Inference", "text": "Growers sell pears early.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "A storage note", "url": "https://example.com/s", "origin": "Note"}],
        "edges": [{"source": "C1", "relation": "supports", "target": "C3"},
                  {"source": "C2", "relation": "challenges", "target": "C1"},
                  {"source": "C2", "relation": "motivates", "target": "C3"},
                  {"source": "C3", "relation": "qualifies", "target": "C1"},
                  {"source": "C2", "relation": "limits", "target": "C1"},
                  {"source": "C1", "relation": "compares with", "target": "C2"}]}';
    rev uuid;
    id1 bigint;
begin
    rev := (research.submit_package(doc, null, 'rp-relations')->>'revision_id')::uuid;
    insert into seen values ('rev', rev::text);

    -- A person asserts, restates and retracts.
    id1 := claims.assert_relation('C3', 'supersedes', 'C2', rev);
    assert (select status from claims.relations where id = id1) = 'confirmed', 'a person''s assertion is confirmed';
    perform claims.restate_relation(id1, 'disputed', false, 'on reflection');
    perform claims.restate_relation(id1, null, true, 'withdrawn');
    insert into seen values ('id1', id1::text);

    -- Requirements that need records not built yet are refused, naming what builds them.
    begin
        perform claims.assert_relation('C1', 'contradicts', 'C2', rev);
        raise exception 'a comparative relation was written within one work (REM-479)';
    exception when check_violation then null;
    end;
    begin
        perform claims.assert_relation('C1', 'same_as', 'C2', rev);
        raise exception 'same_as was written without an occurrence on each side (REM-478)';
    exception when check_violation then null;
    end;
    begin
        perform claims.assert_relation('C1', 'answers', 'C2', rev);
        raise exception 'a predicate that does not relate two claims was written as one';
    exception when check_violation then null;
    end;
    begin
        perform claims.assert_relation('C1', 'supports', 'C9', rev);
        raise exception 'a relation to no occurrence was written';
    exception when foreign_key_violation then null;
    end;
end $$;
reset role;

-- 2. The projection, read as the tables' owner.
do $$
declare
    rev uuid := (select v::uuid from seen where k = 'rev');
    id1 bigint := (select v::bigint from seen where k = 'id1');
    n bigint;
begin
    assert (select array_agg(x order by x) from (
              select e.source_claim_key || ' ' || claims.predicate_of_edge(e.relation) || ' ' || e.target_claim_key
                from research.argument_edges e where e.revision_id = rev) a(x))
         = (select array_agg(x order by x) from (
              select (r.keys->>'src') || ' ' || r.predicate || ' ' || (r.keys->>'dst')
                from claims.relations r join claims.tx t on t.id = r.tx
               where r.evidence = rev and t.actor_kind = 'platform') b(x)),
        'the six relations answer with the same rows through both';
    assert (select bool_and(r.status = 'confirmed' and r.op = 'assert'
                            and r.src = (select claim_id from claims.expresses x where x.revision_id = rev and x.claim_key = r.keys->>'src')
                            and r.dst = (select claim_id from claims.expresses x where x.revision_id = rev and x.claim_key = r.keys->>'dst'))
              from claims.relations r join claims.tx t on t.id = r.tx
             where r.evidence = rev and t.actor_kind = 'platform'),
        'each projected relation is confirmed, between the claims its keys express';

    select count(*) into n from claims.relations;
    perform research.rebuild_projection(rev);
    assert claims.project_edges(rev) = 0 and (select count(*) from claims.relations) = n, 'a rebuild adds no relation';

    assert (select array_agg(status || '/' || op order by id) from claims.relations r
             where (r.src, r.predicate, r.dst) = (select src, predicate, dst from claims.relations where id = id1))
         = '{confirmed/assert,disputed/assert,disputed/retract}', 'a status change and a retraction are later rows';
    begin
        update claims.relations set status = 'proposed' where id = id1;
        raise exception 'a relation was rewritten';
    exception when restrict_violation then null;
    end;
end $$;

-- 3. The owner's agent proposes, and is refused confirmed rather than downgraded.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000474a1", "api_key_id": "00000000-0000-4000-8000-0000000474c1"}';
set local role authenticated;
do $$
declare
    rev uuid := (select v::uuid from seen where k = 'rev');
    id2 bigint;
begin
    id2 := claims.assert_relation('C1', 'supports', 'C2', rev);
    assert (select status from claims.relations where id = id2) = 'proposed', 'an agent''s assertion is proposed';
    begin
        perform claims.assert_relation('C3', 'supports', 'C2', rev, null, 'confirmed');
        raise exception 'an agent wrote confirmed';
    exception when insufficient_privilege then null;
    end;
    begin
        perform claims.restate_relation(id2, 'confirmed');
        raise exception 'an agent confirmed a relation by restating it';
    exception when insufficient_privilege then null;
    end;
end $$;
reset role;

-- 4. A stranger reads none of it and writes none of it.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000474b2"}';
set local role authenticated;
do $$
declare rev uuid := (select v::uuid from seen where k = 'rev');
begin
    assert not exists (select 1 from claims.relations where evidence = rev), 'a stranger reads no relation of a private work';
    assert exists (select 1 from claims.predicates where name = 'supports'), 'but reads the vocabulary';
    begin
        perform claims.assert_relation('C1', 'supports', 'C2', rev);
        raise exception 'a stranger asserted from somebody else''s revision';
    exception when insufficient_privilege then null;
    end;
    begin
        perform claims.restate_relation((select v::bigint from seen where k = 'id1'), 'confirmed');
        raise exception 'a stranger restated somebody else''s relation';
    exception when no_data_found then null;
    end;
end $$;

rollback;
