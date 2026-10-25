-- A ROLE GRANTED IN ONE ORG GIVES NO POWER IN ANOTHER, OR OVER THE INSTALLATION (REM-1166).
--
-- rbac.grants carries an org and rbac.user_roles does not. rbac.has_permission read only user_roles, so a role
-- granted in org A counted everywhere has_permission is asked -- create_user, create_org, define_role, grant_role and
-- every RLS "an administrator reads it all" arm. And grant_with_basis asked rbac.require, which counts a grant in the
-- org the claims name, then wrote the grant into whatever org it was handed. A school's admin could create orgs,
-- redefine roles, and grant roles in another school or in the shared org.
--
--   1. an admin whose grant is held in org A holds no instance-wide permission, and every instance function refuses;
--   2. they grant a role in org A, and are refused in org B and in the shared org;
--   3. they revoke a grant held in org A, and are refused one held in org B;
--   4. an instance admin, whose grant is in the shared org, still grants and revokes in any org;
--   5. the role granted in org A counts in org A's decisions, which is what the grant was for.
--
-- The claims are set as the superuser between blocks. One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000166a1', 'rbac28-instance@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000166b2', 'rbac28-school-a@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000166c3', 'rbac28-pupil-a@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000166d4', 'rbac28-pupil-b@example.test', 'active');
insert into rbac.orgs (id, slug, name) values
    ('00000000-0000-4000-8000-0000000166f1', 'rbac28-school-a', 'School A'),
    ('00000000-0000-4000-8000-0000000166f2', 'rbac28-school-b', 'School B');
insert into rbac.org_members (org_id, user_id, role) values
    ('00000000-0000-4000-8000-0000000166f1', '00000000-0000-4000-8000-0000000166b2', 'admin'),
    ('00000000-0000-4000-8000-0000000166f1', '00000000-0000-4000-8000-0000000166c3', 'member'),
    ('00000000-0000-4000-8000-0000000166f2', '00000000-0000-4000-8000-0000000166d4', 'member');
insert into rbac.roles (name, description) values
    ('rbac28-org-admin', 'administers people and roles'),
    ('rbac28-pupil', 'reads users');
insert into rbac.role_permissions (role, resource, action) values
    ('rbac28-org-admin', 'users', 'admin'),
    ('rbac28-org-admin', 'orgs', 'admin'),
    ('rbac28-pupil', 'users', 'select');

-- The instance admin holds the role in the shared org; the school's admin holds it in school A only.
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000000166a1', 'rbac28-org-admin');
insert into rbac.grants (user_id, role, org_id, basis) values
    ('00000000-0000-4000-8000-0000000166b2', 'rbac28-org-admin', '00000000-0000-4000-8000-0000000166f1', 'operator');
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000000166b2', 'rbac28-org-admin');
-- A pupil in school B holds a grant there, for 3.
insert into rbac.grants (id, user_id, role, org_id, basis) values
    ('00000000-0000-4000-8000-0000000166e2', '00000000-0000-4000-8000-0000000166d4', 'rbac28-pupil',
     '00000000-0000-4000-8000-0000000166f2', 'operator');
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000000166d4', 'rbac28-pupil');


-- 1. The school's admin holds nothing instance-wide.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000166b2", "org_id": "00000000-0000-4000-8000-0000000166f1", "orgs": ["00000000-0000-4000-8000-0000000166f1"]}';
do $$
declare v_refused int := 0;
begin
    assert not rbac.has_permission('00000000-0000-4000-8000-0000000166b2', 'users', 'admin'),
        'a role granted in school A is not users:admin over the installation';
    assert not rbac.has_permission('00000000-0000-4000-8000-0000000166d4', 'users', 'select'),
        'nor is a pupil''s role granted in school B';
    begin perform rbac.create_org('rbac28-school-c', 'School C');
    exception when insufficient_privilege then v_refused := v_refused + 1; end;
    begin perform rbac.create_user('rbac28-new@example.test');
    exception when insufficient_privilege then v_refused := v_refused + 1; end;
    begin perform rbac.define_role('rbac28-pupil', array['users:admin']);
    exception when insufficient_privilege then v_refused := v_refused + 1; end;
    begin perform rbac.grant_role('00000000-0000-4000-8000-0000000166c3', 'rbac28-org-admin');
    exception when insufficient_privilege then v_refused := v_refused + 1; end;
    assert v_refused = 4, format('create_org, create_user, define_role and grant_role all refuse; %s did', v_refused);
end $$;


-- 2. They grant in school A, and are refused in school B and in the shared org.
do $$
declare v_refused int := 0; v_grant uuid;
begin
    v_grant := rbac.grant_with_basis('00000000-0000-4000-8000-0000000166c3', 'rbac28-pupil', 'operator',
                                     p_org => '00000000-0000-4000-8000-0000000166f1');
    assert (select org_id = '00000000-0000-4000-8000-0000000166f1' from rbac.grants where id = v_grant),
        'a grant in school A, by school A''s admin, is written in school A';
    begin perform rbac.grant_with_basis('00000000-0000-4000-8000-0000000166d4', 'rbac28-org-admin', 'operator',
                                        p_org => '00000000-0000-4000-8000-0000000166f2');
    exception when insufficient_privilege then v_refused := v_refused + 1; end;
    begin perform rbac.grant_with_basis('00000000-0000-4000-8000-0000000166c3', 'rbac28-org-admin', 'operator');
    exception when insufficient_privilege then v_refused := v_refused + 1; end;
    assert v_refused = 2, format('a grant in school B and one in the shared org both refuse; %s did', v_refused);
end $$;


-- 3. They revoke in school A, and are refused in school B.
do $$
declare v_refused int := 0;
begin
    perform rbac.revoke_grant((select id from rbac.grants
                                where user_id = '00000000-0000-4000-8000-0000000166c3' and role = 'rbac28-pupil'
                                  and revoked_at is null), 'left the class');
    begin perform rbac.revoke_grant('00000000-0000-4000-8000-0000000166e2', 'not mine to end');
    exception when insufficient_privilege then v_refused := v_refused + 1; end;
    assert v_refused = 1, 'a grant held in school B is not school A''s admin''s to revoke';
end $$;
set local request.jwt.claims = '';
do $$
begin
    assert (select revoked_at is not null from rbac.grants
             where user_id = '00000000-0000-4000-8000-0000000166c3' and role = 'rbac28-pupil'),
        'the grant in school A ended';
    assert (select revoked_at is null from rbac.grants where id = '00000000-0000-4000-8000-0000000166e2'),
        'the grant in school B did not';
end $$;


-- 4. The instance admin still grants and revokes anywhere.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000166a1"}';
do $$
begin
    assert rbac.has_permission('00000000-0000-4000-8000-0000000166a1', 'users', 'admin'),
        'a shared-org grant is users:admin over the installation';
    perform rbac.grant_with_basis('00000000-0000-4000-8000-0000000166d4', 'rbac28-org-admin', 'operator',
                                  p_org => '00000000-0000-4000-8000-0000000166f2');
    perform rbac.revoke_grant('00000000-0000-4000-8000-0000000166e2', 'moved to the admin role');
end $$;
set local request.jwt.claims = '';


-- 5. The role granted in school A still counts in school A's own decisions.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000166b2", "org_id": "00000000-0000-4000-8000-0000000166f1", "orgs": ["00000000-0000-4000-8000-0000000166f1"]}';
do $$
begin
    assert rbac.may_in_org('users', 'admin', '00000000-0000-4000-8000-0000000166f1'),
        'school A''s admin is users:admin in school A';
    assert not rbac.may_in_org('users', 'admin', '00000000-0000-4000-8000-0000000166f2'),
        'and not in school B';
end $$;
set local request.jwt.claims = '';

rollback;
