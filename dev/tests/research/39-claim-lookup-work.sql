-- REM-1006: reading one claim does work proportional to that claim, not to every readable occurrence in the graph.
-- The claims policy was an inline EXISTS over claims.expresses. On analysed statistics the planner hashed it, so a
-- lookup of one claim by id checked every readable occurrence: 157 shared hits with 10 unrelated packages and 2,126
-- with 100. research/32's shape: measured on the statistics found, then after an ANALYZE taken over the first pass's
-- rolled-back rows. Query work, not wall time on a shared machine. All fixtures roll back.
\set ON_ERROR_STOP on
begin;
insert into rbac.users(id,email,status) values
 ('00000000-0000-4000-8000-000000100601','claim-work-owner@example.test','active'),
 ('00000000-0000-4000-8000-000000100602','claim-work-other@example.test','active');
insert into rbac.roles(name,description) values ('claim-work-list','fixture');
insert into rbac.role_permissions(role,resource,action) values ('claim-work-list','research','list');
insert into rbac.user_roles(user_id,role) values ('00000000-0000-4000-8000-000000100602','claim-work-list');
create temporary table claim_work_ids(k text primary key,v uuid);
create temporary table claim_work_samples(pass text, n int, hits bigint);
grant all on claim_work_ids,claim_work_samples to authenticated;
set local request.jwt.claims='{"sub":"00000000-0000-4000-8000-000000100601"}';
set local role authenticated;
insert into claim_work_ids select 'revision',(research.submit_package(
 '{"schema_version":"0.1","title":"Claim lookup anchor","visibility":"private",
 "sources":[{"id":"S1","title":"Anchor source","origin":"Anchor source","url":"https://claim-work.test/anchor"}],
 "claims":[{"id":"C1","kind":"Inference","text":"Anchor claim.","source_ids":["S1"]}],"edges":[]}',
 null,'rp-claim-work-anchor')->>'revision_id')::uuid;
insert into claim_work_ids select 'claim',claim_id from claims.expresses
 where revision_id=(select v from claim_work_ids where k='revision') and claim_key='C1' limit 1;
reset role;

-- One pass: 10 unrelated listed packages, then 100, measuring the owner's lookup of the anchor claim after each.
create function pg_temp.measure(p_pass text) returns void language plpgsql as $$
declare i int; n int; j jsonb; claim uuid:=(select v from claim_work_ids where k='claim'); begin
 for n in select unnest(array[10,100]) loop
  perform set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000100602"}',true);
  execute 'set local role authenticated';
  for i in (case when n=10 then 1 else 11 end)..n loop
   perform research.submit_package(jsonb_build_object('schema_version','0.1','title','Unrelated noise '||i,
    'visibility','listed','sources',jsonb_build_array(jsonb_build_object('id','S1','title','Unrelated source '||i,
    'origin','Unrelated source '||i,'url','https://claim-work.test/noise/'||p_pass||'/'||i)),
    'claims',jsonb_build_array(jsonb_build_object('id','C1','kind','Inference','text','Noise '||i,
    'source_ids',jsonb_build_array('S1'))),'edges','[]'::jsonb),null,'rp-claim-work-noise-'||p_pass||'-'||i);
  end loop;
  execute 'reset role';
  perform set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000100601"}',true);
  execute 'set local role authenticated';
  assert (select count(*) from claims.claims)>n, 'the caller must read the unrelated claims';
  assert (select count(*) from claims.claims where id=claim)=1, 'the owner reads the anchor claim';
  execute format('explain (analyze,buffers,format json) select * from claims.claims where id=%L::uuid',claim) into j;
  insert into claim_work_samples values(p_pass,n,(j->0->'Plan'->>'Shared Hit Blocks')::bigint);
  raise notice 'claim lookup (%): % unrelated packages, % shared hits',p_pass,n,j->0->'Plan'->>'Shared Hit Blocks';
  execute 'reset role';
 end loop;
end $$;

savepoint before_noise;
select pg_temp.measure('found');
rollback to savepoint before_noise;
-- The statistics a small, autovacuumed graph has: taken over the anchor and the first pass's dead rows.
analyze claims.claims, claims.expresses, research.revisions, research.works;
select pg_temp.measure('analysed');

table claim_work_samples;
-- Ten times the unrelated packages may add page reads of the indexes walked, but not work proportional to them: the
-- bound is 3x for 10x the data. The hashed policy subquery made the second sample 13.5 times the first.
do $$ declare p text; begin
 for p in select distinct pass from claim_work_samples loop
  assert (select hits from claim_work_samples where pass=p and n=100)
           < 3 * (select hits from claim_work_samples where pass=p and n=10),
         format('reading one claim grows with unrelated data (%s statistics)', p);
 end loop;
end $$;
rollback;
