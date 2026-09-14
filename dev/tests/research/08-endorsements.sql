-- Endorsements name the exact claims that were checked and keep their withdrawal history (REM-154,
-- specs/tables/schema.md §5): a claim-scoped endorsement names at least one claim of its own revision, a
-- withdrawal is one event and a retry converges on it, an agent cannot endorse, a correction inherits nothing,
-- and the endorsements a correction affects can be listed.
--
-- One transaction, rolled back. Claims are set before each role switch.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000154a1', 'end-owner@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000154c3', 'end-stranger@example.test', 'active');
insert into rbac.api_keys (id, user_id, label, key_hash, scopes) values
    ('00000000-0000-4000-8000-0000000154e1', '00000000-0000-4000-8000-0000000154a1', 'owner agent', 'end-hash-agent', '{packages:create-private}');


-- 1. The owner endorses what they checked, withdraws, retries, endorses again, then corrects.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000154a1"}';
set local role authenticated;
do $$
declare
    doc  jsonb := '{"schema_version": "0.1", "title": "An endorsement test", "visibility": "private", "sources": [], "edges": [],
                    "claims": [{"id": "C1", "kind": "Source assertion", "text": "The first claim."},
                               {"id": "C2", "kind": "Source assertion", "text": "The second claim."},
                               {"id": "C3", "kind": "Inference", "text": "The third claim."}]}';
    rev1 uuid;
    rev2 uuid;
    e1   uuid;
    e2   uuid;
    ed   uuid;
    t    jsonb;
begin
    rev1 := (research.submit_package(doc, null, 'rp-endorsed')->>'revision_id')::uuid;

    begin
        perform research.endorse(rev1, 'no claims at all', 'nothing', array[]::text[]);
        raise exception 'a claim-scoped endorsement with no claim was accepted';
    exception when check_violation then null;
    end;
    begin
        perform research.endorse(rev1, 'a claim that does not exist', 'checked C9', array['C9']);
        raise exception 'an endorsement of a claim outside the revision was accepted';
    exception when foreign_key_violation then null;
    end;
    assert not exists (select 1 from research.endorsements where revision_id = rev1), 'a refused endorsement leaves nothing';

    e1 := research.endorse(rev1, 'claims C1 and C2', 'each against its source passage', array['C1', 'C2', 'C1']);
    assert (select kind from research.endorsements where id = e1) = 'claims', 'an endorsement with keys is claim-scoped';
    assert (select array_agg(claim_key order by claim_key) from research.endorsement_claims where endorsement_id = e1) = '{C1,C2}',
        'it names each checked claim once';

    perform research.withdraw_endorsement(e1, 'rechecked and unsure');
    perform research.withdraw_endorsement(e1, 'a second reason for the same act');
    assert (select count(*) from research.endorsement_withdrawals where endorsement_id = e1) = 1, 'a retry adds no second event';
    assert (select reason from research.endorsement_withdrawals where endorsement_id = e1) = 'rechecked and unsure', 'the first withdrawal stands';
    assert (select withdraw_reason from research.endorsements where id = e1) = 'rechecked and unsure', 'and the row agrees with it';

    e2 := research.endorse(rev1, 'claim C3', 'against the inference it draws', array['C3']);
    assert e2 <> e1, 'a new endorsement is a new row';
    assert (select count(*) from research.endorsements where revision_id = rev1) = 2, 'and the withdrawn one is kept';

    t := research.trust(rev1);
    assert (select e->>'kind' from jsonb_array_elements(t->'endorsements') e where (e->>'id')::uuid = e1) = 'claims', 'trust shows the kind';
    assert (select e->'claims' from jsonb_array_elements(t->'endorsements') e where (e->>'id')::uuid = e1) = '["C1", "C2"]',
        'and the checked claims';
    assert (select (e->>'active')::boolean from jsonb_array_elements(t->'endorsements') e where (e->>'id')::uuid = e1) = false,
        'and the withdrawal';

    -- The correction removes C2, rewords C3 and leaves C1 as it was.
    rev2 := (research.revise_package('rp-endorsed',
        jsonb_set(jsonb_set(doc, '{claims}', (doc->'claims') - 1), '{claims,1,text}', '"The third claim, reworded."'), 'draft-1')->>'revision_id')::uuid;
    assert jsonb_array_length(research.trust(rev2)->'endorsements') = 0, 'a corrected revision inherits no endorsement';
    assert (select array_agg(format('%s:%s:%s', case when endorsement_id = e1 then 'e1' else 'e2' end, claim_key, change)
                             order by claim_key)
              from research.endorsements_affected_by(rev2)) = '{e1:C2:removed,e2:C3:changed}',
        'the correction lists the endorsements of claims it removed or reworded, and nothing for the unchanged C1';

    ed := research.endorse(rev2, 'the whole corrected document', 'read end to end');
    assert (select kind from research.endorsements where id = ed) = 'document', 'no keys is a document-scoped endorsement';
end $$;
reset role;


-- 2. As the table owner: a checked-claim link to a claim of another revision cannot be written at all.
do $$
declare
    e1   uuid := (select e.id from research.endorsements e join research.endorsement_claims ec on ec.endorsement_id = e.id
                   where ec.claim_key = 'C1' limit 1);
    rev2 uuid := (select h.revision_id from research.heads h join research.works w on w.id = h.work_id where w.public_id = 'rp-endorsed');
begin
    begin
        -- C3, not C1: e1 already names C1, so the primary key would refuse first. C3 is a claim of draft-2, so
        -- the only thing that can refuse this link is the key tying it to e1's own revision.
        insert into research.endorsement_claims (endorsement_id, revision_id, claim_key) values (e1, rev2, 'C3');
        raise exception 'a checked claim was linked across revisions';
    exception when foreign_key_violation then null;
    end;
end $$;


-- 3. The owner's agent: it can neither endorse nor withdraw, whatever it has been granted.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000154a1", "api_key_id": "00000000-0000-4000-8000-0000000154e1"}';
set local role authenticated;
do $$
declare
    rev1 uuid := (select v.id from research.revisions v join research.works w on w.id = v.work_id
                   where w.public_id = 'rp-endorsed' and v.label = 'draft-1');
    active uuid := (select id from research.endorsements where revision_id = rev1 and withdrawn_at is null);
begin
    begin
        perform research.endorse(rev1, 'an agent''s endorsement', 'the agent checked it', array['C1']);
        raise exception 'an agent endorsed a revision';
    exception when insufficient_privilege then null;
    end;
    begin
        perform research.withdraw_endorsement(active, 'an agent''s withdrawal');
        raise exception 'an agent withdrew a person''s endorsement';
    exception when insufficient_privilege then null;
    end;
end $$;
reset role;


-- 4. A stranger: cannot endorse the private revision, and sees none of its endorsements, claims or withdrawals.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000154c3"}';
set local role authenticated;
do $$
declare rev1 uuid := (select v.id from research.revisions v where v.label = 'draft-1'
                        and exists (select 1 from research.works w where w.id = v.work_id and w.public_id = 'rp-endorsed'));
begin
    assert rev1 is null, 'a stranger cannot even find the private revision';
    assert not exists (select 1 from research.endorsements), 'nor its endorsements';
    assert not exists (select 1 from research.endorsement_claims), 'nor the checked claims';
    assert not exists (select 1 from research.endorsement_withdrawals), 'nor the withdrawals';
end $$;
reset role;

do $$
declare
    rev1 uuid := (select v.id from research.revisions v join research.works w on w.id = v.work_id
                   where w.public_id = 'rp-endorsed' and v.label = 'draft-1');
    rev2 uuid := (select h.revision_id from research.heads h join research.works w on w.id = h.work_id where w.public_id = 'rp-endorsed');
begin
    perform set_config('end.rev1', rev1::text, true);
    perform set_config('end.rev2', rev2::text, true);
end $$;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000154c3"}';
set local role authenticated;
do $$
begin
    begin
        perform research.endorse(current_setting('end.rev1')::uuid, 'a stranger''s endorsement', 'read it somehow');
        raise exception 'a stranger endorsed a private revision';
    exception when no_data_found then null;
    end;
    assert not exists (select 1 from research.endorsements_affected_by(current_setting('end.rev2')::uuid)),
        'and learns nothing of what a correction affected';
end $$;
reset role;

rollback;
