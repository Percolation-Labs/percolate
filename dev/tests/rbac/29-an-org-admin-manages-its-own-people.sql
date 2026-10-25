-- AN ORG'S ADMINISTRATOR, WITH NO ROLE OVER THE INSTALLATION, MANAGES ITS OWN PEOPLE AND NOBODY ELSE'S (REM-1166).
--
-- A school runs its own org: its admin holds users:admin granted in that org and nothing in the shared org.
--
--   1. they add a member by address, in their org only; an existing account joins as it is, never reactivated;
--   2. they grant that member a role in their org, and not in another;
--   3. they put a member on a finite plan; an unlimited plan, a non-member, and a member of an org they do not
--      administer are each refused;
--   4. an installation administrator may assign any plan to anybody;
--   5. an agent does none of it.
--
-- The claims are set as the superuser between blocks. One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000229a1', 'rbac29-instance@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000229b2', 'rbac29-school-admin@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000229c3', 'rbac29-disabled@example.test', 'disabled'),
    ('00000000-0000-4000-8000-0000000229d4', 'rbac29-other-school@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000229e5', 'rbac29-two-schools@example.test', 'active');
insert into rbac.orgs (id, slug, name) values
    ('00000000-0000-4000-8000-0000000229f1', 'rbac29-school-a', 'School A'),
    ('00000000-0000-4000-8000-0000000229f2', 'rbac29-school-b', 'School B');
insert into rbac.org_members (org_id, user_id) values
    ('00000000-0000-4000-8000-0000000229f1', '00000000-0000-4000-8000-0000000229b2'),
    ('00000000-0000-4000-8000-0000000229f2', '00000000-0000-4000-8000-0000000229d4'),
    ('00000000-0000-4000-8000-0000000229f1', '00000000-0000-4000-8000-0000000229e5'),
    ('00000000-0000-4000-8000-0000000229f2', '00000000-0000-4000-8000-0000000229e5');
insert into rbac.roles (name, description) values
    ('rbac29-org-admin', 'administers the people of one org'),
    ('rbac29-student', 'reads');
insert into rbac.role_permissions (role, resource, action) values
    ('rbac29-org-admin', 'users', 'admin'),
    ('rbac29-student', 'users', 'select');
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000000229a1', 'rbac29-org-admin');
insert into rbac.grants (user_id, role, org_id, basis) values
    ('00000000-0000-4000-8000-0000000229b2', 'rbac29-org-admin', '00000000-0000-4000-8000-0000000229f1', 'operator');
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000000229b2', 'rbac29-org-admin');
insert into rbac.plans (name, description) values
    ('rbac29-student', 'a capped plan'),
    ('rbac29-open', 'model tokens without limit');
insert into rbac.plan_limits (plan, resource_kind, mode, amount) values ('rbac29-student', 'llm_tokens', 'finite', 100000);
insert into rbac.plan_limits (plan, resource_kind, mode) values ('rbac29-open', 'llm_tokens', 'unlimited');


set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000229b2", "org_id": "00000000-0000-4000-8000-0000000229f1", "orgs": ["00000000-0000-4000-8000-0000000229f1"]}';

-- 1 and 2. A member by address, then a role, in school A only.
do $$
declare v_pupil uuid; v_refused int := 0;
begin
    v_pupil := rbac.create_org_member('00000000-0000-4000-8000-0000000229f1', 'rbac29-pupil@example.test');
    perform set_config('rbac29.pupil', v_pupil::text, true);
    assert (select status = 'active' from rbac.users where id = v_pupil), 'a new address is an active account';
    assert exists (select 1 from rbac.org_members
                    where org_id = '00000000-0000-4000-8000-0000000229f1' and user_id = v_pupil and role = 'member'),
        'and a member of school A';
    assert rbac.create_org_member('00000000-0000-4000-8000-0000000229f1', 'RBAC29-disabled@example.test')
           = '00000000-0000-4000-8000-0000000229c3', 'an existing address joins as the account it is';
    perform rbac.grant_with_basis(v_pupil, 'rbac29-student', 'invitation', p_org => '00000000-0000-4000-8000-0000000229f1');

    begin perform rbac.create_org_member('00000000-0000-4000-8000-0000000229f2', 'rbac29-intruder@example.test');
    exception when insufficient_privilege then v_refused := v_refused + 1; end;
    begin perform rbac.create_org_member(rbac.shared_org_id(), 'rbac29-intruder@example.test');
    exception when insufficient_privilege then v_refused := v_refused + 1; end;
    begin perform rbac.grant_with_basis(v_pupil, 'rbac29-student', 'invitation', p_org => '00000000-0000-4000-8000-0000000229f2');
    exception when insufficient_privilege then v_refused := v_refused + 1; end;
    assert v_refused = 3, format('a member of school B, of the shared org, and a role in school B all refuse; %s did', v_refused);
end $$;


-- 3. A finite plan for a member; the rest refused, each for its own reason.
do $$
declare v_pupil uuid := current_setting('rbac29.pupil')::uuid; v_hint text; v_hints text[] := '{}';
begin
    perform rbac.assign_plan(v_pupil, 'rbac29-student', '00000000-0000-4000-8000-0000000229f1');
    assert rbac.plan_of(v_pupil) = 'rbac29-student', 'the member is on the capped plan';

    begin perform rbac.assign_plan(v_pupil, 'rbac29-open', '00000000-0000-4000-8000-0000000229f1');
    exception when insufficient_privilege then get stacked diagnostics v_hint = pg_exception_hint; v_hints := v_hints || v_hint; end;
    begin perform rbac.assign_plan('00000000-0000-4000-8000-0000000229d4', 'rbac29-student', '00000000-0000-4000-8000-0000000229f1');
    exception when insufficient_privilege then get stacked diagnostics v_hint = pg_exception_hint; v_hints := v_hints || v_hint; end;
    begin perform rbac.assign_plan('00000000-0000-4000-8000-0000000229e5', 'rbac29-student', '00000000-0000-4000-8000-0000000229f1');
    exception when insufficient_privilege then get stacked diagnostics v_hint = pg_exception_hint; v_hints := v_hints || v_hint; end;
    begin perform rbac.assign_plan('00000000-0000-4000-8000-0000000229d4', 'rbac29-student', '00000000-0000-4000-8000-0000000229f2');
    exception when insufficient_privilege then get stacked diagnostics v_hint = pg_exception_hint; v_hints := v_hints || v_hint; end;
    assert v_hints = array['plan_not_finite', 'not_a_member', 'another_org', 'not_a_member'],
        format('unlimited, a non-member, a member of school B too, and school B itself refuse; got %s', v_hints);
end $$;
set local request.jwt.claims = '';
do $$
begin
    assert (select status = 'disabled' from rbac.users where id = '00000000-0000-4000-8000-0000000229c3'),
        'the disabled account was not reactivated by joining';
    assert rbac.plan_of('00000000-0000-4000-8000-0000000229e5') = 'default', 'a refused assignment wrote nothing';
end $$;


-- 4. The installation's administrator assigns any plan to anybody.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000229a1"}';
do $$
begin
    perform rbac.assign_plan('00000000-0000-4000-8000-0000000229e5', 'rbac29-open', '00000000-0000-4000-8000-0000000229f2');
    assert rbac.plan_of('00000000-0000-4000-8000-0000000229e5') = 'rbac29-open', 'any plan, from the installation';
end $$;


-- 5. An agent acting for the school's admin does none of it.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000229b2", "actor": "agent", "org_id": "00000000-0000-4000-8000-0000000229f1"}';
do $$
declare v_refused int := 0;
begin
    begin perform rbac.create_org_member('00000000-0000-4000-8000-0000000229f1', 'rbac29-agent@example.test');
    exception when insufficient_privilege then v_refused := v_refused + 1; end;
    begin perform rbac.assign_plan(current_setting('rbac29.pupil')::uuid, 'rbac29-student', '00000000-0000-4000-8000-0000000229f1');
    exception when insufficient_privilege then v_refused := v_refused + 1; end;
    assert v_refused = 2, 'an agent adds no member and assigns no plan';
end $$;
set local request.jwt.claims = '';

rollback;
