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
--   content.register_fetched  let a signed-in caller without resources:create
--                        add content the upload path refuses -- REM-76,
--                        content/09, sources.md §21
--   content.start_source_pull  resolved "is one already running?" by workflow
--                          NAME across every tenant, so pulling your own source
--                          handed you somebody else's run -- content/04, REM-80
--
-- NOTHING IS LEFT DECLARED WITH A GAP. This list used to end "and, left
-- declared with the gap in the sentence: ...", naming the rows that stated a
-- hole rather than a check. Both of those closed within a day of each other
-- (REM-76, REM-77), which is the argument for declaring a gap in the catalogue
-- rather than in a comment somebody has to find: a row that says "GAP" is a
-- task, and it was picked up. Say so here when the next one opens.
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
('content.capture_snapshot(uuid)', 'rbac.may_read',
 'the resource''s own read rule on the locked row, after rbac.require(research, insert); the file and hash come from that row, never from the caller (REM-153)'),
('content.chunks_to_embed(uuid)', 'rbac.may_read',
 'the resource''s own read rule; the claimless arm is the worker''s embed fan-out, and no request over PostgREST is claimless'),
('content.may_upload(uuid)', 'rbac.has_permission',
 'a predicate about the caller: may act in the org, and holds resources:create'),
('content.record_chunks(uuid,jsonb)', 'rbac.may_write',
 'the resource''s own write rule, read off the resource rather than taken as an argument'),
('content.register_evidence(text,text,text,text,bigint,text,text)', 'rbac.require',
 'rbac.require(research, insert), then the caller''s evidence_bytes budget through rbac.reserve_usage; writes only a private resource the caller owns, on the shipped research_evidence channel, with no ingestion. No resources:create by design: the interim policy of REM-242 lets anybody who may write research keep a public page, limited by bytes (REM-239, reviewed in REM-245)'),
('content.register_research_image(text,text,text,bigint,text,text)', 'rbac.require',
 'rbac.require(research, insert), then the caller''s evidence_bytes budget, as register_evidence; refuses any type but PNG, JPEG and WebP and anything over 2 MB, and writes only a private resource the caller owns on the research_evidence channel (REM-309)'),
('content.register_fetched(text,text,text,text,uuid,jsonb)', 'content.may_upload',
 'rbac.is_operator() or content.may_upload(org): a caller that carries claims is refused without resources:create in an org it may act in, the same predicate register_upload asks through the same one home. The GAP this row used to declare is closed (REM-76). The leading operator arm is not a loophole but the only caller: register_fetched is reached by a REGISTERED STEP FUNCTION (selfmodel.ingest_prose via workflow.call_step_function), which sets no claims and runs on the worker login -- and may_upload''s own operator arm needs INSERT on content.resources from session_user, which worker does not hold, so bare may_upload refuses it (measured: session_user=worker, is_operator=t, login_can_insert=f, may_upload=f). A signed-in caller cannot reach that arm: set_config is not PUBLIC''s since user-rbac/roles.sql §6. sources.md §21 states the rule and records what is still owed -- call_step_function does not set the run owner''s claims, so a scheduled fetch is an operator rather than its source owner; dev/tests/content/09 measures both arms'),
('content.register_upload(text,text,text,text,bigint,text,text,text,uuid,jsonb,text,text,text)', 'content.may_upload',
 'refused without resources:create in an org the caller may act in'),
('content.reset_source_progress(uuid)', 'owner',
 'only the source''s author, who must also hold workflows:update'),
('content.resolve_file(uuid)', 'rbac.may_read',
 'the resource''s own read rule (75abb1d)'),
('content.resolve_snapshot(uuid)', 'rbac.may_read',
 'the pinned resource''s own read rule, as resolve_file; nothing once the bytes are removed (REM-153)'),
('content.save_api_source(uuid,text,jsonb,text,timestamp with time zone)', 'workflow.may_define',
 'refused without workflows:update, and an existing source only by its owner'),
('content.save_source(uuid,text,jsonb,jsonb,timestamp with time zone)', 'workflow.may_define',
 'refused without workflows:update, and an existing source only by its owner'),
('content.start_source_pull(uuid,text)', 'workflow.may_access_run',
 'TWO objects, and this row used to name only the first. `owner` -- only the source''s owner may start a pull -- is true of the CHANNEL and was never the whole sentence: the function then resolved "is one already running?" by workflow NAME across every tenant and returned that run''s id, so owning your own source got you somebody else''s run (REM-80, measured: bo pulls his own source and receives ana''s running ingest_file run with her input). Definitions are installation-wide by design, so a shared name like `ingest_file` is everybody''s. The lookup now filters on workflow.may_access_run -- REM-77''s extracted predicate, in workflow.reusable_run''s shape -- and prefers the caller''s own run, so an administrator holding workflow_runs:select still gets their own in-flight pull back. Residual, recorded and not a leak: two sources of the SAME owner naming one shared ingest_workflow still share a run. dev/tests/content/04 measures both people'),
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
('rbac.decide(text,text)', 'owner',
 'the caller''s own application and organisation grants, after active person, human-only and credential scope checks'),
('rbac.decide_in_org(text,text,uuid)', 'rbac.decision',
 'the decision''s person, credential and scope refusals stand, counting a delegation only in that org; then only the caller''s own active grant held in that one org counts, for a member of it (REM-255)'),
('rbac.delegate(uuid,text,text,uuid)', 'rbac.decide_in_org',
 'a person only, a delegable kind, their own live credential, and only where their own decision in that org allows'),
('rbac.revoke_delegation(uuid,text)', 'owner',
 'a person only, and only a delegation they gave'),
('rbac.may_in_org(text,text,uuid)', 'rbac.decide_in_org',
 'the one-org decision as a boolean, asking nothing of its own'),
('rbac.may(text,text)', 'rbac.decide',
 'the decision as a boolean, for the caller only'),
('rbac.require(text,text)', 'rbac.decide',
 'raises unless the caller''s own decision allows'),
('rbac.grant_with_basis(uuid,text,text,text,text,uuid)', 'rbac.require',
 'users:admin or an installation step, and never an agent'),
('rbac.revoke_grant(uuid,text)', 'rbac.require',
 'users:admin or an installation step'),
('rbac.plan_of(uuid)', 'none',
 'returns a plan name only, which carries no row, count or limit; limits go through limit_state, which asks'),
('rbac.limit_state(uuid,text)', 'owner',
 'the caller''s own limits; anybody else''s read as unknown'),
('rbac.has_quota_remaining(uuid,text)', 'rbac.limit_state',
 'answers only for the caller, through limit_state''s owner check'),
('rbac.reserve_usage(text,bigint,text,interval)', 'owner',
 'charges the caller''s own budget and no other'),
('rbac.consume_usage(text,text,bigint)', 'owner',
 'settles the caller''s own reservation'),
('rbac.release_usage(text,text)', 'owner',
 'returns the caller''s own reservation'),
('rbac.access_snapshot(text)', 'owner',
 'describes the caller only'),
('research.readable(uuid)', 'rbac.may_read',
 'the scope rule over the work''s owner, org and visibility'),
('research.work_readable_in_full(uuid)', 'rbac.may_read',
 'the owner, or the org for org-scoped work; public visibility adds nothing, because it exposes exact revisions only'),
('research.revision_readable(uuid)', 'research.readable',
 'in full, or a readable work whose exact revision was exposed'),
('research.visible_head(uuid)', 'research.work_readable_in_full',
 'the head only with full access; otherwise the latest exposed revision of a readable work, or null'),
('research.receipt(uuid,boolean)', 'research.revision_readable',
 'ids and hash only for a revision the caller may read'),
('research.resolve_image(uuid)', 'research.revision_readable',
 'returns bytes'' location only when some revision the caller may read pins the snapshot as an image; one answer for not yours and not there (REM-309)'),
('research.get_package(text,text)', 'research.revision_readable',
 'the visible head or a named revision the caller may read; anything else is null'),
('research.list_packages(boolean)', 'research.visible_head',
 'each work at the revision the caller is shown; works with none are left out'),
('research.list_listed(timestamp with time zone,integer)', 'research.readable',
 'a page of exposed works, newest first, each kept only if the caller may read the work (REM-500)'),
('research.search_claims(text,integer,integer)', 'research.revision_readable',
 'each candidate the text index returns is kept only if the caller may read its revision (REM-500)'),
('claims.question_readable(uuid)', 'research.revision_readable',
 'the questions policy: true only when a revision the caller may read answers the question or one refining it (REM-476)'),
('claims.assert_relation(text,text,text,uuid,uuid,text,jsonb,text)', 'rbac.require',
 'research:insert, from a revision of the caller''s own work; a second revision must be readable to them (REM-474)'),
('claims.restate_relation(bigint,text,boolean,text)', 'rbac.require',
 'research:insert, and only a relation asserted from the caller''s own work; anybody else''s is not found (REM-474)'),
('research.submit_package(jsonb,text,text)', 'rbac.require',
 'research:insert, and research:list to list'),
('research.revise_package(text,jsonb,text,text)', 'rbac.require',
 'research:insert, and only the owner''s work; anybody else''s is not found'),
('research.revise_working(text,jsonb,text,text)', 'rbac.require',
 'research:insert, and only the owner''s work; it exposes nothing, so it needs no listing authority'),
('research.expose_for_publication(text,text,text,uuid)', 'rbac.decide_in_org',
 'research:publish granted in the publication''s own org, human-only, and only the owner''s work; anybody else''s is not found'),
('research.withdraw_publication_exposure(text,text,text)', 'rbac.require',
 'only the owner; a person needs no publish grant, so losing one never traps work, and an agent needs research:publish in the exposure''s org (REM-532)'),
('research.endorse(uuid,text,text,text[])', 'rbac.require',
 'research:endorse is human-only, on a revision the caller may read; the checked claims are keyed to that revision'),
('research.endorsements_affected_by(uuid)', 'research.revision_readable',
 'both the correction and the revision it corrects must be readable by the caller (REM-154)'),
('research.withdraw_endorsement(uuid,text)', 'rbac.require',
 'only the endorser withdraws their endorsement'),
('research.trust(uuid)', 'research.revision_readable',
 'null for a revision the caller may not read'),
('research.trust_state(text,timestamp with time zone)', 'research.revision_readable',
 'null unless the caller may read some revision of the work now; every part is limited to revisions they may read now, the head to full access'),
('research.move_publication_exposure(text,text,text,text,uuid)', 'research.expose_for_publication',
 'through expose_for_publication: research:publish in the publication''s own org, only the owner''s work, and only a revision of that work retired'),
('engagement.set_saved(uuid,boolean)', 'rbac.require',
 'engagement:insert is human-only, on research the caller may read'),
('engagement.my_saves()', 'rbac.require',
 'engagement:select; only the caller''s own saves, a work''s public id, and research.readable for whether they may read it now'),
('engagement.set_following(uuid,boolean)', 'rbac.require',
 'engagement:insert is human-only; the row is the caller''s'),
('engagement.set_useful(uuid,boolean)', 'rbac.require',
 'engagement:insert, a readable revision, and never the caller''s own research'),
('engagement.set_valuation(uuid,bigint,text)', 'rbac.require',
 'engagement:insert on a readable revision; the valuation is private to the caller'),
('engagement.add_comment(uuid,text,text)', 'rbac.require',
 'engagement:insert on a revision the caller may read'),
('engagement.discuss(text,uuid,uuid,uuid,text,text)', 'rbac.require',
 'engagement:discuss, human-only, on a revision or resource the caller may read; a reply inherits its parent''s target'),
('engagement.target_readable(uuid,uuid)', 'rbac.may_read',
 'answers only whether the caller may read the revision (research.revision_readable) or the resource (rbac.may_read)'),
('engagement.edit_comment(uuid,text,integer)', 'rbac.require',
 'engagement:insert, and only the author''s own comment'),
('engagement.withdraw_comment(uuid,text)', 'rbac.require',
 'engagement:insert, and only the author''s own comment'),
('engagement.moderate_comment(uuid,text)', 'rbac.require',
 'engagement:moderate, a separately granted human-only capability'),
('engagement.set_like(uuid,boolean)', 'rbac.require',
 'engagement:insert on a readable comment, never the caller''s own'),
('engagement.revision_signals(uuid)', 'research.revision_readable',
 'counts only for a revision the caller may read'),
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
('workflow.plan_status(text,uuid)', 'workflow.may_access_run',
 'the run''s owner or workflow_runs:select, with rbac.is_operator() as the leading arm. It FILTERS rather than raises, which is why it names may_access_run and not assert_run_access: the run-less form has to resolve "the newest run of this workflow I may see", and a raise is the wrong shape for a lookup that may legitimately find nothing. A run id handed in goes through the same predicate, so naming somebody else''s run returns no rows instead of their steps. Definer at all only because the INVOKER body was unusable: authenticated holds no SELECT on workflow.runs or workflow.tasks, so every call it was granted to raised `permission denied for table tasks` (REM-81). The operator arm is reusable_run''s, and exists because the views that would otherwise serve this are empty for a session with no JWT'),
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
