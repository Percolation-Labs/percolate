-- A claim is an identity, and each occurrence expresses one (REM-473, specs/claims/graph.md §5): a new key mints a
-- claim, an unchanged key carries it forward confirmed, a reworded key carries it forward as a proposal, a rebuild
-- writes nothing new, the links are history, and a stranger sees neither a private claim nor its links.
--
-- One transaction, rolled back. Claims are set before each role switch.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000473a1', 'claims-owner@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000473b2', 'claims-stranger@example.test', 'active');

create temporary table seen (k text primary key, v text) on commit drop;
grant all on seen to authenticated;

-- 1. The owner writes two revisions.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000473a1"}';
set local role authenticated;
do $$
declare
    one jsonb := '{"schema_version": "0.1", "title": "A claims identity test", "visibility": "private",
        "claims": [{"id": "C1", "kind": "Inference", "text": "Quinces ripen late in the year.", "source_ids": ["S1"]},
                   {"id": "C2", "kind": "Inference", "text": "Medlars are eaten bletted.", "source_ids": ["S1"]},
                   {"id": "C3", "kind": "Inference", "text": "Sorb apples are rare.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "An orchard survey", "url": "https://example.com/o", "origin": "Survey"}],
        "edges": []}';
    two jsonb;
    r1  uuid;
    r2  uuid;
begin
    r1 := (research.submit_package(one, null, 'rp-claims-identity')->>'revision_id')::uuid;
    -- C1 keeps its words (only case and spacing change), C2 is reworded, C3 is gone, C4 is new.
    two := one || '{"claims": [{"id": "C1", "kind": "Inference", "text": "quinces  ripen late in the year. ", "source_ids": ["S1"]},
                                {"id": "C2", "kind": "Inference", "text": "Medlars are eaten only once bletted.", "source_ids": ["S1"]},
                                {"id": "C4", "kind": "Inference", "text": "Rowan berries need cooking.", "source_ids": ["S1"]}]}';
    r2 := (research.revise_package('rp-claims-identity', two, 'draft-1')->>'revision_id')::uuid;
    insert into seen values ('r1', r1::text), ('r2', r2::text);
end $$;
reset role;

-- 2. What the projection asserted, read as the owner of the tables.
do $$
declare
    r1 uuid := (select v::uuid from seen where k = 'r1');
    r2 uuid := (select v::uuid from seen where k = 'r2');
    c  record;
    before_rows bigint;
    before_tx   bigint;
begin
    assert (select count(*) from claims.expresses where revision_id = r1) = 3, 'every occurrence of draft-1 is linked';
    assert (select bool_and(method = 'new' and status = 'confirmed' and part = 1 and op = 'assert')
              from claims.expresses where revision_id = r1), 'draft-1 mints each claim, confirmed';
    assert (select count(distinct claim_id) from claims.expresses where revision_id = r1) = 3, 'three claims, one each';
    assert (select count(distinct tx) from claims.expresses where revision_id = r1) = 1, 'in one transaction per revision';
    assert (select actor_kind from claims.tx t join claims.expresses e on e.tx = t.id where e.revision_id = r1 limit 1)
         = 'platform', 'the platform asserts the projection';

    for c in select b.claim_key, b.claim_id as after, b.method, b.status, a.claim_id as before
               from claims.expresses b left join claims.expresses a on a.revision_id = r1 and a.claim_key = b.claim_key
              where b.revision_id = r2 order by b.claim_key loop
        if c.claim_key = 'C1' then
            assert c.after = c.before and c.method = 'unchanged' and c.status = 'confirmed',
                'case and spacing keep a claim, confirmed: ' || c::text;
        elsif c.claim_key = 'C2' then
            assert c.after = c.before and c.method = 'reworded' and c.status = 'proposed',
                'a rewording keeps the claim as a proposal: ' || c::text;
        elsif c.claim_key = 'C4' then
            assert c.before is null and c.method = 'new' and c.status = 'confirmed'
               and c.after not in (select claim_id from claims.expresses where revision_id = r1),
                'a new key mints a new claim: ' || c::text;
        else
            raise exception 'draft-2 linked an occurrence it does not have: %', c.claim_key;
        end if;
    end loop;
    assert exists (select 1 from claims.claims k join claims.expresses e on e.claim_id = k.id
                    where e.revision_id = r1 and e.claim_key = 'C3'), 'C3 is gone from draft-2 and its claim remains';

    insert into seen select 'c1', claim_id::text from claims.expresses where revision_id = r1 and claim_key = 'C1';

    -- The gate: every occurrence expresses exactly one claim at part 1.
    assert not exists (select 1 from research.claims o
                        where (select count(*) from claims.expresses e
                                where e.revision_id = o.revision_id and e.claim_key = o.claim_key and e.part = 1) <> 1),
        'every occurrence in this database expresses exactly one claim';

    -- Re-projecting writes nothing new.
    select count(*) into before_rows from claims.expresses;
    select count(*) into before_tx from claims.tx;
    perform research.rebuild_projection(r2);
    assert claims.link_revision(r2) = 0, 'a second link writes nothing';
    assert (select count(*) from claims.expresses) = before_rows and (select count(*) from claims.tx) = before_tx,
        'a rebuild adds no link and no transaction';

    -- The links are history.
    begin
        update claims.expresses set status = 'confirmed' where revision_id = r2 and claim_key = 'C2';
        raise exception 'a link was rewritten';
    exception when restrict_violation then null;
    end;
    begin
        delete from claims.claims where id = (select claim_id from claims.expresses where revision_id = r1 and claim_key = 'C3');
        raise exception 'a claim was deleted';
    exception when restrict_violation then null;
    end;
end $$;

-- 3. The owner reads their claims; a stranger reads none of a private work's.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000473a1"}';
set local role authenticated;
do $$
begin
    assert (select count(*) from claims.expresses where revision_id = (select v::uuid from seen where k = 'r2')) = 3,
        'the owner reads the links of their own revision';
    assert exists (select 1 from claims.claims where id = (select v::uuid from seen where k = 'c1')),
        'and the claims they express';
    -- A transaction shows its id, time and actor kind behind a readable row, and nothing else (REM-475).
    begin
        perform reason from claims.tx;
        raise exception 'authenticated read a transaction''s reason';
    exception when insufficient_privilege then null;
    end;
end $$;
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000473b2"}';
set local role authenticated;
do $$
begin
    assert not exists (select 1 from claims.expresses where revision_id in (select v::uuid from seen where k in ('r1', 'r2'))),
        'a stranger sees no link of a private work';
    assert not exists (select 1 from claims.claims where id = (select v::uuid from seen where k = 'c1')),
        'and no claim behind one';
end $$;

rollback;
