-- API source ownership, claimed-task boundaries, transactional checkpoints and replay.
\set ON_ERROR_STOP on
begin;
set local role app_owner;
insert into rbac.users(id,email) values
 ('11111111-1111-1111-1111-111111111111','alice-api@test.invalid'),
 ('22222222-2222-2222-2222-222222222222','bob-api@test.invalid') on conflict(id) do nothing;
insert into rbac.user_roles(user_id,role) values
 ('11111111-1111-1111-1111-111111111111','admin'),
 ('22222222-2222-2222-2222-222222222222','admin') on conflict do nothing;
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
select content.save_api_source('faaa0000-0000-4000-8000-000000000004','t_api_source',
 '{"api":{"url":"https://example.test/items","id_path":"id","watermark_type":"number"}}','t-api-source');
select content.start_source_pull('faaa0000-0000-4000-8000-000000000004','t-api-pull');
set local role worker;
set local request.jwt.claims='{}';
do $$ declare t uuid; s jsonb; result jsonb; begin
 select id into t from workflow.claim_task('t-api-source','api-tester');
 s:=content.begin_named_api_pull(t,'api-tester','t_api_source');
 if s->>'source_id'<>'faaa0000-0000-4000-8000-000000000004' then raise exception 'name binding failed';end if;
 begin
  perform content.begin_api_pull(t,'wrong-worker','faaa0000-0000-4000-8000-000000000004');raise exception 'wrong worker accepted';
 exception when insufficient_privilege then null;end;
 result:=content.commit_api_page(t,'api-tester','faaa0000-0000-4000-8000-000000000004',0,
 '[{"external_id":"A","watermark":"10","raw":{"id":"A","v":10},"data":{"v":10}}]','https://example.test/items','https://example.test/items?page=2','10','first');
 -- An entire page, including its first valid record, rolls back on bad data.
 begin
  perform content.commit_api_page(t,'api-tester','faaa0000-0000-4000-8000-000000000004',1,
  '[{"external_id":"B","watermark":"11","raw":{"id":"B"},"data":{}},{"external_id":"","data":{},"raw":{}}]',
  'https://example.test/items?page=2',null,'11','bad');raise exception 'bad page accepted';
 exception when raise_exception then if sqlerrm not like 'Each record needs%' then raise;end if;end;
 begin
  perform content.commit_api_page(t,'api-tester','faaa0000-0000-4000-8000-000000000004',0,'[]','x',null,'10','stale');raise exception 'stale revision accepted';
 exception when serialization_failure then null;end;
 -- Older numeric versions (9 versus 10) cannot overwrite the stored record.
 result:=content.commit_api_page(t,'api-tester','faaa0000-0000-4000-8000-000000000004',1,
 '[{"external_id":"A","watermark":"9","raw":{"id":"A","v":9},"data":{"v":9}}]',
 'https://example.test/items?page=2',null,'10','last');
 if (result->>'unchanged')::int<>1 then raise exception 'older version overwrote data';end if;
 s:=content.begin_api_pull(t,'api-tester','faaa0000-0000-4000-8000-000000000004');
 if s->>'complete'<>'true' or s->'receipt'->>'watermark'<>'10' then raise exception 'completed task replay lost receipt';end if;
 perform workflow.complete_task(t,jsonb_build_object('result',s->'receipt'));
 begin
  perform content.begin_named_api_pull(t,'api-tester','t_api_source');raise exception 'completed lease reused';
 exception when insufficient_privilege then null;end;
end $$;
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
do $$ declare c content.channels; s content.source_state; begin
 select * into s from content.source_state where source_id='faaa0000-0000-4000-8000-000000000004';
 if s.total_records<>1 or s.watermark<>'10' or s.revision<>2 or s.next_url is not null then raise exception 'checkpoint/atomicity failed';end if;
 if (select count(*) from content.source_records where source_id=s.source_id)<>1 then raise exception 'bad page partially persisted';end if;
 -- `is distinct from`: with no row the subquery is NULL, `NULL <> '10'` is
 -- NULL, and `if NULL then` does not fire -- so the assertion that the NEWER
 -- row won would have passed on a table with no rows at all.
 if (select data->>'v' from content.source_records where source_id=s.source_id) is distinct from '10' then raise exception 'older row won';end if;
 select * into c from content.channels where id=s.source_id;
 begin
  perform content.save_api_source(c.id,c.name,jsonb_set(c.config,'{api,url}','"https://other.test"'),'t-api-source',c.updated_at);raise exception 'configuration changed with live progress';
 exception when raise_exception then if sqlerrm not like 'This source has saved progress%' then raise;end if;end;
 -- A stale draft is refused as PT409 (HTTP 409), never 40001: PostgREST retries
 -- serialization_failure forever, so 40001 here hung every client that sent one.
 begin
  perform content.save_api_source(c.id,c.name,c.config,'t-api-source',null);raise exception 'stale draft accepted';
 exception when sqlstate 'PT409' then null;end;
 perform content.reset_source_progress(c.id);
 if (select count(*) from content.source_records where source_id=c.id)<>1 then raise exception 'reset deleted data';end if;
end $$;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
do $$ begin
 if exists(select 1 from content.source_state where source_id='faaa0000-0000-4000-8000-000000000004') or exists(select 1 from content.source_records where source_id='faaa0000-0000-4000-8000-000000000004') then raise exception 'Bob sees private progress/data';end if;
 begin
  perform content.start_source_pull('faaa0000-0000-4000-8000-000000000004');raise exception 'Bob started Alice feed';
 exception when insufficient_privilege then null;end;
 begin
  perform content.reset_source_progress('faaa0000-0000-4000-8000-000000000004');raise exception 'Bob reset Alice feed';
 exception when insufficient_privilege then null;end;
 if has_function_privilege('authenticated','content.commit_api_page(uuid,text,uuid,bigint,jsonb,text,text,text,text)','execute') or has_function_privilege('authenticated','content.begin_named_api_pull(uuid,text,text)','execute') or has_table_privilege('authenticated','content.source_records','insert') then raise exception 'client has worker rights';end if;
end $$;
-- A user who directly starts a known workflow still cannot pull another owner's source.
set local role app_owner;
select workflow.start_workflow('source_faaa0000000040008000000000000004','{"owner_id":"11111111-1111-1111-1111-111111111111"}');
set local role worker;
set local request.jwt.claims='{}';
do $$ declare t uuid; begin
 select id into t from workflow.claim_task('t-api-source','api-tester');
 begin
  perform content.begin_named_api_pull(t,'api-tester','t_api_source');raise exception 'Bob named Alice source';
 exception when insufficient_privilege then null;end;
 begin
  perform content.begin_api_pull(t,'api-tester','faaa0000-0000-4000-8000-000000000004');raise exception 'Bob spoofed source owner';
 exception when insufficient_privilege then null;end;
 raise notice 'content/04: owned API feeds, atomic pages, claim/revision fences, old-version protection, task replay, reset and private data passed';
end $$;

-- ---------------------------------------------------------------------
-- PULLING YOUR OWN SOURCE NEVER HANDS YOU SOMEBODY ELSE'S RUN (REM-80).
--
-- start_source_pull is idempotent by design: pulling a source already being
-- pulled returns the pull in flight rather than starting a second one. It
-- resolved "already being pulled" as ANY running run of the workflow this
-- source names, across every tenant -- and workflow definitions are
-- installation-wide by design, so `ingest_file` is everybody's. The owner check
-- the function already had is about the CHANNEL and says nothing about the RUN.
-- Measured before the fix: bo pulls his own source and is handed ana's running
-- ingest_file run, with her input, without using his own p_external_id at all.
--
-- WHY NOT THE USERS ABOVE. alice-api and bob-api are both `admin`, and `admin`
-- is the one role holding `workflow_runs:select` (measured). The fix scopes the
-- lookup to runs the caller MAY SEE, and an administrator may see every
-- tenant's -- so writing this with those two would assert nothing and pass
-- whether or not the fix is present. Two ordinary members are the callers who
-- can exhibit the defect, so they are the callers it is measured with.
--
-- BOTH SOURCES NAME THE SAME SHARED WORKFLOW, which is the reachable state the
-- defect needs: content.save_api_source mints a per-source definition
-- (`source_<uuid>`), but a channel built any other way can name a shared one,
-- and that is an ordinary insert.
-- ---------------------------------------------------------------------
set local role app_owner;
reset request.jwt.claims;
insert into rbac.users(id,email) values
 ('aaaa0000-0000-4000-8000-00000000000a','ana-pull@test.invalid'),
 ('bbbb0000-0000-4000-8000-00000000000b','bo-pull@test.invalid') on conflict(id) do nothing;
-- `member`, NOT `admin`: see the note above. Asserted rather than assumed,
-- because the whole block is vacuous if either of them can see every run.
do $$
begin
 insert into rbac.user_roles(user_id,role) values
  ('aaaa0000-0000-4000-8000-00000000000a','member'),
  ('bbbb0000-0000-4000-8000-00000000000b','member') on conflict do nothing;
 if rbac.has_permission('bbbb0000-0000-4000-8000-00000000000b','workflow_runs','select') is distinct from false then
  raise exception 'the second puller can see every tenant''s runs, so this block cannot measure the leak';
 end if;
end $$;
insert into content.channels(id,name,kind,config,owner_id,visibility,org_id,enabled) values
 ('aaaa0000-0000-4000-8000-0000000000a1','t-pull-ana','http_pull',
  '{"ingest_workflow":"ingest_file"}'::jsonb,'aaaa0000-0000-4000-8000-00000000000a','private',rbac.shared_org_id(),true),
 ('bbbb0000-0000-4000-8000-0000000000b1','t-pull-bo','http_pull',
  '{"ingest_workflow":"ingest_file"}'::jsonb,'bbbb0000-0000-4000-8000-00000000000b','private',rbac.shared_org_id(),true);

do $$
declare v_ana uuid; v_bo uuid; v_ana_owner uuid; v_bo_owner uuid;
begin
 -- ana pulls her source and gets a run of her own
 set local role authenticated;
 execute format('set local request.jwt.claims = %L', '{"sub":"aaaa0000-0000-4000-8000-00000000000a"}');
 v_ana := content.start_source_pull('aaaa0000-0000-4000-8000-0000000000a1','ana-key-1');
 if v_ana is null then raise exception 'ana got no run for her own source'; end if;

 -- and it is RUNNING, so it is a candidate the old lookup would have matched.
 -- Without this the block could pass because there was nothing to leak.
 -- Read as app_owner: `authenticated` holds no grant on workflow.runs (it goes
 -- through runs_api), which is the point of the table and not a problem here.
 reset role;
 if (select status from workflow.runs where id=v_ana) is distinct from 'running' then
  raise exception 'ana''s run is not running, so bo''s lookup has no row to find and this block measures nothing';
 end if;

 -- bo pulls HIS OWN source, which names the same shared workflow
 set local role authenticated;
 execute format('set local request.jwt.claims = %L', '{"sub":"bbbb0000-0000-4000-8000-00000000000b"}');
 v_bo := content.start_source_pull('bbbb0000-0000-4000-8000-0000000000b1','bo-key-1');
 if v_bo is null then raise exception 'bo got no run for his own source'; end if;

 if v_bo = v_ana then
  raise exception
   'bo pulled his own source and was handed ana''s run (%) -- start_source_pull '
   'is resolving a run by workflow name across every tenant', v_ana;
 end if;

 reset role;
 select owner_id into v_ana_owner from workflow.runs where id=v_ana;
 select owner_id into v_bo_owner  from workflow.runs where id=v_bo;
 if v_ana_owner is distinct from 'aaaa0000-0000-4000-8000-00000000000a'::uuid then
  raise exception 'ana''s run is owned by % rather than ana', v_ana_owner;
 end if;
 if v_bo_owner is distinct from 'bbbb0000-0000-4000-8000-00000000000b'::uuid then
  raise exception 'bo''s run is owned by % rather than bo', v_bo_owner;
 end if;

 raise notice 'content/04: two owners pulling their own sources through one shared workflow each get their own run';
end $$;

-- AND THE IDEMPOTENCE IT EXISTS FOR STILL WORKS -- a scope that refused
-- everything would pass the block above and be an outage. Ana pulls again and
-- must get HER run back rather than a second one.
do $$
declare v_first uuid; v_again uuid; v_n int;
begin
 set local role authenticated;
 execute format('set local request.jwt.claims = %L', '{"sub":"aaaa0000-0000-4000-8000-00000000000a"}');
 reset role;
 select x.id into v_first from workflow.runs x join workflow.definitions d on d.id=x.workflow_def_id
  where d.name='ingest_file' and x.status='running' and x.owner_id='aaaa0000-0000-4000-8000-00000000000a'
  order by x.created_at desc limit 1;
 set local role authenticated;
 v_again := content.start_source_pull('aaaa0000-0000-4000-8000-0000000000a1','ana-key-2');
 if v_again is distinct from v_first then
  raise exception
   'pulling a source whose pull is already in flight started a second run '
   '(% then %) -- the overlap check no longer finds the caller''s own run',
   v_first, v_again;
 end if;
 reset role;
 select count(*) into v_n from workflow.runs x join workflow.definitions d on d.id=x.workflow_def_id
  where d.name='ingest_file' and x.owner_id='aaaa0000-0000-4000-8000-00000000000a';
 if v_n <> 1 then raise exception 'ana has % ingest_file runs, expected exactly 1', v_n; end if;
 raise notice 'content/04: a second pull of a source already in flight still returns the caller''s own run, not a new one';
end $$;
rollback;
