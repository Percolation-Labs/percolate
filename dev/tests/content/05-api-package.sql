-- Package installation assigns a fresh source identity and an explicit owner.
\set ON_ERROR_STOP on
begin;
set local role app_owner;
insert into rbac.users(id,email) values
 ('11111111-1111-1111-1111-111111111111','alice-package@test.invalid'),
 ('22222222-2222-2222-2222-222222222222','bob-package@test.invalid') on conflict(id) do nothing;
insert into rbac.user_roles(user_id,role) values
 ('11111111-1111-1111-1111-111111111111','admin'),
 ('22222222-2222-2222-2222-222222222222','admin') on conflict do nothing;
set local request.jwt.claims='{}';
do $$ declare m jsonb; result jsonb; c content.channels; run uuid; task uuid; state jsonb; begin
 m:='{"name":"t-api-package","version":"0.1.0","sources":[{"name":"t_packaged_api","kind":"http_pull","config":{"api":{"url":"https://example.test/items","id_path":"id"},"ingest_workflow":"t_packaged_api_workflow"}}],"workflows":[{"name":"t_packaged_api_workflow","yaml":"{\"name\":\"t_packaged_api_workflow\",\"steps\":[{\"id\":\"pull\",\"work\":true,\"queue\":\"t-packaged-api\",\"input\":{\"op\":\"api_pull\",\"source_name\":\"t_packaged_api\"}}]}"}]}';
 begin
  perform percolate.apply_package(m);raise exception 'ownerless API package accepted';
 exception when raise_exception then if sqlerrm not like 'An API source package needs%' then raise;end if;end;
 if exists(select 1 from content.channels where name='t_packaged_api') then raise exception 'ownerless package partially installed';end if;
 execute format('set local request.jwt.claims = %L', '{"sub":"11111111-1111-1111-1111-111111111111"}');
 result:=percolate.apply_package(m);
 select * into c from content.channels where name='t_packaged_api';
 if c.owner_id<>'11111111-1111-1111-1111-111111111111'::uuid or c.visibility<>'private' then raise exception 'package source is not privately owned';end if;
 perform percolate.apply_package(m);
 if (select count(*) from content.channels where name='t_packaged_api')<>1 then raise exception 'reinstall duplicated source';end if;
 run:=content.start_source_pull(c.id);
 select id into task from workflow.claim_task('t-packaged-api','package-tester');
 state:=content.begin_named_api_pull(task,'package-tester','t_packaged_api');
 if state->>'source_id'<>c.id::text or state->>'watermark' is not null then raise exception 'package has stale identity or progress';end if;
 execute format('set local request.jwt.claims = %L', '{"sub":"22222222-2222-2222-2222-222222222222"}');
 begin
  perform percolate.apply_package(m);raise exception 'package reassigned another owner source';
 exception when raise_exception then if sqlerrm not like 'API source % already exists%' then raise;end if;end;
 raise notice 'content/05: explicit package owner, private fresh identity, idempotent install, portable name resolution and conflict refusal passed';
end $$;
rollback;
