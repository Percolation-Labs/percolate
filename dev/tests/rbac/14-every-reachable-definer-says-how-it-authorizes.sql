-- EVERY SECURITY DEFINER FUNCTION A PERSON CAN REACH SAYS HOW IT AUTHORIZES.
--
-- A definer function runs as its owner, and app_owner owns every table, so RLS
-- never sees the call: each one has to ask its own question about the caller.
-- Fourteen single-function authorization fixes landed in eleven days, each
-- correct for its own function, each leaving a sibling that asked the org, or
-- the claims, or nothing (meta/postmortems/2026-09-11-fixed-at-the-copy-that-
-- failed.md §3, REM-46). rbac/04 holds who may EXECUTE. Nothing held what each
-- function then ASKS, so every new definer was reviewed or it was not.
--
-- DECLARED, NOT INFERRED. The obvious gate reads each body and guesses whether
-- a check is in it. That is a regex over prose-shaped code, and the rule here
-- is to make it exact or drop it. So the fact is stated once per function,
-- below, as the predicate it calls and a sentence, and the catalog is held to
-- the list in both directions:
--
--   (a) every SECURITY DEFINER function in percolate.extension_schemas() that
--       authenticated, web_anon or api_viewer can execute is declared here --
--       the direction that catches the function added next month;
--   (b) every function declared here still exists and is still reachable --
--       the direction that stops the list naming ghosts;
--   (c) the body calls what the row says it calls. Containment of a declared
--       name, comments stripped: it proves the call is there, not that it is
--       right. Whether it is right is the sentence, and a reviewer reads that.
--
-- THE MECHANISMS.
--
--   <schema>.<function>  the predicate or authorizing callee it calls
--   owner                acts only on rows owned by the caller; calls rbac.current_user_id
--   credential           the caller proves possession of a secret the function
--                        hashes and looks up (a refresh token, an API key); calls digest
--   none                 asks nothing, and `why` says why nothing needs asking
--
-- WHAT DECLARING THEM FOUND, each fixed where the fix was contained and each
-- asserted where it lives:
--   agentic.persist_turn   wrote into any session by id -- agentic/02 §3
--   aiq.schema_graph       sampled keys of private nodes by org -- rbac/13 §6
--   agentic.attach_skill,  said "no agent named %" to anybody before asking --
--   agentic.detach_skill   agentic/02 §6
--   workflow.start_workflow  handed back a run started by whoever else had
--                          used that external_id -- workflow/17, REM-77
-- and, left declared with the gap in the sentence: content.register_fetched
-- (see its row).
--
-- A PACKAGE'S SCHEMA IS OUT OF SCOPE HERE, and that is a decision rather than
-- the list stopping where it was convenient. This file declares what THIS tree
-- ships; a package's functions live in another repository and could never be
-- declared here, so a gate demanding it would be one nobody could satisfy.
-- They are held where they are applied: percolate.check_package_schema()
-- refuses a package schema with a SECURITY DEFINER function PUBLIC can execute
-- (REM-47), and rbac/04 §1 walks by OWNER rather than by schema, so it covers
-- every schema app_owner creates, package schemas included.

\set ON_ERROR_STOP on

begin;

create temp table t14_declared (fn text primary key, mechanism text not null, why text not null);
grant select on t14_declared to public;

insert into t14_declared (fn, mechanism, why) values
-- ---------- agentic --------------------------------------------------------
('agentic.apply_plugin(jsonb)', 'agentic.may_author',
 'installs a plugin''s servers, skills and agents; refused without plugins:update'),
('agentic.apply_summary(jsonb)', 'agentic.upsert_summary',
 'writes only through upsert_summary, which refuses a session that is not the caller''s'),
('agentic.attach_skill(text,text,jsonb)', 'agentic.may_author',
 'refused without agents:update before the agent is looked up, so a non-author learns nothing about which agents exist'),
('agentic.create_session(text)', 'owner',
 'creates a session owned by the caller; it takes no id, so there is nothing of anybody else''s to name'),
('agentic.detach_skill(text,text)', 'agentic.may_author',
 'as attach_skill'),
('agentic.finish_run(uuid,text,jsonb)', 'owner',
 'refuses a run whose owner is not the caller'),
('agentic.may_invoke(text)', 'rbac.may_read',
 'answers only about an agent the caller may read, and only yes with agents:invoke'),
('agentic.persist_turn(jsonb)', 'owner',
 'refuses a row naming a run or a session the caller does not own'),
('agentic.start_run(text,uuid,uuid,uuid,text,text,text,uuid)', 'agentic.may_invoke',
 'refuses an agent the caller may not invoke, and a session or parent run that is not theirs'),
('agentic.upsert_agent(jsonb)', 'agentic.may_author',
 'refused without agents:update. An author may edit any agent by name: the permission is deployment-wide by design'),
('agentic.upsert_skill(jsonb)', 'agentic.may_author',
 'refused without skills:update'),
('agentic.upsert_summary(uuid,text)', 'owner',
 'refuses a session that is not the caller''s'),
('agentic.upsert_tool_server(jsonb)', 'agentic.may_author',
 'refused without tool_servers:update'),
-- ---------- aiq --------------------------------------------------------------
('aiq.schema_drift()', 'none',
 'returns each facet name and md5 hashes of how it renders now and when last recorded: whether the shipped documents changed, and no row of anybody''s'),
('aiq.schema_graph(text)', 'rbac.may_read',
 'the catalogue is installation-wide; the sample keys are only of nodes the caller may read'),
('aiq.schema_p8ql(text)', 'none',
 'the installed parser''s grammar and the installation-wide source and model registries, none of which has a tenant column'),
('aiq.schema_workflow(text)', 'rbac.may_read',
 'lists only agents the caller may read; definitions, queues and step functions are installation-wide, with no tenant column'),
('aiq.set_scan_order(text)', 'none',
 'sets one planner setting for the caller''s own transaction, from three allowed values; reads and writes no rows'),
-- ---------- content ----------------------------------------------------------
('content.assert_org_write(uuid,text)', 'rbac.may_access_org',
 'is itself the org check other definers call: raises unless the caller may act inside that org'),
('content.chunks_to_embed(uuid)', 'rbac.may_read',
 'the resource''s own read rule; the claimless arm is the worker''s embed fan-out, and no request over PostgREST is claimless'),
('content.may_upload(uuid)', 'rbac.has_permission',
 'a predicate about the caller: may act in the org, and holds resources:create'),
('content.record_chunks(uuid,jsonb)', 'rbac.may_write',
 'the resource''s own write rule, read off the resource rather than taken as an argument'),
('content.register_fetched(text,text,text,text,uuid,jsonb)', 'content.assert_org_write',
 'asks only whether the caller may act in the org, and reads the channel through may_read. GAP: it does not ask resources:create, which register_upload does through may_upload. Not changed here: world-model-ingestion/brief.md names a scheduled pull workflow as its caller, which may carry no person, and may_upload''s operator arm also requires the login to hold INSERT on content.resources, which the worker and scheduler logins do not'),
('content.register_upload(text,text,text,text,bigint,text,text,text,uuid,jsonb,text,text,text)', 'content.may_upload',
 'refused without resources:create in an org the caller may act in'),
('content.reset_source_progress(uuid)', 'owner',
 'only the source''s author, who must also hold workflows:update'),
('content.resolve_file(uuid)', 'rbac.may_read',
 'the resource''s own read rule (75abb1d)'),
('content.save_api_source(uuid,text,jsonb,text,timestamp with time zone)', 'workflow.may_define',
 'refused without workflows:update, and an existing source only by its owner'),
('content.save_source(uuid,text,jsonb,jsonb,timestamp with time zone)', 'workflow.may_define',
 'refused without workflows:update, and an existing source only by its owner'),
('content.start_source_pull(uuid,text)', 'owner',
 'only the source''s owner'),
('content.windows_to_index(uuid)', 'rbac.may_read',
 'as chunks_to_embed'),
-- ---------- rbac -------------------------------------------------------------
('rbac.add_org_member(uuid,uuid,text)', 'rbac.has_permission',
 'orgs:admin, or an admin membership of that org'),
('rbac.change_password(text,text)', 'owner',
 'the caller''s own account, and only with its current password'),
('rbac.create_org(text,text)', 'rbac.has_permission',
 'orgs:admin, and the creator becomes the new org''s admin member'),
('rbac.create_user_with_password(text,text)', 'none',
 'signup: anonymous by necessity, and what it creates is a pending account nobody else can reach'),
('rbac.current_org_ids()', 'owner',
 'the caller''s own memberships; it takes no argument that could name anyone else'),
('rbac.grant_role(uuid,text)', 'rbac.has_permission',
 'users:admin'),
('rbac.has_permission(uuid,text,text)', 'none',
 'every policy calls it, so every role must be able to. It answers yes or no about any user id, which tells a caller whether somebody holds a permission and nothing more'),
('rbac.login(text,text,text,text)', 'rbac.attempt_login',
 'a password, throttled and audited by attempt_login'),
('rbac.refresh_session(text,text)', 'credential',
 'the refresh token, looked up by its hash'),
('rbac.remove_org_member(uuid,uuid)', 'rbac.has_permission',
 'orgs:admin, or an admin membership of that org'),
('rbac.reset_password(text,text)', 'credential',
 'the reset token, looked up by its hash'),
('rbac.revoke_all_sessions()', 'owner',
 'the caller''s own sessions'),
('rbac.revoke_session(uuid)', 'owner',
 'one of the caller''s own sessions; another''s id matches no row'),
('rbac.verify_api_key(text)', 'credential',
 'the API key, looked up by its hash'),
-- ---------- workflow ---------------------------------------------------------
('workflow.cancel_run(uuid)', 'workflow.assert_run_access',
 'the run''s owner, or runs:cancel'),
('workflow.define_yaml(text)', 'workflow.may_define',
 'workflows:update, because a step may carry SQL'),
('workflow.execute_as_viewer(text,boolean,jsonb)', 'none',
 'owned by api_viewer, not app_owner, so it runs WITH row-level security rather than past it -- that is its purpose. api_viewer reaches it as its owner; only app_owner is granted it and nobody but app_owner is a member of api_viewer'),
('workflow.matrix_outputs(uuid)', 'workflow.assert_run_access',
 'the run''s owner or runs:select, unless the caller is that run''s own step'),
('workflow.matrix_rows(uuid)', 'workflow.assert_run_access',
 'the run''s owner or runs:select'),
('workflow.queue_depth(text)', 'none',
 'one count of ready and running tasks on a named queue, across tenants: queues are installation-wide and a worker pool scales on the true depth (queues_api)'),
('workflow.schedule_workflow(text,text,text,jsonb,text,text)', 'workflow.assert_schedule_access',
 'schedules:create, and an existing schedule only by its owner'),
('workflow.set_schedule_enabled(text,boolean)', 'workflow.assert_schedule_access',
 'the schedule''s owner, or schedules:update'),
('workflow.signal_task(uuid,text,jsonb)', 'workflow.assert_run_access',
 'the run''s owner, or runs:signal'),
('workflow.start_workflow(text,jsonb,text,text)', 'workflow.reusable_run',
 'definitions are installation-wide (no tenant column, no policy, no permission to start one); the run is owned by the caller (trg_set_run_owner) and each step runs as that owner through execute_as_viewer. The idempotency match now asks whose run the external_id found: reusable_run matches only among the runs the caller may see -- their own, or one their permissions reach, which is assert_run_access''s rule through the may_access_run they share -- while an operator with no identity (tick() firing a schedule) matches every run under the key, authorized by the grant. The key is unique per OWNER, so a second person''s start is a new run rather than a unique violation (REM-77)'),
('workflow.unschedule_workflow(text)', 'workflow.assert_schedule_access',
 'the schedule''s owner, or schedules:delete');

-- What is reachable, computed once and read by every section below.
create temp view t14_reachable as
select p.oid, p.oid::regprocedure::text as fn,
       regexp_replace(p.prosrc, '--[^\n]*', '', 'g') as body
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname in (select percolate.extension_schemas())
   and p.prosecdef
   and (has_function_privilege('authenticated', p.oid, 'execute')
        or has_function_privilege('web_anon', p.oid, 'execute')
        or has_function_privilege('api_viewer', p.oid, 'execute'));

-- ---------------------------------------------------------------------
-- 0. THE SUBJECT EXISTS. An empty reachable set would pass (a), and an empty
--    declaration list would pass (b) and (c).
-- ---------------------------------------------------------------------
do $$
begin
    if (select count(*) from t14_reachable) < 20 then
        raise exception 'only % reachable SECURITY DEFINER functions -- this database is not the '
                        'one the list describes, and every check below would pass on nothing',
                        (select count(*) from t14_reachable);
    end if;
    if (select count(*) from t14_declared) < 20 then
        raise exception 'the declaration list is nearly empty';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- (a) EVERY REACHABLE DEFINER IS DECLARED.
-- ---------------------------------------------------------------------
do $$
declare v_bad text;
begin
    select string_agg(r.fn, E'\n       ' order by r.fn) into v_bad
      from t14_reachable r
     where not exists (select 1 from t14_declared d where d.fn = r.fn);
    if v_bad is not null then
        raise exception E'these SECURITY DEFINER functions are reachable by a person and do not say how they authorize:\n       %\n\n'
            'Each runs as its owner, past row-level security. Add a row to '
            'dev/tests/rbac/14 naming the predicate it calls (rbac.may_read, '
            'rbac.has_permission, workflow.assert_run_access, ...), or owner, '
            'credential, or none with the reason none is needed -- or revoke the '
            'grant that makes it reachable.', v_bad;
    end if;
    raise notice 'rbac/14: all % reachable SECURITY DEFINER functions are declared',
        (select count(*) from t14_reachable);
end $$;

-- ---------------------------------------------------------------------
-- (b) EVERY DECLARED FUNCTION STILL EXISTS AND IS STILL REACHABLE.
-- ---------------------------------------------------------------------
do $$
declare v_bad text;
begin
    select string_agg(d.fn, ', ' order by d.fn) into v_bad
      from t14_declared d
     where not exists (select 1 from t14_reachable r where r.fn = d.fn);
    if v_bad is not null then
        raise exception 'declared in rbac/14 and not a reachable SECURITY DEFINER function: %. '
            'A signature changed, the function went, or it stopped being reachable -- '
            'update or delete the row, so the list does not describe a database '
            'that no longer exists.', v_bad;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- (c) EACH BODY CALLS WHAT ITS ROW SAYS, AND EVERY ROW SAYS WHY.
-- ---------------------------------------------------------------------
do $$
declare v_bad text;
begin
    select string_agg(format('%s declares %s', d.fn, d.mechanism), E'\n       ' order by d.fn)
      into v_bad
      from t14_declared d
      join t14_reachable r on r.fn = d.fn
     where d.mechanism <> 'none'
       and r.body !~ ('\m' || replace(case d.mechanism
                                          when 'owner'      then 'rbac.current_user_id'
                                          when 'credential' then 'digest'
                                          else d.mechanism end, '.', '\.')
                      || '\s*\(');
    if v_bad is not null then
        raise exception E'these functions do not call what rbac/14 says they authorize with:\n       %\n\n'
            'owner means a call to rbac.current_user_id, credential a call to digest, '
            'and anything else a call to that function by name.', v_bad;
    end if;

    select string_agg(d.fn, ', ' order by d.fn) into v_bad
      from t14_declared d
     where d.mechanism !~ '^(none|owner|credential|[a-z_]+\.[a-z_]+)$'
        or length(btrim(d.why)) < 10;
    if v_bad is not null then
        raise exception 'rows in rbac/14 with no mechanism it understands, or no reason: %', v_bad;
    end if;
    raise notice 'rbac/14: every declared mechanism is called by its function, and every row says why';
end $$;

rollback;
