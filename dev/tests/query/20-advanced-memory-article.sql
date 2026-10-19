-- PART THREE OF THE SERIES: FROM A REMEMBERED FACT TO THE QUESTION IT BEARS ON.
--
-- The blocks of part three (Percolate writing ld-a56393c09254) that need no model, verbatim and in the article's
-- order, each followed by the assertion that keeps the article true:
--   §1 one setup block knits Priya's sessions and makes the bindings later sections use (reconciling them is part
--      two's, for Zep users);
--   §2 questions answered from notes, and a withdrawn answer kept as a row;
--   §3 TEXT's warnings, and an iterated join that resolves and one that stops at its bound.
-- The blocks that call a model (linking facts to questions with Jev, embedding notes, SEARCH and SEMANTIC in a
-- workflow) run against a live stack in dev/examples/advanced-memory/run.sh, which runs every block in order.
--
-- WHAT WOULD MAKE IT FAIL. Leave P. Raman unbound and §1 raises; let withdraw_answer delete and §2 raises; drop
-- TEXT's count and §3 raises.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on
begin;

create function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
    if p_ok is not true then
        raise exception 'part three article: %', p_what;
    end if;
end $$;
create function pg_temp.priya() returns table(relation text, key text) language sql as $$
    select relation, key from jsonb_to_recordset(aiq.query('GRAPH "Priya Raman" DEPTH 1') -> 'rows')
        as r(relation text, key text)
$$;

-- Part one's shell makes this user with rbac.bootstrap_admin on a fresh install. A suite database already has an
-- admin, so here the reader is made as the neighbouring research tests make theirs: a user and a role that may write
-- research, define workflows and register text, inside this transaction.
insert into rbac.users (email, status) values ('me@example.com', 'active') on conflict do nothing;
insert into rbac.roles (name, description) values ('rp-q20', 'may list, read and write research (test)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values
    ('rp-q20', 'research', 'list'), ('rp-q20', 'research', 'select'), ('rp-q20', 'research', 'insert'),
    ('rp-q20', 'workflows', 'update'), ('rp-q20', 'resources', 'create')
    on conflict do nothing;
insert into rbac.user_roles (user_id, role) select id, 'rp-q20' from rbac.users where email = 'me@example.com'
    on conflict do nothing;

-- The suite's graph sample (dev/init/04) already holds a typed Priya Raman in demo.people. The article runs on a
-- fresh install, where she does not exist until HR's list arrives, so the sample's row is set aside here, inside
-- this transaction.
delete from demo.people where lower(full_name) = 'priya raman';

-- §1
create schema if not exists team;
create table if not exists team.people (id uuid primary key default gen_random_uuid(), name text not null unique);
select aiq.register_entity_table('person', 'team.people', 'n.name', 'n.name', 'rbac.shared_org_id()');
select aiq.register_graph_vocabulary($v$[{"relation": "works_on", "single_valued": true}, {"relation": "prefers"}]$v$) ->> 'relations' as relations;

select aiq.upsert_graph($g$
 {"nodes": [{"k":"person","n":"Priya Raman"}, {"k":"project","n":"Harbour Rewrite"}, {"k":"tool","n":"Postgres"}],
  "edges": [{"s":0,"t":1,"r":"works_on"}, {"s":0,"t":2,"r":"prefers"}]}$g$,
 '{"agent":"knit","run_id":"jan-12","valid_from":"2026-01-12T10:00:00Z"}') ->> 'edges_new' as jan_12;
select aiq.upsert_graph($g$
 {"nodes": [{"k":"person","n":"P. Raman"}, {"k":"tool","n":"DuckDB"}],
  "edges": [{"s":0,"t":1,"r":"prefers"}]}$g$,
 '{"agent":"knit","run_id":"mar-03","valid_from":"2026-03-03T15:00:00Z"}') ->> 'edges_new' as mar_03;
select aiq.upsert_graph($g$
 {"nodes": [{"k":"person","n":"Priya Raman"}, {"k":"project","n":"Tide Dashboard"}],
  "edges": [{"s":0,"t":1,"r":"works_on"}]}$g$,
 '{"agent":"knit","run_id":"jun-02","valid_from":"2026-06-02T08:30:00Z"}') ->> 'edges_new' as jun_02;

insert into team.people (name) values ('Priya Raman') on conflict do nothing;
select aiq.dream() ->> 'promoted_exact' as bound_by_rule;
select aiq.promote_soft_node(
         (select id from aiq.soft_nodes where key = 'p. raman'),
         (select node_id from aiq.lookup('Priya Raman')),
         'harbour-lead', 'human', '{"why": "P. Raman is Priya"}') ->> 'moved' as bound_by_judge;

select relation, key from jsonb_to_recordset(aiq.query('GRAPH "Priya Raman" DEPTH 1') -> 'rows')
    as r(relation text, key text) order by relation, key;
select pg_temp.check((select array_agg(key order by key) from pg_temp.priya()) = '{project/tide dashboard,tool/duckdb,tool/postgres}',
    '§1 after setup Priya should prefer DuckDB and Postgres and work on Tide Dashboard');
select pg_temp.check(exists (select 1 from aiq.soft_nodes where key = 'p. raman' and resolved_node_id is not null),
    '§1 P. Raman should be bound to Priya, which the walk in §3 depends on');

-- §2
select set_config('request.jwt.claims', json_build_object('sub',
         (select id from rbac.users where email = 'me@example.com'))::text, false) is not null as signed_in;
create or replace function pg_temp.note(p_title text, p_claim text) returns uuid language sql as $$
  select (research.submit_package(jsonb_build_object(
    'schema_version', '0.1', 'title', p_title, 'visibility', 'listed', 'edges', '[]'::jsonb,
    'claims',  jsonb_build_array(jsonb_build_object('id', 'C1', 'kind', 'Inference', 'text', p_claim,
                                                    'source_ids', '["S1"]'::jsonb)),
    'sources', jsonb_build_array(jsonb_build_object('id', 'S1', 'title', p_title, 'origin', p_title,
                                                    'url', 'https://example.com/' || md5(p_title))))) ->> 'revision_id')::uuid
$$;
select claims.pose_question('Should the harbour analytics move off Postgres?');
select claims.pose_question('Should an agent''s memory record when each fact became true?');
select claims.pose_question('Is a method validated at one clinic valid at another hospital?');

select claims.propose_answer(pg_temp.note('Berth log benchmark, March',
         'DuckDB scanned a year of berth logs in 4 seconds where Postgres took 41.'), 'C1', (select id from claims.questions where phrasing = 'Should the harbour analytics move off Postgres?'), 'yes');
select claims.propose_answer(pg_temp.note('Ops review, April',
         'Postgres already holds the berth logs and every permission on them; a second store doubles both.'), 'C1', (select id from claims.questions where phrasing = 'Should the harbour analytics move off Postgres?'), 'no');
select claims.propose_answer(pg_temp.note('Agent memory notes',
         'An assistant that dates a fact by when it was stored answers questions about the past wrongly.'), 'C1', (select id from claims.questions where phrasing = 'Should an agent''s memory record when each fact became true?'), 'yes');
select claims.propose_answer(pg_temp.note('Clinical transfer study',
         'A triage method validated in one hospital lost a third of its accuracy in two others.'), 'C1', (select id from claims.questions where phrasing = 'Is a method validated at one clinic valid at another hospital?'), 'no');
insert into aiq.embedding_models (name, dim, provider, endpoint, credential_ref, notes)
values ('text-embedding-3-small', 1536, 'openai', 'https://api.openai.com/v1/embeddings', 'LLM_API_KEY',
        'called by the worker with the key it holds as LLM_API_KEY; no secret is stored here')
on conflict (name) do nothing;
set role app_owner;
select aiq.register_embedding_space('text-embedding-3-small');
reset role;
select claims.install_fact_question_workflow('text-embedding-3-small');
insert into content.channels (name, kind, visibility) values ('notes', 'manual', 'public') on conflict do nothing;
select content.install_text_embed_workflow('text-embedding-3-small');

select content.register_text('notes', 'standup-0303', $j$[{"content":
  "Standup, 3 March. P. Raman: the berth log scans are too slow in Postgres; DuckDB read a year of them in four seconds. Wants to try it for the harbour analytics."}]$j$) ->> 'resource_id' as standup;
select content.register_text('notes', 'review-0420', $j$[{"content":
  "Ops review, 20 April. Keep the berth logs in Postgres: the permissions live there, and a second store doubles the access rules. Revisit after the Tide Dashboard ships."}]$j$) ->> 'resource_id' as review;

select workflow.start_workflow('embed_text', jsonb_build_object('resource_id', id)) as embed_run
  from content.resources where external_id in ('standup-0303', 'review-0420');

select workflow.define_yaml($y$
name: ask_notes
steps:
  - id: search
    p8ql: 'SEARCH "{{run.question}}" FROM chunks USING text-embedding-3-small LIMIT 1'
  - id: questions
    p8ql: 'SEMANTIC "{{run.question}}" FROM questions USING text-embedding-3-small LIMIT 2'
$y$);
select now() as before_withdrawal \gset
select claims.withdraw_answer(r.evidence, r.claim_key, r.question_id)
  from claims.answered r join claims.questions q on q.id = r.question_id
 where q.phrasing = 'Should the harbour analytics move off Postgres?' and r.stance = 'no';

select c.stance_then, c.stance_now, c.change
  from claims.questions q, claims.stance_changes(q.id, :'before_withdrawal', now()) c
 where q.phrasing = 'Should the harbour analytics move off Postgres?';
-- In one transaction now() does not move and an answer added and withdrawn in it never held at any instant, so
-- stance_changes has nothing to say here; the live run (dev/examples/advanced-memory) shows its output. This reads the
-- withdrawal as the row it is.
select pg_temp.check(exists (select 1 from claims.answered a join claims.questions q on q.id = a.question_id
                              where q.phrasing = 'Should the harbour analytics move off Postgres?'
                                and a.stance = 'no' and a.op = 'retract'),
    '§2 the Ops review answer should be withdrawn as a retract row, not deleted');
select pg_temp.check((select count(*) from claims.answered a join claims.questions q on q.id = a.question_id
                       where q.phrasing = 'Should the harbour analytics move off Postgres?' and a.op = 'assert') = 2,
    '§2 both original answers should still be rows beside the withdrawal');

-- §3
select e ->> 'code' as code, e -> 'evidence' as evidence
  from jsonb_array_elements(aiq.query('TEXT "berth" FROM chunks LIMIT 1') -> 'exceptions') e;
select e ->> 'code' as code, e ->> 'prompt' as prompt
  from jsonb_array_elements(aiq.query('TEXT "zeppelin" FROM chunks') -> 'exceptions') e;
select pg_temp.check((aiq.query('TEXT "berth" FROM chunks LIMIT 1') -> 'exceptions' -> 0 ->> 'code') = 'TRUNCATED_AT_LIMIT',
    '§3 TEXT with more matches than its limit should say so');
select round, entity_type, resolved, jsonb_pretty(path) as path
  from aiq.iterated_join('tool/duckdb', 'person', 3);
select round, resolved, path ->> 'reason' as reason
  from aiq.iterated_join('tool/duckdb', 'company', 2);
select pg_temp.check((select bool_and(resolved) from aiq.iterated_join('tool/duckdb', 'person', 3)) is true,
    '§3 the walk from DuckDB should reach Priya');
select pg_temp.check((select bool_or(resolved) from aiq.iterated_join('tool/duckdb', 'company', 2)) is false,
    '§3 the walk to a company should stop at its bound');

do $$ begin raise notice 'query/20: part three''s model-free blocks run as written'; end $$;
rollback;
