-- AN ORG'S ADMIN DOES NOT JOIN AN EXISTING ACCOUNT TO THEIR ORG, BY ID EITHER (REM-1192).
--
-- rbac.create_org_member refuses an existing account to an org's admin (REM-1166), because joining somebody without
-- their say hands the org a hold on them: their plan, first of all. rbac.add_org_member, older, took any account by
-- id for anybody holding the admin role in the org's membership, so an org's admin could join an outsider and then
-- cap the outsider's plan through rbac.assign_plan.
--
--   1. an org's admin is refused joining an outsider by id, and so cannot cap the outsider's plan;
--   2. they still change the role of somebody already a member of their org;
--   3. the installation's admin joins an existing account by id as before.
--
-- The claims are set as the superuser between blocks. One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000001192a1', 'rbac30-instance@example.test', 'active'),
    ('00000000-0000-4000-8000-0000001192b2', 'rbac30-school-admin@example.test', 'active'),
    ('00000000-0000-4000-8000-0000001192c3', 'rbac30-pupil@example.test', 'active'),
    ('00000000-0000-4000-8000-0000001192d4', 'rbac30-outsider@example.test', 'active');
insert into rbac.orgs (id, slug, name) values ('00000000-0000-4000-8000-0000001192f1', 'rbac30-school', 'School');
insert into rbac.org_members (org_id, user_id, role) values
    ('00000000-0000-4000-8000-0000001192f1', '00000000-0000-4000-8000-0000001192b2', 'admin'),
    ('00000000-0000-4000-8000-0000001192f1', '00000000-0000-4000-8000-0000001192c3', 'member');
insert into rbac.roles (name, description) values ('rbac30-org-admin', 'administers the people of one org');
insert into rbac.role_permissions (role, resource, action) values
    ('rbac30-org-admin', 'users', 'admin'),
    ('rbac30-org-admin', 'orgs', 'admin');
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000001192a1', 'rbac30-org-admin');
insert into rbac.grants (user_id, role, org_id, basis) values
    ('00000000-0000-4000-8000-0000001192b2', 'rbac30-org-admin', '00000000-0000-4000-8000-0000001192f1', 'operator');
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000001192b2', 'rbac30-org-admin');
insert into rbac.plans (name, description) values ('rbac30-capped', 'a capped plan');
insert into rbac.plan_limits (plan, resource_kind, mode, amount) values ('rbac30-capped', 'llm_tokens', 'finite', 1);


-- 1. The school's admin joins the outsider by id, then caps their plan: both refused.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000001192b2", "org_id": "00000000-0000-4000-8000-0000001192f1", "orgs": ["00000000-0000-4000-8000-0000001192f1"]}';
do $$
declare v_hint text; v_hints text[] := '{}';
begin
    begin perform rbac.add_org_member('00000000-0000-4000-8000-0000001192f1', '00000000-0000-4000-8000-0000001192d4');
    exception when insufficient_privilege then get stacked diagnostics v_hint = pg_exception_hint; v_hints := v_hints || v_hint; end;
    begin perform rbac.assign_plan('00000000-0000-4000-8000-0000001192d4', 'rbac30-capped', '00000000-0000-4000-8000-0000001192f1');
    exception when insufficient_privilege then get stacked diagnostics v_hint = pg_exception_hint; v_hints := v_hints || v_hint; end;
    assert v_hints = array['existing_account', 'not_a_member'],
        format('joining the outsider and then capping their plan both refuse; got %s', v_hints);

-- 2. A member of the school is the school's to promote.
    perform rbac.add_org_member('00000000-0000-4000-8000-0000001192f1', '00000000-0000-4000-8000-0000001192c3', 'admin');
end $$;
set local request.jwt.claims = '';
do $$
begin
    assert rbac.plan_of('00000000-0000-4000-8000-0000001192d4') = 'default', 'the outsider''s plan is their own';
    assert not exists (select 1 from rbac.org_members where user_id = '00000000-0000-4000-8000-0000001192d4'),
        'and they joined nothing';
    assert (select role = 'admin' from rbac.org_members
             where org_id = '00000000-0000-4000-8000-0000001192f1' and user_id = '00000000-0000-4000-8000-0000001192c3'),
        'the member was promoted';
end $$;


-- 3. The installation's admin joins the outsider by id.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000001192a1"}';
select rbac.add_org_member('00000000-0000-4000-8000-0000001192f1', '00000000-0000-4000-8000-0000001192d4');
set local request.jwt.claims = '';
do $$
begin
    assert exists (select 1 from rbac.org_members
                    where org_id = '00000000-0000-4000-8000-0000001192f1' and user_id = '00000000-0000-4000-8000-0000001192d4'),
        'the installation joins an existing account';
end $$;

rollback;
