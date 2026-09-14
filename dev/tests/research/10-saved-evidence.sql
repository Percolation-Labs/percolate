-- Saving a public page as research evidence (REM-239, the policy decided in REM-242): anybody who may write
-- research keeps a copy without resources:create; the copy is stored rather than ingested, private to its saver
-- and capturable; saving the same page again is the same resource and charges nothing more; a page past the
-- evidence_bytes budget is refused and charges nothing; and the default plan ships a daily cap.
--
-- One transaction, rolled back. Claims are set before each role switch.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000239a1', 'save-owner@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000239b2', 'save-stranger@example.test', 'active');


-- 1. A writer with no upload permission saves a page, captures it, and is charged once for it.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000239a1"}';
set local role authenticated;
do $$
declare me uuid := '00000000-0000-4000-8000-0000000239a1'; r1 uuid; r2 uuid; r3 uuid;
begin
    assert not content.may_upload(null), 'the saver holds no resources:create';
    r1 := content.register_evidence('https://example.com/study', 'save-sum-1', 'bucket', 'objects/sa/save-sum-1',
                                    1000, 'text/html', 'The study');
    assert (select status = 'stored' and visibility = 'private' and owner_id = me
              from content.resources where id = r1), 'the copy is stored, private and the saver''s';
    r2 := content.register_evidence('https://example.com/study', 'save-sum-1', 'bucket', 'objects/sa/save-sum-1',
                                    1000, 'text/html', 'The study');
    assert r1 = r2, 'saving the same page again is the same resource';
    assert (rbac.limit_state(me, 'evidence_bytes')->>'used')::bigint = 1000, 'and it is charged once';
    assert content.capture_snapshot(r1) is not null, 'a saved page can be captured';

    r3 := content.register_evidence('https://example.com/mirror', 'save-sum-1', 'bucket', 'objects/sa/save-sum-1',
                                    1000, 'text/html', null);
    assert r3 <> r1 and (select uri from content.resources where id = r3) = 'https://example.com/mirror',
        'the same bytes read from another address are that address''s evidence';

    begin
        perform content.register_evidence('ftp://example.com/study', 'save-sum-2', 'bucket', 'k2', 10, null, null);
        raise exception 'a page from a non-http address was saved';
    exception when check_violation then null;
    end;
    begin
        perform content.register_evidence('https://example.com/empty', 'save-sum-3', 'bucket', 'k3', 0, null, null);
        raise exception 'an empty page was saved';
    exception when check_violation then null;
    end;
end $$;
reset role;


-- 2. Another person cannot see it.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000239b2"}';
set local role authenticated;
do $$
begin
    assert not exists (select 1 from content.resources where uri = 'https://example.com/study'),
        'a saved page is private to the person who saved it';
end $$;
reset role;


-- 3. The budget: a page that would pass it is refused, and neither saves nor charges anything.
insert into rbac.plans (name, description) values ('rem239-small', 'a small evidence budget, for this test');
insert into rbac.plan_limits (plan, resource_kind, mode, amount, period)
values ('rem239-small', 'evidence_bytes', 'finite', 1500, interval '1 day');
insert into rbac.plan_assignments (user_id, plan) values ('00000000-0000-4000-8000-0000000239b2', 'rem239-small');

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000239b2"}';
set local role authenticated;
do $$
declare me uuid := '00000000-0000-4000-8000-0000000239b2';
begin
    perform content.register_evidence('https://example.com/a', 'save-sum-a', 'bucket', 'ka', 1000, null, null);
    begin
        perform content.register_evidence('https://example.com/b', 'save-sum-b', 'bucket', 'kb', 1000, null, null);
        raise exception 'a page past the evidence budget was saved';
    exception when insufficient_privilege then null;
    end;
    assert (rbac.limit_state(me, 'evidence_bytes')->>'used')::bigint = 1000, 'the refused page charged nothing';
    assert not exists (select 1 from content.resources where uri = 'https://example.com/b'), 'and saved nothing';
end $$;
reset role;


-- 4. What the extension ships.
do $$
begin
    assert (select mode = 'finite' and amount > 0 and period = interval '1 day' and shipped
              from rbac.plan_limits where plan = 'default' and resource_kind = 'evidence_bytes'),
        'the default plan ships a daily byte cap for saved evidence';
    assert (select not required from rbac.resource_kinds where name = 'evidence_bytes'),
        'evidence_bytes is optional: a plan without a row allows saving';
    assert (select shipped and visibility = 'public' and not (config ? 'ingest_workflow')
              from content.channels where name = 'research_evidence' and org_id = rbac.shared_org_id()),
        'the evidence channel is shipped, findable, and starts no ingestion';
end $$;

rollback;
