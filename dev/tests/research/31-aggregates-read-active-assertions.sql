-- REM-603: aggregate reads reduce history and then check the current occurrence identity. Everything rolls back.
-- Expected correct output: origin_record=0 for the new origin; frame_coverage.answering=0 after retraction.
\set ON_ERROR_STOP on
begin;
insert into rbac.users(id,email,status) values ('00000000-0000-4000-8000-000000059021','aggregate-probe@example.test','active');
insert into rbac.roles(name,description) values ('aggregate-resolver','probe');
insert into rbac.role_permissions(role,resource,action) values ('aggregate-resolver','research','resolve');
insert into rbac.user_roles(user_id,role) values ('00000000-0000-4000-8000-000000059021','aggregate-resolver');
create temporary table ids(k text primary key,v text) on commit drop;
grant all on ids to authenticated;
set local request.jwt.claims='{"sub":"00000000-0000-4000-8000-000000059021"}';
set local role authenticated;
insert into ids select 'r1',research.submit_package('{"schema_version":"0.1","title":"Aggregate history","visibility":"private","edges":[],
 "sources":[{"id":"S1","title":"Old study","url":"https://aggregate.test/old"}],
 "claims":[{"id":"C1","kind":"Inference","text":"The old proposition.","source_ids":["S1"],
 "frame":{"subject":"medlars","outcome":"ripening","direction":"late"}}]}',null,'rp-aggregate-probe')->>'revision_id';
insert into ids select 'old',claim_id::text from claims.expresses where revision_id=(select v::uuid from ids where k='r1');
insert into ids select 'r2',research.revise_package('rp-aggregate-probe','{"schema_version":"0.1","title":"Aggregate history revised","visibility":"private","edges":[],
 "sources":[{"id":"S1","title":"New study","url":"https://aggregate.test/new"}],
 "claims":[{"id":"C1","kind":"Inference","text":"A different proposition.","source_ids":["S1"],
 "frame":{"subject":"medlars","outcome":"ripening","direction":"late"}}]}','draft-1')->>'revision_id';
insert into ids select 'new',claims.answer_rewording((select v::uuid from ids where k='r2'),'C1','new')::text;
do $$ begin
 assert (select count(*) from claims.answers_of((select v::uuid from ids where k='new')))=1, 'new identity keeps its projected answer';
 assert (select count(*) from claims.answers_of((select v::uuid from ids where k='old')))=1, 'old identity keeps only the old revision answer';
 assert (select count(*) from claims.answered where evidence=(select v::uuid from ids where k='r2'))=3, 'answer reassignment preserves assertion history';
 assert (select answering from claims.frame_coverage('rp-aggregate-probe'))=1, 'current frame answers once after reassignment';
end $$;
insert into ids select 'resolution',claims.propose_resolution((select v::uuid from ids where k='old'),
 (select v::uuid from ids where k='r1'),'held','old proposition checked','https://aggregate.test/old',current_date,'probe review')::text;
select claims.review_resolution((select v::bigint from ids where k='resolution'),'confirmed');
-- The confirmed old proposition never cited this origin in an active occurrence.
do $$ begin
 assert coalesce((select sum(claims) from claims.origin_record((select id from claims.origins where key='url:aggregate.test/new'))),0)=0,
   'a new origin must not inherit an old reassigned claim outcome';
 assert coalesce((select sum(claims) from claims.origin_record((select id from claims.origins where key='url:aggregate.test/old'))),0)=1,
   'the actual old origin keeps its confirmed outcome';
end $$;
reset role;
-- There is no public answer-retraction writer yet; seed a valid append-only retraction as the owner.
with t as (insert into claims.tx(actor_kind,revision_id,reason) values
 ('platform',(select v::uuid from ids where k='r2'),'probe retract answer') returning id)
insert into claims.answered(claim_id,question_id,stance,status,op,evidence,claim_key,tx)
select a.claim_id,a.question_id,a.stance,a.status,'retract',a.evidence,a.claim_key,t.id
 from claims.answered a,t where a.evidence=(select v::uuid from ids where k='r2');
set local role authenticated;
do $$ begin
 assert (select answering from claims.frame_coverage('rp-aggregate-probe'))=0, 'a retracted answer must not count';
end $$;
reset role;
rollback;
