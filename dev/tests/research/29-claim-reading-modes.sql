-- REM-584. A small chronological oracle, independent of the read implementation.
-- Separate transactions make real knowledge-time boundaries. Only the origin correction fixture uses
-- owner inserts: there is no named correction writer yet (C6). Every observation uses authenticated RLS.
\set ON_ERROR_STOP on
select research.erase_work(public_id, 'REM-584 fixture reset') from research.works where public_id = 'rp-reading';
insert into rbac.users(id,email,status) values
 ('00000000-0000-4000-8000-000000058401','reading-owner@example.test','active'),
 ('00000000-0000-4000-8000-000000058402','reading-reader@example.test','active') on conflict do nothing;
insert into rbac.roles(name,description) values ('reading-list','fixture') on conflict do nothing;
insert into rbac.role_permissions(role,resource,action) values ('reading-list','research','list') on conflict do nothing;
insert into rbac.user_roles(user_id,role) values ('00000000-0000-4000-8000-000000058401','reading-list') on conflict do nothing;
create temporary table ids(k text primary key,v uuid);
create temporary table marks(k text primary key,v timestamptz);
grant all on ids, marks to authenticated;
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000058401"}';
set role authenticated;
insert into ids select 'r1', (research.submit_package('{"schema_version":"0.1","title":"Reading","visibility":"listed",
 "sources":[{"id":"S1","title":"One","origin":"doi:10.0584/one","url":"https://reading.test/one"},
            {"id":"S2","title":"Two","origin":"doi:10.0584/two","url":"https://reading.test/two"}],
 "claims":[{"id":"C1","kind":"Inference","text":"Medlars ripen late.","source_ids":["S1","S2"]},
           {"id":"C2","kind":"Inference","text":"Early harvest is possible."}],
 "edges":[{"source":"C2","target":"C1","relation":"challenges"}]}',null,'rp-reading')->>'revision_id')::uuid;
insert into ids select 'claim',claim_id from claims.expresses where revision_id=(select v from ids where k='r1') and claim_key='C1';
reset role;
insert into marks values('first',clock_timestamp());
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000058402"}';
set role authenticated;
do $$ begin
 assert jsonb_array_length(claims.reading((select v from ids where k='claim'))->'relations')=1, 'public reader initially sees the challenge';
end $$;
reset role;
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000058401"}';
set role authenticated;
insert into ids select 'r2',(research.revise_package('rp-reading','{"schema_version":"0.1","title":"Reading revised","visibility":"private",
 "sources":[{"id":"S1","title":"One","origin":"doi:10.0584/one","url":"https://reading.test/one"}],
 "claims":[{"id":"C1","kind":"Inference","text":"Medlars ripen in late autumn.","source_ids":["S1"]}],"edges":[]}', 'draft-1')->>'revision_id')::uuid;
reset role;
insert into marks values('reworded',clock_timestamp());
-- Oracle: owner current has the rewording and no challenge; pinned/history first has the old challenge.
set role authenticated;
do $$ declare c uuid := (select v from ids where k='claim'); j jsonb; begin
 j:=claims.reading(c); assert jsonb_array_length(j->'occurrences')=1 and jsonb_array_length(j->'relations')=0, 'current omits removed challenge';
 j:=claims.reading(c,'pinned',array[(select v from ids where k='r1')]);
 assert jsonb_array_length(j->'relations')=1, 'pinned retains challenge';
 j:=claims.reading(c,'historical',null,(select v from marks where k='first'));
 assert j->'occurrences'->0->>'revision_id'=(select v::text from ids where k='r1') and jsonb_array_length(j->'relations')=1, 'historical selects old owned head';
 assert jsonb_array_length(claims.claim(c)->'occurrences')=2, 'legacy keeps every readable revision';
end $$;
insert into ids select 'newclaim',claims.answer_rewording((select v from ids where k='r2'),'C1','new');
reset role;
insert into marks values('answered',clock_timestamp());
set role authenticated;
do $$ declare c uuid := (select v from ids where k='claim'); j jsonb; begin
 assert claims.reading(c) is null, 'old identity has no current occurrence';
 assert (select max(citing_occurrences) from claims.evidence(c))=1, 'old evidence excludes reassigned occurrence';
 j:=claims.reading(c,'pinned',array[(select v from ids where k='r2')],(select v from marks where k='reworded'));
 assert jsonb_array_length(j->'occurrences')=1, 'pre-answer pinned reading retains proposed identity';
 assert claims.reading(c,'pinned',array[(select v from ids where k='r2')]) is null, 'post-answer pinned reading no longer carries old identity';
end $$;
reset role;
-- A later origin merge, duplicate assertion, and retraction. Expectations: 2,1,1,2 origin groups.
insert into ids select 'o1',id from claims.origins where key='doi:10.0584/one';
insert into ids select 'o2',id from claims.origins where key='doi:10.0584/two';
insert into marks values('before_merge',clock_timestamp());
with t as (insert into claims.tx(actor_kind,revision_id,reason) values ('platform',(select v from ids where k='r1'),'test merge') returning id)
insert into claims.origin_links(a,b,status,evidence,source_key,tx)
select least(a.v,b.v),greatest(a.v,b.v),'confirmed',r.v,'S1',t.id from ids a,ids b,ids r,t where a.k='o1' and b.k='o2' and r.k='r1';
insert into marks values('merged',clock_timestamp());
with t as (insert into claims.tx(actor_kind,revision_id,reason) values ('platform',(select v from ids where k='r1'),'test duplicate') returning id)
insert into claims.origin_links(a,b,status,evidence,source_key,tx)
select least(a.v,b.v),greatest(a.v,b.v),'confirmed',r.v,'S1',t.id from ids a,ids b,ids r,t where a.k='o1' and b.k='o2' and r.k='r1';
insert into marks values('duplicate',clock_timestamp());
with t as (insert into claims.tx(actor_kind,revision_id,reason) values ('platform',(select v from ids where k='r1'),'test split') returning id)
insert into claims.origin_links(a,b,status,op,evidence,source_key,tx)
select least(a.v,b.v),greatest(a.v,b.v),'confirmed','retract',r.v,'S1',t.id from ids a,ids b,ids r,t where a.k='o1' and b.k='o2' and r.k='r1';
insert into marks values('split',clock_timestamp());
set role authenticated;
do $$ declare c uuid := (select v from ids where k='claim'); r record; n int; begin
 for r in select * from (values ('before_merge',2),('merged',1),('duplicate',1),('split',2)) expected(mark,total) loop
   select count(*) into n from claims.evidence(c,(select v from marks where k=r.mark));
   assert n=r.total, format('origin oracle at %s expected %s got %s',r.mark,r.total,n);
 end loop;
end $$;
reset role;
-- Identity merge is evaluated at the same cutoff, and both evidence revisions must be selected.
insert into marks values('before_identity',clock_timestamp());
set role authenticated;
select claims.assert_relation('C1','same_as','C1',(select v from ids where k='r1'),(select v from ids where k='r2'),
 'confirmed','{"src": "Medlars ripen late.", "dst": "Medlars ripen in late autumn.", "slots": {"src": {"subject": "medlars", "predicate": "ripen", "object": "late", "scope": "autumn", "polarity": "positive", "modality": "asserted"}, "dst": {"subject": "medlars", "predicate": "ripen", "object": "late", "scope": "autumn", "polarity": "positive", "modality": "asserted"}}}');
do $$ declare c uuid := (select v from ids where k='claim'); both_revs uuid[] := (select array_agg(v) from ids where k in ('r1','r2')); begin
 assert jsonb_array_length(claims.reading(c,'pinned',both_revs)->'identity_set')=2, 'confirmed merge extends pinned pair';
 assert jsonb_array_length(claims.reading(c,'pinned',both_revs,(select v from marks where k='before_identity'))->'identity_set')=1, 'later merge cannot rewrite earlier identity';
 assert jsonb_array_length(claims.reading(c,'pinned',array[(select v from ids where k='r1')])->'identity_set')=1, 'pinned view cannot import outside evidence';
end $$;
reset role;
-- A stranger cannot see the private draft, even when explicitly pinned or historically requested.
set request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000058402"}';
set role authenticated;
do $$ declare c uuid := (select v from ids where k='claim'); begin
 assert claims.reading((select v from ids where k='newclaim'),'pinned',array[(select v from ids where k='r2')]) is null, 'private pinned revision denied';
 -- Revising to private unlists the work, so present-day access also denies its public past.
 assert claims.reading(c) is null, 'revoked current access denied';
 assert claims.reading(c,'historical',null,(select v from marks where k='first')) is null, 'revoked historical access denied';
 assert claims.reading('00000000-0000-4000-8000-000000058499') is null, 'missing and denied anchors have same response';
end $$;
reset role;
reset request.jwt.claims;
select research.erase_work('rp-reading','REM-584 fixture cleanup');
