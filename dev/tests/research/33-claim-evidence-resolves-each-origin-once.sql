-- REM-615: the full evidence read must not repeat study traversal for each source and output key.
-- Count traversal calls, not elapsed time; timings depend on unrelated production data and hardware.
\set ON_ERROR_STOP on
begin;
set local track_functions='all';
insert into rbac.users(id,email,status) values
 ('00000000-0000-4000-8000-000000061501','claim-evidence-work@example.test','active');
set local request.jwt.claims='{"sub":"00000000-0000-4000-8000-000000061501"}';
set local role authenticated;
select research.submit_package('{"schema_version":"0.1","title":"Several reports of two studies","visibility":"private",
 "sources":[
 {"id":"S1","title":"Paper","origin":"https://doi.org/10.615/paper","url":"https://claim-work.test/paper"},
 {"id":"S2","title":"PDF","origin":"https://doi.org/10.615/paper","url":"https://claim-work.test/paper.pdf"},
 {"id":"S3","title":"Other study","origin":"https://claim-work.test/other","url":"https://claim-work.test/other"}],
 "claims":[{"id":"C1","kind":"Inference","text":"Two studies, despite three sources.","source_ids":["S1","S2","S3"]}],"edges":[]}',
 null,'rp-claim-evidence-work');
do $$ declare c uuid; before_calls bigint; after_calls bigint; n int; k int; begin
 select e.claim_id into c from claims.expresses e join research.revisions r on r.id=e.revision_id
 join research.works w on w.id=r.work_id where w.public_id='rp-claim-evidence-work';
 select coalesce(sum(calls),0) into before_calls from pg_stat_xact_user_functions
 where funcid='claims.study_of(uuid,timestamptz,uuid[])'::regprocedure;
 select count(*),sum(cardinality(keys)) into n,k from claims.evidence(c);
 select coalesce(sum(calls),0) into after_calls from pg_stat_xact_user_functions
 where funcid='claims.study_of(uuid,timestamptz,uuid[])'::regprocedure;
 assert n=2 and k=4, 'three sources retain two studies and all four strong keys';
 raise notice 'full evidence read: % study traversals',after_calls-before_calls;
 assert after_calls-before_calls=4, 'each of the four cited origins must be resolved once';
end $$;
reset role;
rollback;
