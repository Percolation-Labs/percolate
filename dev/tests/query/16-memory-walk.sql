-- ONE WALK THROUGH THE GRAPH MEMORY -- write, reconcile, query, as of a date,
-- and the questions graph beside it. The blocks of "Advanced Percolate memory
-- and semantic iteration" (specs/design/core-product.md §2.3) are these
-- statements, so the article goes red when this file does (§1: an article is
-- a test).
--
-- Every other file in this directory asserts one surface at its boundaries.
-- This one asserts that the surfaces compose in the order a memory system uses
-- them: two sessions knit the same fact, a third knits a wrong one, a later
-- pass binds an alias and withdraws the bad run, and the graph answers before
-- and after. Each piece is tested harder elsewhere (10, 14, 15, research/36);
-- what only this file can fail is the hand-off between them.
--
-- Two behaviours are asserted AS THEY ARE, because the article prints them and
-- a reader will hit them: a relation outside the vocabulary is dropped until
-- registered, and a soft node answers LOOKUP by its bare name (REM-995).
-- If either changes, this file fails and the article is corrected with it.
--
-- Every comparison is `is distinct from`, not `<>`: a missing row is NULL, and
-- `if NULL <> 1` is false, so the first draft passed with the stance it checks
-- deleted. pg_temp.check refuses anything but true for the same reason.
--
-- THE ARTICLE'S BLOCKS ARE THE TOP-LEVEL STATEMENTS HERE, word for word, so a
-- reader can paste them into psql in order (dev/article-blocks.py holds the two
-- to each other). Ids and receipts pass between steps with \gset, never through
-- plpgsql variables, and each step's assertion follows it as a separate
-- `select pg_temp.check(...)` that is not part of the article.
--
-- Reads the committed samples (dev/init/04-graph-sample.sql for Priya Raman,
-- 05-corpus-sample.sql for the chunks). One transaction, rolled back.

\set ON_ERROR_STOP on

begin;
set local role app_owner;

create or replace function pg_temp.parser_current() returns boolean language sql stable as $$
    select coalesce((select p.extversion = c.extversion
                       from pg_catalog.pg_extension p, pg_catalog.pg_extension c
                      where p.extname = 'percolate_parser' and c.extname = 'percolate'), false)
       and coalesce(current_setting('percolate.parser_behind', true), 'absent') <> 'yes';
$$;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
    if p_ok is not true then
        raise exception 'memory walk: %', p_what;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- (Each knit names its run, not a resource: since REM-962 a resource_id must
--  name a real resource, whose owner and visibility the facts then take.)
-- 1. THE VOCABULARY IS CLOSED UNTIL YOU OPEN IT. The first session's two
--    relations are dropped and named in the receipt, and its nodes land.
-- ---------------------------------------------------------------------
select aiq.upsert_graph('{"nodes":[{"k":"person","n":"Priya Raman"},{"k":"project","n":"Harbour Rewrite"},{"k":"tool","n":"Postgres"}], "edges":[{"s":0,"t":1,"r":"works_on"},{"s":0,"t":2,"r":"prefers"}]}', '{"agent":"knit","run_id":"r1"}') as receipt \gset
\echo :receipt
select pg_temp.check(:'receipt'::jsonb->'node_residence' = '["pg","soft","soft"]'::jsonb,
    'Priya Raman did not land on her typed row, or the new names did not land soft: ' || :'receipt');
select pg_temp.check((:'receipt'::jsonb->>'edges_new')::int = 0
    and (select array_agg(r order by r) from jsonb_array_elements_text(:'receipt'::jsonb->'edges_dropped_unknown_relation') r)
        = '{prefers,works_on}', 'an unregistered relation was not dropped and named: ' || :'receipt');

select aiq.register_graph_vocabulary('[{"relation":"works_on"},{"relation":"prefers"}]');

select aiq.upsert_graph('{"nodes":[{"k":"person","n":"Priya Raman"},{"k":"project","n":"Harbour Rewrite"},{"k":"tool","n":"Postgres"}], "edges":[{"s":0,"t":1,"r":"works_on"},{"s":0,"t":2,"r":"prefers"}]}', '{"agent":"knit","run_id":"r1"}') as receipt \gset
\echo :receipt
select pg_temp.check((:'receipt'::jsonb->>'edges_new')::int = 2, 'the registered relations did not land: ' || :'receipt');

-- ---------------------------------------------------------------------
-- 2. KNIT: a second session repeats one fact, which is one edge with two
--    sources, and names an alias. A third, from a bad extractor, is wrong.
-- ---------------------------------------------------------------------
select aiq.upsert_graph('{"nodes":[{"k":"person","n":"Priya Raman"},{"k":"project","n":"Harbour Rewrite"},{"k":"person","n":"P. Raman"},{"k":"tool","n":"DuckDB"}], "edges":[{"s":0,"t":1,"r":"works_on"},{"s":2,"t":3,"r":"prefers"}]}', '{"agent":"knit","run_id":"r2"}') as receipt \gset
\echo :receipt
select pg_temp.check((:'receipt'::jsonb->>'edges_merged')::int = 1 and (:'receipt'::jsonb->>'edges_new')::int = 1,
    'the repeated fact did not merge into the existing edge: ' || :'receipt');
select pg_temp.check((select array_agg(s->>'run_id' order by s->>'run_id')
                        from aiq.edges e join aiq.node_keys k on k.node_id = e.src_id and k.key = 'priya raman',
                             jsonb_array_elements(e.provenance->'sources') s
                       where e.relation = 'works_on') = '{r1,r2}',
    'one fact from two sessions is not one edge with both sources');

select aiq.upsert_graph('{"nodes":[{"k":"person","n":"Priya Raman"},{"k":"tool","n":"MySQL"}], "edges":[{"s":0,"t":1,"r":"prefers"}]}', '{"agent":"knit-bad","run_id":"r3"}');

-- This walk takes seconds, so the three sessions are dated a day back to give
-- the as-of read in §5 a past to read.
update aiq.edges set valid_from = now() - interval '1 day' where provenance->'sources' @> '[{"run_id":"r1"}]' or provenance->'sources' @> '[{"run_id":"r2"}]' or provenance->'sources' @> '[{"run_id":"r3"}]';

-- ---------------------------------------------------------------------
-- 3. RECONCILE: bind the alias to the person, and withdraw the bad run.
--    The alias's edge moves to Priya and its name stays a key; the bad edge
--    is retracted with its provenance intact, not deleted.
-- ---------------------------------------------------------------------
select id as alias from aiq.soft_nodes where claimed_kind = 'person' and key = 'p. raman' \gset
select node_id as priya from aiq.node_keys where key = 'priya raman' \gset
select aiq.promote_soft_node(:'alias', :'priya', 'dream', 'llm', '{"why":"same surname, same project, same week"}') as receipt \gset
\echo :receipt
select pg_temp.check((:'receipt'::jsonb->>'moved')::int = 1 and :'receipt'::jsonb->'name'->>'kept' = 'true',
    'the alias was not bound with its edge and its name: ' || :'receipt');

select aiq.retract_derived('knit-bad') as receipt \gset
\echo :receipt
select pg_temp.check((:'receipt'::jsonb->>'retracted')::int = 1,
    'withdrawing one bad run did not retract its one edge: ' || :'receipt');
select pg_temp.check((select count(*) from aiq.edges e join aiq.node_keys k on k.node_id = e.dst_id
                       where e.src_id = :'priya' and k.key = 'tool/mysql'
                         and e.valid_to is not null and e.provenance->'sources' @> '[{"run_id":"r3"}]') = 1,
    'the bad edge is gone instead of retracted with its provenance');

-- ---------------------------------------------------------------------
-- 4. QUERY, in one dialect: the alias resolves to the person, the walk sees
--    the moved edge and not the retracted one, and a soft node answers to its
--    kind-prefixed key only. Each read is the article's statement, then the
--    same read asserted.
-- ---------------------------------------------------------------------
select aiq.query('FUZZY LOOKUP "raman"');
select pg_temp.check(aiq.query('FUZZY LOOKUP "raman"')->'rows'->0->>'node_id' = :'priya',
    'the bound alias does not resolve to the person');

select aiq.query('GRAPH "Priya Raman" DEPTH 1');
select pg_temp.check((select array_agg(r->>'key' order by r->>'key')
                        from jsonb_array_elements(aiq.query('GRAPH "Priya Raman" DEPTH 1')->'rows') r
                       where r->>'key' like 'tool/%' or r->>'key' like 'project/%')
                     = '{project/harbour rewrite,tool/duckdb,tool/postgres}',
    'the walk after reconcile should see the moved DuckDB edge and no MySQL');

select aiq.query('LOOKUP "Harbour Rewrite"');
select pg_temp.check(aiq.query('LOOKUP "Harbour Rewrite"')->'rows'->0->>'key' = 'project/harbour rewrite',
    'a soft node does not answer its bare name (REM-995)');
select aiq.query('LOOKUP "project/harbour rewrite"');
select pg_temp.check(aiq.query('LOOKUP "project/harbour rewrite"')->'rows'->0->>'key' = 'project/harbour rewrite',
    'a soft node does not answer its kind-prefixed key');

-- The same dialect reads the corpus: SEMANTIC over the sample's literal vectors.
select pg_temp.check(aiq.query('SEMANTIC "anything" FROM chunks USING demo-quad-a LIMIT 1', '[1,0,0,0]')->'rows'->0->>'chunk_id'
                     = '33330000-0000-0000-0000-000000000001',
    'SEMANTIC through the dialect did not rank the sample''s nearest chunk first');

-- ---------------------------------------------------------------------
-- 5. AS OF A DATE: an hour ago the graph still believed the bad run; now it
--    does not. Ranked reads go through the compiled snapshot, which a write in
--    the same backend does not refresh, so it is rebuilt first.
-- ---------------------------------------------------------------------
select pg_temp.parser_current() as parser_ok \gset
\if :parser_ok
select aiq.graph_snapshot(true);
select key from aiq.related(array['priya raman'], 10, 'prefers', 250, now() - interval '1 hour');
select key from aiq.related(array['priya raman'], 10, 'prefers');
select pg_temp.check((select array_agg(key order by key) from aiq.related(array['priya raman'], 10, 'prefers', 250, now() - interval '1 hour')
                       where key like 'tool/%') is not distinct from '{tool/duckdb,tool/mysql,tool/postgres}',
    'as of an hour ago the bad run''s MySQL should still be believed');
select pg_temp.check((select array_agg(key order by key) from aiq.related(array['priya raman'], 10, 'prefers')
                       where key like 'tool/%') is not distinct from '{tool/duckdb,tool/postgres}',
    'now the retracted MySQL should be gone: retraction must be history');
\else
\echo 'DEFERRED: query/16 §5 as-of through related -- the compiled parser is behind the extension SQL'
\endif

-- ---------------------------------------------------------------------
-- 6. THE QUESTIONS GRAPH sits beside the memory graph, over research works:
--    the writer's agent poses a question, proposes a stance from a claim, and
--    the web shows it, proposed until the writer confirms it. (research/36 asserts its rules; this is the walk's last step.)
-- ---------------------------------------------------------------------
reset role;
insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-000000016aa1', 'walk-writer@example.test', 'active');
insert into rbac.roles (name, description) values ('rp-walk-lister', 'may list research (test)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('rp-walk-lister', 'research', 'list') on conflict do nothing;
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-000000016aa1', 'rp-walk-lister');
insert into rbac.api_keys (id, user_id, label, key_hash, scopes) values
    ('00000000-0000-4000-8000-000000016dd4', '00000000-0000-4000-8000-000000016aa1', 'walk-agent', 'walk-k1',
     '{research:select,research:insert}');
create temporary table walk_ids (k text primary key, v uuid) on commit drop;
grant all on walk_ids to authenticated;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000016aa1"}';
set local role authenticated;
insert into walk_ids select 'rev', (research.submit_package('{"schema_version": "0.1", "edges": [],
    "title": "Harbour Rewrite notes", "visibility": "listed",
    "sources": [{"id": "S1", "title": "Session 2", "url": "https://example.com/s2", "origin": "Session"}],
    "claims": [{"id": "C1", "kind": "Inference", "text": "Moving the harbour analytics to DuckDB cut the nightly run.",
                "source_ids": ["S1"]}]}'::jsonb, null, 'rp-walk')->>'revision_id')::uuid;
-- The writer's agent, through its key: what it proposes lands proposed.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000016aa1", "api_key_id": "00000000-0000-4000-8000-000000016dd4"}';
do $$
declare q uuid; w record;
begin
    q := claims.pose_question('Should the harbour analytics move off Postgres?');
    perform claims.propose_answer((select v from walk_ids where k = 'rev'), 'C1', q, 'yes', 0.7::real);
    select * into w from claims.question_web(now(), 1) where question = q;
    if w.works is distinct from 1 or w.answers->0->>'stance' is distinct from 'yes'
       or w.answers->0->>'status' is distinct from 'proposed' then
        raise exception 'the question web does not show the agent''s proposed stance: %', coalesce(w::text, 'nothing');
    end if;
end $$;
reset role;

do $$ begin raise notice 'query/16: knit, reconcile, query, as-of and a question compose in one walk'; end $$;

rollback;
