-- loads: research-platform/schema.sql
-- An application withdraws a grant it issued (architecture.md §7, REM-248).
--
--   1. the provisioner revokes a writer grant it issued, with a reason; the grant stays as history, revoked_by
--      names the deciding person, the role leaves user_roles, and a second revocation changes nothing;
--   2. it cannot revoke a grant issued under another application, or one whose role carries a capability an
--      application may not grant, and a revocation without a reason is refused;
--   3. a signed-in person, even the one whose decision it is, cannot call it.
--
-- One transaction, rolled back.
\set ON_ERROR_STOP on
begin;
do $$ begin
 if not exists(select 1 from pg_roles where rolname='app_provisioner') then
  create role app_provisioner nologin;
 end if;
end $$;
\i /tmp/schema.sql

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-000000248a01', 'rem248-writer@example.test', 'active'),
    ('00000000-0000-4000-8000-000000248a02', 'rem248-editor@example.test', 'active');
insert into rbac.roles (name, description) values ('rem248-admin', 'an administrator (test)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('rem248-admin', 'users', 'admin') on conflict do nothing;
insert into rbac.grants (id, user_id, role, application, basis) values
    ('00000000-0000-4000-8000-000000248c01', '00000000-0000-4000-8000-000000248a01', 'rem248-admin', 'hub', 'operator');
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-000000248a01', 'rem248-admin');

set local session authorization app_provisioner;
select rbac.declare_application('hub', '2', '[{"resource": "draft", "action": "submit", "human_only": true}]');
select rbac.grant_application_role('00000000-0000-4000-8000-000000248a01', 'rem248-writer', 'hub.draft', 'submit',
                                   'invitation', 'invited by the editor', 'hub', null);
select rbac.grant_application_role('00000000-0000-4000-8000-000000248a01', 'rem248-elsewhere', 'hub.draft', 'submit',
                                   'invitation', 'issued by another application', 'elsewhere', null);
reset session authorization;
-- The provisioner may not read rbac.grants, so the ids it needs are handed over in a table it may read.
create temp table t248 as select role, id from rbac.grants where user_id = '00000000-0000-4000-8000-000000248a01';
grant select on t248 to public;
set local session authorization app_provisioner;

-- 1. Withdrawn, kept, and idempotent.
do $$
declare v_grant uuid;
begin
    select id into v_grant from t248 where role = 'rem248-writer';
    assert rbac.revoke_application_role(v_grant, '  left the hub  ', 'hub', '00000000-0000-4000-8000-000000248a02'),
        'the provisioner withdraws a grant it issued';
    assert not rbac.revoke_application_role(v_grant, 'again', 'hub', '00000000-0000-4000-8000-000000248a02'),
        'withdrawing it again changes nothing';
end $$;
reset session authorization;
do $$
begin
    assert (select revoked_at is not null and revoked_by = '00000000-0000-4000-8000-000000248a02' and revoke_reason = 'left the hub'
              from rbac.grants where user_id = '00000000-0000-4000-8000-000000248a01' and role = 'rem248-writer'),
        'the grant stays, revoked, naming who decided and why';
    assert not exists (select 1 from rbac.user_roles where user_id = '00000000-0000-4000-8000-000000248a01' and role = 'rem248-writer'),
        'the role leaves the effective set';
    assert exists (select 1 from rbac.user_roles where user_id = '00000000-0000-4000-8000-000000248a01' and role = 'rem248-elsewhere'),
        'another application''s grant is untouched';
end $$;

-- 2. Only its own grants, only application capabilities, always a reason.
set local session authorization app_provisioner;
do $$
declare v_elsewhere uuid;
begin
    begin
        perform rbac.revoke_application_role('00000000-0000-4000-8000-000000248c01', 'not an application''s to end', 'hub', null);
        raise exception 'an application revoked an administrator grant';
    exception when insufficient_privilege then null;
    end;
    select id into v_elsewhere from t248 where role = 'rem248-elsewhere';
    begin
        perform rbac.revoke_application_role(v_elsewhere, 'not ours', 'hub', null);
        raise exception 'an application revoked another application''s grant';
    exception when no_data_found then null;
    end;
    begin
        perform rbac.revoke_application_role(v_elsewhere, '   ', 'elsewhere', null);
        raise exception 'a revocation without a reason was accepted';
    exception when invalid_parameter_value then null;
    end;
    begin
        perform rbac.revoke_application_role(v_elsewhere, 'a stranger decided', 'elsewhere', '00000000-0000-4000-8000-000000248fff');
        raise exception 'a decision by nobody was recorded';
    exception when invalid_parameter_value then null;
    end;
end $$;
reset session authorization;

-- 3. Not a person's to call, not even the editor's.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000248a02"}';
set local role authenticated;
do $$
declare v_elsewhere uuid := (select id from t248 where role = 'rem248-elsewhere');
begin
    begin
        perform rbac.revoke_application_role(coalesce(v_elsewhere, '00000000-0000-4000-8000-000000248c02'), 'as a person', 'elsewhere', null);
        raise exception 'a signed-in person called the provisioner''s revocation';
    exception when insufficient_privilege then null;
    end;
end $$;
reset role;

rollback;
