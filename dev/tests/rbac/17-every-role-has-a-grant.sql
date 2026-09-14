-- EVERY ROLE A PERSON HOLDS SAYS HOW IT WAS GIVEN, AND ONLY AN ACTIVE GRANT COUNTS (REM-171).
--
-- rbac.decide used to honour a role row with no grant behind it ("pre-ledger core roles keep their existing
-- meaning"), and two writers made exactly those rows: rbac.grant_role and bootstrap_admin. A role could exist with
-- no granter, basis or evidence, and revoke_grant had nothing to revoke. Now every writer records a grant --
-- grant_role as 'operator', anything else through trg_user_roles_record_grant as 'installation' -- and decide
-- counts a role only through an active grant.
--
--   1. a role inserted directly (an installation step, a fixture) is recorded as an 'installation' grant;
--   2. an administrator's grant_role is recorded as an 'operator' grant that names them;
--   3. a role row whose only grant is revoked grants nothing, though the row is still there;
--   4. grant_with_basis and the trigger together record one grant, the one that says why.
--
-- The claims are set as the superuser between blocks, because a person's role may not call set_config (REM-44).
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000171a1', 'rbac17-admin@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000171b2', 'rbac17-person@example.test', 'active');
select rbac.declare_application('rbac17', '1', '[{"resource": "notes", "action": "read"}]');
insert into rbac.roles (name, description) values ('rbac17-reader', 'reads rbac17 notes');
insert into rbac.role_permissions (role, resource, action) values ('rbac17-reader', 'rbac17.notes', 'read');


-- 1. A role inserted directly is recorded as an installation grant.
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000000171a1', 'admin');
do $$
begin
    assert (select count(*) from rbac.grants
             where user_id = '00000000-0000-4000-8000-0000000171a1' and role = 'admin'
               and basis = 'installation' and revoked_at is null) = 1,
        'a role inserted directly is recorded as one installation grant';
end $$;


-- 2. The administrator grants a role through grant_role: an operator grant naming them.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000171a1"}';
select rbac.grant_role('00000000-0000-4000-8000-0000000171b2', 'rbac17-reader');
set local request.jwt.claims = '';
do $$
begin
    assert (select count(*) from rbac.grants
             where user_id = '00000000-0000-4000-8000-0000000171b2' and role = 'rbac17-reader'
               and revoked_at is null) = 1,
        'grant_role records exactly one grant';
    assert (select basis = 'operator' and granted_by = '00000000-0000-4000-8000-0000000171a1'
              from rbac.grants
             where user_id = '00000000-0000-4000-8000-0000000171b2' and role = 'rbac17-reader'),
        'and it is the administrator''s operator grant';
end $$;


-- 3. The person may read; then the grant is revoked behind the role row's back, and the row grants nothing.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000171b2"}';
do $$
begin
    assert rbac.may('rbac17.notes', 'read'), 'the granted person may read';
end $$;
set local request.jwt.claims = '';

update rbac.grants set revoked_at = now(), revoke_reason = 'rbac/17: revoked without removing the role row'
 where user_id = '00000000-0000-4000-8000-0000000171b2' and role = 'rbac17-reader';

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000171b2"}';
do $$
begin
    assert exists (select 1 from rbac.user_roles
                    where user_id = '00000000-0000-4000-8000-0000000171b2' and role = 'rbac17-reader'),
        'the role row is still there';
    assert not rbac.may('rbac17.notes', 'read'), 'a role whose only grant is revoked grants nothing';
    assert (rbac.decide('rbac17.notes', 'read')->>'reason') = 'no_grant', 'and decide says there is no grant';
end $$;
set local request.jwt.claims = '';


-- 4. grant_with_basis writes its grant before the role row, so the trigger adds nothing.
select rbac.grant_with_basis('00000000-0000-4000-8000-0000000171a1', 'rbac17-reader', 'invitation', 'rbac/17');
do $$
begin
    assert (select count(*) from rbac.grants
             where user_id = '00000000-0000-4000-8000-0000000171a1' and role = 'rbac17-reader'
               and revoked_at is null) = 1,
        'grant_with_basis and the trigger record one grant, not two';
    assert (select basis from rbac.grants
             where user_id = '00000000-0000-4000-8000-0000000171a1' and role = 'rbac17-reader'
               and revoked_at is null) = 'invitation',
        'and it is the grant that says why';
    raise notice 'rbac/17: direct role rows and grant_role are recorded, a revoked grant grants nothing, and no grant is recorded twice';
end $$;

rollback;
