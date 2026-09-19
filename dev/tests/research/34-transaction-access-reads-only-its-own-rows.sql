-- REM-626: deciding whether a caller may read one claims.tx row must not read every row of the graph.
-- tx_readable asks whether a readable row names the transaction. Without an index on each table's tx column the
-- planner answered it by hashing the whole table, and research.revision_readable ran once per row in the database:
-- a claim page on production took 3.3 s with 700 occurrences in the whole graph, and grew with every package added.
-- Count access checks, not elapsed time; the count is what grows with unrelated data.
\set ON_ERROR_STOP on
begin;
set local track_functions='all';
insert into rbac.users(id,email,status) values
 ('00000000-0000-4000-8000-000000062601','tx-access-anchor@example.test','active'),
 ('00000000-0000-4000-8000-000000062602','tx-access-others@example.test','active');
set local request.jwt.claims='{"sub":"00000000-0000-4000-8000-000000062602"}';
set local role authenticated;
-- Unrelated work by somebody else: forty packages the anchor's reader never asks about.
do $$ begin for i in 1..40 loop
 perform research.submit_package(jsonb_build_object('schema_version','0.1','title','Unrelated '||i,'visibility','public',
  'sources',jsonb_build_array(jsonb_build_object('id','S1','title','Paper','origin','https://doi.org/10.626/u'||i,
                                                 'url','https://tx-access.test/u'||i)),
  'claims',jsonb_build_array(jsonb_build_object('id','C1','kind','Inference','text','Unrelated claim '||i,
                                                'source_ids',jsonb_build_array('S1'))),
  'edges','[]'::jsonb), null, 'rp-tx-access-unrelated-'||i);
end loop; end $$;
reset role;
analyze claims.expresses, claims.relations, claims.answered, claims.cites, claims.origin_links, claims.resolutions,
        claims.consensus, claims.tx;
set local request.jwt.claims='{"sub":"00000000-0000-4000-8000-000000062601"}';
set local role authenticated;
select research.submit_package('{"schema_version":"0.1","title":"One claim, two studies","visibility":"private",
 "sources":[
 {"id":"S1","title":"Paper","origin":"https://doi.org/10.626/anchor","url":"https://tx-access.test/anchor"},
 {"id":"S2","title":"Other","origin":"https://tx-access.test/other","url":"https://tx-access.test/other"}],
 "claims":[{"id":"C1","kind":"Inference","text":"Two studies behind one claim.","source_ids":["S1","S2"]}],"edges":[]}',
 null,'rp-tx-access-anchor');
do $$ declare c uuid; before_calls bigint; after_calls bigint; n int; begin
 select e.claim_id into c from claims.expresses e join research.revisions r on r.id=e.revision_id
 join research.works w on w.id=r.work_id where w.public_id='rp-tx-access-anchor';
 select coalesce(sum(calls),0) into before_calls from pg_stat_xact_user_functions
  where funcid='research.revision_readable(uuid)'::regprocedure;
 select count(*) into n from claims.evidence(c);
 select coalesce(sum(calls),0) into after_calls from pg_stat_xact_user_functions
  where funcid='research.revision_readable(uuid)'::regprocedure;
 assert n=2, 'the claim keeps its two studies';
 raise notice 'claim evidence: % revision access checks', after_calls-before_calls;
 -- The anchor has one revision, one occurrence and four cited keys; forty unrelated packages add 40 occurrences,
 -- 160 citations and their links. Checking only rows that name the anchor's transactions stays well under 40.
 assert after_calls-before_calls < 40,
  format('claim evidence checked %s revisions: tx access is reading unrelated rows', after_calls-before_calls);
end $$;
reset role;
rollback;
