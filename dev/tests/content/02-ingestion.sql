-- INGESTION -- the policy layering, the pipeline installer, and the two
-- functions the fan-out needs.
--
-- What this surface CANNOT test is the part that needs a worker and a model:
-- parsing a PDF, chunking it and embedding the chunks is three libraries and a
-- network call, and a test that faked them would assert against its own fake.
-- That half is `dev/tests/content/e2e-ingest.py`, which uploads five real
-- formats through a running stack.
--
-- What is here is everything the DATABASE decides: whose policy wins, what a
-- worker is told about a resource, what a receipt says, and what the installer
-- does when the deployment cannot embed. Every one of these is a rule that
-- would otherwise be enforced only by the Python that reads it.

\set ON_ERROR_STOP on

begin;

set local role app_owner;

-- ---------------------------------------------------------------------
-- 1. Policy layering: family default <- channel <- upload, key by key,
--    at every depth.
--
-- The deep merge is the point. A shallow `||` would let an upload that sets
-- one chunking field erase the channel's other chunking fields, silently --
-- the uploader would be running a chunking strategy nobody chose.
-- ---------------------------------------------------------------------
do $$
declare v jsonb;
begin
    v := content.merge_policy(
            '{"chunking": {"target_tokens": 900, "overlap": 0.15}, "mode": "text"}'::jsonb,
            '{"chunking": {"target_tokens": 400}}'::jsonb);

    if (v->'chunking'->>'target_tokens') <> '400' then
        raise exception 'the patch did not win: %', v;
    end if;
    if (v->'chunking'->>'overlap') is null then
        raise exception
            'a sibling key was erased by a patch that did not mention it -- this is '
            'the shallow-merge bug the deep merge exists to prevent: %', v;
    end if;
    if (v->>'mode') <> 'text' then
        raise exception 'an untouched top-level key was lost: %', v;
    end if;

    -- A patch that is not an object cannot be merged into one. Returning the
    -- base is the only answer that keeps a malformed policy from erasing a
    -- good one.
    if content.merge_policy('{"a": 1}'::jsonb, '"nonsense"'::jsonb) <> '{"a": 1}'::jsonb then
        raise exception 'a scalar patch overwrote an object policy';
    end if;
    raise notice 'policy merge: deep, and a malformed patch is inert';
end $$;

-- ---------------------------------------------------------------------
-- 2. ingest_target: one call, everything the worker needs, both policy
--    layers already merged.
-- ---------------------------------------------------------------------
create temp table t_ing (channel uuid, res uuid, file uuid);

do $$
declare v_ch uuid; v_res uuid; v_file uuid; v jsonb;
begin
    insert into content.channels (name, kind, config)
    values ('t-ingest', 'file_upload',
            '{"ingest_policy": {"chunking": {"target_tokens": 900, "overlap": 0.2}}}'::jsonb)
    returning id into v_ch;

    insert into content.files (checksum, bucket, object_key, size_bytes, content_type)
    values ('t-ingest-checksum', 'p8-content', 'objects/tt/t-ingest', 42, 'application/pdf')
    returning id into v_file;

    insert into content.resources (channel_id, file_id, title, status, metadata)
    values (v_ch, v_file, 'a.pdf', 'pending',
            '{"ingest_policy": {"chunking": {"target_tokens": 300}, "keep_markdown": false}}'::jsonb)
    returning id into v_res;

    insert into t_ing values (v_ch, v_res, v_file);

    v := content.ingest_target(v_res);

    if v->>'bucket' is null or v->>'object_key' is null then
        raise exception 'the worker was not told where the bytes are: %', v;
    end if;
    if v->>'content_type' <> 'application/pdf' then
        raise exception 'the content type did not come from the file row: %', v;
    end if;
    -- The upload's 300 beats the channel's 900, and the channel's overlap
    -- survives because the upload did not mention it.
    if (v->'policy'->'chunking'->>'target_tokens') <> '300'
       or (v->'policy'->'chunking'->>'overlap') <> '0.2'
       or (v->'policy'->>'keep_markdown') <> 'false' then
        raise exception 'the two override layers did not merge as specified: %', v->'policy';
    end if;

    if content.ingest_target(gen_random_uuid()) is not null then
        raise exception 'a resource that does not exist resolved to something';
    end if;
    raise notice 'ingest_target: location, type and both policy layers, in one call';
end $$;

-- ---------------------------------------------------------------------
-- 3. record_ingest: chunks, spans, provenance, status -- one transaction.
--
-- The status rule is the load-bearing one. 'ready' means "in the corpus";
-- a mode that produces no chunks is 'stored', because check_drift() reports a
-- ready resource with no chunks as a writer bug and it would be right to.
-- ---------------------------------------------------------------------
do $$
declare v_res uuid; v jsonb; r record;
begin
    select res into v_res from t_ing;

    v := content.record_ingest(v_res, jsonb_build_object(
        'mode', 'text', 'parser', 'pymupdf4llm',
        'markdown', jsonb_build_object('bucket','p8-content','object_key','md/x','bytes',120),
        'detail', jsonb_build_object('pages', 4),
        'chunks', jsonb_build_array(
            jsonb_build_object('content','the first chunk','token_count',3,
                               'start_offset',0,'end_offset',15),
            jsonb_build_object('content','the second chunk','token_count',3,
                               'start_offset',12,'end_offset',28))));

    if (v->>'chunks')::int <> 2 or v->>'status' <> 'ready' then
        raise exception 'receipt is wrong: %', v;
    end if;

    select count(*) filter (where start_offset is not null) as spans, count(*) as n
      into r from content.resource_chunks where resource_id = v_res;
    if r.n <> 2 or r.spans <> 2 then
        raise exception
            'the spans were dropped -- start_offset/end_offset are columns this '
            'schema has always had and nothing filled: % of % chunks', r.spans, r.n;
    end if;

    if (select metadata->'ingest'->>'parser' from content.resources where id = v_res)
       is distinct from 'pymupdf4llm' then
        raise exception 'the parser that produced these chunks was not recorded';
    end if;
    if (select metadata->'ingest'->'markdown'->>'object_key' from content.resources
         where id = v_res) is distinct from 'md/x' then
        raise exception 'the parsed markdown reference was not kept';
    end if;
    -- The policy the resource carried must survive: record_ingest patches
    -- metadata, it does not replace it.
    if (select metadata->'ingest_policy'->'chunking'->>'target_tokens'
          from content.resources where id = v_res) is distinct from '300' then
        raise exception 'record_ingest overwrote the uploader''s own policy';
    end if;
    raise notice 'record_ingest: 2 chunks with spans, parser and markdown recorded, ready';
end $$;

-- A chunkless outcome is 'stored', not 'ready'.
do $$
declare v_res uuid; v jsonb;
begin
    select res into v_res from t_ing;
    v := content.record_ingest(v_res, '{"mode": "store", "parser": null}'::jsonb);
    if v->>'status' <> 'stored' then
        raise exception 'a chunkless ingest called itself %', v->>'status';
    end if;
    if exists (select 1 from content.check_drift() d
               where d.kind = 'ready_but_empty' and d.id = v_res) then
        raise exception 'drift reports the resource this test just wrote correctly';
    end if;
    raise notice 'record_ingest: no chunks means stored, and drift stays clean';
end $$;

-- ---------------------------------------------------------------------
-- 4. chunks_to_embed: the row set an embed matrix fans out over.
--
-- Named in workflow-engine/YAML.md as THE example of per-row embedding, and
-- it did not exist until now -- the documented pipeline could not have run.
-- ---------------------------------------------------------------------
do $$
declare v_res uuid; v jsonb;
begin
    select res into v_res from t_ing;
    perform content.record_ingest(v_res, jsonb_build_object('mode','text','parser','x',
        'chunks', jsonb_build_array(
            jsonb_build_object('content','alpha','ordinal',0),
            jsonb_build_object('content','beta','ordinal',1))));

    v := content.chunks_to_embed(v_res);
    if jsonb_array_length(v) <> 2 then
        raise exception 'expected two rows, got %', v;
    end if;
    if v->0->>'content' <> 'alpha' or (v->0->>'chunk_id') is null then
        raise exception 'a fan-out row must carry the id AND the text: %', v->0;
    end if;
    -- Order matters: a matrix child is named by its position, and a row set
    -- that reordered between runs would rename every child.
    if v->1->>'content' <> 'beta' then
        raise exception 'rows are not in ordinal order: %', v;
    end if;
    if content.chunks_to_embed(gen_random_uuid()) <> '[]'::jsonb then
        raise exception 'an unknown resource should fan out over nothing';
    end if;
    raise notice 'chunks_to_embed: ordinal order, id and text, empty for nothing';
end $$;

-- ---------------------------------------------------------------------
-- 5. Datasets: a table is registered, not chunked, and appends accumulate.
-- ---------------------------------------------------------------------
do $$
declare v_ch uuid; v_r1 uuid; v_r2 uuid; v jsonb;
begin
    insert into content.channels (name, kind) values ('t-tables','file_upload')
    returning id into v_ch;
    insert into content.resources (channel_id, title) values (v_ch, 'jan.csv') returning id into v_r1;
    insert into content.resources (channel_id, title) values (v_ch, 'feb.csv') returning id into v_r2;

    v := content.register_dataset(v_r1, 'sales', 'p8-content',
            'datasets/sales/aaa.parquet',
            '[{"name":"month","type":"string"},{"name":"amount","type":"double"}]'::jsonb,
            100, 'append');
    perform content.register_dataset(v_r2, 'sales', 'p8-content',
            'datasets/sales/bbb.parquet',
            '[{"name":"month","type":"string"},{"name":"amount","type":"double"}]'::jsonb,
            50, 'append');

    if (select row_count from content.datasets where name='sales') is distinct from 150
       or (select file_count from content.datasets where name='sales') is distinct from 2 then
        raise exception 'an append did not accumulate: %',
            (select to_jsonb(d) from content.datasets d where name='sales');
    end if;

    -- The reader is a glob over the prefix, which is the whole of the
    -- "Iceberg-like" claim: two uploads, one logical table, one read.
    if content.dataset_uri('sales') <> 's3://p8-content/datasets/sales/*.parquet' then
        raise exception 'the reader would look in the wrong place: %',
            content.dataset_uri('sales');
    end if;

    -- 'replace' drops the other members and keeps the bytes: deleting objects
    -- is not this function's authority.
    perform content.register_dataset(v_r2, 'sales', 'p8-content',
            'datasets/sales/ccc.parquet', '[]'::jsonb, 70, 'replace');
    if (select file_count from content.datasets where name='sales') is distinct from 1
       or (select row_count from content.datasets where name='sales') is distinct from 70 then
        raise exception 'replace did not replace';
    end if;
    if not exists (select 1 from content.resources where id = v_r1) then
        raise exception 'replace deleted a resource -- it may only forget a member';
    end if;
    raise notice 'datasets: appends accumulate, replace forgets members not bytes';
end $$;

-- ---------------------------------------------------------------------
-- 6. install_ingest_workflow: what it does when the deployment cannot embed.
--
-- The fixture corpus registers `demo-quad-a` as the DEFAULT model, with
-- provider `fixture` and no endpoint -- deliberately, so retrieval can be
-- tested with no model server. That makes it the perfect probe for the
-- installer: choosing it silently would define a pipeline whose every run
-- fails at the embed step.
-- ---------------------------------------------------------------------
do $$
declare v_msg text; v_spec jsonb;
begin
    -- A model the CALLER named, which cannot be called, must RAISE. Silently
    -- installing a lesser pipeline than the one that was asked for is the
    -- failure-reports-success shape.
    begin
        perform content.install_ingest_workflow('demo-quad-a', 'ingest', 't_ingest_named');
        raise exception 'naming an uncallable model was accepted';
    exception when others then
        if sqlerrm not like '%fixture%' and sqlerrm not like '%provider%' then
            raise exception 'refused for the wrong reason: %', sqlerrm;
        end if;
    end;

    -- A default it chose ITSELF degrades to parse-only and says why.
    select content.install_ingest_workflow(null, 'ingest', 't_ingest_default') into v_msg;
    if v_msg not like '%parse only%' then
        raise exception 'the installer did not degrade: %', v_msg;
    end if;
    if v_msg not like '%demo-quad-a%' or v_msg not like '%provider%' then
        raise exception
            'the message does not carry the compiler''s own reason: %', v_msg;
    end if;

    select spec into v_spec from workflow.definitions
     where name = 't_ingest_default' order by version desc limit 1;
    if jsonb_array_length(v_spec->'steps') <> 1
       or v_spec->'steps'->0->>'kind' <> 'work' then
        raise exception 'the parse-only pipeline is not one work step: %', v_spec;
    end if;
    raise notice 'installer: named model raises, chosen default degrades and says why';
end $$;

-- With a callable model, the pipeline is three steps and the embed template
-- is expanded from the registry -- no url in any document.
do $$
declare v_msg text; v_spec jsonb; v_tmpl jsonb;
begin
    insert into aiq.embedding_models (name, dim, provider, endpoint)
    values ('t-ingest-model', 768, 'ollama', 'http://localhost:11434/api/embeddings');

    select content.install_ingest_workflow('t-ingest-model', 'ingest', 't_ingest_full') into v_msg;
    select spec into v_spec from workflow.definitions
     where name = 't_ingest_full' order by version desc limit 1;

    if jsonb_array_length(v_spec->'steps') <> 2 then
        raise exception 'expected parse and embed: %', v_spec;
    end if;
    v_tmpl := v_spec->'steps'->1->'input';
    if v_tmpl->>'op' <> 'embed' or v_tmpl->>'model' <> 't-ingest-model' then
        raise exception 'the embed step does not name the model: %', v_tmpl;
    end if;
    -- A `work` step, not a matrix of `embed:` children, and the test says so
    -- explicitly because the declarative shape is the one a reader expects:
    -- corpus vectors cannot travel through tasks.output (64KB against ~31KB
    -- per 1536-dimension vector), so batching requires the process that
    -- receives them to write them. ingestion.sql carries the argument.
    if v_spec->'steps'->1->>'kind' <> 'work' then
        raise exception 'the embed step is not a work step: %', v_spec->'steps'->1;
    end if;
    raise notice 'installer: parse -> embed (batched, model from the registry)';
end $$;

-- ---------------------------------------------------------------------
-- 6b. The batch request is built from the registry, not from a document.
--
-- The whole point of embed_batch_call: a worker learns the url, the body
-- shape, where the vectors are and WHICH CREDENTIAL NAME to use from the same
-- two tables `embed:` reads. A second code path that knew any of that itself
-- is how a batch path starts calling a different model than the single path.
-- ---------------------------------------------------------------------
do $$
declare v jsonb;
begin
    v := aiq.embed_batch_call('t-ingest-model',
             '["alpha","beta"]'::jsonb);
    if v->>'url' is null or v->>'model' <> 't-ingest-model' then
        raise exception 'the batch call was not resolved from the registry: %', v;
    end if;
    -- ollama has no batch template, so a batch is N calls and the spec says so
    -- rather than pretending: the single-text shapes come back too.
    if (v->>'batch')::boolean is not false then
        raise exception 'ollama was described as batch-capable: %', v;
    end if;
    if v->'single_template' is null or v->>'single_path' is null then
        raise exception
            'a provider that cannot batch must still be callable one text at a '
            'time, and the spec carries no single-text shape: %', v;
    end if;

    -- openai can, and the texts become a jsonb ARRAY in the body rather than a
    -- string containing JSON -- the same whole-value rule embed_call follows.
    insert into aiq.embedding_models (name, dim, provider, endpoint, credential_ref)
    values ('t-batch-model', 1536, 'openai', 'https://example.invalid/v1/embeddings', 'X_KEY');
    v := aiq.embed_batch_call('t-batch-model', '["alpha","beta"]'::jsonb);
    if (v->>'batch')::boolean is not true then
        raise exception 'openai was not described as batch-capable: %', v;
    end if;
    if jsonb_typeof(v->'body'->'input') <> 'array'
       or jsonb_array_length(v->'body'->'input') <> 2 then
        raise exception 'the texts did not arrive as an array: %', v->'body';
    end if;
    if v->>'credential_ref' <> 'X_KEY' then
        raise exception 'the credential NAME did not come along: %', v;
    end if;
    if v->>'jsonpath' <> 'data' then
        raise exception 'the batch response path is wrong: %', v;
    end if;
    raise notice 'embed_batch_call: array body, batch path, credential by name';
end $$;

-- record_embeddings writes the space, and re-embedding replaces.
do $$
declare v_chunk uuid; v_n int; v_vec jsonb;
begin
    select id into v_chunk from content.resource_chunks limit 1;
    if v_chunk is null then
        raise notice 'no chunks on this database -- skipping record_embeddings';
        return;
    end if;
    select jsonb_agg(1.0) into v_vec from generate_series(1, 1536);

    v_n := aiq.record_embeddings('t-batch-model',
        jsonb_build_array(jsonb_build_object('chunk_id', v_chunk, 'embedding', v_vec)));
    if v_n <> 1 then
        raise exception 'expected one vector landed, got %', v_n;
    end if;
    -- The space is created on demand: a caller must not have to arrange it.
    if to_regclass('aiq.emb_t_batch_model') is null then
        raise exception 'record_embeddings did not register the space';
    end if;
    -- Twice is an update, not a duplicate and not an error.
    v_n := aiq.record_embeddings('t-batch-model',
        jsonb_build_array(jsonb_build_object('chunk_id', v_chunk, 'embedding', v_vec)));
    if v_n <> 1 or (select count(*) from aiq.emb_t_batch_model) <> 1 then
        raise exception 're-embedding a chunk did not replace its vector';
    end if;
    raise notice 'record_embeddings: space created on demand, re-embed replaces';
end $$;

-- ---------------------------------------------------------------------
-- 6c. The SECOND indexer, over the same parse.
--
-- The claim this section pins is the shape: `parse` has two dependents, so the
-- semantic index and the graph index are siblings rather than a chain. A
-- deployment with no embedding model can still index a graph, and a failed
-- extraction does not cost the vectors.
-- ---------------------------------------------------------------------
do $$
declare v_msg text; v_spec jsonb; v_keys text[]; v_tmpl jsonb;
begin
    if to_regprocedure('aiq.install_structure_null(text)') is null then
        raise notice 'graph.sql is not installed -- skipping the graph branch';
        return;
    end if;
    perform aiq.install_structure_null('gpt-4o-mini');

    select content.install_ingest_workflow(
               p_model => 't-ingest-model', p_name => 't_ingest_two',
               p_graph_index => true, p_graph_model => 'gpt-4o-mini') into v_msg;

    select spec into v_spec from workflow.definitions
     where name = 't_ingest_two' order by version desc limit 1;
    select array_agg(s->>'key' order by ord) into v_keys
      from jsonb_array_elements(v_spec->'steps') with ordinality t(s, ord);

    if v_keys is distinct from array['parse','embed','graph','land_graph'] then
        raise exception 'the two-index pipeline is not parse/embed/graph/land_graph: %', v_keys;
    end if;

    -- SIBLINGS, not a chain: both index branches wait on the parse and on
    -- nothing else.
    if (v_spec->'steps'->1->'depends_on')::text <> '["parse"]'
       or (v_spec->'steps'->2->'depends_on')::text <> '["parse"]' then
        raise exception
            'the two indexes are not siblings -- one waits on the other: % / %',
            v_spec->'steps'->1->'depends_on', v_spec->'steps'->2->'depends_on';
    end if;

    -- The extractor's prompt and schema come from the AGENT ROW, so the agent
    -- is still the unit of authorship even though the transport is a rest call.
    v_tmpl := v_spec->'steps'->2->'input'->'template'->'input';
    if v_tmpl->'body'->'response_format'->'json_schema'->'schema' is null then
        raise exception 'the extractor call carries no output shape: %', v_tmpl;
    end if;
    if (v_tmpl->'body'->'messages'->0->>'content') not like '%Assert nothing the document does not state%' then
        raise exception
            'the system prompt did not come from agentic.agents -- an extractor '
            'whose prompt lives in a workflow is not a row any more: %',
            v_tmpl->'body'->'messages'->0;
    end if;
    if v_tmpl->'extractor'->>'agent' <> 'structure_null' then
        raise exception 'the task will not say which extractor produced it: %', v_tmpl;
    end if;

    -- The row source is windows, and the fan-in is the one that parses and
    -- cleans -- see ingestion.sql for why it is not aiq.land_graph_fanout.
    if v_spec->'steps'->2->'input'->'rows'->>'function' <> 'windows_to_index' then
        raise exception 'the graph matrix does not fan out over windows: %',
            v_spec->'steps'->2->'input'->'rows';
    end if;
    if v_spec->'steps'->3->'input'->>'function' <> 'land_graph_windows' then
        raise exception 'nothing lands the graphs: %', v_spec->'steps'->3;
    end if;

    if v_msg not like '%graph-index%' then
        raise exception 'the installer did not say it installed a second index: %', v_msg;
    end if;
    raise notice 'installer: parse -> (embed | graph over windows -> land), two indexes, one parse';
end $$;

-- windows_to_index carries the two fields the fan-in attributes a graph with.
do $$
declare v_res uuid; v jsonb;
begin
    select res into v_res from t_ing;
    v := content.windows_to_index(v_res);
    if jsonb_array_length(v) = 0 then
        raise exception 'a chunked resource produced no windows';
    end if;
    if v->0->>'resource_id' is null or v->0->'window_ordinal' is null
       or v->0->>'content' is null then
        raise exception
            'a window must carry the resource and the ordinal, or a landed node '
            'cannot be traced to the passage that named it: %', v->0;
    end if;
    -- A chunkless resource fans out over NOTHING, which is what lets a tabular
    -- upload skip the graph branch instead of failing it. Found by running it:
    -- the document-level shape raised on a CSV and failed an ingest run that
    -- had otherwise succeeded.
    if content.windows_to_index(gen_random_uuid()) <> '[]'::jsonb then
        raise exception 'an unknown resource fanned out over something';
    end if;
    raise notice 'windows_to_index: resource and ordinal on every row, empty for a table';
end $$;

-- extractor_call refuses an agent that cannot produce a graph, by name.
do $$
declare v_ok boolean;
begin
    if to_regprocedure('aiq.extractor_call(text,text,text,text,text)') is null then
        return;
    end if;
    begin
        perform aiq.extractor_call('no_such_agent', 'gpt-4o-mini', 'hello');
        raise exception 'an unknown extractor was accepted';
    exception when others then
        if sqlerrm not like '%an extractor is a row%' then
            raise exception 'refused for the wrong reason: %', sqlerrm;
        end if;
    end;

    -- An agent with a schema that is not a graph schema is an extractor for
    -- something else, and land_graph could not land what it returns.
    perform agentic.upsert_agent(jsonb_build_object(
        'name','t_not_a_graph','category','extractor','audience','internal',
        'system_prompt','x',
        'structured_output_schema', '{"type":"object","properties":{"summary":{"type":"string"}}}'::jsonb));
    begin
        perform aiq.extractor_call('t_not_a_graph', 'gpt-4o-mini', 'hello');
        raise exception 'a non-graph extractor was accepted';
    exception when others then
        if sqlerrm not like '%does not declare a GRAPH schema%' then
            raise exception 'refused for the wrong reason: %', sqlerrm;
        end if;
    end;
    raise notice 'extractor_call: an unknown agent and a non-graph shape are both refused by name';
end $$;

-- ---------------------------------------------------------------------
-- 7. land_embeddings refuses a matrix from another run.
--
-- Same guard matrix_outputs has, and for the same reason: a registered step
-- function handed an arbitrary task id would be a read of someone else's run.
-- ---------------------------------------------------------------------
do $$
declare v_run uuid; v_task uuid;
begin
    select id into v_run from workflow.runs limit 1;
    if v_run is null then
        raise notice 'no runs on this database -- skipping the cross-run guard';
        return;
    end if;
    select id into v_task from workflow.tasks where run_id = v_run limit 1;

    begin
        -- No workflow.current_run_id is set outside a step, so this is exactly
        -- the "a task id from elsewhere" case.
        perform aiq.land_embeddings(v_task);
        raise exception 'land_embeddings read a task outside its own run';
    exception when others then
        if sqlerrm not like '%not the run being executed%' then
            raise exception 'refused for the wrong reason: %', sqlerrm;
        end if;
    end;
    raise notice 'land_embeddings: refuses a matrix task from another run';
end $$;

-- ---------------------------------------------------------------------
-- 8. GRANTING IS NOT SCOPING -- the same enumeration query/06 §5 runs over
--    aiq, run over content.
--
-- Postgres grants EXECUTE on a new function to PUBLIC unless it is taken away,
-- so every `grant execute ... to worker` in this collection is an ADDITION to
-- access every role already had. The engine found eleven functions like that.
-- Here the interesting half is which layer was actually holding: an anonymous
-- caller is refused with "permission denied for SCHEMA content", because
-- web_anon was never granted usage -- so the function grants were decorative
-- and the schema grant was load-bearing, which is not a defence anyone chose.
--
-- Written as a predicate over pg_proc rather than as a list of names, for the
-- reason query/06 gives: the function added next month is the one that is not
-- on the list.
-- ---------------------------------------------------------------------
do $$
declare v_bad text;
begin
    select string_agg(p.proname, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'content' and p.prosecdef
      and has_function_privilege('web_anon', p.oid, 'execute');
    if v_bad is not null then
        raise exception
            'content SECURITY DEFINER functions are callable by web_anon: %. '
            'Only schema usage stands between an unauthenticated request and '
            'these, and record_chunks rewrites the corpus SEMANTIC reads.', v_bad;
    end if;

    -- The worker-facing three, specifically: ingest_target hands back a bucket
    -- and an object key, and the read path a user is offered is the Content
    -- Server proxy exactly so that a storage location never becomes a
    -- capability someone holds.
    select string_agg(p.proname, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'content'
      and p.proname in ('ingest_target','record_ingest','register_dataset')
      and has_function_privilege('authenticated', p.oid, 'execute');
    if v_bad is not null then
        raise exception
            'worker-only content functions are callable by authenticated: %. '
            'Their authorization IS the grant, so a second holder of it is a '
            'second authorization path nobody wrote down.', v_bad;
    end if;
    raise notice 'content: no definer function is reachable by web_anon, and the worker-only three are worker-only';
end $$;

-- ---------------------------------------------------------------------
-- 9. A PARSE THAT FAILS FOR GOOD LEAVES ITS RESOURCE 'failed', NOT 'pending'.
--
-- Found on 0.1.6: a parse that failed terminally on a duplicate key ended its
-- run, and its resource read 'pending' from then on, because only a parse that
-- succeeds reaches the code that sets a status. Driven through the calls the
-- worker makes -- claim_task, record_ingest, complete_task, fail_task -- on a
-- queue of its own, so no fixture task is claimed by mistake. Three uploads:
-- one parse succeeds, one fails for good, one fails and will be retried.
-- ---------------------------------------------------------------------
do $$
declare
    v_ch  uuid;
    v_ok  uuid; v_dead uuid; v_retry uuid;
    r     record;
    v_seen int := 0;
begin
    perform content.install_ingest_workflow(null, 't_fail_q', 't_ingest_fail');
    insert into content.channels (name, kind, config, visibility)
    values ('t-fail-uploads', 'file_upload', '{"ingest_workflow": "t_ingest_fail"}', 'public')
    returning id into v_ch;
    v_ok    := content.register_upload('t-fail-uploads', 't-fail-ok',    'b', 't-fail/ok',    1, 'text/plain', 'parses');
    v_dead  := content.register_upload('t-fail-uploads', 't-fail-dead',  'b', 't-fail/dead',  1, 'text/plain', 'fails for good');
    v_retry := content.register_upload('t-fail-uploads', 't-fail-retry', 'b', 't-fail/retry', 1, 'text/plain', 'fails once');

    -- Claim all three, then act on each by the resource its run names.
    perform workflow.claim_task('t_fail_q', 't-fail-worker') from generate_series(1, 3);
    for r in
        select t.id as task, (run.input->>'resource_id')::uuid as res
          from workflow.tasks t join workflow.runs run on run.id = t.run_id
         where t.queue = 't_fail_q' and t.status = 'running'
    loop
        v_seen := v_seen + 1;
        if r.res = v_ok then
            perform content.record_ingest(v_ok, '{"mode": "text", "chunks": [{"content": "parsed"}]}');
            perform workflow.complete_task(r.task, '{"result": {"ok": true}}');
        elsif r.res = v_dead then
            perform workflow.fail_task(r.task,
                '{"error": "duplicate key value violates unique constraint", "terminal": true}', true);
        else
            perform workflow.fail_task(r.task, '{"error": "connection reset"}', false);
        end if;
    end loop;
    if v_seen <> 3 then
        raise exception 'expected to claim three parse tasks on t_fail_q, claimed %', v_seen;
    end if;

    for r in
        select res.title, res.status, run.status as run_status
          from content.resources res
          join workflow.runs run on run.external_id = 'ingest:' || res.id::text
         where res.channel_id = v_ch
    loop
        if (r.title, r.run_status, r.status) not in (('parses', 'succeeded', 'ready'),
                                                      ('fails for good', 'failed', 'failed'),
                                                      ('fails once', 'running', 'pending')) then
            raise exception 'upload "%": run %, resource % -- a run that ended for good must '
                            'not leave its resource pending, and one that will retry must',
                            r.title, r.run_status, r.status;
        end if;
    end loop;
    raise notice 'content: a terminally failed parse fails its resource; success and retry are untouched';
end $$;

-- A model answer carrying the NUL escape still lands. `\u0000` is valid JSON
-- that jsonb refuses, and land_graph_windows cast each child's answer directly,
-- so one such window failed the whole document's graph landing (the tour's
-- extractor produced one from a real GitHub issue).
do $$
declare v jsonb;
begin
    begin
        perform ('{"n":"a\u0000b"}')::jsonb;
        raise exception 'jsonb accepted the NUL escape -- the premise of content.model_json changed';
    exception when untranslatable_character or invalid_text_representation then null;
    end;
    v := content.model_json('{"nodes":[{"k":"x","n":"a\u0000b"}],"edges":[]}');
    if v->'nodes'->0->>'n' is distinct from 'ab' then
        raise exception 'model_json did not strip the NUL escape: %', v;
    end if;
    begin
        perform content.model_json('not json');
        raise exception 'model_json accepted text that is not JSON';
    exception when invalid_text_representation then null;
    end;
    -- A SOURCE-TEXT GREP, and what it can and cannot catch (REM-73's third
    -- bullet, applied to the greps that survive rather than only to the two
    -- that were replaced).
    --
    -- It CAN catch the call being removed or renamed -- the fan-in going back
    -- to a bare ::jsonb cast, which is the regression that matters, because a
    -- model answer carrying a \u0000 escape then aborts the landing.
    --
    -- It CANNOT catch the call being made and its result discarded, nor a
    -- second unparsed path added alongside it. And it would pass on the string
    -- appearing only in a COMMENT -- the failure that made both arms of
    -- content/01 §6 inert for months. Checked here rather than assumed: the one
    -- occurrence in this body is the live assignment
    -- `v_graph := content.model_json(...)`, not a comment.
    --
    -- It stays a grep because the behavioural version needs a completed child
    -- task carrying a NUL escape through the real fan-in, which is evals
    -- territory (dev/tests/evals), not a single transaction. The statements
    -- above it DO measure model_json's behaviour directly; this one only
    -- asserts that the fan-in is wired to it.
    if not exists (select 1 from pg_proc where oid = 'content.land_graph_windows(uuid)'::regprocedure
                     and prosrc like '%content.model_json(%') then
        raise exception 'land_graph_windows does not parse child answers through content.model_json';
    end if;
    raise notice 'content: a model answer with a NUL escape parses, and the graph fan-in uses the parser that allows it';
end $$;

-- ---------------------------------------------------------------------
-- 6d. A graph landed from an upload stays in the upload's org.
--
-- content.land_graph_windows did not pass the resource's org to
-- aiq.upsert_graph, which reads an omitted org as the shared tier -- so
-- every entity and edge the upload pipeline extracted was readable outside
-- the org its document was uploaded into. aiq.land_graph always passed it.
-- Found backfilling private transcripts on the dogfood stack, 2026-09-11.
-- ---------------------------------------------------------------------
do $$
declare v_org uuid := gen_random_uuid(); v_ch uuid; v_res uuid; v_run uuid; v_mx uuid;
        v_r jsonb; v_edges int; v_wrong int;
begin
    if to_regprocedure('content.land_graph_windows(uuid)') is null then
        raise notice 'graph.sql is not installed -- skipping graph org scoping';
        return;
    end if;
    insert into rbac.orgs (id, slug, name) values (v_org, 't-graph-org', 'graph org');
    select channel into v_ch from t_ing limit 1;
    insert into content.resources (channel_id, title, status, org_id)
    values (v_ch, 'g.md', 'ready', v_org) returning id into v_res;

    insert into workflow.definitions (name, spec) values ('t_graph_org', jsonb_build_object(
        'steps', jsonb_build_array(jsonb_build_object(
            'key', 'graph', 'kind', 'matrix', 'queue', 't', 'input', jsonb_build_object(
                'items', jsonb_build_array(jsonb_build_object(
                    'resource_id', v_res, 'window_ordinal', 0, 'content', 'x')),
                'max_fanout', 5,
                'template', jsonb_build_object('queue', 't-graph', 'kind', 'work',
                                               'input', jsonb_build_object('op', 'noop')))))));
    v_run := workflow.start_workflow('t_graph_org', '{}'::jsonb);
    select id into v_mx from workflow.tasks where run_id = v_run and step_key = 'graph';

    update workflow.tasks set status = 'running', claimed_by = 't', claimed_at = now()
     where matrix_parent_id = v_mx;
    perform workflow.complete_task(t.id, jsonb_build_object('result',
        '{"nodes":[{"k":"company","n":"Orgville Metals"},{"k":"company","n":"Orgville Parts"}],
          "edges":[{"s":0,"t":1,"r":"mentions"}]}'::jsonb))
       from workflow.tasks t where t.matrix_parent_id = v_mx;

    perform set_config('workflow.current_run_id', v_run::text, true);
    v_r := content.land_graph_windows(v_mx);

    select count(*), count(*) filter (where e.org_id is distinct from v_org)
      into v_edges, v_wrong
      from aiq.edges e
     where e.provenance->'sources' @> jsonb_build_array(jsonb_build_object('resource_id', v_res::text));
    if v_edges <> 1 or v_wrong <> 0 then
        raise exception 'an upload''s graph did not land in its org: % edges, % elsewhere (receipt %)',
            v_edges, v_wrong, v_r;
    end if;
    if exists (select 1 from aiq.soft_nodes s
                where s.key in ('orgville metals', 'orgville parts')
                  and s.org_id is distinct from v_org) then
        raise exception 'an upload''s entities landed outside its org';
    end if;
    raise notice 'content: a graph extracted from an upload lands in the upload''s org, not the shared tier';
end $$;

rollback;
