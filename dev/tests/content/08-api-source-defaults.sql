-- An omitted API setting means one thing, whoever wrote the source (REM-61).
--
-- The defaults are content.api_source in percolate.types. Before this, a source
-- saved through SQL without watermark_type pulled as `timestamp` in the worker
-- and was guarded as `none` in commit_api_page, so a late, older version of a
-- record replaced the newer one -- on exactly the sources an agent or a SQL user
-- wrote, and never on the UI's, which always sends every key.
\set ON_ERROR_STOP on
begin;
set local role app_owner;
insert into rbac.users(id,email) values
 ('11111111-1111-1111-1111-111111111111','alice-api@test.invalid') on conflict(id) do nothing;
insert into rbac.user_roles(user_id,role) values
 ('11111111-1111-1111-1111-111111111111','admin') on conflict do nothing;
-- A row written before the writers stored the whole block: no watermark_type,
-- no pagination. Inserted directly because no writer produces one any more.
insert into content.channels(id,name,kind,config,owner_id,visibility)
values('faaa0000-0000-4000-8000-000000000081','t_api_legacy','http_pull',
 '{"api":{"url":"https://example.test/legacy","id_path":"id"},"ingest_workflow":"t_api_legacy_workflow"}',
 '11111111-1111-1111-1111-111111111111','private');
select workflow.define_yaml('{"name":"t_api_legacy_workflow","steps":[{"id":"pull","work":true,"queue":"t-api-defaults","input":{"op":"api_pull","source_id":"faaa0000-0000-4000-8000-000000000081"}}]}');

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
do $$ declare c content.channels; d jsonb; begin
 -- Only what differs from the default: the endpoint. id_path defaults too.
 perform content.save_api_source('faaa0000-0000-4000-8000-000000000082','t_api_minimal',
  '{"api":{"url":"https://example.test/minimal"}}','t-api-defaults');
 select * into c from content.channels where id='faaa0000-0000-4000-8000-000000000082';
 select jsonb_object_agg(p.key,p.value->'default') into d
   from percolate.types t, jsonb_each(t.schema->'properties') p
  where t.name='content.api_source' and p.value ? 'default';
 if c.config->'api'->>'watermark_type' is distinct from 'timestamp'
    or c.config->'api'->>'pagination' is distinct from 'link_header'
    or c.config->'api'->>'id_path' is distinct from 'id' then
  raise exception 'saved source does not state the declared defaults: %',c.config->'api';end if;
 -- Every declared setting is stored, not only the three this test names.
 if exists(select 1 from jsonb_object_keys(d) k where not c.config->'api' ? k) then
  raise exception 'saved source omits declared settings: %',c.config->'api';end if;

 begin
  perform content.save_api_source('faaa0000-0000-4000-8000-000000000083','t_api_typo',
   '{"api":{"url":"https://example.test/x","watermark_typ":"none"}}','t-api-defaults');
  raise exception 'misspelt setting accepted';
 exception when raise_exception then if sqlerrm not like 'Unknown API settings: watermark_typ.%' then raise;end if;end;
 begin
  perform content.save_api_source('faaa0000-0000-4000-8000-000000000083','t_api_enum',
   '{"api":{"url":"https://example.test/x","watermark_type":"hourly"}}','t-api-defaults');
  raise exception 'unknown watermark type accepted';
 exception when raise_exception then if sqlerrm not like 'Unsupported watermark_type: "hourly"%' then raise;end if;end;
 begin
  perform content.save_api_source('faaa0000-0000-4000-8000-000000000083','t_api_token',
   '{"api":{"url":"https://example.test/x","token":"s3cret"}}','t-api-defaults');
  raise exception 'literal token accepted';
 exception when raise_exception then if sqlerrm not like 'Store authentication by credential reference%' then raise;end if;end;

 perform content.start_source_pull('faaa0000-0000-4000-8000-000000000082','t-api-minimal-pull');
 perform content.start_source_pull('faaa0000-0000-4000-8000-000000000081','t-api-legacy-pull');
end $$;

-- The guard, on both: the saved minimal source and the legacy row.
set local role worker;
set local request.jwt.claims='{}';
do $$ declare t uuid; s jsonb; r jsonb; src uuid; begin
 for i in 1..2 loop
  select id,(input->>'source_id')::uuid into t,src from workflow.claim_task('t-api-defaults','defaults-tester');
  s:=content.begin_api_pull(t,'defaults-tester',src);
  -- The worker is handed the settings, defaults included, not the raw row.
  if s->'config'->>'watermark_type' is distinct from 'timestamp' or s->'config'->>'pagination' is distinct from 'link_header' then
   raise exception 'worker handed raw settings for %: %',src,s->'config';end if;
  r:=content.commit_api_page(t,'defaults-tester',src,(s->>'revision')::bigint,
   '[{"external_id":"A","watermark":"2026-09-02T00:00:00Z","raw":{"id":"A","v":"newer"},"data":{"v":"newer"}}]',
   'https://example.test/p1','https://example.test/p2','2026-09-02T00:00:00Z','first');
  r:=content.commit_api_page(t,'defaults-tester',src,(r->>'revision')::bigint,
   '[{"external_id":"A","watermark":"2026-09-01T00:00:00Z","raw":{"id":"A","v":"older"},"data":{"v":"older"}}]',
   'https://example.test/p2',null,'2026-09-02T00:00:00Z','last');
  if (r->>'unchanged')::int<>1 then raise exception 'older version of A replaced the newer one for %',src;end if;
  perform workflow.complete_task(t,jsonb_build_object('result',r->'receipt'));
 end loop;
end $$;

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
do $$ begin
 if (select count(*) from content.source_records
      where source_id in ('faaa0000-0000-4000-8000-000000000081','faaa0000-0000-4000-8000-000000000082')
        and data->>'v'='newer') is distinct from 2::bigint then
  raise exception 'a late older record won on a source that omitted watermark_type';end if;
end $$;

-- The third writer: a package. It stores the same whole block, re-installs as
-- the same source, and refuses what save_api_source refuses.
set local role app_owner;
do $$ declare m jsonb; c content.channels; begin
 m:='{"name":"t-api-defaults-package","version":"0.1.0","sources":[{"name":"t_packaged_minimal","kind":"http_pull","config":{"api":{"url":"https://example.test/pkg","id_path":"id"},"ingest_workflow":"t_packaged_minimal_workflow"}}],"workflows":[{"name":"t_packaged_minimal_workflow","yaml":"{\"name\":\"t_packaged_minimal_workflow\",\"steps\":[{\"id\":\"pull\",\"work\":true,\"queue\":\"t-api-defaults\",\"input\":{\"op\":\"api_pull\",\"source_name\":\"t_packaged_minimal\"}}]}"}]}';
 execute format('set local request.jwt.claims = %L', '{"sub":"11111111-1111-1111-1111-111111111111"}');
 perform percolate.apply_package(m);
 select * into c from content.channels where name='t_packaged_minimal';
 if c.config->'api'->>'watermark_type' is distinct from 'timestamp' then raise exception 'package stored a partial block: %',c.config->'api';end if;
 perform percolate.apply_package(m);
 begin
  perform percolate.apply_package(jsonb_set(jsonb_set(m,'{name}','"t-api-bad-package"'),'{sources,0}',
   '{"name":"t_packaged_bad","kind":"http_pull","config":{"api":{"url":"https://example.test/pkg","pagination":"cursor"}}}'));
  raise exception 'package with an unknown pagination accepted';
 exception when raise_exception then if sqlerrm not like 'Unsupported pagination: "cursor"%' then raise;end if;end;
end $$;

-- The vocabulary is published, so a client can be told it rather than guess.
do $$ begin
 if (select admits from percolate.enums() where table_name='content.api_source' and column_name='watermark_type')
    is distinct from array['none','number','timestamp'] then
  raise exception 'percolate.enums() does not publish content.api_source.watermark_type';end if;
 raise notice 'content/08: omitted API settings take one default on every writer and reader; typos, unknown values and literal tokens refused';
end $$;
rollback;
