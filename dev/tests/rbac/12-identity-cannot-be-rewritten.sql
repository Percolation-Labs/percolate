-- Nobody a person can become may rewrite who they are.
--
-- Every row rule in the collection reads the caller from one setting:
-- rbac.current_user_id() is `request.jwt.claims ->> 'sub'`. Until 2026-09-11
-- any role could write it -- set_config is PUBLIC by default, and
-- aiq.sql_passthrough, granted to `authenticated`, runs any SELECT, of which
-- `select set_config('request.jwt.claims', '{"sub":"<alice>"}', true)` is one.
-- Measured on the tour stack: carol read 24 nodes as herself and 229, alice's
-- count, after writing alice's id into the setting. `workflow.current_run_id`,
-- which the step functions trust to mean "my own run", fell the same way.
-- (meta/postmortems/2026-09-11-fixed-at-the-copy-that-failed.md §2.1, §3.)
--
-- The fix is one superuser statement per database (specs/user-rbac/roles.sql
-- §6), not a check in each of the functions that read the setting. So this
-- file asserts the statement's effect from each seat a person has, and that the
-- seats which set identity on someone's behalf still can. Each forgery is
-- attempted for real: an assertion that inspected the ACL alone would pass
-- against a database where some other route to set_config had been left open.

\set ON_ERROR_STOP on

-- 1. The ACL, as the roles see it -- every role a person can become lacks it,
--    every role that sets identity on someone's behalf holds it.
do $$
declare r text;
begin
    foreach r in array array['authenticated', 'web_anon', 'api_viewer'] loop
        if has_function_privilege(r, 'pg_catalog.set_config(text, text, boolean)', 'execute') then
            raise exception '% can call set_config, so it can write request.jwt.claims and act as anyone', r;
        end if;
    end loop;
    foreach r in array array['authenticator', 'app_owner', 'worker', 'scheduler'] loop
        if not has_function_privilege(r, 'pg_catalog.set_config(text, text, boolean)', 'execute') then
            raise exception '% cannot call set_config, and it sets identity or a run on someone''s behalf', r;
        end if;
    end loop;
    raise notice 'rbac/12: set_config is held by the four roles that set identity for others, and by no role a person can become';
end $$;

-- 2. The forgery itself, direct: bob, signed in, tries to become alice.
begin;
set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
do $$
declare v_err text;
begin
    begin
        perform set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
    exception when insufficient_privilege then v_err := sqlerrm;
    end;
    if v_err is null then
        raise exception 'bob rewrote his own claims with set_config';
    end if;
    if rbac.current_user_id() <> '22222222-2222-2222-2222-222222222222'::uuid then
        raise exception 'bob is now %, after a refused set_config', rbac.current_user_id();
    end if;
    raise notice 'rbac/12: a signed-in caller cannot call set_config (%)', v_err;
end $$;
commit;

-- 3. The forgery the way it was measured: through the passthrough, which is
--    granted to authenticated and exposed over PostgREST. Both settings a row
--    rule trusts, the caller and the run.
begin;
set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
do $$
declare v_err text; v_setting text;
begin
    foreach v_setting in array array['request.jwt.claims', 'workflow.current_run_id'] loop
        v_err := null;
        begin
            perform aiq.sql_passthrough(format(
                'select set_config(%L, %L, true) as x', v_setting,
                case v_setting when 'request.jwt.claims'
                     then '{"sub":"11111111-1111-1111-1111-111111111111"}'
                     else gen_random_uuid()::text end));
        exception when insufficient_privilege then v_err := sqlerrm;
        end;
        if v_err is null then
            raise exception 'aiq.sql_passthrough let a signed-in caller write %', v_setting;
        end if;
    end loop;
    if rbac.current_user_id() <> '22222222-2222-2222-2222-222222222222'::uuid then
        raise exception 'bob is now %, after the passthrough', rbac.current_user_id();
    end if;
    raise notice 'rbac/12: the passthrough cannot write the caller or the run';
end $$;
-- And the passthrough still does its job: the read-only switch it makes for
-- itself no longer goes through set_config, which bob does not hold.
do $$
begin
    if (aiq.sql_passthrough('select 1 as one')->0->>'one') is distinct from '1' then
        raise exception 'the passthrough no longer reads for a signed-in caller';
    end if;
    raise notice 'rbac/12: the passthrough still reads for a signed-in caller';
end $$;
commit;

-- 4. The door PostgREST uses still opens: authenticator sets the claims, THEN
--    becomes authenticated -- the order every service now has to use.
begin;
set local role authenticator;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true) is not null as authenticator_sets_claims;
set local role authenticated;
do $$
begin
    if rbac.current_user_id() is distinct from '11111111-1111-1111-1111-111111111111'::uuid then
        raise exception 'claims set by authenticator did not survive the switch to authenticated: %',
            rbac.current_user_id();
    end if;
    raise notice 'rbac/12: authenticator sets the caller, then becomes them -- the PostgREST order still works';
end $$;
commit;

-- 5. The passthrough refuses a SECOND statement, not just a set_config SELECT.
--    §3 proved bob cannot write the claims through a SELECT, because he holds
--    no set_config. But `SET request.jwt.claims` is a STATEMENT, needs no grant,
--    and the passthrough wraps the caller's text as a subquery -- so an author
--    who closes the `(%s) _p8_passthrough` bracket himself smuggled a SET and a
--    second read past it: `select 1) _p8_passthrough limit 1) t; set local
--    request.jwt.claims = '{alice}'; select ... from (select <alice's rows>`
--    read as alice under plain EXECUTE (REM-64, the same break-out the workflow
--    write path took). The passthrough opens its wrapped statement as a cursor
--    now, which refuses the multi-statement string before any of it runs.
begin;
set local role app_owner;
create table t_pt_scoped (owner_id uuid, secret text);
alter table t_pt_scoped enable row level security;
create policy own on t_pt_scoped for select using (owner_id = rbac.current_user_id());
grant select on t_pt_scoped to authenticated;
insert into t_pt_scoped values
    ('11111111-1111-1111-1111-111111111111', 'alice secret'),
    ('22222222-2222-2222-2222-222222222222', 'bob secret');
set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
do $$
declare v_err text; v jsonb;
begin
    -- The control: bob's own honest read sees only bob's row.
    if (aiq.sql_passthrough('select secret from t_pt_scoped')->0->>'secret')
       is distinct from 'bob secret' then
        raise exception 'the passthrough did not read bob''s own row';
    end if;
    begin
        v := aiq.sql_passthrough(
            'select 1) _p8_passthrough limit 1) t; '
            'set local request.jwt.claims = ''{"sub":"11111111-1111-1111-1111-111111111111"}''; '
            'select coalesce(jsonb_agg(t), ''[]''::jsonb) from '
            '(select * from (select secret from t_pt_scoped');
    exception when others then v_err := sqlerrm;
    end;
    if v_err is null then
        raise exception
            'the passthrough ran a break-out and returned %, which is alice''s row read '
            'as alice -- the second statement was not refused', v;
    end if;
    if rbac.current_user_id() <> '22222222-2222-2222-2222-222222222222'::uuid then
        raise exception 'bob is now %, after a refused passthrough break-out', rbac.current_user_id();
    end if;
    raise notice 'rbac/12: the passthrough refuses a smuggled SET and second read (%)', v_err;
end $$;
rollback;
