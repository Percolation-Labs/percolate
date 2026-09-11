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
rollback;
