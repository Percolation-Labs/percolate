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
create or replace function workflow.p8ql(p_query text)
returns jsonb as $$
    select aiq.query(p_query);
$$ language sql;

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
