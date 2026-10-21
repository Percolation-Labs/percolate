-- A SCHEDULE IS REWRITTEN ONLY BY ITS OWNER OR A SCHEDULE ADMINISTRATOR (REM-1120).
--
-- schedule_workflow asked assert_schedule_access(name, 'create') and then
-- upserted on name, keeping owner_id. A holder of workflow_schedules:create
-- who did not own an existing schedule repointed it, and it fired the new
-- workflow as its owner. rbac/14 already said "an existing schedule only by
-- its owner"; nothing held it. Asserted here:
--   1. Leo, holding workflow_schedules:create, cannot rewrite Alice's schedule,
--      and it is unchanged;
--   2. Alice rewrites her own;
--   3. a holder of workflow_schedules:update can, and grants_all holds it.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

\set alice '''00000000-0000-4000-8000-000000112001'''
\set leo   '''00000000-0000-4000-8000-000000112002'''
\set admin '''00000000-0000-4000-8000-000000112003'''
\set as_alice 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-000000112001"}''; set local role authenticated;'
\set as_leo   'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-000000112002"}''; set local role authenticated;'
\set as_admin 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-000000112003"}''; set local role authenticated;'

begin;
insert into rbac.users (id, email, status) values
    (:alice, 'rem1120-alice@example.test', 'active'),
    (:leo,   'rem1120-leo@example.test',   'active'),
    (:admin, 'rem1120-admin@example.test', 'active');
insert into rbac.roles (name) values ('rem1120_scheduler'), ('rem1120_admin');
insert into rbac.role_permissions (role, resource, action) values
    ('rem1120_scheduler', 'workflow_schedules', 'create'),
    ('rem1120_admin',     'workflow_schedules', 'update');
insert into rbac.user_roles (user_id, role) values (:leo, 'rem1120_scheduler'), (:admin, 'rem1120_admin');
insert into workflow.definitions (name, spec, visibility) values
    ('rem1120_alices', '{"steps":[{"key":"a","kind":"work","queue":"rem1120"}]}', 'public'),
    ('rem1120_other',  '{"steps":[{"key":"a","kind":"work","queue":"rem1120"}]}', 'public');

create function pg_temp.refused(p_sql text, p_like text) returns void language plpgsql as $$
begin
    execute p_sql;
    raise exception 'accepted, and should have been refused: %', p_sql;
exception when others then
    if sqlerrm not like p_like then raise; end if;
end $$;
grant execute on function pg_temp.refused(text, text) to authenticated;

:as_alice
select workflow.schedule_workflow('rem1120', 'rem1120_alices', '0 * * * *') \g /dev/null

-- 1. Leo.
:as_leo
select pg_temp.refused($q$select workflow.schedule_workflow('rem1120', 'rem1120_other', '* * * * *', '{"x":1}')$q$,
                       'not authorized to update schedule "rem1120"');
reset role;
do $$
begin
    if (select workflow_name || ' ' || cron_expr from workflow.schedules where name = 'rem1120')
       is distinct from 'rem1120_alices 0 * * * *' then
        raise exception 'a refused rewrite changed Alice''s schedule anyway';
    end if;
end $$;

-- 2. Alice, her own.
:as_alice
select workflow.schedule_workflow('rem1120', 'rem1120_alices', '30 * * * *') \g /dev/null
-- 3. workflow_schedules:update.
:as_admin
select workflow.schedule_workflow('rem1120', 'rem1120_other', '15 * * * *') \g /dev/null
reset role;
do $$
begin
    if (select workflow_name || ' ' || cron_expr from workflow.schedules where name = 'rem1120')
       is distinct from 'rem1120_other 15 * * * *' then
        raise exception 'the owner, then a holder of workflow_schedules:update, could not rewrite the schedule';
    end if;
    if exists (select 1 from rbac.roles r where r.grants_all
                and not exists (select 1 from rbac.role_permissions p where p.role = r.name
                                 and p.resource = 'workflow_schedules' and p.action = 'update')) then
        raise exception 'an administrator''s grants_all role does not hold workflow_schedules:update';
    end if;
end $$;

rollback;

\echo workflow/34: a schedule is rewritten only by its owner or a holder of workflow_schedules:update
