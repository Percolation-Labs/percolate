-- REM-606: unrelated readable assertions must not be reduced at every traversal hop.
-- Query work, rather than wall time on a shared machine. All fixtures roll back.
\set ON_ERROR_STOP on
begin;
insert into rbac.users(id,email,status) values
 ('00000000-0000-4000-8000-000000060601','origin-work-owner@example.test','active'),
 ('00000000-0000-4000-8000-000000060602','origin-work-other@example.test','active');
insert into rbac.roles(name,description) values ('origin-work-list','fixture');
insert into rbac.role_permissions(role,resource,action) values ('origin-work-list','research','list');
insert into rbac.user_roles(user_id,role) values ('00000000-0000-4000-8000-000000060602','origin-work-list');
create temporary table origin_work_ids(k text primary key,v uuid);
create temporary table origin_work_samples(n int, hits bigint);
grant all on origin_work_ids,origin_work_samples to authenticated;
set local request.jwt.claims='{"sub":"00000000-0000-4000-8000-000000060601"}';
set local role authenticated;
insert into origin_work_ids select 'revision',(research.submit_package(
 '{"schema_version":"0.1","title":"Traversal anchor","visibility":"private",
 "sources":[{"id":"S1","title":"Shared title","origin":"Shared title","url":"https://origin-work.test/anchor"}],
 "claims":[{"id":"C1","kind":"Inference","text":"Anchor claim.","source_ids":["S1"]}],"edges":[]}',
 null,'rp-origin-work-anchor')->>'revision_id')::uuid;
insert into origin_work_ids select 'origin',origin_id from claims.cites
 where revision_id=(select v from origin_work_ids where k='revision') and claim_key='C1' and via='origin';
reset role;
do $$ declare i int; n int; j jsonb; origin uuid:=(select v from origin_work_ids where k='origin'); begin
 for n in select unnest(array[10,100]) loop
  perform set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000060602"}',true);
  execute 'set local role authenticated';
  for i in (case when n=10 then 1 else 11 end)..n loop
   perform research.submit_package(jsonb_build_object('schema_version','0.1','title','Unrelated noise '||i,
    'visibility','listed','sources',jsonb_build_array(jsonb_build_object('id','S1','title','Unrelated title '||i,
    'origin','Unrelated title '||i,'url','https://origin-work.test/noise/'||i)),
    'claims',jsonb_build_array(jsonb_build_object('id','C1','kind','Inference','text','Noise '||i,
    'source_ids',jsonb_build_array('S1'))),'edges','[]'::jsonb),null,'rp-origin-work-noise-'||i);
  end loop;
  execute 'reset role';
  perform set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000060601"}',true);
  execute 'set local role authenticated';
  assert (select count(*) from claims.origin_links)>=n, 'the caller must see the unrelated links';
  assert claims.study_of(origin)=(select origin_id from claims.cites
    where revision_id=(select v from origin_work_ids where k='revision') and via='url'),
    'unrelated evidence never joins the anchor';
  execute format('explain (analyze,buffers,format json) select claims.study_of(%L::uuid)',origin) into j;
  insert into origin_work_samples values(n,(j->0->'Plan'->>'Shared Hit Blocks')::bigint);
  raise notice 'origin work: % unrelated works, % shared hits',n,j->0->'Plan'->>'Shared Hit Blocks';
  execute 'reset role';
 end loop;
end $$;
table origin_work_samples;
-- A decade of unrelated data may add permission checks, but not a quadratic traversal.
do $$ begin
 assert (select hits from origin_work_samples where n=100)
          < 20 * (select hits from origin_work_samples where n=10), 'origin traversal grows quadratically';
end $$;
rollback;
