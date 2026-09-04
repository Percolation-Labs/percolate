-- ARTIFACTS -- the fourth output class, asserted end to end.
--
-- `../../../specs/workflow-engine/outputs.md`. A step produces rows, a
-- validated assistant message, an inline payload, or BYTES. This file is about
-- the fourth: what a step does when its output does not fit in a column, and
-- what stops the answer from being a bucket path in a JSONB field.
--
-- The bytes half needs object storage, so the object is written by the harness
-- before this runs (see the header of section 3). Everything else is
-- deterministic and offline.

\set ON_ERROR_STOP on

begin;

set local role app_owner;

-- The cap is set locally rather than assumed: this database has it raised, and
-- a test that depends on the operator's number tests the operator.
set local workflow.max_payload_bytes = '65536';

insert into workflow.definitions (name, spec) values
('t_art', '{"steps":[{"key":"render","kind":"work","queue":"t"},
                     {"key":"consume","kind":"sql","queue":"t","depends_on":["render"],
                      "input":{"function":"artifact","args":["{{steps.render.$artifact}}"]}}]}');

-- ---------------------------------------------------------------------
-- 1. An oversized inline payload is refused, terminally, and the message
--    names the remedy that actually exists.
--
--    It used to name `$ref`, which never worked: the check uses the jsonb `?`
--    operator (top-level only) while YAML.md nests every payload under
--    `result`, so the shape that satisfied the check broke the templates and
--    the shape that kept the templates was refused. Probed both ways before
--    this was changed.
-- ---------------------------------------------------------------------
do $$
declare v_run uuid; v_task uuid; t workflow.tasks;
begin
    v_run := workflow.start_workflow('t_art', '{}'::jsonb);
    select id into v_task from workflow.tasks where run_id = v_run and step_key = 'render';

    -- Incompressible, so the byte count is the byte count -- pg_column_size on
    -- an in-memory jsonb is uncompressed today, and a repeat('x', n) payload
    -- would stop testing anything the day that changes. (gen_random_bytes caps
    -- at 1024, which is why this is aggregated rather than asked for at once.)
    perform workflow.complete_task(v_task, jsonb_build_object(
        'result', (select string_agg(md5(random()::text), '')
                   from generate_series(1, 3000))));

    select * into t from workflow.tasks where id = v_task;
    if t.status <> 'failed' then
        raise exception 'an unstorable output did not fail the task: %', t.status;
    end if;
    if t.attempts > 1 then
        raise exception 'an unstorable output was retried (% attempts)', t.attempts;
    end if;
    if t.error->>'error' not like '%$artifact%'
       or t.error->>'error' not like '%register_artifact%' then
        raise exception 'the failure does not name the remedy: %', t.error;
    end if;
    -- The old spelling must not survive in the guidance.
    if t.error->>'error' like '%s3://%' then
        raise exception 'the failure still tells the caller to write a bucket path: %', t.error;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. The two ways of getting the ref wrong, both terminal, both saying what
--    to write instead. Neither is retryable: a bad ref is bad on every
--    attempt, exactly like an oversized payload.
-- ---------------------------------------------------------------------
do $$
declare v_run uuid; v_task uuid; t workflow.tasks;
begin
    -- 2a. The old spelling, pointing at a bucket.
    v_run := workflow.start_workflow('t_art', '{}'::jsonb);
    select id into v_task from workflow.tasks where run_id = v_run and step_key = 'render';
    perform workflow.complete_task(v_task,
        jsonb_build_object('result', 'ok', '$ref', 's3://p8-content/artifacts/x'));
    select * into t from workflow.tasks where id = v_task;
    if t.status <> 'failed' or t.error->>'error' not like '%$artifact%' then
        raise exception 'a legacy $ref was accepted or failed unhelpfully: % / %',
            t.status, t.error;
    end if;
    if t.attempts > 1 then
        raise exception 'a legacy $ref was retried -- it is the same string every time';
    end if;

    -- 2b. The right key, a bucket path for a value. This is the mistake the
    --     old spec actively invited, so it is the one worth asserting.
    v_run := workflow.start_workflow('t_art', '{}'::jsonb);
    select id into v_task from workflow.tasks where run_id = v_run and step_key = 'render';
    perform workflow.complete_task(v_task,
        jsonb_build_object('result', 'ok', '$artifact', 's3://p8-content/artifacts/x'));
    select * into t from workflow.tasks where id = v_task;
    if t.status <> 'failed' or t.error->>'error' not like '%resource uuid%' then
        raise exception 'a bucket path passed as $artifact was accepted: % / %',
            t.status, t.error;
    end if;

    -- 2c. And the extractor agrees: a malformed ref is not a ref.
    if workflow.artifact_ref('{"$artifact":"s3://b/k"}'::jsonb) is not null
       or workflow.artifact_ref('{"$artifact":"yes"}'::jsonb) is not null
       or workflow.artifact_ref('{"result":{"$artifact":"11111111-1111-1111-1111-111111111111"}}'::jsonb)
          is not null then
        raise exception 'artifact_ref accepted something that is not a top-level uuid ref';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. The whole path, with real bytes.
--
--    The object is written to MinIO by the harness before this file runs:
--
--      docker run --rm --network dev_default minio/mc \
--        ... cp report.bin m/p8-content/artifacts/probe/report.bin
--
--    1.2 MB of urandom -- four hundred times the wire limit, and
--    incompressible, so no amount of TOAST makes it fit. The checksum below is
--    that object's; the test asserts the sizes line up rather than re-hashing,
--    because the database is not where the bytes are.
-- ---------------------------------------------------------------------
do $$
declare
    v_run  uuid; v_task uuid; v_res uuid; t workflow.tasks;
    v_args jsonb; v_node int; v_msg text;
begin
    v_run := workflow.start_workflow('t_art', '{}'::jsonb);
    select id into v_task from workflow.tasks where run_id = v_run and step_key = 'render';

    v_res := workflow.register_artifact(
        p_task_id      => v_task,
        p_checksum     => 'e21e6964d2e92a16dee3624571febeafba4f442acf95d231824c7fcdefa027c5',
        p_bucket       => 'p8-content',
        p_object_key   => 'artifacts/probe/report.bin',
        p_size_bytes   => 1200000,
        p_content_type => 'application/octet-stream',
        p_title        => 'probe report');

    -- The ref is a SIBLING of result, which is the placement the whole design
    -- turns on: `?` finds it, output_schema never sees it, and
    -- {{steps.render.result}} still means the value.
    perform workflow.complete_task(v_task, jsonb_build_object(
        'result', jsonb_build_object('rows', 12, 'title', 'probe report'),
        '$artifact', v_res));

    select * into t from workflow.tasks where id = v_task;
    if t.status <> 'succeeded' then
        raise exception 'a task that offloaded its bytes did not complete: % / %',
            t.status, t.error;
    end if;

    -- 3a. Both halves survive into runs.context, and each means what it says.
    if (select context #>> '{render,result,rows}' from workflow.runs where id = v_run) is distinct from '12' then
        raise exception 'the inline result did not survive alongside the ref';
    end if;
    if (select workflow.artifact_ref(context->'render') from workflow.runs where id = v_run)
       is distinct from v_res then
        raise exception 'the ref did not survive into runs.context';
    end if;

    -- 3b. A template reaches it with no resolver change: resolve_args' pattern
    --     already admits `$`, which is why the ref could be spelled this way.
    v_args := workflow.resolve_args('["{{steps.render.$artifact}}"]'::jsonb, v_run);
    if (v_args->>0) <> v_res::text then
        raise exception '{{steps.render.$artifact}} resolved to % rather than the resource id',
            v_args->>0;
    end if;

    -- 3c. And a downstream step gets the bytes' location IN-DATABASE, through
    --     the ordinary sql-step path -- no worker, no process, the artifact
    --     reached by an ordinary {{...}} argument. This is the assertion the
    --     rest of the section exists to make possible.
    perform workflow.drain_sql_steps(v_run, 10);
    select * into t from workflow.tasks where run_id = v_run and step_key = 'consume';
    if t.status <> 'succeeded' then
        raise exception 'the sql step could not resolve the artifact: % / %',
            t.status, t.error;
    end if;
    if t.output #>> '{result,bucket}' <> 'p8-content'
       or t.output #>> '{result,object_key}' <> 'artifacts/probe/report.bin'
       or (t.output #>> '{result,size_bytes}')::bigint <> 1200000 then
        raise exception 'the artifact resolved to the wrong object: %', t.output;
    end if;

    -- A ref that does not resolve is terminal, not a null result reported as
    -- success -- the failure mode a set-returning step function would have had.
    begin
        perform workflow.artifact('00000000-0000-0000-0000-000000000000'::uuid);
        raise exception 'an unresolvable artifact returned instead of raising';
    exception when others then
        get stacked diagnostics v_msg = message_text;
        if v_msg not like '%not resolvable%' then raise; end if;
    end;

    -- 3d. Both directions of the link, from one view.
    if not exists (select 1 from workflow.v_artifacts
                   where run_id = v_run and task_id = v_task
                     and resource_id = v_res and step_key = 'render'
                     and object_key = 'artifacts/probe/report.bin') then
        raise exception 'v_artifacts does not join the task to what it produced';
    end if;

    -- 3e. THE TWO COLLISIONS THAT MADE 'stored' A STATUS OF ITS OWN.
    --
    -- An artifact is retrievable the moment it lands and is not corpus. Under
    -- 'ready' it would be permanent drift noise (a resource with no chunks)
    -- and a graph node (machine-generated volume in the node registry, which
    -- is the exact argument graph-identity.md uses to keep chunks out).
    -- Neither is a predicate anyone has to remember: the status excludes it
    -- from both by construction.
    if exists (select 1 from content.check_drift() where id = v_res) then
        raise exception 'a workflow artifact is reported as content drift -- '
            'every artifact ever produced would be permanent noise in that report';
    end if;
    select count(*) into v_node from aiq.nodes n
    join aiq.node_keys k on k.node_id = n.id
    where n.entity_type = 'document' and k.key = 'probe report';
    if v_node > 0 then
        raise exception 'a workflow artifact was projected into the node registry as a document';
    end if;

    -- 3f. Idempotent under retry: the task id is the resource's external id,
    --     so attempt 2 repoints one resource instead of orphaning the first.
    if workflow.register_artifact(
           v_task, 'e21e6964d2e92a16dee3624571febeafba4f442acf95d231824c7fcdefa027c5',
           'p8-content', 'artifacts/probe/report.bin', 1200000) <> v_res then
        raise exception 're-registering the same task''s artifact created a second resource';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 4. A step that produced ONLY bytes has no value, and says so.
-- ---------------------------------------------------------------------
do $$
declare v_run uuid; v_task uuid; v_res uuid; v_msg text;
begin
    v_run := workflow.start_workflow('t_art', '{}'::jsonb);
    select id into v_task from workflow.tasks where run_id = v_run and step_key = 'render';
    v_res := workflow.register_artifact(
        v_task, repeat('a', 64), 'p8-content', 'artifacts/probe/only.bin', 99);
    perform workflow.complete_task(v_task, jsonb_build_object('$artifact', v_res));

    begin
        perform workflow.resolve_args('["{{steps.render.result}}"]'::jsonb, v_run);
        raise exception 'a bytes-only step let {{steps.render.result}} resolve to something';
    exception when others then
        get stacked diagnostics v_msg = message_text;
        if v_msg not like '%resolved to nothing%' then
            raise;
        end if;
    end;
end $$;

do $$
begin
    raise notice 'workflow/08: an oversized payload names $artifact and register_artifact, not a bucket path';
    raise notice 'workflow/08: $ref and a bucket path passed as $artifact both fail terminally, with the fix';
    raise notice 'workflow/08: the ref is a sibling of result -- both survive, and {{steps.x.$artifact}} resolves';
    raise notice 'workflow/08: an artifact resolves to its object in-database, and v_artifacts joins both ends';
    raise notice 'workflow/08: status stored keeps artifacts out of the drift report AND out of the node registry';
    raise notice 'workflow/08: re-registering a retried task''s artifact repoints one resource, not two';
end $$;

rollback;
