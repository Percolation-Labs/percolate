-- ============================================================
-- ai-query-layer <-> workflow-engine integration.
--
-- Applied AFTER both schemas, as app_owner. Split out for the same reason
-- workflow-engine/integration-rbac.sql is: each core must stay deployable on
-- its own, and anything crossing a boundary belongs in one file applied last.
--
-- Caught by verifying a clean install rather than by reading: putting
-- workflow.p8ql() in workflow-engine/schema.sql made that file reference
-- aiq.query(), and the install failed at step 2 with `schema "aiq" does not
-- exist` -- because workflow loads before ai-query-layer. A workflow engine
-- that cannot be installed without a query layer is not the workflow engine
-- this collection specs.
-- ============================================================

-- Two arities. SEMANTIC and SEARCH need a vector, which the database cannot
-- produce -- embedding is an external model call. So those modes are composed
-- as: a `rest` step that embeds, then a p8ql step taking
-- {{steps.embed.result}} as its second argument. LOOKUP, GRAPH and TEXT need
-- no vector and use the one-argument form.
-- SQL MODE IS EXECUTED HERE, and for a while it silently was not.
--
-- aiq.query deliberately does not run a SQL-mode query: it returns the
-- statement and a note saying to run it through the SECURITY INVOKER
-- passthrough, so that function's own security mode stays irrelevant to
-- caller-supplied SQL (schema.sql §9). As a workflow step that produced a task
-- marked DONE whose result was the note -- a step that succeeds and answers
-- nothing, found by writing the obvious `p8ql: "select ..."` in a real pipeline
-- and getting a green run with no rows.
--
-- So the note is honoured rather than returned: the statement goes through
-- aiq.sql_passthrough, which is SECURITY INVOKER and read-only-enforced. That
-- keeps the property the note was protecting -- inside a step the invoker is
-- the engine owner, so the query is as expressive as the rest of the step
-- path; called directly by an authenticated user it runs as THEM, under RLS.
-- Routing it through the DEFINER workflow.run_sql instead would have handed
-- every caller of this function an owner-privileged read of the whole database,
-- which is the escalation this collection has fixed twice already.
create or replace function workflow.p8ql(p_query text)
returns jsonb as $$
declare v_out jsonb;
begin
    v_out := aiq.query(p_query);
    if v_out->>'mode' = 'SQL' then
        -- AND THE POLICY THAT TURNS THE TRADE OFF HAS TO REACH THIS DOOR TOO.
        --
        -- workflow-engine/schema.sql states the trade plainly: inside a step,
        -- SQL runs as the engine owner and "anyone who may define a workflow
        -- may therefore read anything in the database", deliberate for the
        -- beta, with `percolate.sql_policy = 'registered'` as the lever that
        -- refuses statements on a deployment that will not take it.
        --
        -- That lever did not cover this path. `sql: "select ..."` is refused at
        -- define time by check_spec_before_insert; `p8ql: "select ..."` is not
        -- a `statement` in the spec -- it compiles to the registered function
        -- `p8ql` with the query as an argument -- so it never reached the
        -- check, and executed as app_owner on a deployment whose operator had
        -- explicitly locked statements out. Measured, same database, same
        -- policy: the sql: form refused at authoring, the p8ql: form returning
        -- `current_user = app_owner`. A control that reports success while the
        -- thing it guards stays open is the failure this collection keeps
        -- finding, and this is it in the one place a reader was told to trust.
        --
        -- CHECKED AT EXECUTION, NOT ONLY AT AUTHORING, and the distinction is
        -- load-bearing: a definition written while the policy was `open`
        -- outlives the change, so refusing only at define time would leave
        -- every workflow authored before the lock still able to run.
        --
        -- ONLY INSIDE A STEP. `workflow.current_run_id` is set by
        -- execute_sql_step and by nothing else, so it is the signal for "the
        -- invoker is the engine owner". Called directly by an authenticated
        -- user this function is SECURITY INVOKER running as THEM under RLS --
        -- which is safe, is what the grant below is for, and is not what the
        -- policy is about.
        -- TWO NESTED `if`s, NOT ONE `and`, and that is not style.
        -- `workflow.sql_policy()` is not granted to `authenticated`, and
        -- plpgsql evaluates a whole condition as a single SELECT -- so both
        -- the flat `and` form AND the one-if version raised `permission denied
        -- for function sql_policy` on the DIRECT call, which is the one path
        -- this check exists to leave alone. Observed twice, at line 36 and
        -- then at line 43, before splitting the statements. The alternative
        -- was to widen a grant so a guard could run, which is the wrong
        -- direction: the guard should not need privileges the caller lacks.
        if nullif(current_setting('workflow.current_run_id', true), '') is not null then
          if workflow.sql_policy() = 'registered' then
            raise exception
                'this step carries plain SQL, and percolate.sql_policy is '
                '''registered'' on this deployment -- inside a step it would run '
                'as the engine owner, which is the read this policy exists to '
                'refuse. Register the query as a step function and name it with '
                'sql: {function: ...}, or run the SQL directly, where it is '
                'scoped to you.';
          end if;
        end if;
        return jsonb_build_object(
            'mode', 'SQL',
            'statement', v_out->>'statement',
            'rows', aiq.sql_passthrough(v_out->>'statement'));
    end if;
    return v_out;
end;
$$ language plpgsql;

create or replace function workflow.p8ql(p_query text, p_embedding jsonb)
returns jsonb as $$
    select aiq.query(p_query,
        case when p_embedding is null or p_embedding = 'null'::jsonb then null
             else (select array_agg((v #>> '{}')::real order by ord)
                   from jsonb_array_elements(p_embedding) with ordinality t(v, ord))::vector
        end);
$$ language sql;

grant execute on function workflow.p8ql(text) to authenticated, worker;
grant execute on function workflow.p8ql(text, jsonb) to authenticated, worker;

-- Register P8QL as a workflow step function, so `p8ql:` in a YAML workflow
-- resolves. Registration is owner-only (§17), so this is the deployment
-- deciding that queries may run as steps -- not something a workflow author
-- can grant themselves.
select workflow.register_step_function(
    'p8ql', 'workflow.p8ql', array['text'], 30000,
    'Run a P8QL query as a workflow step');
select workflow.register_step_function(
    'p8ql_vec', 'workflow.p8ql', array['text','jsonb'], 30000,
    'P8QL with an embedding produced by a prior step');

-- ============================================================
-- Embed steps: the half of a vector search the database cannot do.
--
-- The two arities above are the mechanism, and for a long time they were also
-- the interface: an author wrote the `rest:` call to a model by hand, then
-- passed {{steps.embed.result}} into p8ql_vec. That has two defects, and only
-- the first is ergonomic.
--
--  1. The url, the request body's shape and the path to the vector in the
--     response are deployment facts written into a document that outlives
--     deployments. Two workflows in one database embed differently against the
--     same model because two people wrote two `rest:` blocks.
--
--  2. NOTHING TIED THE TWO HALVES TOGETHER. The embed step names a model, the
--     query names a space with USING (or takes the default), and if those two
--     disagree the run does not fail -- aiq.semantic_in only checks the
--     DIMENSION, so two 768-dim models produce a cosine distance that is a
--     number and not an answer. §10 says this in the strongest terms it has
--     ("meaningless, not merely imprecise") and then left the workflow author
--     to hold both ends of it by hand.
--
-- So the compiler emits a MARKER -- an http_call whose input is
-- {"embed": {"text": ..., "model": ...}} and no url -- and this function turns
-- it into an ordinary REST call at DEFINITION time, from the registry. Three
-- consequences worth stating:
--
--   * The shipped worker needs no new handler. After expansion this is an
--     http_call like any other, on the queue the author named, with retry,
--     backoff, the reaper and tracing already applying. An `embed:` step is
--     not a new deployable and not a new execution path.
--   * The model is resolved ONCE and pinned into BOTH halves -- written into
--     the query as `USING <model>` if it was not already there, and refused if
--     it was there and disagrees. The invariant the two-step form could not
--     hold is now unstatable in a stored definition.
--   * It resolves at definition time rather than dispatch, so the answer is
--     visible in workflow.definitions.spec. A run does not re-decide which
--     model it meant because someone moved is_default in between.
-- ============================================================
-- ONE marker becomes ONE call, and it is a function rather than a block
-- because there are two places a marker can be: a step, and the template a
-- matrix step fans out. The second was missed on the first pass -- the
-- compiler accepted `template: {embed: ...}`, nothing expanded it, and every
-- child was created as an http_call with no url, failing at dispatch N times
-- with a message about a document nobody wrote. Found by asking where else a
-- step can hide, which is the question `matrix` has now answered wrongly
-- three times (nested fan-out, the successors that had to be rewired, this).
create or replace function aiq.embed_call(p_marker jsonb, p_step_key text)
returns jsonb as $$
declare
    v_text  text := p_marker->>'text';
    v_named text := p_marker->>'model';
    v_body  jsonb;
    v_input jsonb;
    m       aiq.embedding_models;
    p       aiq.embedding_providers;
begin
    if v_named is null then
        select * into m from aiq.embedding_models where is_default;
        if not found then
            raise exception
                'step ''%'' embeds text but this deployment has no default embedding '
                'model. Name one with `embed: {text: ..., model: <name>}` (or '
                'USING <model> in the query), or set is_default on a row in '
                'aiq.embedding_models.', p_step_key;
        end if;
    else
        select * into m from aiq.embedding_models where name = v_named;
        if not found then
            raise exception
                'step ''%'' embeds with model ''%'', which is not registered. '
                'SCHEMA "graph" lists the registered ones.', p_step_key, v_named;
        end if;
    end if;

    -- Null is a real answer since embedding_models.provider gained a foreign
    -- key onto embedding_providers: a space whose vectors are written directly
    -- -- the demo fixture spaces -- says so with NULL rather than by inventing
    -- a provider name. It is a different mistake from naming a provider nobody
    -- registered, so it gets a different message; one error for both would send
    -- the reader to the wrong fix, and the generic arm below renders a null as
    -- the literal '<NULL>', which explains nothing.
    if m.provider is null then
        raise exception
            'step ''%'' embeds with model ''%'', whose vectors are written '
            'directly rather than produced here -- it has no provider, so there '
            'is nothing to call. Embed against a model that has one.',
            p_step_key, m.name;
    end if;

    select * into p from aiq.embedding_providers where provider = m.provider;
    if not found then
        raise exception
            'embedding model ''%'' is served by provider ''%'', which has no row in '
            'aiq.embedding_providers -- so nothing here knows what its request '
            'body looks like or where the vector sits in its response.',
            m.name, m.provider;
    end if;

    -- Refused rather than defaulted: a guessed url is a step that 404s on
    -- every run of every workflow that ever names this model, and the message
    -- would name the endpoint rather than the omission.
    if m.endpoint is null then
        raise exception
            'embedding model ''%'' has no endpoint, so step ''%'' has nowhere to send '
            'its text. Set aiq.embedding_models.endpoint -- it may be written as '
            '''{{env.LLM_URL}}/api/embeddings'', which the worker resolves.',
            m.name, p_step_key;
    end if;

    -- Whole VALUES only (§10a): the author's text becomes a jsonb string via
    -- to_jsonb, so quotes, newlines and braces in it are escaped by the
    -- database rather than by a regex of ours.
    select jsonb_object_agg(k,
               case when v = '"{{text}}"'::jsonb  then to_jsonb(v_text)
                    when v = '"{{model}}"'::jsonb then to_jsonb(m.name)
                    else v end)
      into v_body
      from jsonb_each(p.request_template) e(k, v);

    v_input := jsonb_build_object(
        'url',        m.endpoint,
        'method',     p.method,
        'body',       v_body,
        'jsonpath',   p.response_path,
        'timeout_ms', 30000,
        -- Kept beside the call, not consumed by it. It is what makes a task
        -- row say what it IS -- "the embedding of {{run.question}} in
        -- nomic-embed-text" -- rather than leaving a reader to infer an intent
        -- from a url and a body. It is also what makes expansion idempotent: a
        -- marker is recognised by having NO url, so an expanded step cannot be
        -- expanded twice.
        'embed',      jsonb_build_object('text', v_text, 'model', m.name));

    if m.credential_ref is not null then
        v_input := v_input || jsonb_build_object('credential_ref', m.credential_ref);
    end if;
    return v_input;
end;
$$ language plpgsql stable;

grant execute on function aiq.embed_call(jsonb, text) to authenticated;

create or replace function aiq.expand_embed_steps(p_spec jsonb)
returns jsonb as $$
declare
    v_steps   jsonb := '[]'::jsonb;
    v_out     jsonb;
    v_step    jsonb;
    v_models  jsonb := '{}'::jsonb;   -- embed step key -> the model it resolved to
    v_input   jsonb;
    v_ref     text;
    v_plan    jsonb;
    v_query   text;
    v_model   text;
begin
    if p_spec is null or p_spec->'steps' is null then
        return p_spec;
    end if;

    -- Pass 1: every marker becomes a REST call, wherever the marker is.
    for v_step in select * from jsonb_array_elements(p_spec->'steps') loop

        if v_step->>'kind' = 'http_call'
           and v_step->'input' ? 'embed' and not (v_step->'input' ? 'url') then
            v_input  := aiq.embed_call(v_step->'input'->'embed', v_step->>'key');
            v_step   := jsonb_set(v_step, '{input}', v_input);
            v_models := v_models || jsonb_build_object(
                            v_step->>'key', v_input->'embed'->>'model');

        -- A matrix template is a step in every way except that it has no key
        -- of its own, so it needs the same expansion and borrows the parent's
        -- key for any message. There is no model to PIN here, and that is not
        -- an omission: a template is ONE step, so nothing inside it consumes
        -- the vector. A successor reads the children through matrix_outputs,
        -- and the model each child embedded with is recorded on the child.
        elsif v_step->>'kind' = 'matrix'
           and v_step#>'{input,template,input}' ? 'embed'
           and not (v_step#>'{input,template,input}' ? 'url') then
            v_step := jsonb_set(v_step, '{input,template,input}',
                aiq.embed_call(v_step#>'{input,template,input,embed}',
                               (v_step->>'key') || ' (matrix template)'));
        end if;

        v_steps := v_steps || jsonb_build_array(v_step);
    end loop;

    -- Pass 2: pin the model into the query that consumes each vector.
    --
    -- The pairing is read off the DATA FLOW -- a p8ql step whose arguments
    -- reference {{steps.<an embed step>.result}} -- rather than off a marker
    -- the compiler left behind. That is deliberate: it makes the check apply
    -- to the hand-written two-step form exactly as it applies to the sugar,
    -- so the raw spelling is not the one that quietly keeps the old defect.
    v_out := '[]'::jsonb;
    for v_step in select * from jsonb_array_elements(v_steps) loop
        if v_step->>'kind' = 'sql'
           and coalesce(v_step->'input'->>'function', '') in ('p8ql', 'p8ql_vec') then

            v_query := v_step->'input'->'args'->>0;
            v_model := null;
            for v_ref in
                select m2[1] from regexp_matches(v_step::text,
                    '\{\{\s*steps\.([a-zA-Z0-9_-]+)\.result\s*\}\}', 'g') m2
            loop
                if v_models ? v_ref then
                    -- Refused rather than last-one-wins. A query takes ONE
                    -- vector, so a step reading two embeddings is already
                    -- saying something it cannot mean -- and silently pinning
                    -- whichever reference the scan happened to see last is the
                    -- exact shape of bug this whole pass exists to remove.
                    if v_model is not null and v_model <> v_models->>v_ref then
                        raise exception
                            'step ''%'' reads vectors from two embed steps, produced by '
                            '''%'' and ''%''. A query ranks against one embedding, so '
                            'there is no answer to which space it is searching.',
                            v_step->>'key', v_model, v_models->>v_ref;
                    end if;
                    v_model := v_models->>v_ref;
                end if;
            end loop;

            if v_query is not null and v_model is not null then
                execute 'select aiq_parse($1)' into v_plan using v_query;

                -- A query that does not parse is the lint's to report, with
                -- the step key and the parser's own message. Saying it twice,
                -- here, in a function about embeddings, would put the worst
                -- version of that message in front of the author.
                if coalesce((v_plan->>'ok')::boolean, false)
                   and v_plan->>'mode' in ('SEMANTIC', 'SEARCH') then

                    if v_plan->>'model' is null then
                        -- USING takes ONE token, and a registered name is free
                        -- text -- so a model called 'weird model' pinned as
                        -- `USING weird model` made the author's own query stop
                        -- parsing, and the lint then reported `unexpected token
                        -- 'model'` about a query that was correct as written.
                        -- The tokenizer treats a quoted run as one token, so
                        -- quoting is the fix; it is applied only where it is
                        -- needed, so the ordinary case still pins the bare name
                        -- the hand-written form would have.
                        if v_model ~ '[\s,]' then
                            if v_model like '%"%' then
                                raise exception
                                    'embedding model ''%'' cannot be named in a query: it '
                                    'contains a space and a double quote, and USING takes '
                                    'one token. Rename the model.', v_model;
                            end if;
                            v_query := v_query || ' USING "' || v_model || '"';
                        else
                            v_query := v_query || ' USING ' || v_model;
                        end if;
                        v_step := jsonb_set(v_step, '{input,args,0}', to_jsonb(v_query));

                    elsif v_plan->>'model' <> v_model then
                        raise exception
                            'step ''%'' searches the ''%'' space but is handed a vector produced '
                            'by ''%''. Nothing downstream can catch this: cosine distance '
                            'between two embedding spaces is a number, not an answer, and '
                            'the dimension check passes whenever the two models happen to '
                            'be the same width.',
                            v_step->>'key', v_plan->>'model', v_model;
                    end if;
                end if;
            end if;
        end if;
        v_out := v_out || jsonb_build_array(v_step);
    end loop;

    return jsonb_set(p_spec, '{steps}', v_out);
end;
$$ language plpgsql stable;

grant execute on function aiq.expand_embed_steps(jsonb) to authenticated;

comment on function aiq.expand_embed_steps(jsonb) is
    'Turn every `embed:` marker in a compiled workflow spec into an ordinary REST '
    'call from aiq.embedding_models + aiq.embedding_providers, and pin the model it '
    'resolved to into the query that consumes the vector. Called by '
    'workflow.define_yaml; an unexpanded marker is refused by the lint.';

-- ============================================================
-- Landing the vectors: the half of `embed:` that had nowhere to go.
--
-- `embed:` produces a vector and hands it to the next step as a template
-- value. That is exactly right for a QUERY -- embed the question, rank against
-- it, discard the vector -- and it is the entire story this collection had.
-- Embedding a CORPUS is the other direction: N vectors that must be KEPT, in
-- the space of the model that produced them, keyed by the chunk they describe.
--
-- Nothing could do that. `aiq.register_embedding_space()` creates the table
-- and `aiq.semantic_in()` reads it; no function anywhere writes a row into it,
-- so every vector in the collection's only embedding space arrived as a
-- literal in a fixture (dev/init/05-corpus-sample.sql, which says so in
-- capitals). A pipeline that embeds an uploaded document had no last step.
--
-- THE MODEL IS NOT AN ARGUMENT, and that is the point of the shape.
--
-- The obvious signature is land_embeddings(matrix_task, model) -- and it
-- reintroduces, one step later, the exact defect aiq.expand_embed_steps()
-- exists to remove. The author would name the model twice (once on the embed
-- template, once here), the two could disagree, and the result would be
-- vectors from model A sitting in model B's space: no error, no dimension
-- mismatch when the two are the same width, and a corpus that ranks
-- confidently and wrongly forever.
--
-- So the model is read off each child's OWN task input, where embed_call()
-- recorded it -- "the model each child embedded with is recorded on the
-- child", as expand_embed_steps' own comment already promised. The vector and
-- the name of the space it belongs in travel together on one row, and there is
-- no second place to state it and therefore nothing to disagree with.
-- ============================================================
-- SECURITY INVOKER, and it matters that this is not a preference. Its only
-- legitimate caller is workflow.execute_sql_step, which is SECURITY DEFINER
-- and owned by the schema owner -- so an invoker function called from there
-- already runs with the privileges it needs, and gains nothing from carrying
-- them itself. What it gains from NOT carrying them is that a client calling
-- it directly is refused by the grants on aiq.emb_* rather than by this
-- function's own run-id guard alone.
--
-- dev/tests/query/06 enforces exactly this for the whole aiq schema, with a
-- named exemption list and a comment about why a named list is dangerous --
-- "the function added next month is the one that is not on it". This was that
-- function, and the test caught it the day it landed.
create or replace function aiq.land_embeddings(p_matrix_task uuid)
returns jsonb as $$
declare
    v_run     uuid;
    v_model   text;
    v_tbl     text;
    v_landed  int := 0;   -- accumulated across spaces, not per space
    v_this    int := 0;
    v_total   int := 0;
    v_missing int;
    v_models  text[] := '{}';
begin
    -- Raises unless this task belongs to the run being executed: a registered
    -- step function handed an arbitrary task id would otherwise be a read of
    -- someone else's run. One body, in workflow-engine/schema.sql §20c.
    v_run := workflow.assert_task_in_current_run(p_matrix_task);

    select count(*) into v_total from workflow.tasks
     where matrix_parent_id = p_matrix_task;

    -- A child that succeeded and left no `result` is the offload case: its
    -- output went to object storage as an artifact and the vector is not in
    -- the column. Raised rather than skipped, because a chunk silently absent
    -- from the space is a hole in a corpus that still answers questions --
    -- the failure-reporting-success shape this collection keeps finding.
    select count(*) into v_missing from workflow.tasks
     where matrix_parent_id = p_matrix_task
       and status = 'succeeded'
       and (output is null or not (output ? 'result'));
    if v_missing > 0 then
        raise exception
            '% of % embed children completed with no vector in their output -- they '
            'were offloaded as artifacts (workflow-engine/outputs.md class 4) because '
            'the response exceeded workflow.max_payload_bytes. A vector that is not in '
            'the payload cannot be landed from here; raise the cap for the queue that '
            'embeds, or embed with a smaller model.', v_missing, v_total;
    end if;

    for v_model in
        select distinct t.input->'embed'->>'model'
        from workflow.tasks t
        where t.matrix_parent_id = p_matrix_task
          and t.input->'embed' ? 'model'
    loop
        -- register_embedding_space() is the one place that knows how a space
        -- table is named and shaped; calling it here rather than reproducing
        -- the name is what keeps this function correct when that one changes.
        -- It is idempotent (create table if not exists), so the space existing
        -- is not a precondition the pipeline has to arrange separately.
        perform aiq.register_embedding_space(v_model);
        v_tbl    := 'emb_' || replace(v_model, '-', '_');
        v_models := v_models || v_model;

        execute format($q$
            insert into aiq.%1$I (chunk_id, embedding)
            select (t.input->'item'->>'chunk_id')::uuid,
                   (select array_agg((v #>> '{}')::real order by ord)
                      from jsonb_array_elements(t.output->'result') with ordinality e(v, ord))::vector
            from workflow.tasks t
            where t.matrix_parent_id = $1
              and t.status = 'succeeded'
              and t.input->'embed'->>'model' = $2
              and t.input->'item' ? 'chunk_id'
            -- Re-embedding a chunk REPLACES its vector. A run that re-ingests
            -- a resource whose text changed must not leave the old vector
            -- ranking against the new text, and the chunk id is the key of
            -- the space, so ON CONFLICT is the whole of the update path.
            on conflict (chunk_id) do update
                set embedding = excluded.embedding, embedded_at = now()
        $q$, v_tbl) using p_matrix_task, v_model;

        get diagnostics v_this = row_count;
        v_landed := v_landed + v_this;
    end loop;

    if v_landed = 0 and v_total > 0 and array_length(v_models, 1) is null then
        raise exception
            'none of the % embed children carry a model on their input, so there is no '
            'space to land them in. This step reads the fan-out of an `embed:` matrix '
            'template; a hand-written `rest:` call to a model endpoint records nothing '
            'about which space its vector belongs to and cannot be landed.', v_total;
    end if;

    -- A receipt (outputs.md §2): counts and the spaces written, not the rows.
    return jsonb_build_object('landed', v_landed, 'children', v_total,
                              'models', to_jsonb(v_models));
end;
$$ language plpgsql set search_path = pg_catalog, public;

select workflow.register_step_function(
    'land_embeddings', 'aiq.land_embeddings', array['uuid'], 120000,
    'Store an embed matrix''s vectors in the space each child embedded with');

-- A registered step function is called by workflow.execute_sql_step as the
-- schema owner, never by a client, so the PUBLIC default EXECUTE that came
-- with it was reach nobody needs. See workflow-engine/integration-rbac.sql §6
-- for the enumeration this came out of.
revoke execute on function aiq.land_embeddings(uuid) from public;

-- ============================================================
-- The plan-graph facet -- which corpus, and which space it is ranked in
--
-- The other half of workflow.plan_catalog() (workflow-engine/plan-graph.md).
-- The engine can see that a step calls `p8ql`; only this schema knows whether
-- the source that query names is registered, and -- the part no other view in
-- this collection answers -- WHICH MODELS that corpus has actually been
-- embedded with.
--
-- That last column is why this facet exists at all. `expand_embed_steps` pins
-- one model into both halves of the sugar path, so `p8ql: 'SEARCH ... FROM
-- chunks'` cannot rank in a space it did not embed into. The hand-written pair
-- -- an `embed:` step and a `p8ql:` step the author wired together -- is
-- outside that guarantee by construction, and its failure is not an error
-- anywhere: ranking a corpus in a space it has no rows in returns no rows, and
-- ranking it in the wrong space returns a number. `spaces` is what lets the
-- plan graph refuse it before the run rather than after the answer.
-- ============================================================

-- Does this model's space hold any vector belonging to this corpus?
--
-- Dynamic because the space table's NAME is derived from the model, so a
-- static reference would have to exist per model -- and because a model
-- registered without register_embedding_space() has no table at all, which
-- must answer false rather than raise. to_regclass is the guard that makes the
-- second case cheap.
create or replace function aiq.space_populated(p_model text, p_source_table text)
returns boolean
language plpgsql
stable
set search_path = pg_catalog, public
as $$
declare
    v_tbl text := 'aiq.' || quote_ident('emb_' || replace(p_model, '-', '_'));
    v_hit boolean;
begin
    if to_regclass(v_tbl) is null then
        return false;
    end if;
    -- LIMIT 1 through the primary key, never a count: this asks whether the
    -- corpus is represented in the space, and a count of six million vectors
    -- answers the same question a great deal more slowly.
    execute format(
        'select exists (select 1 from %s e join %s c on c.id = e.chunk_id limit 1)',
        v_tbl, p_source_table) into v_hit;
    return coalesce(v_hit, false);
exception
    -- A registered source whose table has no `id` column is a registration
    -- defect, not a reason for the whole plan graph to fail. Reported as "no
    -- space" and left to the source's own audit.
    when undefined_column or undefined_table then
        return false;
end;
$$;

-- Every registered source, and what is true of it. A name can be registered
-- both ways -- `chunks` is lexical AND semantic -- so this is a full join
-- rather than a union: one row per NAME, carrying which modes it supports.
create or replace view aiq.v_plan_sources as
select coalesce(s.name, l.name)                as name,
       coalesce(s.source_table, l.source_table) as source_table,
       s.name is not null                       as semantic,
       l.name is not null                       as lexical,
       coalesce(s.content_col, l.content_col)   as content_col,
       l.regconfig                              as regconfig,
       -- The spaces this corpus has rows in. A model's space is a table
       -- (aiq.emb_<model>, §10) and its rows are per chunk, so "embedded with
       -- M" is a question about data, not about registration -- which is the
       -- honest form of it, since registering a model creates an empty table.
       coalesce((
           select jsonb_agg(jsonb_build_object('model', m.name, 'dim', m.dim)
                            order by m.name)
             from aiq.embedding_models m
            where aiq.space_populated(m.name, coalesce(s.source_table, l.source_table))
       ), '[]'::jsonb)                          as spaces,
       -- THE SHAPE OF WHAT IT READS. Names and types, and nothing else: the
       -- point of expanding a source is to see how data moves through the
       -- schema, and constraints, defaults and indexes answer a different
       -- question at ten times the length. Generated columns are excluded
       -- because search_tsv is this schema's own bookkeeping, not the
       -- corpus's shape.
       coalesce((
           select jsonb_agg(jsonb_build_object('name', c.column_name,
                                               'type', c.data_type)
                            order by c.ordinal_position)
             from information_schema.columns c
            where c.table_schema = split_part(coalesce(s.source_table, l.source_table), '.', 1)
              and c.table_name   = split_part(coalesce(s.source_table, l.source_table), '.', 2)
              and c.is_generated = 'NEVER'
       ), '[]'::jsonb)                          as columns
  from aiq.semantic_sources s
  full join aiq.lexical_sources l on l.name = s.name;

create or replace function aiq.plan_facet()
returns jsonb
language sql
stable
as $$
    select jsonb_build_object(
        'sources', coalesce((
            select jsonb_object_agg(name, jsonb_strip_nulls(jsonb_build_object(
                'table', source_table, 'semantic', semantic,
                'lexical', lexical, 'content_col', content_col,
                'regconfig', regconfig, 'columns', columns,
                -- The model NAMES, for the space check the graph does, and the
                -- dimensioned form beside it for a reader.
                'spaces', (select coalesce(jsonb_agg(e->>'model'), '[]'::jsonb)
                             from jsonb_array_elements(spaces) e),
                'space_detail', spaces)))
              from aiq.v_plan_sources), '{}'::jsonb),
        'models', coalesce((
            select jsonb_object_agg(m.name, jsonb_strip_nulls(jsonb_build_object(
                'dim', m.dim, 'provider', m.provider, 'is_default', m.is_default,
                -- Where the vector comes from. A url with a {{env.X}} in it is
                -- the registry doing its job, and it belongs in a plan for the
                -- same reason the model name does.
                'endpoint', m.endpoint,
                -- Registered and never created is a real, silent state: the
                -- embed call succeeds and there is nowhere to land the vector.
                'space_exists', to_regclass(
                    'aiq.' || quote_ident('emb_' || replace(m.name, '-', '_'))) is not null)))
              from aiq.embedding_models m), '{}'::jsonb),
        'entities', coalesce((
            select jsonb_object_agg(entity_type, jsonb_build_object(
                'table', source_table, 'key', key_expr))
              from aiq.entity_registry), '{}'::jsonb));
$$;

grant select on aiq.v_plan_sources to authenticated;
grant execute on function aiq.plan_facet() to authenticated;
grant execute on function aiq.space_populated(text, text) to authenticated;

comment on function aiq.plan_facet() is
    'The ai-query-layer half of workflow.plan_catalog(): registered sources and '
    'the spaces they are actually embedded in, the model registry, and the '
    'entity registry -- in the shape p8_plan_graph reads.';
