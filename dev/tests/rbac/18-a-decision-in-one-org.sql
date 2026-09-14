-- A DECISION CAN BE ASKED IN EXACTLY ONE ORG, AND A SHARED-ORG GRANT DOES NOT COUNT IN IT (REM-255).
--
-- rbac.decide counts a grant held in the shared org inside any org's scope, so one shared hub.publication:publish
-- grant would open every publication (REM-249). rbac.decide_in_org asks decide's person, credential and scope
-- checks unchanged, then counts only an active grant held in the named org, for a member of that org.
--
--   1. a member whose only grant is in the shared org is refused in the org, and decide still allows them;
--   2. a member with a grant in the org is allowed there, and refused in an org they do not belong to;
--   3. a non-member with a grant held in the org is refused;
--   4. the shared org, or no org, is not an org to decide in;
--   5. a revoked grant in the org counts for nothing;
--   6. a refusal before the grant question stands, and a capability every person holds passes for a member;
--   7. may_in_org says what decide_in_org decides.
--
-- The claims are set as the superuser between blocks. One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000255a1', 'rbac18-shared@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000255b2', 'rbac18-member@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000255c3', 'rbac18-outsider@example.test', 'active');
insert into rbac.orgs (id, slug, name) values
    ('00000000-0000-4000-8000-0000000255f1', 'rbac18-publication-one', 'Publication one'),
    ('00000000-0000-4000-8000-0000000255f2', 'rbac18-publication-two', 'Publication two');
select rbac.declare_application('rbac18', '1',
    '[{"resource": "publication", "action": "publish"}, {"resource": "notes", "action": "read", "every_person": true}]');
insert into rbac.roles (name, description) values ('rbac18-publisher', 'publishes in a publication');
insert into rbac.role_permissions (role, resource, action) values ('rbac18-publisher', 'rbac18.publication', 'publish');

-- The shared-org holder: a member of publication one, whose publisher grant is the installation grant in the shared org.
insert into rbac.org_members (org_id, user_id) values
    ('00000000-0000-4000-8000-0000000255f1', '00000000-0000-4000-8000-0000000255a1'),
    ('00000000-0000-4000-8000-0000000255f1', '00000000-0000-4000-8000-0000000255b2');
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000000255a1', 'rbac18-publisher');

-- The member and the outsider: each holds the publisher grant in publication one, written before the role row.
insert into rbac.grants (user_id, role, application, org_id, basis) values
    ('00000000-0000-4000-8000-0000000255b2', 'rbac18-publisher', 'rbac18', '00000000-0000-4000-8000-0000000255f1', 'operator'),
    ('00000000-0000-4000-8000-0000000255c3', 'rbac18-publisher', 'rbac18', '00000000-0000-4000-8000-0000000255f1', 'operator');
insert into rbac.user_roles (user_id, role) values
    ('00000000-0000-4000-8000-0000000255b2', 'rbac18-publisher'),
    ('00000000-0000-4000-8000-0000000255c3', 'rbac18-publisher');


-- 1. The shared-org grant opens decide, and not a decision in publication one.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000255a1"}';
do $$
begin
    assert (select org_id = rbac.shared_org_id() from rbac.grants
             where user_id = '00000000-0000-4000-8000-0000000255a1' and role = 'rbac18-publisher'),
        'the fixture holds its only grant in the shared org';
    assert rbac.may('rbac18.publication', 'publish'), 'decide still counts the shared-org grant';
    assert (rbac.decide_in_org('rbac18.publication', 'publish', '00000000-0000-4000-8000-0000000255f1')->>'reason')
           = 'no_grant', 'a shared-org grant does not count in one org';
end $$;
set local request.jwt.claims = '';


-- 2 and 7. The member is allowed in the org their grant is held in, and not in one they do not belong to.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000255b2"}';
do $$
declare v jsonb;
begin
    v := rbac.decide_in_org('rbac18.publication', 'publish', '00000000-0000-4000-8000-0000000255f1');
    assert (v->>'allowed')::boolean and v->>'org_id' = '00000000-0000-4000-8000-0000000255f1',
        'a grant held in the org allows the decision there, and says which org';
    assert rbac.may_in_org('rbac18.publication', 'publish', '00000000-0000-4000-8000-0000000255f1'),
        'may_in_org agrees';
    assert (rbac.decide_in_org('rbac18.publication', 'publish', '00000000-0000-4000-8000-0000000255f2')->>'reason')
           = 'not_a_member', 'an org the caller does not belong to refuses';
    assert not rbac.may_in_org('rbac18.publication', 'publish', '00000000-0000-4000-8000-0000000255f2'),
        'and may_in_org agrees';

-- 4. The shared org, or no org, is not an org to decide in.
    assert (rbac.decide_in_org('rbac18.publication', 'publish', rbac.shared_org_id())->>'reason') = 'org_required',
        'the shared org is refused as the one org';
    assert (rbac.decide_in_org('rbac18.publication', 'publish', null)->>'reason') = 'org_required',
        'so is no org at all';

-- 6. A capability every person holds passes for a member, and still needs an org.
    assert rbac.may_in_org('rbac18.notes', 'read', '00000000-0000-4000-8000-0000000255f1'),
        'an every-person capability passes for a member without a grant';
    assert (rbac.decide_in_org('rbac18.notes', 'read', '00000000-0000-4000-8000-0000000255f2')->>'reason')
           = 'not_a_member', 'but not in an org the caller does not belong to';
end $$;
set local request.jwt.claims = '';


-- 3. The outsider holds the grant in publication one and is not a member of it.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000255c3"}';
do $$
begin
    assert (rbac.decide_in_org('rbac18.publication', 'publish', '00000000-0000-4000-8000-0000000255f1')->>'reason')
           = 'not_a_member', 'a grant in an org the caller does not belong to does not open it';
end $$;
set local request.jwt.claims = '';


-- 6. A refusal before the grant question stands: an anonymous caller is anonymous in every org.
do $$
begin
    assert (rbac.decide_in_org('rbac18.publication', 'publish', '00000000-0000-4000-8000-0000000255f1')->>'reason')
           = 'anonymous', 'an anonymous caller is refused as anonymous, not for want of an org grant';
end $$;


-- 5. The member's grant is revoked, and it counts for nothing.
update rbac.grants set revoked_at = now(), revoke_reason = 'rbac/18: a revoked grant in the org'
 where user_id = '00000000-0000-4000-8000-0000000255b2' and role = 'rbac18-publisher';
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000255b2"}';
do $$
begin
    assert (rbac.decide_in_org('rbac18.publication', 'publish', '00000000-0000-4000-8000-0000000255f1')->>'reason')
           = 'no_grant', 'a revoked grant in the org counts for nothing';
end $$;
set local request.jwt.claims = '';

rollback;
