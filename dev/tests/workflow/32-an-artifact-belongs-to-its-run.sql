-- AN OFFLOADED STEP OUTPUT IS STORED, AND IS ITS RUN'S (REM-1119).
--
-- workflow.register_artifact used to call content.register_upload with no
-- claims. On the worker's own login that was refused -- may_upload's claimless
-- arm needs INSERT on content.resources from session_user, which worker does
-- not hold -- so an over-cap output could not be offloaded; workflow/08 runs
-- as app_owner and could not see it. As the owner it succeeded and stored the
-- artifact public and ownerless, whatever the run. Asserted here, on the
-- worker's login (SET SESSION AUTHORIZATION, so session_user is worker):
--   1. the worker registers an artifact for Maya's private run;
--   2. the resource is Maya's and private, as her run is;
--   3. Maya resolves it and Leo does not.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

\set maya '''00000000-0000-4000-8000-000000111901'''
\set leo  '''00000000-0000-4000-8000-000000111902'''

begin;
insert into rbac.users (id, email, status) values
    (:maya, 'rem1119-maya@example.test', 'active'),
    (:leo,  'rem1119-leo@example.test',  'active');
insert into workflow.definitions (name, spec, owner_id, visibility) values
    ('rem1119_render', '{"steps":[{"key":"render","kind":"work","queue":"rem1119"}]}', :maya, 'private');

set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000111901"}';
set local role authenticated;
select workflow.start_workflow('rem1119_render', '{}'::jsonb) as run \gset
reset role;
set local request.jwt.claims = '';
select id as task from workflow.tasks where run_id = :'run' and step_key = 'render' \gset

-- 1. The worker's login.
set session authorization worker;
select workflow.register_artifact(:'task'::uuid, 'rem1119-sum', 'bucket', 'artifacts/rem1119', 42,
                                  'application/json', 'rem1119 output') as res \gset
reset session authorization;

select set_config('rem1119.res', :'res', true) \g /dev/null

-- 2. Whose it is.
do $$
declare v content.resources;
begin
    select * into v from content.resources where id = current_setting('rem1119.res')::uuid;
    if v.owner_id is distinct from '00000000-0000-4000-8000-000000111901' or v.visibility <> 'private' then
        raise exception 'the artifact of Maya''s private run is owner %, visibility %', v.owner_id, v.visibility;
    end if;
    if v.status <> 'stored' then
        raise exception 'an artifact is stored the moment it lands, and this one is %', v.status;
    end if;
end $$;

-- 3. Who reads it.
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000111901"}';
set local role authenticated;
do $$ begin
    if not exists (select 1 from content.resolve_file(current_setting('rem1119.res')::uuid)) then
        raise exception 'Maya cannot resolve the artifact of her own run';
    end if;
end $$;
reset role;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000111902"}';
set local role authenticated;
do $$ begin
    if exists (select 1 from content.resolve_file(current_setting('rem1119.res')::uuid)) then
        raise exception 'Leo resolves the artifact of Maya''s private run';
    end if;
end $$;
reset role;

rollback;

\echo workflow/32: the worker stores an artifact on its own login, and it is its run's: owner, visibility, and who resolves it
