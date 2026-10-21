-- A ROLE IS DEFINED AND GRANTED BY FUNCTION, NOT BY WRITING ROWS (REM-1082).
--
-- Setting up access meant inserting rows, and a wrong row is silent: a role given
-- a permission no policy reads looks populated and grants nothing.
--
--   1. define_role refuses a pair no policy or function checks, naming it and the
--      pairs that resource does have, and creates nothing;
--   2. it defines a role from checked pairs;
--   3. grant_role_by_email grants it, refuses an unknown address and an unknown
--      role, and records the grant in the ledger;
--   4. add_org_member enrols someone from the same installer session;
--   5. an ordinary signed-in person may do none of it, and the worker role holds
--      no grant on it. (A worker LOGIN is also refused by rbac.is_installer,
--      which asks session_user; under `set role` here the session is still the
--      owner's, so that arm is proven by the grant and not by this file.)
--
-- One transaction, rolled back. As the owner, which is the installer session.

\set ON_ERROR_STOP on

begin;
insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-000000108201', 'rem1082-ana@example.test', 'active'),
    ('00000000-0000-4000-8000-000000108202', 'rem1082-ben@example.test', 'active');
insert into rbac.orgs (id, slug, name) values ('00000000-0000-4000-8000-000000108203', 'rem1082-org', 'REM-1082 org');

do $$
declare msg text; hint text; r jsonb; uid uuid;
begin
    -- 1. An unchecked pair is refused by name, and nothing is created.
    begin
        perform rbac.define_role('rem1082-reviewer', array['research:select', 'research:approve']);
        raise exception 'a role with an unchecked permission was defined';
    exception when check_violation then
        get stacked diagnostics msg = message_text, hint = pg_exception_hint;
        if msg is distinct from 'no policy or function checks research:approve, so a role holding it would grant nothing' then
            raise exception 'the refusal does not name the pair: %', msg;
        end if;
        if hint not like 'the pairs checked on that resource: %research:select%' then
            raise exception 'the refusal does not list what the resource does check: %', hint;
        end if;
    end;
    if exists (select 1 from rbac.roles where name = 'rem1082-reviewer') then
        raise exception 'a refused role was created anyway';
    end if;

    -- 2. Checked pairs define a role.
    r := rbac.define_role('rem1082-reviewer', array['research:select', 'research:list'], 'reads research');
    if r is distinct from '{"role": "rem1082-reviewer", "permissions": ["research:list", "research:select"]}'::jsonb then
        raise exception 'define_role returned %', r;
    end if;

    -- 3. Granted by email; an unknown address and an unknown role are refused.
    uid := rbac.grant_role_by_email('REM1082-Ana@example.test', 'rem1082-reviewer');
    if uid is distinct from '00000000-0000-4000-8000-000000108201'::uuid then
        raise exception 'the grant reached % instead of ana', uid;
    end if;
    if not rbac.has_permission(uid, 'research', 'list') then
        raise exception 'the granted role does not reach the user';
    end if;
    if not exists (select 1 from rbac.grants where user_id = uid and role = 'rem1082-reviewer' and basis = 'operator') then
        raise exception 'the grant is not in the ledger';
    end if;
    begin
        perform rbac.grant_role_by_email('nobody-rem1082@example.test', 'rem1082-reviewer');
        raise exception 'an unknown email was granted a role';
    exception when no_data_found then
        get stacked diagnostics msg = message_text;
        if msg is distinct from 'no user has the email nobody-rem1082@example.test' then raise; end if;
    end;
    begin
        perform rbac.grant_role_by_email('rem1082-ana@example.test', 'rem1082-nonesuch');
        raise exception 'an unknown role was granted';
    exception when no_data_found then
        null;
    end;

    -- 4a. An org and a passwordless reader at fixed ids, which is what a sample needs, and a replay converges.
    if rbac.create_org('rem1082-two', 'Two', '00000000-0000-4000-8000-000000108204') is distinct from
       '00000000-0000-4000-8000-000000108204'::uuid then
        raise exception 'create_org did not use the fixed id';
    end if;
    perform rbac.create_org('rem1082-two', 'Two, renamed', '00000000-0000-4000-8000-000000108204');
    if (select name from rbac.orgs where id = '00000000-0000-4000-8000-000000108204') is distinct from 'Two, renamed' then
        raise exception 'a replayed create_org did not converge';
    end if;
    if exists (select 1 from rbac.org_members where org_id = '00000000-0000-4000-8000-000000108204') then
        raise exception 'an org the installer created has a member nobody chose';
    end if;
    if rbac.create_user('rem1082-reader@example.test', '00000000-0000-4000-8000-000000108205')
       is distinct from '00000000-0000-4000-8000-000000108205'::uuid
       or rbac.create_user('rem1082-reader@example.test', '00000000-0000-4000-8000-000000108205')
       is distinct from '00000000-0000-4000-8000-000000108205'::uuid then
        raise exception 'create_user did not return the same reader on a replay';
    end if;
    if (select status from rbac.users where id = '00000000-0000-4000-8000-000000108205') is distinct from 'active' then
        raise exception 'the reader is not active';
    end if;
    begin
        perform rbac.create_user('rem1082-ana@example.test', '00000000-0000-4000-8000-000000108206');
        raise exception 'create_user moved an email to another id';
    exception when unique_violation then null;
    end;

    -- 4. Enrolment from the installer session, through the function.
    perform rbac.add_org_member('00000000-0000-4000-8000-000000108203', uid);
    if not exists (select 1 from rbac.org_members where org_id = '00000000-0000-4000-8000-000000108203' and user_id = uid) then
        raise exception 'add_org_member did not enrol from the installer session';
    end if;
end $$;

-- 5. Nobody else may.
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000108202"}', true) \g /dev/null
set local role authenticated;
do $$
begin
    begin
        perform rbac.define_role('rem1082-self', array['research:select']);
        raise exception 'an ordinary person defined a role';
    exception when insufficient_privilege then null;
    end;
    begin
        perform rbac.grant_role_by_email('rem1082-ben@example.test', 'rem1082-reviewer');
        raise exception 'an ordinary person granted themselves a role';
    exception when insufficient_privilege then null;
    end;
    begin
        perform rbac.create_user('rem1082-mallory@example.test');
        raise exception 'an ordinary person created a user';
    exception when insufficient_privilege then null;
    end;
    begin
        perform rbac.create_org('rem1082-mine', 'Mine');
        raise exception 'an ordinary person created an org';
    exception when insufficient_privilege then null;
    end;
end $$;
reset role;
select set_config('request.jwt.claims', '', true) \g /dev/null
set local role worker;
do $$
begin
    begin
        perform rbac.grant_role_by_email('rem1082-ben@example.test', 'rem1082-reviewer');
        raise exception 'a worker login with no claims granted a role';
    exception when insufficient_privilege then null;
    end;
end $$;
reset role;

rollback;
