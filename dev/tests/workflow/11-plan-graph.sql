-- THE PLAN GRAPH -- a definition expanded along what it names, and the
-- reaches that do not resolve.
--
-- `schema.sql`'s plan-graph section, plus the two facets that make it more
-- than a step list: `agentic.plan_facet()` and `aiq.plan_facet()`.
--
-- What is worth asserting here, and why it is not "the graph has N nodes":
--
--   1. THE CATALOG IS THE CALLER'S. p8_plan_graph makes no query -- it is
--      handed what plan_catalog() could see. §1 asserts the sections exist and
--      carry what the registries hold, because everything downstream is a
--      lookup into them and a missing section silently means "cannot judge".
--   2. AN ABSENT SUBSYSTEM IS NOT A DEFECT. §2. The engine installs without
--      agentic and without aiq, and on such a deployment every agent step must
--      still draw and none of them may be reported missing. This is the
--      assertion that stops the graph from being useless on the install the
--      engine was designed to support.
--   3. THE DEFECTS ARE THE POINT. §4-§7. Each one is a plan that compiles,
--      registers, starts, and does something other than what it says -- so
--      each assertion names the failure it prevents rather than the code it
--      expects.
--
-- ONE THING THIS FILE CANNOT DO ON ITS OWN. p8_plan_graph ships in
-- `percolate_parser`, which is compiled: on an image built before it existed,
-- §3 onward SKIP and say so loudly. A green run of this file is therefore
-- evidence about the catalog half unless you see the graph notices at the end
-- -- which is the same honesty check_hot_paths() makes when it refuses to pass
-- on a shallow queue.

\set ON_ERROR_STOP on

begin;

set local role app_owner;

-- ---------------------------------------------------------------------
-- 1. The catalog. Every section a graph can look into, and the registries
--    behind them -- p8ql is registered, and a name nobody registered is
--    absent rather than empty.
-- ---------------------------------------------------------------------
do $$
declare
    v_cat jsonb := workflow.plan_catalog();
    v_missing text[];
begin
    select array_agg(s) into v_missing
    from unnest(array['functions','queues','rate_keys','workflows']) s
    where not v_cat ? s;
    if v_missing is not null then
        raise exception 'plan_catalog is missing engine sections: %', v_missing;
    end if;

    if v_cat #>> '{functions,p8ql,fn}' <> 'workflow.p8ql' then
        raise exception 'plan_catalog does not carry the registered p8ql function: %',
            v_cat->'functions'->'p8ql';
    end if;
    if v_cat->'functions' ? 'no_such_function' then
        raise exception 'plan_catalog invented a function nobody registered';
    end if;

    -- The facets, where the subsystems are installed. Conditional in exactly
    -- the way plan_catalog() is: this test runs against the full stack, but
    -- the assertion has to be about what is present, not about what this
    -- particular image happens to bake.
    if to_regprocedure('agentic.plan_facet()') is not null then
        if not (v_cat ? 'agents' and v_cat ? 'servers') then
            raise exception 'agentic is installed and its facet did not merge';
        end if;
    end if;
    if to_regprocedure('aiq.plan_facet()') is not null then
        if not (v_cat ? 'sources' and v_cat ? 'models') then
            raise exception 'ai-query-layer is installed and its facet did not merge';
        end if;
        -- The column no other view in this collection answers: which models a
        -- corpus is ACTUALLY embedded in, as opposed to which are registered.
        if not (v_cat #> '{sources,chunks,spaces}' @> '"demo-quad-a"'::jsonb) then
            raise exception 'the sample corpus reports no demo-quad-a space: %',
                v_cat #> '{sources,chunks,spaces}';
        end if;
        if v_cat #> '{sources,chunks,spaces}' @> '"text-embedding-3-small"'::jsonb then
            raise exception 'chunks reports a space it has no vectors in -- '
                            'space_populated is answering registration, not data';
        end if;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. A source registered both ways is ONE row, not two.
--
--    `chunks` is a semantic source and a lexical one. A union would have made
--    it two entries in `sources`, and the second would have overwritten the
--    first in the object -- with the lexical row's empty `spaces` winning
--    about half the time, which is a defect that appears and disappears
--    between deployments.
-- ---------------------------------------------------------------------
do $$
declare v_n int;
begin
    if to_regclass('aiq.v_plan_sources') is null then
        raise notice 'workflow/11: SKIPPED source-shape check -- ai-query-layer not installed';
        return;
    end if;
    select count(*) into v_n from aiq.v_plan_sources where name = 'chunks';
    if v_n <> 1 then
        raise exception 'chunks appears % times in v_plan_sources, expected 1', v_n;
    end if;
    if not exists (select 1 from aiq.v_plan_sources
                    where name = 'chunks' and semantic and lexical) then
        raise exception 'chunks is registered semantically AND lexically and the '
                        'view reports only one of them';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. Fixtures for the graph half: four definitions, each one a plan that
--    compiles, registers and starts.
--
--    Written as JSON rather than YAML deliberately -- a spec can reach
--    workflow.definitions three ways (schema.sql §22c) and the graph has to
--    judge the one that never passed the compiler, which is the one nothing
--    else checks.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
-- (a) Sound, as the HAND-WRITTEN PAIR: an embed step and the query that
--     consumes it, ranked against the model that corpus is really embedded
--     in. The engine's own lint refuses a bare SEARCH with no vector, so the
--     pair is the only shape this fixture could take -- which is the shape
--     the split below is about.
('t_pg_sound', '{"steps":[
    {"key":"retrieve__embed", "kind":"http_call", "queue":"http",
     "input":{"embed":{"text":"outage", "model":"demo-quad-a"},
              "url":"http://ollama:11434/api/embeddings", "method":"POST",
              "body":{"model":"demo-quad-a", "prompt":"outage"},
              "jsonpath":"embedding"}},
    {"key":"retrieve", "kind":"sql", "queue":"none", "depends_on":["retrieve__embed"],
     "input":{"function":"p8ql_vec",
              "args":["SEARCH \"outage\" FROM chunks USING demo-quad-a LIMIT 3",
                      "{{steps.retrieve__embed.result}}"]}}
 ]}'),
-- (b) The split. Same corpus, a registered model it has no vectors in. Not an
--     error anywhere at runtime: the query returns rows ranked in a space this
--     corpus was never embedded into.
('t_pg_split', '{"steps":[
    {"key":"retrieve__embed", "kind":"http_call", "queue":"http",
     "input":{"embed":{"text":"outage", "model":"text-embedding-3-small"},
              "url":"https://api.openai.com/v1/embeddings", "method":"POST",
              "body":{"model":"text-embedding-3-small", "input":"outage"},
              "jsonpath":"data.0.embedding"}},
    {"key":"retrieve", "kind":"sql", "queue":"none", "depends_on":["retrieve__embed"],
     "input":{"function":"p8ql_vec",
              "args":["SEARCH \"outage\" FROM chunks USING text-embedding-3-small LIMIT 3",
                      "{{steps.retrieve__embed.result}}"]}}
 ]}'),
-- (c) A throttle nobody created. claim_task calls try_consume_rate_limit,
--     which updates no row and returns false -- forever.
('t_pg_throttle', '{"steps":[
    {"key":"call", "kind":"http_call", "queue":"http", "rate_key":"t_pg_nonesuch",
     "input":{"url":"https://example.invalid/v1/x"}}
 ]}'),
-- (d) An agent nobody registered, reached the way the compiler emits it.
('t_pg_ghost', '{"steps":[
    {"key":"classify", "kind":"http_call", "queue":"http",
     "input":{"url":"{{env.P8_AGENT_URL}}/v1/chat/completions",
              "body":{"model":"t_pg_no_such_agent"}}}
 ]}');

-- ---------------------------------------------------------------------
-- 4-7. The graph itself, where the compiled half is installed.
-- ---------------------------------------------------------------------
do $$
declare
    v_g     jsonb;
    v_codes text[];
    v_nodes text[];
begin
    if to_regprocedure('p8_plan_graph(jsonb,jsonb)') is null then
        raise notice '========================================================';
        raise notice 'workflow/11: SKIPPED the graph half -- the installed';
        raise notice 'workflow/11: percolate_parser has no p8_plan_graph. Only';
        raise notice 'workflow/11: the catalog (§1-§2) was proven. Rebuild the';
        raise notice 'workflow/11: extension image to run §4-§7.';
        raise notice '========================================================';
        return;
    end if;

    -- 4. A sound plan has no errors, and the data flow is IN the graph: the
    --    step reads the corpus, and the corpus is ranked in the model.
    v_g := workflow.plan_graph('t_pg_sound');
    if (v_g #>> '{stats,errors}')::int <> 0 then
        raise exception 'a sound plan reported % errors: %',
            v_g #>> '{stats,errors}', v_g->'defects';
    end if;
    if not (v_g->'edges' @> '[{"from":"step:retrieve","to":"source:chunks","kind":"reads"}]'::jsonb) then
        raise exception 'the query step does not reach the corpus it names: %', v_g->'edges';
    end if;
    if not (v_g->'edges' @> '[{"from":"source:chunks","to":"model:demo-quad-a","kind":"ranked_in"}]'::jsonb) then
        raise exception 'the corpus is not linked to the space it ranks in: %', v_g->'edges';
    end if;

    -- 5. THE SPLIT. The compiler pins one model into both halves of the sugar
    --    path; the hand-written pair is outside that guarantee by
    --    construction, and this is where it becomes visible before a run.
    v_g := workflow.plan_graph('t_pg_split');
    select array_agg(d->>'code') into v_codes
      from jsonb_array_elements(v_g->'defects') d;
    if not ('space_model_split' = any(v_codes)) then
        raise exception 'ranking a corpus in a space it was never embedded into was '
                        'not reported: %', v_codes;
    end if;

    -- 6. The unclaimable throttle. An unthrottled step would have run; a step
    --    naming a throttle that does not exist never runs at all, and nothing
    --    else in the collection says so before the queue stops moving.
    v_g := workflow.plan_graph('t_pg_throttle');
    select array_agg(d->>'code') into v_codes
      from jsonb_array_elements(v_g->'defects') d where d->>'severity' = 'error';
    if not ('unknown_rate_key' = any(v_codes)) then
        raise exception 'a rate_key with no rate_limits row was not an error: %', v_codes;
    end if;

    -- 7. The ghost agent -- but ONLY where agentic is installed. Without it
    --    the catalog has no `agents` section, and the graph must draw the node
    --    and stay silent rather than report every agent in the deployment
    --    missing.
    v_g := workflow.plan_graph('t_pg_ghost');
    select array_agg(n->>'id') into v_nodes from jsonb_array_elements(v_g->'nodes') n;
    if not ('agent:t_pg_no_such_agent' = any(v_nodes)) then
        raise exception 'an agent step did not produce an agent node: %', v_nodes;
    end if;
    select array_agg(d->>'code') into v_codes
      from jsonb_array_elements(v_g->'defects') d;
    if to_regprocedure('agentic.plan_facet()') is not null then
        if not ('unknown_agent' = any(coalesce(v_codes, '{}'))) then
            raise exception 'agentic is installed and a missing agent was not reported: %',
                v_codes;
        end if;
    else
        if 'unknown_agent' = any(coalesce(v_codes, '{}')) then
            raise exception 'agentic is NOT installed and the graph reported its agents '
                            'missing -- absence of a subsystem is not a defect';
        end if;
    end if;

    -- The audit shape, over everything: plan_defects walks the current version
    -- of every definition on ONE catalog, which is the form a deployment gate
    -- wants.
    if not exists (select 1 from workflow.plan_defects()
                    where workflow = 't_pg_throttle' and code = 'unknown_rate_key') then
        raise exception 'plan_defects() did not surface a defect plan_graph() reports';
    end if;
    if exists (select 1 from workflow.plan_defects('t_pg_sound') where severity = 'error') then
        raise exception 'plan_defects() reported an ERROR against the sound plan: %',
            (select array_agg(code) from workflow.plan_defects('t_pg_sound'));
    end if;

    -- AND THE WARNING IT DOES REPORT IS TRUE, which running this found.
    --
    -- The sound plan's embed step is claimed from `http`, and the shipped
    -- sample deployment has NO workflow.queue_config rows at all -- so the
    -- queue every worker in the compose stack polls has no configured lease
    -- and no lookahead, and runs on claim_task's and the reaper's fallbacks
    -- (20, and two minutes). Nothing else in the collection says so: the
    -- fallbacks are correct code, and a queue that works is indistinguishable
    -- from a queue that was configured. Asserted rather than tolerated,
    -- because the day somebody adds a row for `http` this line should be the
    -- thing that notices.
    if not exists (select 1 from workflow.plan_defects('t_pg_sound')
                    where code = 'unconfigured_queue' and node = 'queue:http') then
        raise exception 'the http queue is configured now, or the warning stopped working '
                        '-- either way this assertion needs rewriting';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 8. THE DOCUMENT EXPANDS WHERE THE STEP USES IT.
--
-- plan_graph answers "does this resolve"; plan_document answers "what does
-- this pipeline actually say". The assertion that matters is not that the
-- document exists, it is that the ENTITY IS INLINE -- an agent's prompt at the
-- step that asks it, a corpus's columns at the step that reads it. A document
-- that named them and made you go looking would be the graph with extra steps.
-- ---------------------------------------------------------------------
do $$
declare
    v_doc  jsonb;
    v_step jsonb;
begin
    if to_regprocedure('p8_plan_document(jsonb,jsonb)') is null then
        raise notice 'workflow/11: SKIPPED the document -- installed parser has no p8_plan_document';
        return;
    end if;

    v_doc := workflow.plan_document('t_pg_sound');

    -- Steps come out in rank order, so the document reads as the pipeline runs.
    if v_doc #>> '{steps,0,id}' <> 'retrieve__embed'
       or v_doc #>> '{steps,1,id}' <> 'retrieve' then
        raise exception 'the document is not in rank order: %',
            (select jsonb_agg(x->>'id') from jsonb_array_elements(v_doc->'steps') x);
    end if;

    v_step := v_doc #> '{steps,1}';
    if v_step #>> '{reads,table}' <> 'content.resource_chunks' then
        raise exception 'the corpus was not expanded at the step that reads it: %',
            v_step->'reads';
    end if;
    if jsonb_array_length(coalesce(v_step #> '{reads,columns}', '[]'::jsonb)) = 0 then
        raise exception 'the corpus expanded without its columns -- "how data moves through '
                        'the schema" is the question this is for';
    end if;
    if v_step #>> '{calls,description}' is null then
        raise exception 'the step function expanded without what it does';
    end if;

    -- And the agent case: the prompt IS the intent, so it has to be here.
    if to_regprocedure('agentic.plan_facet()') is not null
       and exists (select 1 from agentic.agents) then
        declare v_agent text; v_doc2 jsonb;
        begin
            select name into v_agent from agentic.agents order by name limit 1;
            insert into workflow.definitions (name, spec) values
            ('t_pg_agentic', jsonb_build_object('steps', jsonb_build_array(
                jsonb_build_object(
                    'key', 'ask', 'kind', 'http_call', 'queue', 'http',
                    'input', jsonb_build_object(
                        'url', '{{env.P8_AGENT_URL}}/v1/chat/completions',
                        'body', jsonb_build_object('model', v_agent))))));
            v_doc2 := workflow.plan_document('t_pg_agentic');
            if v_doc2 #>> '{steps,0,calls,agent}' <> v_agent then
                raise exception 'the agent step did not expand its agent: %',
                    v_doc2 #> '{steps,0}';
            end if;
            if coalesce(v_doc2 #>> '{steps,0,calls,system_prompt}', '') = '' then
                raise exception 'the agent expanded without its prompt, which is its intent';
            end if;
            if v_doc2 #>> '{steps,0,about}' not like 'asks agent %' then
                raise exception 'the one-line summary does not say what the step does: %',
                    v_doc2 #>> '{steps,0,about}';
            end if;
        end;
    end if;
end $$;

do $$
begin
    raise notice 'workflow/11: plan_catalog carries every section a graph looks into, from the registries';
    raise notice 'workflow/11: a corpus registered semantically and lexically is one row, with the spaces it HAS';
    raise notice 'workflow/11: a sound plan reaches its corpus and the space that corpus is ranked in';
    raise notice 'workflow/11: ranking a corpus in a space it was never embedded into is reported before the run';
    raise notice 'workflow/11: a rate_key with no rate_limits row is an error -- the task would never be claimed';
    raise notice 'workflow/11: an agent nobody registered is a node AND a defect; an absent subsystem is neither';
    raise notice 'workflow/11: the document reads in rank order, with the corpus and the agent expanded where they are used';
end $$;

rollback;
