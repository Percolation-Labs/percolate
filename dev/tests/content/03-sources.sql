-- Save atomically, reject stale edits and keep private source use private.
\set ON_ERROR_STOP on
begin;
set local role app_owner;
insert into rbac.users(id,email) values
 ('11111111-1111-1111-1111-111111111111','alice-source@test.invalid'),
 ('22222222-2222-2222-2222-222222222222','bob-source@test.invalid') on conflict(id) do nothing;
insert into rbac.user_roles(user_id,role) values
 ('11111111-1111-1111-1111-111111111111','admin'),
 ('22222222-2222-2222-2222-222222222222','admin') on conflict do nothing;
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
select content.save_source('faaa0000-0000-4000-8000-000000000001','t_private_source',
 '{"description":"test","ingest_policy":{"mode":"text"},"editor":{}}',
 '{"name":"source_faaa0000000040008000000000000001","steps":[{"id":"parse","work":true,"queue":"source-test","input":{"op":"ingest"}}]}');
do $$ declare c content.channels; begin
 select * into c from content.channels where name='t_private_source';
 if c.visibility<>'private' or c.owner_id<>'11111111-1111-1111-1111-111111111111'::uuid then raise exception 'source not private and owned';end if;
 begin
  perform content.save_source(c.id,c.name,'{"ingest_policy":{}}',c.config->'workflow',null);
  raise exception 'stale revision accepted';
 exception when serialization_failure then null;end;
 perform content.save_source(c.id,c.name,'{"ingest_policy":{},"description":"updated"}',c.config->'workflow',c.updated_at);
end $$;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
do $$ begin
 if exists(select 1 from content.channels where name='t_private_source')then raise exception 'Bob sees private channel';end if;
 begin
  perform content.save_source('faaa0000-0000-4000-8000-000000000001','t_private_source','{"ingest_policy":{}}','{"name":"source_faaa0000000040008000000000000001"}');
  raise exception 'Bob overwrote private channel';
 exception when insufficient_privilege then null;end;
 begin
  perform content.register_fetched('t_private_source','test','not allowed');
  raise exception 'Bob used guessed private channel';
 exception when raise_exception then
  if sqlerrm not like 'no channel named%' then raise;end if;
 end;
 begin
  perform content.register_upload('t_private_source','test-bucket','test-object','test-checksum',1,'text/plain','not allowed');
  raise exception 'Bob uploaded through private channel';
 exception when raise_exception then
  if sqlerrm not like 'no channel named%' then raise;end if;
 end;
end $$;
set local request.jwt.claims = '{}';
do $$ begin
 begin
  perform content.save_source('faaa0000-0000-4000-8000-000000000002','t_no_user','{"ingest_policy":{}}','{}');
  raise exception 'ownerless authoring allowed';
 exception when insufficient_privilege then null;end;
 if has_function_privilege('authenticated','content.source_passages(uuid)','execute') or
    has_function_privilege('web_anon','content.save_source(uuid,text,jsonb,jsonb,timestamptz)','execute') then
  raise exception 'source functions have excess grants';end if;
end $$;
set local role app_owner;
-- An invalid workflow rolls its channel back with it.
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
do $$ begin
 begin
  perform content.save_source('faaa0000-0000-4000-8000-000000000002','t_bad_source','{"ingest_policy":{}}',
   '{"name":"source_faaa0000000040008000000000000002","steps":[{"id":"broken","unknown":true}]}');
 exception when others then null;end;
 if exists(select 1 from content.channels where name='t_bad_source') then raise exception 'invalid source was persisted';end if;
 raise notice 'content/03: private visibility, owned updates, stale revisions, guessed upload/fetch, anonymous refusal and atomic validation passed';
end $$;
-- The transformation reader follows the actual run owner, including when a
-- caller puts somebody else's resource ID in the workflow input.
do $$ declare a uuid; b uuid; resource uuid; result jsonb; begin
 insert into content.resources(channel_id,title,owner_id,visibility)
 values('faaa0000-0000-4000-8000-000000000001','private source evidence','11111111-1111-1111-1111-111111111111','private') returning id into resource;
 insert into content.resource_chunks(resource_id,ordinal,content) values(resource,0,'Owned evidence.');
 a := workflow.start_workflow('source_faaa0000000040008000000000000001',jsonb_build_object('resource_id',resource));
 perform set_config('workflow.current_run_id',a::text,true);
 result := content.source_passages(resource);
 if result->'rows'->0->>'content' <> 'Owned evidence.' then raise exception 'owner evidence missing';end if;
 perform set_config('request.jwt.claims','{"sub":"22222222-2222-2222-2222-222222222222"}',true);
 b := workflow.start_workflow('source_faaa0000000040008000000000000001',jsonb_build_object('resource_id',resource,'owner_id','11111111-1111-1111-1111-111111111111'));
 perform set_config('workflow.current_run_id',b::text,true);
 begin
  perform content.source_passages(resource);raise exception 'run input impersonated owner';
 exception when insufficient_privilege then null;end;
 perform set_config('workflow.current_run_id',a::text,true);
 update content.resource_chunks set content=repeat('x',80001) where resource_id=resource;
 begin
  perform content.source_passages(resource);raise exception 'oversized evidence silently truncated';
 exception when raise_exception then
  if sqlerrm not like 'This document exceeds%' then raise;end if;
 end;
 raise notice 'content/03: owned evidence, spoofed resource refusal and explicit size limit passed';
end $$;
rollback;
