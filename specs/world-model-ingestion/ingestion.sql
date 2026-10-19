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
-- WHAT p_endpoint MAY POINT AT, said here because the signature on its own
-- promises more than the body delivers. Everything this function builds is
-- OpenAI chat-completions: `messages` with an inline system role,
-- `response_format.json_schema`, and a `choices.0.message.content` extraction
-- path. So the parameter means "same wire shape, different HOST" -- Azure
-- OpenAI, vLLM, OpenRouter, Together, LiteLLM and anything else serving that
-- API -- and NOT "any provider".
--
-- Pointed at https://api.anthropic.com/v1/messages it produces a well-formed
-- POST to an API that wants `system` as a top-level field, a required
-- `max_tokens`, a tool carrying `input_schema` for structured output, and an
-- answer at `content.0.input`. That fails at request time in a worker rather
-- than at registration, which is the worst place for it to fail, and a consumer
-- who brought an Anthropic key and no OpenAI key has to write their own worker
-- for this and this alone.
--
-- Kept as a parameter rather than a constant because the hosts above are real
-- and are the common case; a second provider is a second branch here plus a
-- second `jsonpath`, and the `jsonpath` is already a RETURNED field rather than
-- a hard-coded reader, so the seam is half-built. What is not acceptable is
-- leaving the signature to imply the branch exists.
-- `agentic.agent_call` -- the general request builder this delegates to -- is
-- in specs/agentic/schema.sql, with the schema that owns it. What stays here is
-- the graph-extractor guard, which is the only part specific to this pipeline.
create or replace function aiq.extractor_call(
    p_agent      text,
    p_model      text,
    p_text       text,
    -- Any host serving the OpenAI chat-completions API. NOT any provider --
    -- see the note above.
    p_endpoint   text default 'https://api.openai.com/v1/chat/completions',
    p_credential text default 'LLM_API_KEY'
) returns jsonb as $$
declare a agentic.agents; v_call jsonb;
begin
    select * into a from agentic.agents where name = p_agent;
    if not found then
        raise exception
            'no agent named ''%'' -- an extractor is a row, and this one is not '
            'installed. Run: select aiq.install_structure_null(''%'');',
            p_agent, coalesce(p_model, 'gpt-4o-mini');
    end if;
    -- THE ONE THING THAT IS SPECIFIC TO AN EXTRACTOR, which is why this
    -- function still exists after the body moved: an agent whose schema is not
    -- a graph returns something `land_graph` cannot land, and the good place to
    -- say so is here rather than three steps later on a shape error.
    if a.structured_output_schema is not null
       and not aiq.is_graph_schema(a.structured_output_schema) then
        raise exception
            'agent ''%'' does not declare a GRAPH schema (nodes with k/n, edges with '
            's/t/r), so aiq.land_graph cannot land what it returns. It is an '
            'extractor for something else -- build its call with '
            'agentic.agent_call().', p_agent;
    end if;

    -- The row's own model when the caller names none, which is what
    -- ingest_file's run description has always said ("the agent's own
    -- model"). It fell through to gpt-4o-mini whatever the row pinned (REM-54).
    v_call := agentic.agent_call(p_agent, p_text,
                                 coalesce(p_model, a.model, 'gpt-4o-mini'),
                                 p_endpoint, p_credential);
    -- `extractor` rather than `agent`, and the schema name stays 'graph':
    -- both are what this function has always returned, and a consumer reading
    -- either is not a caller to break for tidiness.
    return (v_call - 'agent')
        || jsonb_build_object('extractor', v_call->'agent')
        || jsonb_build_object('body', jsonb_set(v_call->'body',
               '{response_format,json_schema,name}', '"graph"'::jsonb));
end;
$$ language plpgsql stable;

revoke execute on function aiq.extractor_call(text, text, text, text, text) from public;
grant execute on function aiq.extractor_call(text, text, text, text, text) to authenticated;

-- THE RELATIONS AN EXTRACTOR MAY USE ARE READ WHEN A RUN STARTS, not when its
-- workflow was installed (REM-1057). extractor_call builds the whole request,
-- and the response_format in it carries the relation enum from
-- aiq.graph_vocabulary at the moment it is called. The ingest and reflect
-- workflows used to call it once, at install, and bake the request into the
-- definition, so a relation registered afterwards was never offered to the
-- model: the Zep tutorial registered ships_via after installing reflect, and
-- gpt-4o wrote `located_in` for a sentence about shipping, because ships_via
-- was not in the list it was given.
--
-- So the definition keeps the request with its response_format replaced by a
-- reference, and the run's first step computes it. The worker resolves a
-- whole-string reference to its native type (percolate-core worker/templates),
-- so the model is sent an object, not a JSON string.
--
-- THE AGENT ROW HAD THE SAME SNAPSHOT. install_structure_null stores
-- aiq.graph_schema() as the agent's structured_output_schema, so its enum is the
-- vocabulary on the day the agent was installed, and computing the request at
-- run time from that row only moved the snapshot. An agent tagged
-- `null-extractor` is the vocabulary's own extractor -- that is what
-- install_structure_null makes -- so its schema is taken from graph_schema() at
-- the run. Any other extractor keeps the schema its author wrote, which may
-- narrow the relations on purpose.
create or replace function aiq.extractor_response_format(p_agent text, p_model text)
returns jsonb as $$
    select case when 'null-extractor' = any(a.tags)
                then jsonb_set(f, '{json_schema,schema}', aiq.graph_schema())
                else f end
      from (select aiq.extractor_call(p_agent, p_model, '') -> 'body' -> 'response_format' as f) c
      cross join (select tags from agentic.agents where name = p_agent) a
$$ language sql stable;
revoke execute on function aiq.extractor_response_format(text, text) from public;
grant execute on function aiq.extractor_response_format(text, text) to authenticated, worker;

do $$ begin
    perform workflow.register_step_function('extractor_format', 'aiq.extractor_response_format',
        array['text', 'text'], 30000,
        'the extractor''s response_format, with the relations aiq.graph_vocabulary holds now');
end $$;

-- The request a workflow template sends, as extractor_call builds it, with the
-- response_format left to the run's extractor_format step.
create or replace function aiq.extractor_call_at_run(p_agent text, p_model text, p_text text)
returns jsonb as $$
    select jsonb_set(aiq.extractor_call(p_agent, p_model, p_text), '{body,response_format}',
                     to_jsonb('{{steps.extractor_format.result}}'::text))
$$ language sql stable;
revoke execute on function aiq.extractor_call_at_run(text, text, text) from public;

-- The step that computes it, as YAML, for the workflows that send it.
create or replace function aiq.extractor_format_step(p_agent text, p_model text)
returns text as $$
    select format(E'  - id: extractor_format\n    sql: {function: extractor_format, args: %s}\n',
                  jsonb_build_array(p_agent, p_model))
$$ language sql immutable;
revoke execute on function aiq.extractor_format_step(text, text) from public;

-- ------------------------------------------------------------
-- WHETHER A MODEL'S QUOTE IS IN ITS SOURCE, decided once (extraction.md §4.2).
--
-- Every extractor here asks for a verbatim quote and discards or flags an
-- answer whose quote is not found. The check was written eight times with four
-- rules (REM-59): the self-model scripts forgave asterisks and smart quotes and
-- had no minimum, pgvector-watch forgave neither and wanted eight characters,
-- the tour accepted a three-letter quote. The same quote against the same text
-- counted as evidence in one package and not in the next, so evidence counts
-- could not be compared across them.
--
-- The rule is an identity check with formatting taken out, not a similarity
-- measure: both sides are lowercased, every quote mark is folded to one, the
-- emphasis a model adds (`*`, `_`, backticks) is dropped and whitespace runs
-- become one space; the quote also loses the punctuation and quote marks at
-- its edges. What is left must occur whole, and be at least eight characters,
-- because a short enough quote occurs in anything. A paraphrase stays a
-- miss: accepting a fragment of the quote accepts everything eventually
-- (extraction.md §4.2 records the measurement).
create or replace function aiq.quote_occurs(p_quote text, p_source text)
returns boolean language sql immutable parallel safe
set search_path = pg_catalog, public
as $$
    with norm as (
        -- Both texts, the same way: fold the quote marks, drop the emphasis
        -- (translate deletes the characters its target string runs out
        -- for), lowercase, collapse whitespace.
        select t.side, btrim(regexp_replace(lower(translate(coalesce(t.v, ''),
                   E'‘’“”"*_`', repeat(chr(39), 5))), '\s+', ' ', 'g')) as v
          from (values ('quote', p_quote), ('source', p_source)) as t(side, v)
    ), q as (
        select btrim(v, E' \'.,;:…-') as v from norm where side = 'quote'
    )
    select length(q.v) >= 8 and strpos(s.v, q.v) > 0
      from q, norm s where s.side = 'source';
$$;

comment on function aiq.quote_occurs(text, text) is
    'True when a model''s quote occurs in its source after both are lowercased, '
    'quote marks folded, emphasis markup dropped and whitespace collapsed, and '
    'the quote is at least 8 characters once its edge punctuation is trimmed. '
    'The one rule for "is this evidence" (extraction.md §4.2).';

revoke execute on function aiq.quote_occurs(text, text) from public;
grant execute on function aiq.quote_occurs(text, text) to authenticated, worker;

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
-- A model's answer, as jsonb. The one thing a JSON parser accepts and jsonb
-- does not is the NUL escape: `\u0000` is valid JSON and jsonb refuses it
-- ("unsupported Unicode escape sequence"), because a Postgres text value
-- cannot hold a NUL. Models do emit it -- scenarios/tour's extractor wrote one
-- into a quote from a GitHub issue -- and in a fan-in that casts each child's
-- answer, one such window used to fail the landing of the whole document.
-- Stripping it changes no meaning a Postgres row could have held.
create or replace function content.model_json(p_text text)
returns jsonb language sql immutable parallel safe
set search_path = pg_catalog as $$
    select replace(p_text, '\u0000', '')::jsonb
$$;
revoke all on function content.model_json(text) from public;

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
               t.input->'item'->'window_ordinal' as win,
               t.input->'item' as item
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
                v_graph := content.model_json(v_child.payload #>> '{}');
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

        -- THE RESOURCE'S ORG, which aiq.land_graph has always passed and this
        -- function did not: upsert_graph maps an omitted org to the shared
        -- tier, so every graph the upload pipeline produced was readable
        -- outside the org its document was uploaded into. Found backfilling
        -- private session transcripts on the dogfood stack, 2026-09-11.
        -- A WINDOW SAYS WHAT IT WAS READ FROM. A document's window names its
        -- resource; a conversation's names its session, the message and when
        -- it was said (agentic.session_windows, REM-969), so the fact holds
        -- from the moment it was stated and cites the message that stated it.
        if v_child.item ? 'session_id' then
            v_r := aiq.upsert_graph(v_graph, jsonb_build_object(
                'session_id', v_child.item->>'session_id',
                'message_ids', jsonb_build_array(v_child.item->>'message_id'),
                'valid_from', v_child.item->>'at',
                'run_id', v_run, 'agent', 'structure_null'));
        else
            -- A DOCUMENT SAYS WHEN IT WAS WRITTEN (REM-1022). register_text has
            -- always stored p_metadata, and a caller that knows when the text
            -- was said puts it there as said_at; nothing read it, so a note
            -- written last January and uploaded today had every fact hold
            -- from today, and the Mem0 and Zep tutorials typed their history
            -- as graph JSON by hand to date it. A said_at that is not a time,
            -- or is in the future, is ignored rather than failing the upload:
            -- the document is still worth reading, and its facts then hold
            -- from when they were read, as before.
            v_r := aiq.upsert_graph(v_graph, jsonb_build_object(
                'resource_id', v_child.rid, 'run_id', v_run,
                'org_id', (select r.org_id from content.resources r where r.id = v_child.rid),
                'valid_from', (select r.metadata->>'said_at' from content.resources r
                                where r.id = v_child.rid
                                  and pg_input_is_valid(r.metadata->>'said_at', 'timestamptz')
                                  and (r.metadata->>'said_at')::timestamptz <= now()),
                'window', v_child.win, 'agent', 'structure_null'));
        end if;

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

-- A PIPELINE FOR TEXT THAT IS ALREADY TEXT, PACED ON PURPOSE (REM-628).
--
-- install_ingest_workflow builds parse -> embed, because an upload arrives as
-- bytes. content.register_text has the text already, so this installs the embed
-- step alone: one task per resource, on the ingest queue, against the registered
-- model.
--
-- THE RATE KEY IS WHY THIS FUNCTION EXISTS RATHER THAN A FLAG. Embedding runs
-- in the worker now, so its cost is this node's CPU rather than somebody's API
-- quota, and the node also serves readers. A bucket makes the queue SLOW BY
-- CONSTRUCTION: tasks wait their turn instead of taking every core the moment a
-- publisher saves fifty articles. The defaults -- 5 tokens refilling at 0.5 a
-- second -- mean a burst of five resources goes at once and the steady rate is
-- one resource every two seconds, which at the measured 10 chunks a second is
-- about a fifth of one core. Raise refill_rate on a machine that has the
-- headroom; that is a deployment's judgement and it is an argument rather than
-- a measurement.
--
-- THE BUCKET IS CREATED HERE, BEFORE ANY STEP NAMES IT, for the reason the
-- graph branch below records at length: a rate_key with no row in
-- workflow.rate_limits is never claimed by anyone, forever, with no error and
-- an empty-looking queue.
create or replace function content.install_text_embed_workflow(
    p_model       text default null,
    p_queue       text default 'ingest',
    p_name        text default 'embed_text',
    p_rate_key    text default 'text_embedding',
    p_capacity    numeric default 5,
    p_refill_rate numeric default 0.5
) returns text as $$
declare
    v_model text := p_model;
begin
    if v_model is null then
        select name into v_model from aiq.embedding_models where is_default;
    elsif not exists (select 1 from aiq.embedding_models where name = v_model) then
        raise exception
            'embedding model ''%'' is not registered, so every run of this '
            'pipeline would fail at its only step.', v_model;
    end if;
    if v_model is null then
        raise exception
            'no embedding model is registered and none was named, so there is '
            'nothing for this pipeline to embed with. Register one first: '
            'specs/ai-query-layer/USAGE.md.';
    end if;

    insert into workflow.rate_limits (key, capacity, tokens, refill_rate)
    values (p_rate_key, p_capacity, p_capacity, p_refill_rate)
    on conflict (key) do update
        set capacity = excluded.capacity, refill_rate = excluded.refill_rate;

    -- define_yaml, the same door install_ingest_workflow uses: a definition is
    -- a document, and there is no second way to write one.
    perform workflow.define_yaml(format($y$
name: %1$s
steps:
  - id: embed
    work: true
    queue: %2$s
    rate_key: %3$s
    input:
      op: embed
      resource_id: '{{run.resource_id}}'
      model: %4$s
$y$, p_name, p_queue, p_rate_key, v_model));
    return format('%s: embed with %s, paced at %s a second (bucket %s, burst %s)',
                  p_name, v_model, p_refill_rate, p_rate_key, p_capacity);
end;
$$ language plpgsql;

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
        v_graph := aiq.extractor_format_step(p_graph_agent, p_graph_model) || format($y$
  - id: graph
    needs: [parse, extractor_format]
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
$y$, (aiq.extractor_call_at_run(p_graph_agent, p_graph_model, '{{item.content}}'))::text);
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
    -- turn out to be uncallable -- and then the pipeline degrades to what it
    -- can run and SAYS SO, carrying the compiler's own message rather than a
    -- summary of it.
    --
    -- The case that produced this block: the committed corpus fixture
    -- registers `demo-quad-a` as the DEFAULT, and its vectors are written by
    -- hand rather than produced by anything, so it cannot embed. It used to say
    -- that by naming a provider called `fixture`, which resolved to nothing and
    -- failed the install with "provider 'fixture' has no row in
    -- aiq.embedding_providers" -- an install broken by a fixture.
    --
    -- That spelling is now unrepresentable: embedding_models.provider carries a
    -- foreign key onto embedding_providers, and a space whose vectors come from
    -- outside says so with NULL. So the failure this degradation path catches
    -- is no longer an invented provider name; it is the honest case of a
    -- default that genuinely cannot embed. The path stays, because that case is
    -- real -- a model with a null provider or no endpoint is still a default
    -- this function may find itself holding.
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

-- ------------------------------------------------------------
-- A conversation writes what it learned into the graph (REM-969).
--
-- A session's messages were rows in agentic.messages and nothing read them
-- back into memory. reflect_session is the upload graph branch pointed at a
-- conversation: one window per thing the user said, the same extractor row,
-- the same landing. What changes is the source. Each fact cites the session
-- and the message it came from and holds from when it was said, and it is
-- scoped by the session, so a private conversation's facts are its owner's
-- (aiq.upsert_graph, aiq.edge_sources_readable).
--
-- THE USER'S WORDS ONLY. activity-memory.md §3: "only the user's words are
-- evidence about the user". The assistant's turns are context and are not
-- windows, so an agent saying "you live in Leeds" never becomes the fact.
--
-- Started per session, by whoever may read it, naming who spoke:
--     select workflow.start_workflow('reflect_session',
--                                    '{"session_id": "...", "speaker": "Maya Okafor"}');
-- ------------------------------------------------------------
-- WHO IS SPEAKING, because a person talks in the first person. "I am
-- vegetarian and allergic to peanuts" read alone gave the extractor no
-- subject, and on a real run (gpt-4o-mini, 0.2.23) it wrote `vegetarian
-- -allergic_to-> peanuts`. A window now reads "<speaker> wrote: <words>", the
-- speaker coming from the run's input ({"speaker": "Maya Okafor"}), so the
-- facts attach to the same person node her other memories name. Without one
-- it says "The person", which is honest and names nobody. `said` keeps the
-- words alone.
--
-- THE RUN, NOT THE SPEAKER, IS THE ARGUMENT. A step template that names a run
-- input the caller did not send fails the run ("template 'run.speaker'
-- resolved to nothing"), so an optional input cannot be a template argument.
-- The run's own id always resolves ({{run.$id}}), and the speaker is read from
-- its input here.
drop function if exists agentic.session_windows(uuid);
drop function if exists agentic.session_windows(uuid, text);
create or replace function agentic.session_windows(p_session uuid, p_run uuid default null)
returns jsonb as $$
begin
    -- A SESSION THE CALLER CANNOT READ IS REFUSED BY NAME (REM-1021). It used to
    -- filter to nothing, so reflect_session started by the wrong person -- the
    -- tour's `start` helper signs as the admin, and Maya's conversation is
    -- private to Maya -- read zero windows, wrote nothing and reported
    -- `succeeded`; a Mem0 reader got an empty facts table and no error. One
    -- message covers "no such session" and "someone else's", so the refusal
    -- says nothing about a session the caller may not see.
    if not (rbac.is_operator() or agentic.session_readable(p_session)) then
        raise exception 'session % is not one the run''s owner can read: it does not exist, or it belongs to someone else', p_session
            using errcode = 'insufficient_privilege',
                  hint = 'start reflect_session as the person who had the conversation, with their token';
    end if;
    return (
    with speaker as (
        select coalesce(nullif(btrim((select r.input->>'speaker' from workflow.runs r where r.id = p_run)), ''),
                        'The person') as name
    )
    select coalesce(jsonb_agg(jsonb_build_object(
               'session_id', m.session_id,
               'message_id', m.id,
               'at',         m.created_at,
               'said',       m.content,
               'content',    format('%s wrote: %s', (select name from speaker), m.content))
               order by m.seq), '[]'::jsonb)
    from agentic.messages m
    where m.session_id = p_session
      and m.role = 'user'
      and coalesce(btrim(m.content), '') <> '');
end;
$$ language plpgsql stable security definer set search_path = pg_catalog, public;
revoke execute on function agentic.session_windows(uuid, uuid) from public;

select workflow.register_step_function(
    'session_windows', 'agentic.session_windows', array['uuid', 'uuid'], 30000,
    'One window per message the user wrote in a session, naming who wrote it, with the message id and when');

-- ------------------------------------------------------------
-- THE PERSON'S OWN AGENT READS A CONVERSATION AND LANDS WHAT IT LEARNED (REM-1056).
--
-- reflect_session makes Percolate call a model of its own to read a session.
-- A person whose agent is already connected (their own Claude, over MCP) has a
-- reader in hand: these two calls let that agent do the reading, so a memory
-- tutorial runs with no second API key. The rule is reflect_session's, item by
-- item, so the two paths cannot disagree about what a conversation may teach:
--
--   * whoever may read the session may reflect on it (agentic.session_readable);
--   * only what the user wrote is evidence, never the assistant's turns;
--   * a fact cites the one message it came from and holds from when it was said;
--   * it lands through aiq.upsert_graph, so residence, vocabulary and the soft
--     tier are the same, and a bind upsert_graph leaves soft reaches the
--     judgement queue at the next aiq.dream like any other.
--
-- What differs is the name on it. The extractor is recorded as
-- `agent:<user id>`, the person whose agent read it, never a model's row name,
-- so an agent's facts can be told from structure_null's and undone as a set.
-- ------------------------------------------------------------

-- The windows, for the person's own agent. session_windows is the engine's
-- (it reads a reflect run's input for the speaker); this is the caller's,
-- with no run, so it reads nothing but the session it was asked about, and
-- session_windows already refuses a session the caller may not read.
create or replace function agentic.session_messages(p_session uuid)
returns jsonb as $$
    select agentic.session_windows(p_session, null);
$$ language sql stable security definer set search_path = pg_catalog, public;
revoke execute on function agentic.session_messages(uuid) from public;
grant execute on function agentic.session_messages(uuid) to authenticated;

-- One message's facts, landed as the caller's agent. The graph is the
-- extractor's own shape ({"nodes":[{"k","n"}...], "edges":[{"s","t","r"}...]}),
-- the one land_graph_fanout passes to upsert_graph.
create or replace function agentic.land_message_facts(p_message_id uuid, p_graph jsonb)
returns jsonb as $$
declare
    v_uid uuid := rbac.current_user_id();
    m     agentic.messages;
begin
    if v_uid is null then
        raise exception 'land_message_facts: sign in first; the facts are recorded as your agent''s'
            using errcode = '42501';
    end if;
    select * into m from agentic.messages where id = p_message_id;
    -- One answer for a message that does not exist and one the caller may not
    -- read, so the error tells nobody which ids are real.
    if m.id is null or not agentic.session_readable(m.session_id) then
        raise exception 'land_message_facts: no message % that you may read', p_message_id
            using errcode = '42501';
    end if;
    if m.role <> 'user' then
        raise exception 'land_message_facts: message % is the %''s, and only what the user wrote is evidence about them',
            p_message_id, m.role using errcode = '22023';
    end if;
    if jsonb_typeof(p_graph->'nodes') is distinct from 'array' then
        raise exception 'land_message_facts: the graph needs a nodes array, as {"nodes":[...],"edges":[...]}'
            using errcode = '22023';
    end if;
    return aiq.upsert_graph(p_graph, jsonb_build_object(
        'session_id',  m.session_id,
        'message_ids', jsonb_build_array(m.id),
        'valid_from',  m.created_at,
        'agent',       'agent:' || v_uid));
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;
revoke execute on function agentic.land_message_facts(uuid, jsonb) from public;
grant execute on function agentic.land_message_facts(uuid, jsonb) to authenticated;

create or replace function agentic.install_reflect_workflow(
    p_graph_model text default null,
    p_graph_agent text default 'structure_null',
    p_name        text default 'reflect_session'
) returns text as $$
begin
    insert into workflow.rate_limits (key, capacity, tokens, refill_rate)
    values ('structure_extraction', 20, 20, 1)
    on conflict (key) do nothing;

    perform workflow.define_yaml(format($y$
name: %1$s
steps:
%3$s
  - id: graph
    needs: [extractor_format]
    matrix:
      rows: {function: session_windows, args: ['{{run.session_id}}', '{{run.$id}}']}
      max_fanout: 200
      template:
        queue: http
        rate_key: structure_extraction
        rest: %2$s

  - id: land_graph
    needs: [graph]
    sql: {function: land_graph_windows, args: ['{{steps.graph.result.task_id}}']}
$y$, p_name, (aiq.extractor_call_at_run(p_graph_agent, p_graph_model, '{{item.content}}'))::text,
       rtrim(aiq.extractor_format_step(p_graph_agent, p_graph_model), E'\n')));

    return p_name || ': each message the user wrote, graph-indexed with ' || p_graph_agent
                  || ' (' || coalesce(p_graph_model, 'the agent''s own model') || ')';
end;
$$ language plpgsql;
revoke execute on function agentic.install_reflect_workflow(text, text, text) from public;

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

    -- `public` explicitly, and it is the same omission one door along from the
    -- one this comment already records. The channel exists now; it defaulted to
    -- `private` with no owner, and rbac.may_read(null, shared_org, 'private')
    -- is NULL, so register_upload's lookup dropped it and POST /files raised
    -- "no channel named uploads for this org" -- the very sentence above,
    -- earned a second time by a different cause. The visibility of the CHANNEL
    -- is not the visibility of what is uploaded through it: each resource
    -- still takes rbac.default_visibility(p_org_id).
    insert into content.channels (name, kind, config, visibility)
    select 'uploads', 'file_upload',
           jsonb_build_object(
               'description', 'the default channel for POST /files',
               'ingest_workflow', 'ingest_file'),
           'public'
    where not exists (
        select 1 from content.channels
         where name = 'uploads' and org_id = rbac.shared_org_id());

    -- MARKED BY ITS OWN STATEMENT, because the insert above is guarded by
    -- `where not exists` and therefore does nothing at all on a replay -- so
    -- on an upgraded database the seed would keep the `false` the column was
    -- added with, be dumped, and collide with itself on restore. The five
    -- tables seeded through shared register functions get this for free from
    -- their `on conflict do update`; these two channels are the seeds with no
    -- conflict clause to hang it on, and the name is right here rather than in
    -- a list somewhere that a later seed would not be added to.
    -- AND IT REPAIRS THE ROW, because on an upgraded database it cannot mark
    -- it without doing so. Measured on 0.1.6 -> 0.2.0: both global channels
    -- are there as `private` with no owner and no org. `not (visibility =
    -- 'private' and owner_id is null)` was added NOT VALID, so those rows
    -- survived unchecked -- and any UPDATE to one revalidates it, which is how
    -- marking `shipped` found them.
    --
    -- They are not merely invalid, they are DEAD: rbac.may_read(null,
    -- shared_org, 'private') is NULL, so the channel lookup drops the row and
    -- POST /files answers "no channel named uploads for this org" -- REM-83's
    -- failure, still shipping on every database upgraded rather than
    -- installed. A fresh 0.2.0 seeds these public; converging the upgraded one
    -- onto that is what dev/upgrade-converges.sh asks for anyway.
    --
    -- Visibility only. owner_id stays null because these channels have no
    -- owner by design -- they are everybody's -- and `public` is what makes
    -- that legible to the read path instead of unreachable.
    update content.channels
       set shipped = true, visibility = 'public'
     where name = 'uploads' and org_id = rbac.shared_org_id()
       and (not shipped or visibility is distinct from 'public');
end $$;


-- The PUBLIC-EXECUTE revoke and its invariant used to end this file, as "the
-- last file in build-sql.py's ORDER". Six files were later added after it, so
-- it moved to identity/closing.sql, which build-sql.py emits after everything.
