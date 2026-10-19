-- REM-606: unrelated readable assertions must not be reduced at every traversal hop.
-- Query work, rather than wall time on a shared machine. All fixtures roll back.
--
-- REM-1003: measured twice. The first pass runs on whatever statistics the database has; the second runs after an
-- ANALYZE taken over the first pass's rolled-back rows, which is what a CI database or a small production graph
-- looks like once autovacuum has visited it. On those statistics the planner hashed the origins and tx policies'
-- subqueries, so one study_of call checked every readable citation in the graph: 2,555 shared hits with 10
-- unrelated works and 36,871 with 100. Both passes must now stay flat in unrelated data, not merely sub-quadratic.
\set ON_ERROR_STOP on
begin;
insert into rbac.users(id,email,status) values
 ('00000000-0000-4000-8000-000000060601','origin-work-owner@example.test','active'),
 ('00000000-0000-4000-8000-000000060602','origin-work-other@example.test','active');
insert into rbac.roles(name,description) values ('origin-work-list','fixture');
insert into rbac.role_permissions(role,resource,action) values ('origin-work-list','research','list');
insert into rbac.user_roles(user_id,role) values ('00000000-0000-4000-8000-000000060602','origin-work-list');
create temporary table origin_work_ids(k text primary key,v uuid);
create temporary table origin_work_samples(pass text, n int, hits bigint);
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

-- One pass: 10 unrelated works, then 100, measuring study_of's work for the anchor after each.
create function pg_temp.measure(p_pass text) returns void language plpgsql as $$
declare i int; n int; j jsonb; origin uuid:=(select v from origin_work_ids where k='origin'); begin
 for n in select unnest(array[10,100]) loop
  perform set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000060602"}',true);
  execute 'set local role authenticated';
  for i in (case when n=10 then 1 else 11 end)..n loop
   perform research.submit_package(jsonb_build_object('schema_version','0.1','title','Unrelated noise '||i,
    'visibility','listed','sources',jsonb_build_array(jsonb_build_object('id','S1','title','Unrelated title '||i,
    'origin','Unrelated title '||i,'url','https://origin-work.test/noise/'||p_pass||'/'||i)),
    'claims',jsonb_build_array(jsonb_build_object('id','C1','kind','Inference','text','Noise '||i,
    'source_ids',jsonb_build_array('S1'))),'edges','[]'::jsonb),null,'rp-origin-work-noise-'||p_pass||'-'||i);
  end loop;
  execute 'reset role';
  perform set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000060601"}',true);
  execute 'set local role authenticated';
  assert (select count(*) from claims.origin_links)>=n, 'the caller must see the unrelated links';
  assert claims.study_of(origin)=(select origin_id from claims.cites
    where revision_id=(select v from origin_work_ids where k='revision') and via='url'),
    'unrelated evidence never joins the anchor';
  execute format('explain (analyze,buffers,format json) select claims.study_of(%L::uuid)',origin) into j;
  insert into origin_work_samples values(p_pass,n,(j->0->'Plan'->>'Shared Hit Blocks')::bigint);
  raise notice 'origin work (%): % unrelated works, % shared hits',p_pass,n,j->0->'Plan'->>'Shared Hit Blocks';
  execute 'reset role';
 end loop;
end $$;

savepoint before_noise;
select pg_temp.measure('found');
rollback to savepoint before_noise;
-- The statistics a small, autovacuumed graph has: taken over the anchor and the first pass's dead rows.
analyze claims.origins, claims.cites, claims.origin_links, claims.tx, research.revisions, research.works;
select pg_temp.measure('analysed');

table origin_work_samples;
-- Ten times the unrelated works may add page reads of the small tables still scanned by id, but not work
-- proportional to them: the bound is 3x for 10x the data. A hashed policy subquery made the second sample 14 times
-- the first, and the policy checked ahead of the endpoint test made it 8 times (REM-1003).
do $$ declare p text; begin
 for p in select distinct pass from origin_work_samples loop
  assert (select hits from origin_work_samples where pass=p and n=100)
           < 3 * (select hits from origin_work_samples where pass=p and n=10),
         format('origin traversal grows with unrelated data (%s statistics)', p);
 end loop;
end $$;
rollback;
