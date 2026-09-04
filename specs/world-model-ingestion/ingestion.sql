-- ============================================================
-- The default ingestion pipeline.
--
-- A SEPARATE FILE, APPLIED LAST, and the reason is a fact about
-- workflow.define_yaml rather than a preference: defining a workflow LINTS it,
-- and the lint checks `agent:` steps against agentic.agents. So any file that
-- defines a workflow depends on the agentic schema, which loads after this
-- subsystem -- and putting these lines in integration.sql broke `CREATE
-- EXTENSION percolate` on a clean database with
--
--     ERROR: relation "agentic.agents" does not exist
--
-- from inside a DO block about content channels. Found by installing from
-- scratch rather than by reading; the running dev database had agentic
-- already, so the same statements had worked there for hours.
--
-- Everything here therefore comes after every schema in the collection. It is
-- the only file in world-model-ingestion that installs BEHAVIOUR rather than
-- structure: a workflow definition and the channel that points at it.
-- ============================================================

-- ------------------------------------------------------------
-- The default ingestion workflow, installed as a FUNCTION rather than as a
-- literal define_yaml() call, for one concrete reason: `embed:` resolves its
-- model at DEFINITION time (aiq.expand_embed_steps), so a definition
-- containing one cannot be written by an extension script that may be
-- installing into a database with no embedding model registered. It would
-- fail the install, and the remedy -- "register a model first" -- is not
-- something an extension may demand.
--
-- So the shape of the pipeline that gets installed depends on what the
-- deployment can actually do, and the function SAYS WHICH ONE IT INSTALLED
-- rather than quietly picking:
--
--   * with an embedding model: parse -> embed (matrix over the chunks) ->
--     land. Upload to answerable, with nothing to run but the ingest worker.
--   * without one: parse only. The chunks exist and TEXT mode searches them;
--     SEMANTIC and SEARCH do not, because there is no space to rank in. Call
--     this function again after registering a model and the pipeline upgrades
--     itself -- workflow.define_yaml versions the definition, so runs already
--     in flight keep the shape they started with.
--
-- The parse step is `work:` because chunking is the one thing here that needs
-- code you did not get from this repository -- brief.md §3 is explicit that
-- `chunk:` was refused as a shorthand because the strategy is a decision the
-- author has to make. percolate-core ships a default implementation of that
-- decision; the step kind is what keeps it replaceable.
-- ------------------------------------------------------------
-- The graph branch's extractor call, built from the AGENT ROW.
--
-- graph-index.md §6.1 writes this step as `agent: structure_null`, and that is
-- the right end state: an extractor is a row in agentic.agents, so changing its
-- prompt or its schema never touches a workflow. It cannot run today, and the
-- reason is a seam rather than an omission -- MEASURED, not assumed:
--
--   * the compiler emits `{{env.P8_AGENT_URL}}/v1/chat/completions` for an
--     `agent:` step (percolate_parser/src/lib.rs);
--   * the Agent Runtime serves `POST /chat`, which is SSE and refuses
--     `stream: false` by design, plus `POST /internal/run`, which is the
--     machine-to-machine trigger the brief actually specifies;
--   * so the url an `agent:` step calls is a route no runtime serves, and
--     `select count(*) from agentic.runs where workflow_task_id is not null`
--     is 0 on every deployment -- which workflow-engine/outputs.md §3 already
--     reports without naming this as the cause.
--
-- What this function does instead keeps the part that matters and gives up the
-- part that is broken: THE EXTRACTOR IS STILL A ROW. The system prompt and the
-- output schema are read from agentic.agents at definition time, so the agent
-- is still the unit of authorship; only the transport is an ordinary `rest:`
-- call to a chat endpoint rather than a call to the runtime. When the seam is
-- closed this becomes `agent: structure_null` and this function is deleted --
-- and because the prompt and schema come from the same row either way, the
-- extraction does not change when it does.
create or replace function aiq.extractor_call(
    p_agent      text,
    p_model      text,
    p_text       text,
    p_endpoint   text default 'https://api.openai.com/v1/chat/completions',
    p_credential text default 'LLM_API_KEY'
) returns jsonb as $$
declare a agentic.agents;
begin
    select * into a from agentic.agents where name = p_agent;
    if not found then
        raise exception
            'no agent named ''%'' -- an extractor is a row, and this one is not '
            'installed. Run: select aiq.install_structure_null(''%'');',
            p_agent, coalesce(p_model, 'gpt-4o-mini');
    end if;
    if a.structured_output_schema is null then
        raise exception
            'agent ''%'' declares no structured_output_schema, so there is no shape '
            'to land. An extractor without one is a model call with extra steps.',
            p_agent;
    end if;
    if not aiq.is_graph_schema(a.structured_output_schema) then
        raise exception
            'agent ''%'' does not declare a GRAPH schema (nodes with k/n, edges with '
            's/t/r), so aiq.land_graph cannot land what it returns. It is an '
            'extractor for something else.', p_agent;
    end if;

    return jsonb_build_object(
        'url',        p_endpoint,
        'method',     'POST',
        'timeout_ms', 120000,
        'credential_ref', p_credential,
        -- The vectorless half of what the runtime would have done: system
        -- prompt from the row, schema from the row, text from the matrix item.
        'body', jsonb_build_object(
            'model', coalesce(p_model, a.model),
            'temperature', 0,
            'messages', jsonb_build_array(
                jsonb_build_object('role','system','content', a.system_prompt),
                jsonb_build_object('role','user','content', p_text)),
            'response_format', jsonb_build_object(
                'type','json_schema',
                'json_schema', jsonb_build_object(
                    'name','graph', 'schema', a.structured_output_schema))),
        'jsonpath',   'choices.0.message.content',
        -- Kept beside the call for the same reason embed_call keeps its
        -- marker: the task row should say what it IS, not leave a reader to
        -- infer an intent from a url and a body.
        'extractor',  jsonb_build_object('agent', a.name,
                                         'model', coalesce(p_model, a.model)));
end;
$$ language plpgsql stable;

revoke execute on function aiq.extractor_call(text, text, text, text, text) from public;
grant execute on function aiq.extractor_call(text, text, text, text, text) to authenticated;

-- ------------------------------------------------------------
-- The graph fan-in, with the two things running it found.
--
-- aiq.land_graph_fanout does this job and is the function graph-index.md
-- specifies. This one exists beside it rather than instead of it, because a
-- real extraction over real documents hit two things that function does not
-- handle -- and one of them is a decision in its own file that is not mine to
-- overturn:
--
--  1. A MATRIX TEMPLATE CANNOT DECLARE output_schema. The compiler accepts
--     queue, rate_key, rest, embed, agent, work, input, session, jsonpath and
--     matrix inside a template -- and not output_schema, which is the field
--     that parses a model's JSON-in-a-string answer into an object before
--     storing it (workflow.complete_task §21). So every child of a graph
--     fan-out lands a jsonb STRING where a graph is expected. This is the
--     fourth thing `matrix:` has answered wrongly by omission, after nested
--     fan-out, the successors that had to be rewired, and `template: {embed:}`
--     -- and the fix belongs in the parser, at which point this function
--     collapses into theirs.
--
--  2. A MODEL EMITS EDGE ORDINALS THAT ARE OUT OF RANGE. Measured on the first
--     real run: gpt-4o-mini at temperature 0, eight nodes, an edge citing
--     s=7 t=8. aiq.upsert_graph raises on that, deliberately and with a stated
--     argument ("a dropped edge is a hole in a graph that still answers
--     questions, which is worse than a run that failed loudly"), and the
--     argument is right about a graph and wrong about a model: an ordinal past
--     the end is not a hole in the evidence, it is the extractor mis-numbering
--     a list, and it is ordinary rather than exceptional. So the edge is
--     dropped HERE, before upsert_graph sees it, and COUNTED in the receipt --
--     which keeps their invariant exactly as written: what reaches upsert_graph
--     is coherent, and nothing is lost silently.
create or replace function content.land_graph_windows(p_matrix_task uuid)
returns jsonb as $$
declare
    v_run     uuid;
    v_child   record;
    v_graph   jsonb;
    v_nodes   int;
    v_edges   jsonb;
    v_kept    jsonb;
    v_e       jsonb;
    v_dropped int := 0;
    v_offvocab int := 0;
    v_total   int := 0;
    v_r       jsonb;
    v_acc     jsonb := jsonb_build_object('graphs',0,'edges_new',0,'edges_merged',0,
                                          'self_edges_dropped',0);
begin
    -- Raises unless this task belongs to the run being executed: a registered
    -- step function handed an arbitrary task id would otherwise be a read of
    -- someone else's run. One body, in workflow-engine/schema.sql §20c.
    v_run := workflow.assert_task_in_current_run(p_matrix_task);

    for v_child in
        select t.id, t.step_key, t.output->'result' as payload,
               (t.input->'item'->>'resource_id')::uuid as rid,
               t.input->'item'->'window_ordinal' as win
        from workflow.tasks t
        where t.matrix_parent_id = p_matrix_task and t.status = 'succeeded'
        order by t.created_at
    loop
        v_total := v_total + 1;

        if v_child.payload is null then
            raise exception
                'child % completed with no payload -- it was offloaded as an artifact '
                'because the response exceeded workflow.max_payload_bytes. Window the '
                'document more finely, or raise the cap for the queue that extracts.',
                v_child.step_key;
        end if;

        -- (1) above: the model's answer arrives as a string.
        if jsonb_typeof(v_child.payload) = 'string' then
            begin
                v_graph := (v_child.payload #>> '{}')::jsonb;
            exception when others then
                raise exception
                    'child % returned text that is not JSON, so there is no graph to '
                    'land: %', v_child.step_key, left(v_child.payload #>> '{}', 200);
            end;
        else
            v_graph := v_child.payload;
        end if;

        if not (v_graph ? 'nodes' and v_graph ? 'edges') then
            raise exception
                'child % returned JSON that is not a graph (no nodes/edges): %',
                v_child.step_key, left(v_graph::text, 200);
        end if;

        -- (2) above: drop the edges a model got wrong, and count each kind.
        --
        -- OUT-OF-VOCABULARY IS THE SECOND KIND, and it is not the schema being
        -- ignored -- it is the schema not being enforced. `r` carries an enum
        -- built from aiq.graph_vocabulary, and OpenAI honours an enum only in
        -- STRICT structured-output mode, which aiq.graph_schema() cannot use:
        -- strict requires every property to appear in `required`, and `a` (the
        -- attribute bag) is deliberately optional. So the enum is a strong hint
        -- and not a constraint, and a cheap model reaches past it -- measured,
        -- gpt-4o-mini emitted `trips` on a document about a robotic arm.
        -- upsert_graph refuses it, correctly and terminally; a refusal that
        -- fails the upload is the wrong end of a right rule.
        v_nodes := jsonb_array_length(v_graph->'nodes');
        v_kept  := '[]'::jsonb;
        for v_e in select value from jsonb_array_elements(v_graph->'edges') loop
            if (v_e->>'s')::int is null or (v_e->>'t')::int is null
               or (v_e->>'s')::int < 0 or (v_e->>'t')::int < 0
               or (v_e->>'s')::int >= v_nodes or (v_e->>'t')::int >= v_nodes then
                v_dropped := v_dropped + 1;
            elsif not exists (select 1 from aiq.graph_vocabulary g
                              where g.relation = lower(trim(v_e->>'r'))) then
                v_offvocab := v_offvocab + 1;
            else
                v_kept := v_kept || jsonb_build_array(v_e);
            end if;
        end loop;
        v_graph := jsonb_set(v_graph, '{edges}', v_kept);

        v_r := aiq.upsert_graph(v_graph, jsonb_build_object(
            'resource_id', v_child.rid, 'run_id', v_run,
            'window', v_child.win, 'agent', 'structure_null'));

        v_acc := jsonb_build_object(
            'graphs',             (v_acc->>'graphs')::int + 1,
            'edges_new',          (v_acc->>'edges_new')::int + coalesce((v_r->>'edges_new')::int,0),
            'edges_merged',       (v_acc->>'edges_merged')::int + coalesce((v_r->>'edges_merged')::int,0),
            'self_edges_dropped', (v_acc->>'self_edges_dropped')::int
                                  + coalesce((v_r->>'self_edges_dropped')::int,0));
    end loop;

    -- Both counts in the receipt, never silently: a vocabulary that is being
    -- reached past constantly is the signal that it is too small, and it is
    -- only visible if the drops are counted. graph.sql says the first
    -- operational task after it ships is to count which relations are ever
    -- emitted and which never resolve; this is half of that measurement.
    return v_acc || jsonb_build_object('children', v_total,
                                       'edges_dropped_ordinal', v_dropped,
                                       'edges_dropped_offvocab', v_offvocab);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

revoke execute on function content.land_graph_windows(uuid) from public;

select workflow.register_step_function(
    'land_graph_windows', 'content.land_graph_windows', array['uuid'], 120000,
    'Upsert every graph a window fan-out produced, dropping edges a model mis-numbered');

-- Drop-then-create, because the signature GREW. `create or replace` leaves the
-- old three-argument body in place beside the new one, and every no-argument
-- call is then ambiguous: "could not choose a best candidate function", which
-- is what an upgraded database says the first time anything uploads a file.
drop function if exists content.install_ingest_workflow(text, text, text);

create or replace function content.install_ingest_workflow(
    p_model text default null,
    p_queue text default 'ingest',
    p_name  text default 'ingest_file',
    -- The second index, off by default. graph-index.md §6.1 argues the
    -- default: an embedding per chunk is cheap and is the whole point of an
    -- upload; a completion per window is a different order of money, so it is
    -- opt-in and the return value says which shape was installed rather than
    -- leaving an operator to infer it from a bill.
    p_graph_index boolean default false,
    p_graph_model text default null,
    p_graph_agent text default 'structure_null'
) returns text as $$
declare
    v_model  text := p_model;
    v_chosen boolean := p_model is not null;   -- did the CALLER name it?
    v_parse  text;
    v_embed  text;
    v_graph  text;
    v_says   text;
begin
    if v_model is null then
        select name into v_model from aiq.embedding_models where is_default;
    elsif not exists (select 1 from aiq.embedding_models where name = v_model) then
        raise exception
            'embedding model ''%'' is not registered, so an ingestion pipeline '
            'naming it would fail at every run. Register it first, or call this '
            'with no argument to install the parse-only pipeline.', v_model;
    end if;

    v_parse := format($y$
name: %1$s
steps:
  - id: parse
    work: true
    queue: %2$s
    input:
      op: ingest
      resource_id: '{{run.resource_id}}'
$y$, p_name, p_queue);

    -- THE TWO INDEXES ARE SIBLINGS, NOT A CHAIN, and that is the whole shape.
    -- Both declare needs: [parse], so the semantic index and the graph index
    -- run concurrently over the same parse and their failures are independent:
    -- a deployment with no embedding model can still index a graph, and a
    -- failed extraction does not cost the vectors. Same workflow, two
    -- indexers, one parse.
    if v_model is not null then
        -- THE EMBED STEP IS `work`, NOT A MATRIX OF `embed:`, AND THE REASON IS
        -- THE PAYLOAD CAP.
        --
        -- The declarative shape -- a matrix over the chunks with an `embed:`
        -- template and aiq.land_embeddings as the fan-in -- is written, tested
        -- and still the right way to embed a QUERY. It cannot be the way to
        -- embed a CORPUS: it is one HTTP request per chunk, and it cannot be
        -- batched, because a step's output is capped at
        -- workflow.max_payload_bytes (64KB) and one 1536-dimension vector is
        -- ~31KB of JSON. Two vectors do not fit in one task output.
        --
        -- So the process that receives the vectors writes them, and what comes
        -- back to the engine is a receipt. The MODEL still comes from
        -- aiq.embedding_models -- the worker asks aiq.embed_batch_call() for
        -- the url, the body shape, the response path and the credential NAME --
        -- so naming it here is naming a registered model and there is still no
        -- url in this document.
        v_embed := format($y$
  - id: embed
    needs: [parse]
    work: true
    queue: %2$s
    input:
      op: embed
      resource_id: '{{run.resource_id}}'
      model: %1$s
$y$, v_model, p_queue);
    end if;

    -- The graph branch: a matrix over WINDOWS, because a completion has a
    -- context limit where a batch of embeddings has a request limit, and one
    -- extraction per window is the unit graph-index.md §6.2 specifies. The
    -- fan-in is aiq.land_graph_fanout, which reads the model's output off each
    -- child and attributes every node to the window that named it.
    if p_graph_index then
        -- THE THROTTLE HAS TO EXIST BEFORE THE STEP NAMES IT, and this is the
        -- one place the pipeline still names one. `rate_key` is not a
        -- declaration -- it is a reference to a row in workflow.rate_limits,
        -- and claim_task's try_consume_rate_limit() does
        -- `update ... where key = p_key`, which matches nothing when there is
        -- no row and returns false. A task whose rate_key names a bucket that
        -- does not exist is never claimed BY ANYONE, forever, while the worker
        -- beside it reports an empty queue. Measured on the embed fan-out
        -- before it was batched: six children in `ready`, no error, no retry,
        -- no dead task.
        --
        -- A SEPARATE KEY from embeddings, deliberately (graph-index.md §6.1):
        -- completions and embeddings hit different provider limits, so sharing
        -- one bucket would throttle the cheap call behind the expensive one.
        -- 20 tokens refilling at 1/second is an argument, not a measurement:
        -- one completion per second per deployment is slow enough to be
        -- survivable on any provider and fast enough that a fifty-window
        -- document indexes in under a minute.
        insert into workflow.rate_limits (key, capacity, tokens, refill_rate)
        values ('structure_extraction', 20, 20, 1)
        on conflict (key) do nothing;

        -- A MATRIX OVER WINDOWS, which is graph-index.md §6.2's shape, and
        -- three things make it the right one here rather than §6.1's single
        -- document extraction:
        --
        --   * A CHUNKLESS RESOURCE SKIPS THE BRANCH FOR FREE. A tabular upload
        --     has no text, and an empty row set releases the successor
        --     immediately -- where a document-level step has to raise, which
        --     failed the whole ingest run of a CSV that had succeeded.
        --   * A long document does not have to fit in a task payload. The
        --     document shape carries its text through tasks.output, which caps
        --     at 64KB -- about fifteen pages.
        --   * The window is the chunk, so the extractor reads exactly what the
        --     embedder embedded, and a node can be attributed to the passage
        --     that named it rather than to the file.
        --
        -- The fan-in is content.land_graph_windows rather than
        -- aiq.land_graph_fanout for two reasons that are recorded where that
        -- function is defined: a matrix template cannot declare output_schema,
        -- and a model mis-numbers an edge ordinal often enough that raising on
        -- it fails ordinary ingestion.
        v_graph := format($y$
  - id: graph
    needs: [parse]
    matrix:
      rows: {function: windows_to_index, args: ['{{run.resource_id}}']}
      max_fanout: 200
      template:
        queue: http
        rate_key: structure_extraction
        rest: %1$s

  - id: land_graph
    needs: [graph]
    sql: {function: land_graph_windows, args: ['{{steps.graph.result.task_id}}']}
$y$, (aiq.extractor_call(p_graph_agent, p_graph_model, '{{item.content}}'))::text);
    end if;

    if v_model is null and not p_graph_index then
        perform workflow.define_yaml(v_parse);
        return p_name || ': parse only -- no embedding model is registered and graph '
                      || 'indexing was not asked for, so chunks will be searchable by '
                      || 'TEXT and by nothing else';
    end if;

    -- A REGISTERED MODEL IS NOT NECESSARILY A CALLABLE ONE, and the difference
    -- is what this block is for. The probe has to be explicit: while the embed
    -- half was a matrix of `embed:` markers, define_yaml expanded them and
    -- refused an uncallable model for free; a `work` step names a model in its
    -- input, which the compiler has no reason to resolve. Without this line an
    -- unreachable model would be accepted here and fail at every run, which is
    -- precisely the trade the `embed:` sugar exists to prevent. An empty batch
    -- resolves the endpoint, the provider and the request shape without
    -- embedding anything.
    --
    -- The rule, stated rather than implied: a model the CALLER named must
    -- work, and a failure raises. A default this function chose for itself may
    -- turn out to be uncallable -- the committed corpus fixture registers
    -- `demo-quad-a` as the DEFAULT with provider `fixture` and no endpoint, so
    -- installing on a database carrying the sample once failed with "provider
    -- 'fixture' has no row in aiq.embedding_providers", an install broken by a
    -- fixture -- and then the pipeline degrades to what it can run and SAYS
    -- SO, carrying the compiler's own message rather than a summary of it.
    begin
        if v_model is not null then
            perform aiq.embed_batch_call(v_model, '[]'::jsonb);
        end if;
        perform workflow.define_yaml(v_parse || coalesce(v_embed,'') || coalesce(v_graph,''));
    exception when others then
        if v_chosen or p_graph_index then
            raise;
        end if;
        perform workflow.define_yaml(v_parse);
        return p_name || ': parse only -- the default embedding model '
                      || quote_literal(v_model) || ' cannot be called (' || sqlerrm || ')';
    end;

    v_says := p_name || ': parse';
    if v_model is not null then
        v_says := v_says || ', embed with ' || v_model || ' in batches';
    end if;
    if p_graph_index then
        v_says := v_says || ', graph-index each window with ' || p_graph_agent
                         || ' (' || coalesce(p_graph_model, 'the agent''s own model') || ')';
    end if;
    return v_says;
end;
$$ language plpgsql;

-- Not callable by anyone but the owner: it runs workflow.define_yaml, which
-- decides what the deployment's uploads do with their bytes. PUBLIC holds
-- EXECUTE on every new function until it is taken away, so this line is what
-- makes "owner-only" true rather than intended.
revoke execute on function content.install_ingest_workflow(text, text, text, boolean, text, text) from public;

-- The channel POST /files defaults to when no X-P8-Channel header is sent.
--
-- It did not exist. percolate-core's Content Server defaults `x_p8_channel` to
-- 'uploads', register_upload raises 'no channel named uploads for this org',
-- and the documented first command in RELEASE-0.1.md §2 therefore 400s on a
-- clean install. Found by reading the two halves against each other while
-- wiring up ingestion; every upload this collection had ever done named a
-- channel explicitly.
--
-- WHERE NOT EXISTS rather than ON CONFLICT, for the reason §5b gives: the
-- unique index is (org_id, name) with a nullable org_id, and NULLs are
-- distinct.
do $$
declare v_msg text;
begin
    -- Install the pipeline first: a channel pointing at a definition that does
    -- not exist turns every upload into an error from start_workflow.
    select content.install_ingest_workflow() into v_msg;
    raise notice 'ingestion pipeline installed -- %', v_msg;

    insert into content.channels (name, kind, config)
    select 'uploads', 'file_upload',
           jsonb_build_object(
               'description', 'the default channel for POST /files',
               'ingest_workflow', 'ingest_file')
    where not exists (
        select 1 from content.channels where name = 'uploads' and org_id is null);
end $$;


-- ============================================================
-- THE LAST WORD ON PUBLIC EXECUTE, for every schema this extension owns.
--
-- Postgres grants EXECUTE on a new function to PUBLIC unless somebody takes it
-- away, and user-rbac 9(a) states the rule that follows as a structural one
-- for the whole collection: "a new function added later is unreachable via
-- REST until someone deliberately grants it. Deny-by-default, not
-- allow-by-omission."
--
-- IT DID NOT HOLD. Four of the five schemas revoke mid-file and then keep
-- defining functions -- `workflow-engine/schema.sql` revokes at its 9(b) and
-- defines FIFTY more functions below it in the same file; `aiq` revokes in
-- `integration-rbac.sql` and again in `graph-algorithms.sql`, and then
-- `world-model-ingestion/graph.sql` adds fourteen projection triggers,
-- `resolve_ref` and `graph_schema` after both. Measured on a clean install:
-- FORTY-SIX functions across `workflow` and `aiq` still carried EXECUTE for
-- PUBLIC, including `workflow.p8ql`, `workflow.plan_graph`,
-- `workflow.lint_spec` and `workflow.resolve_statement`.
--
-- Not a live leak, for the same accidental reason `agentic` 9's own header
-- gives about the three IT had missed: `web_anon` holds USAGE on neither
-- schema, and the three that are SECURITY DEFINER are two trigger functions
-- and a read-only capability probe. An accident of grant ordering is not a
-- control -- user-rbac 1 says exactly that, about set_password, and says
-- "never trust that again".
--
-- SO THE REVOKE MOVES TO WHERE NOTHING CAN BE DEFINED AFTER IT. This is the
-- last file in build-sql.py's ORDER, and its last statement. A revoke placed
-- beside the definitions it covers is the readable shape and it is the shape
-- that failed four times, because a file goes on being edited after the line
-- that was its end; there is no "later" than here.
--
-- REVOKE ... FROM PUBLIC removes only PUBLIC's own grant, so every
-- role-specific grant made above -- in this file and in the eleven before it
-- -- survives untouched. That is what makes one statement per schema safe
-- rather than a re-grant exercise.
--
-- The per-file revokes above are kept and are not redundant: they state the
-- intent at the point of definition, and they are what a reader of one file
-- sees. This is what makes the intent true.
-- ============================================================
revoke execute on all functions in schema workflow from public;
revoke execute on all functions in schema rbac     from public;
revoke execute on all functions in schema aiq      from public;
revoke execute on all functions in schema content  from public;
revoke execute on all functions in schema agentic  from public;

-- And the check that makes forgetting it a load-time failure rather than a
-- quiet one, generalised from the one `agentic/schema.sql` 10(c) added for a
-- single schema. `proacl is null` matters as much as the explode: a function
-- nobody has touched has a NULL ACL, which MEANS the default, which means
-- PUBLIC holds EXECUTE -- a check that only inspected non-null ACLs would pass
-- every function it is written to catch.
do $$
declare v_bad text;
begin
    select string_agg(n.nspname || '.' || p.proname, ', ' order by n.nspname, p.proname)
      into v_bad
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('workflow','rbac','aiq','content','agentic')
       and (p.proacl is null
            or exists (select 1 from aclexplode(p.proacl) a
                        where a.grantee = 0 and a.privilege_type = 'EXECUTE'));
    if v_bad is not null then
        raise exception
            'PUBLIC EXECUTE INVARIANT VIOLATED: % still carries EXECUTE for PUBLIC. '
            'Every function this extension ships is deny-by-default; add the schema '
            'to the revoke block above this check, then grant the callers it is '
            'meant to have.', v_bad;
    end if;
    raise notice 'no function in workflow, rbac, aiq, content or agentic is executable by PUBLIC';
end $$;
