-- The research platform with no application in the loop: access decisions,
-- plans and usage, research revisions, engagement and the trust read, each
-- exercised as `authenticated` with the claims a trusted boundary would mint.
-- Core owns them, so any application gets them without installing another.
--
-- One transaction, rolled back. Claims are set before each role switch,
-- because `authenticated` cannot set them itself.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-00000000a001', 'rp-alice@example.test', 'active'),
    ('00000000-0000-4000-8000-00000000b002', 'rp-bob@example.test',   'active');
insert into rbac.api_keys (id, user_id, label, key_hash, scopes) values
    ('00000000-0000-4000-8000-000000000a01', '00000000-0000-4000-8000-00000000a001', 'alice reading agent', 'rp-test-hash-read',  '{packages:read-own}'),
    ('00000000-0000-4000-8000-000000000a02', '00000000-0000-4000-8000-00000000a001', 'alice writing agent', 'rp-test-hash-write', '{packages:create-private}');
insert into rbac.roles (name, description) values ('rp-lister', 'may list research (test)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('rp-lister', 'research', 'list') on conflict do nothing;


-- 1. A package: create, retry, revise, stale revise, no-op, listing refused.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-00000000a001"}';
set local role authenticated;
do $$
declare
    d  jsonb := '{"schema_version": "0.1", "title": "A research question for testing", "summary": "A brief source-based question.",
                  "claims": [{"id": "C1", "kind": "Source assertion", "text": "The supplied source makes this assertion.", "source_ids": ["S1"], "locator": "Paragraph 1"},
                             {"id": "C2", "kind": "Inference", "text": "A second claim that rests on the first.", "source_ids": [], "locator": ""}],
                  "sources": [{"id": "S1", "title": "Example source", "url": "https://example.com/a", "origin": "Example", "status": "Reported", "locator": "Paragraph 1"}],
                  "edges": [{"source": "C1", "relation": "supports", "target": "C2"}], "visibility": "private"}';
    r1 jsonb;
begin
    r1 := research.submit_package(d, 'key-1', 'rp-test-one');
    assert r1->>'revision' = 'draft-1' and (r1->>'created')::boolean, 'the first submit creates draft-1';
    assert research.submit_package(d, 'key-1', 'rp-test-one')->>'revision_id' = r1->>'revision_id', 'a retry returns the same receipt';
    begin
        perform research.submit_package(d || '{"title": "A different package under the same key"}', 'key-1');
        raise exception 'a reused key with a different package was accepted';
    exception when unique_violation then null;
    end;
    assert research.revise_package('rp-test-one', d || '{"title": "A revised research question"}', 'draft-1')->>'revision' = 'draft-2',
        'a revision from the head becomes draft-2';
    begin
        perform research.revise_package('rp-test-one', d || '{"title": "A stale revision"}', 'draft-1');
        raise exception 'a stale revision was accepted';
    exception when sqlstate 'PT409' then null;
    end;
    assert research.revise_package('rp-test-one', d || '{"title": "A revised research question"}', 'draft-2')->>'created' = 'false',
        'an unchanged revision is a no-op';
    assert research.submit_package(d, 'key-1')->>'revision' = 'draft-1',
        'retrying the original create after a revision returns the original receipt';
    begin
        perform research.submit_package(d || '{"visibility": "listed"}', null, 'rp-test-listed');
        raise exception 'listing without a grant was accepted';
    exception when insufficient_privilege then null;
    end;
    assert (select count(*) from research.claims c join research.revisions r on r.id = c.revision_id
             join research.works w on w.id = r.work_id where w.public_id = 'rp-test-one') = 4,
        'each revision projects its own claims';
end $$;
reset role;


-- 2. A stranger: cannot read, cannot revise, is told nothing exists.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-00000000b002"}';
set local role authenticated;
do $$
begin
    assert research.get_package('rp-test-one') is null, 'a stranger cannot read a private package';
    assert not exists (select 1 from research.works where public_id = 'rp-test-one'), 'row security hides the work';
    begin
        perform research.revise_package('rp-test-one', '{"schema_version": "0.1"}', 'draft-2');
        raise exception 'a stranger revised a package';
    exception when no_data_found then null;
    end;
end $$;
reset role;


-- 3. Agents: a credential makes the caller an agent; scopes keep their narrow
--    meaning; human-only actions refuse; a revoked key refuses at the next call.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-00000000a001", "api_key_id": "00000000-0000-4000-8000-000000000a01"}';
set local role authenticated;
do $$
begin
    assert rbac.current_actor() = 'agent', 'a credential makes the caller an agent';
    assert research.get_package('rp-test-one')->>'revision' = 'draft-2', 'a reading key reads';
    assert rbac.decide('research', 'insert')->>'reason' = 'scope_missing', 'a reading key may not write';
    assert rbac.decide('engagement', 'insert')->>'reason' = 'human_only', 'an agent may not comment or vote';
end $$;
reset role;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-00000000a001", "api_key_id": "00000000-0000-4000-8000-000000000a02"}';
set local role authenticated;
do $$
begin
    assert rbac.may('research', 'insert'), 'a writing key writes';
    assert rbac.decide('research', 'list')->>'reason' = 'scope_missing', 'create-private does not become listing';
end $$;
reset role;

update rbac.api_keys set revoked_at = now() where id = '00000000-0000-4000-8000-000000000a02';
set local role authenticated;
do $$
begin
    assert rbac.decide('research', 'insert')->>'reason' = 'credential_revoked', 'a revoked key refuses at the next call';
end $$;
reset role;


-- 4. Grants carry who, why and how they ended.
set local request.jwt.claims = '';
do $$
declare g uuid;
begin
    g := rbac.grant_with_basis('00000000-0000-4000-8000-00000000a001', 'rp-lister', 'invitation', 'test invitation');
    assert exists (select 1 from rbac.user_roles where user_id = '00000000-0000-4000-8000-00000000a001' and role = 'rp-lister'),
        'a grant takes effect';
    perform set_config('rp.grant', g::text, true);
end $$;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-00000000a001"}';
set local role authenticated;
do $$
begin
    assert research.submit_package('{"schema_version": "0.1", "title": "A listed package", "claims": [], "sources": [], "edges": [], "visibility": "listed"}',
                                   null, 'rp-test-listed')->>'visibility' = 'listed', 'a lister lists';
end $$;
reset role;

set local request.jwt.claims = '';
do $$
begin
    perform rbac.revoke_grant(current_setting('rp.grant')::uuid, 'test revocation');
    assert not exists (select 1 from rbac.user_roles where user_id = '00000000-0000-4000-8000-00000000a001' and role = 'rp-lister'),
        'revoking the grant removes the role';
    assert (select revoke_reason from rbac.grants where id = current_setting('rp.grant')::uuid) = 'test revocation',
        'the revocation keeps its reason';
end $$;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-00000000a001"}';
set local role authenticated;
do $$
begin
    assert rbac.decide('research', 'list')->>'reason' = 'no_grant', 'after revocation the next decision refuses';
end $$;
reset role;


-- 5. Plans and usage: unset is not zero, one budget per person and agents,
--    a retry charges once, a failed transaction charges nothing.
set local request.jwt.claims = '';
insert into rbac.resource_kinds (name, description, required) values
    ('rp-hosted-research', 'test budget', true), ('rp-optional', 'test optional limit', false)
on conflict do nothing;
insert into rbac.plans (name, description) values ('rp-small', 'test plan') on conflict do nothing;
insert into rbac.plan_limits (plan, resource_kind, mode, amount) values ('rp-small', 'rp-hosted-research', 'finite', 100) on conflict do nothing;
insert into rbac.plan_assignments (user_id, plan) values ('00000000-0000-4000-8000-00000000a001', 'rp-small')
on conflict (user_id) do update set plan = excluded.plan;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-00000000a001"}';
set local role authenticated;
do $$
declare me uuid := rbac.current_user_id();
begin
    assert rbac.limit_state(me, 'rp-optional')->>'status' = 'unset', 'no row is unset, not zero';
    assert rbac.has_quota_remaining(me, 'rp-optional'), 'an unset optional limit does not refuse';
    assert not rbac.has_quota_remaining(me, 'llm_tokens'), 'a required budget with no policy on this plan refuses';
    assert rbac.has_quota_remaining(null, 'llm_tokens'), 'a run with no person has no personal budget';
    assert (rbac.reserve_usage('rp-hosted-research', 60, 'op-1')->>'reserved')::boolean, 'a reservation within the limit';
    assert (rbac.reserve_usage('rp-hosted-research', 60, 'op-1')->>'retry')::boolean, 'a retried operation is recognised';
    assert (rbac.limit_state(me, 'rp-hosted-research')->>'used')::int = 60, 'the retry did not charge twice';
    begin
        perform rbac.reserve_usage('rp-hosted-research', 10, 'op-failed');
        raise exception 'roll this back';
    exception when raise_exception then null;
    end;
    assert not exists (select 1 from rbac.usage_ledger where operation_id = 'op-failed'), 'a failed transaction charges nothing';
    assert rbac.limit_state('00000000-0000-4000-8000-00000000b002', 'rp-hosted-research')->>'status' = 'unknown',
        'another person''s limits are not visible';
end $$;
reset role;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-00000000a001", "actor": "agent"}';
set local role authenticated;
do $$
declare s jsonb;
begin
    assert rbac.reserve_usage('rp-hosted-research', 60, 'op-2')->>'reason' = 'quota_exceeded', 'the agent draws on the person''s budget';
    perform rbac.consume_usage('rp-hosted-research', 'op-1', 30);
    assert (rbac.reserve_usage('rp-hosted-research', 60, 'op-3')->>'reserved')::boolean, 'consuming less than reserved frees the rest';
    assert rbac.reserve_usage('rp-nonexistent', 1, 'op-4')->>'reason' = 'no_policy', 'an unknown resource refuses';
    s := rbac.access_snapshot();
    assert s->>'actor' = 'agent' and s->>'plan' = 'rp-small', 'the snapshot names the actor and plan';
    assert exists (select 1 from jsonb_array_elements(s->'limits') l
                    where l->>'resource_kind' = 'rp-hosted-research' and (l->>'remaining')::int = 10),
        'the snapshot reports what remains';
    assert exists (select 1 from jsonb_array_elements(s->'capabilities') c
                    where c->>'resource' = 'engagement' and c->>'action' = 'insert' and c->>'reason' = 'human_only'),
        'the snapshot and the decision agree';
end $$;
reset role;

-- 5b. An expired reservation (REM-189): its retry and its settlement take only capacity that is still
--     there, keep the operation's one row, and a settled or returned operation holds nothing.
--     Budget so far: op-1 consumed 30, op-3 reserved 60, so 10 remain of 100.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-00000000a001"}';
set local role authenticated;
do $$
declare me uuid := rbac.current_user_id();
begin
    begin
        perform rbac.reserve_usage('rp-hosted-research', 1, 'op-no-ttl', interval '0 seconds');
        raise exception 'a zero time to live was accepted';
    exception when invalid_parameter_value then null;
    end;
    assert (rbac.reserve_usage('rp-hosted-research', 10, 'op-expiring')->>'reserved')::boolean, 'the last 10 are reserved';
    assert (rbac.limit_state(me, 'rp-hosted-research')->>'used')::int = 100, 'the budget is full';
end $$;
reset role;
update rbac.usage_ledger set expires_at = now() - interval '1 second' where operation_id = 'op-expiring';

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-00000000a001", "actor": "agent"}';
set local role authenticated;
do $$
declare me uuid := rbac.current_user_id(); r jsonb;
begin
    assert (rbac.limit_state(me, 'rp-hosted-research')->>'used')::int = 90, 'an expired reservation holds nothing';
    assert (rbac.reserve_usage('rp-hosted-research', 10, 'op-other')->>'reserved')::boolean, 'another operation takes the freed 10';
    r := rbac.reserve_usage('rp-hosted-research', 10, 'op-expiring');
    assert not (r->>'reserved')::boolean and r->>'reason' = 'expired' and (r->>'retry')::boolean,
        'the expired retry is refused once its capacity has gone';
    assert (rbac.limit_state(me, 'rp-hosted-research')->>'used')::int = 100, 'the refused retry charged nothing';
    r := rbac.consume_usage('rp-hosted-research', 'op-expiring', 10);
    assert not (r->>'consumed')::boolean and r->>'reason' = 'expired', 'a late settlement cannot spend the budget twice';
    perform rbac.release_usage('rp-hosted-research', 'op-other');
    r := rbac.reserve_usage('rp-hosted-research', 10, 'op-other');
    assert not (r->>'reserved')::boolean and r->>'reason' = 'released', 'a returned operation holds nothing on retry';
    r := rbac.reserve_usage('rp-hosted-research', 10, 'op-expiring');
    assert (r->>'reserved')::boolean and (r->>'reacquired')::boolean, 'the expired retry reacquires capacity that is there';
    assert (rbac.limit_state(me, 'rp-hosted-research')->>'used')::int = 100, 'reacquiring charged it once';
    r := rbac.consume_usage('rp-hosted-research', 'op-expiring', 10);
    assert (r->>'consumed')::boolean and r->>'state' = 'consumed', 'the reacquired reservation settles';
    r := rbac.consume_usage('rp-hosted-research', 'op-expiring', 10);
    assert (r->>'consumed')::boolean and (r->>'retry')::boolean, 'a settlement retry returns the receipt';
    assert (rbac.limit_state(me, 'rp-hosted-research')->>'used')::int = 100, 'the settlement retry charged nothing';
    r := rbac.reserve_usage('rp-hosted-research', 10, 'op-expiring');
    assert not (r->>'reserved')::boolean and r->>'reason' = 'consumed', 'a settled operation must not run again';
    assert (select count(*) from rbac.usage_ledger where operation_id = 'op-expiring') = 1, 'one operation, one row';
end $$;
reset role;


-- 6. Engagement: one active vote, withdrawals kept, no self-votes or
--    self-likes, versioned edits, no agent comments, hidden with the target.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-00000000b002"}';
set local role authenticated;
do $$
declare rev uuid := (research.get_package('rp-test-listed')->'receipt'->>'revision_id')::uuid; c uuid;
begin
    assert rev is not null, 'a listed package is readable by others';
    assert engagement.set_useful(rev, true), 'a reader marks it useful';
    perform engagement.set_useful(rev, true);
    assert (select count(*) from engagement.votes where revision_id = rev and withdrawn_at is null) = 1, 'one active vote per person';
    perform engagement.set_useful(rev, false);
    perform engagement.set_useful(rev, true);
    assert (select count(*) from engagement.votes where revision_id = rev) = 2, 'a withdrawal keeps its history';
    c := engagement.add_comment(rev, 'A comment on the listed revision.');
    assert engagement.edit_comment(c, 'An edited comment on the listed revision.', 1) = 2, 'an edit makes version 2';
    begin
        perform engagement.edit_comment(c, 'A stale edit.', 1);
        raise exception 'a stale edit was accepted';
    exception when sqlstate 'PT409' then null;
    end;
    begin
        perform engagement.set_like(c, true);
        raise exception 'a self-like was accepted';
    exception when check_violation then null;
    end;
end $$;
reset role;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-00000000a001"}';
set local role authenticated;
do $$
declare rev uuid := (research.get_package('rp-test-listed')->'receipt'->>'revision_id')::uuid;
        c uuid := (select id from engagement.comments where revision_id = rev limit 1);
begin
    begin
        perform engagement.set_useful(rev, true);
        raise exception 'a self-vote was accepted';
    exception when check_violation then null;
    end;
    assert engagement.set_like(c, true), 'the author of the research likes a reader''s comment';
    perform engagement.set_like(c, true);
    assert (select count(*) from engagement.comment_likes where comment_id = c and withdrawn_at is null) = 1, 'one active like';
    assert (engagement.revision_signals(rev)->>'useful_votes')::int = 1, 'signals count the active vote';
end $$;
reset role;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-00000000b002", "actor": "agent"}';
set local role authenticated;
do $$
declare rev uuid := (research.get_package('rp-test-listed')->'receipt'->>'revision_id')::uuid;
begin
    begin
        perform engagement.add_comment(rev, 'An agent comment.');
        raise exception 'an agent commented';
    exception when insufficient_privilege then null;
    end;
end $$;
reset role;

-- A revoked listing grant cannot rewrite or withdraw a public head.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-00000000a001"}';
set local role authenticated;
do $$
begin
    begin
        perform research.revise_package('rp-test-listed',
            '{"schema_version": "0.1", "title": "A listed package", "claims": [], "sources": [], "edges": [], "visibility": "private"}',
            'draft-1');
        raise exception 'a revoked lister withdrew public work';
    exception when insufficient_privilege then null;
    end;
end $$;
reset role;

-- An explicit renewed grant permits unlisting, which hides dependent engagement.
set local request.jwt.claims = '';
select rbac.grant_with_basis('00000000-0000-4000-8000-00000000a001',
    'rp-lister', 'invitation', 'renewed test invitation');
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-00000000a001"}';
set local role authenticated;
select research.revise_package('rp-test-listed',
    '{"schema_version": "0.1", "title": "A listed package", "claims": [], "sources": [], "edges": [], "visibility": "private"}',
    'draft-1') is not null as unlisted;
reset role;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-00000000b002"}';
set local role authenticated;
do $$
begin
    assert research.get_package('rp-test-listed') is null, 'an unlisted package is gone for others';
    assert not exists (select 1 from engagement.comments), 'its comments are hidden, including from their author';
    assert (select count(*) from engagement.votes where withdrawn_at is null) = 1, 'a person still sees their own vote record';
end $$;
reset role;


-- 7. The trust read: head, corrections, self-endorsement, withdrawal, no
--    inherited endorsements, uncited claims, no invented interpretation.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-00000000a001"}';
set local role authenticated;
do $$
declare r1 uuid; r2 uuid; e uuid; t jsonb;
begin
    select r.id into r1 from research.revisions r join research.works w on w.id = r.work_id
     where w.public_id = 'rp-test-one' and r.label = 'draft-1';
    r2 := (research.get_package('rp-test-one')->'receipt'->>'revision_id')::uuid;
    e := research.endorse(r1, 'claim C1', 'against paragraph 1 of the source');
    t := research.trust(r1);
    assert not (t->'revision'->>'is_head')::boolean, 'draft-1 is not the head';
    assert t->'corrections'->'superseded_by' = '["draft-2"]'::jsonb, 'the correction is linked';
    assert (t->'endorsements'->0->>'self')::boolean, 'an author endorsement is marked as self';
    assert (t->'claims'->1->>'uncited')::boolean, 'an uncited claim is marked';
    assert t->'interpretations'->>'status' = 'unavailable', 'a missing analysis provider is said, not invented';
    assert jsonb_array_length(research.trust(r2)->'endorsements') = 0, 'a correction inherits no endorsements';
    perform research.withdraw_endorsement(e, 'rechecked and unsure');
    assert not (research.trust(r1)->'endorsements'->0->>'active')::boolean, 'a withdrawn endorsement stays, marked inactive';
end $$;
reset role;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-00000000b002"}';
set local role authenticated;
do $$
declare r1 uuid;
begin
    reset role;
    select r.id into r1 from research.revisions r join research.works w on w.id = r.work_id
     where w.public_id = 'rp-test-one' and r.label = 'draft-1';
    set local role authenticated;
    assert research.trust(r1) is null, 'a stranger gets no trust read for a private revision';
end $$;
reset role;


-- 8. Application provisioning: only the provisioner (here the superuser running
--    the suite), and never an administrator.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-00000000b002"}';
set local role authenticated;
do $$
begin
    begin
        perform rbac.provision_application_user('00000000-0000-4000-8000-00000000c003');
        raise exception 'a signed-in person provisioned a user';
    exception when insufficient_privilege then null;
    end;
end $$;
reset role;

set local request.jwt.claims = '';
do $$
declare g uuid;
begin
    perform rbac.provision_application_user('00000000-0000-4000-8000-00000000c003');
    perform rbac.provision_application_user('00000000-0000-4000-8000-00000000c003');
    assert (select status from rbac.users where id = '00000000-0000-4000-8000-00000000c003') = 'active',
        'provisioning a user is idempotent and active';
    perform rbac.provision_application_credential('00000000-0000-4000-8000-000000000c01',
        '00000000-0000-4000-8000-00000000c003', 'an app token', '{packages:read-own}');
    perform rbac.revoke_application_credential('00000000-0000-4000-8000-000000000a01');
    assert (select revoked_at from rbac.api_keys where id = '00000000-0000-4000-8000-000000000a01') is null,
        'the provisioner cannot revoke a key it did not provision';
    perform rbac.revoke_application_credential('00000000-0000-4000-8000-000000000c01');
    assert (select revoked_at from rbac.api_keys where id = '00000000-0000-4000-8000-000000000c01') is not null,
        'the provisioner revokes its own credential';
    g := rbac.grant_application_role('00000000-0000-4000-8000-00000000c003', 'rp-app-lister', 'research', 'list', 'operator');
    assert g = rbac.grant_application_role('00000000-0000-4000-8000-00000000c003', 'rp-app-lister', 'research', 'list', 'operator'),
        'granting the same role twice keeps one active grant';
    begin
        perform rbac.grant_application_role('00000000-0000-4000-8000-00000000c003', 'rp-app-admin', 'users', 'admin', 'operator');
        raise exception 'the provisioner granted users:admin';
    exception when insufficient_privilege then null;
    end;
end $$;

rollback;
