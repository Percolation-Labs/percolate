-- MATRIX BATCHING -- a child owns a CHUNK of the row set, not a row of it.
--
-- `schema.sql` §20j. §20 gave the map half of map-reduce exactly one
-- granularity: one row, one task. That is right when a row is somebody else's
-- HTTP endpoint and wrong the moment a row is cheap -- a hundred four-
-- millisecond writes become a hundred claims, heartbeats, completions and
-- cascades, and the engine costs more than the job.
--
-- `batch_size` says how many rows one worker may own; `partition_by` says
-- which rows must not be split across workers. Three assertions here are worth
-- more than the rest, because all three are failures that report success:
--
--   1. THE REWIRE STILL COUNTS CHILDREN (§4). The fan-in increments
--      pending_deps once per child. Batching changes how many children there
--      are, and an aggregate released after ninety of a hundred rows is
--      exactly the shape §20's fan-in was built to prevent.
--   2. NO ROW IS LOST OR DUPLICATED (§2, §5). Chunking is arithmetic over a
--      row set, and off-by-one arithmetic produces a run that completes with
--      ninety of a hundred rows processed and nothing anywhere saying so.
--   3. A VARYING COLUMN IS NOT SUBSTITUTED (§7). {{item.tenant}} on a batch
--      spanning two tenants must fail, not silently address the first --
--      which would look correct in every test written at a batch size of one.
--
-- Everything is driven in-database. No worker runs; `work` children are
-- completed by calling complete_task directly, which is what a worker does.

\set ON_ERROR_STOP on

begin;

set local role app_owner;

-- ---------------------------------------------------------------------
-- Fixture. A hundred numbered rows, and a small tenanted set whose
-- partitions are deliberately uneven -- 3/2/1 -- because equal partitions
-- hide every grouping bug there is.
-- ---------------------------------------------------------------------
create function t_bx_hundred() returns jsonb as $fn$
    select jsonb_agg(jsonb_build_object('n', i, 'label', 'row-' || i) order by i)
    from generate_series(1, 100) i;
$fn$ language sql stable;

create function t_bx_tenants() returns jsonb as $fn$
    select jsonb_agg(jsonb_build_object('tenant', t, 'doc', d) order by ord)
    from (values ('acme','a1',1), ('acme','a2',2), ('beta','b1',3),
                 ('acme','a3',4), ('beta','b2',5), ('ceta','c1',6))
         as v(t, d, ord);
$fn$ language sql stable;

-- The reduce half, as a step function: handed the WHOLE batch, it returns one
-- row for it. This is the shape batching exists to make possible -- one call
-- per ten rows rather than ten calls.
create table t_bx_landed (n int);
create function t_bx_land(p_items jsonb) returns jsonb as $fn$
    with ins as (
        insert into t_bx_landed (n)
        select (e->>'n')::int from jsonb_array_elements(p_items) e
        returning n)
    select jsonb_build_object('landed', count(*)) from ins;
$fn$ language sql volatile;

create function t_bx_width(p_items jsonb) returns jsonb as $fn$
    select jsonb_build_object('width', jsonb_array_length(p_items));
$fn$ language sql stable;

select workflow.register_step_function('t_bx_hundred', 't_bx_hundred', '{}');
select workflow.register_step_function('t_bx_tenants', 't_bx_tenants', '{}');
select workflow.register_step_function('t_bx_land',    't_bx_land',    '{jsonb}');
select workflow.register_step_function('t_bx_width',   't_bx_width',   '{jsonb}');

-- ---------------------------------------------------------------------
-- 1. batch_size alone. A hundred rows become TEN tasks, and each one says how
--    many rows it owns without anybody having to count them.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
('t_bx_ten', '{"steps":[
    {"key":"fan", "kind":"matrix", "queue":"bx", "input":{
        "rows":       {"function":"t_bx_hundred", "args":[]},
        "max_fanout": 1000,
        "batch_size": 10,
        "template":   {"queue":"bx-work", "kind":"work"}}},
    {"key":"rollup", "kind":"work", "queue":"bx", "depends_on":["fan"]}
 ]}');

do $$
declare
    v_run  uuid;
    v_fan  workflow.tasks;
    v_kids int;
    v_c0   workflow.tasks;
    v_c9   workflow.tasks;
begin
    v_run := workflow.start_workflow('t_bx_ten', '{}'::jsonb);
    select * into v_fan from workflow.tasks where run_id = v_run and step_key = 'fan';

    select count(*) into v_kids from workflow.tasks where matrix_parent_id = v_fan.id;
    if v_kids <> 10 then
        raise exception 'expected 10 children from 100 rows at batch_size 10, got %', v_kids;
    end if;

    select * into v_c0 from workflow.tasks
     where matrix_parent_id = v_fan.id and step_key = 'fan[0]';
    select * into v_c9 from workflow.tasks
     where matrix_parent_id = v_fan.id and step_key = 'fan[9]';

    -- THE SHAPE SAYS HOW MANY ROWS THE TASK OWNS: `items`, not `item`, and not
    -- `item` quietly set to the first of ten. A reader of this row -- human,
    -- handler or aggregate -- must not be able to mistake a batch for a row.
    if v_c0.input ? 'item' then
        raise exception 'a batched child carries `item`: %', v_c0.input;
    end if;
    if jsonb_array_length(v_c0.input->'items') <> 10 then
        raise exception 'batch 0 holds % rows, expected 10',
            jsonb_array_length(v_c0.input->'items');
    end if;

    -- Contiguous, in source order, and the boundaries where arithmetic says.
    if (v_c0.input#>>'{items,0,n}', v_c0.input#>>'{items,9,n}') <> ('1','10') then
        raise exception 'batch 0 is not rows 1..10: % .. %',
            v_c0.input#>>'{items,0,n}', v_c0.input#>>'{items,9,n}';
    end if;
    if (v_c9.input#>>'{items,0,n}', v_c9.input#>>'{items,9,n}') <> ('91','100') then
        raise exception 'batch 9 is not rows 91..100: % .. %',
            v_c9.input#>>'{items,0,n}', v_c9.input#>>'{items,9,n}';
    end if;

    -- input.batch is what a task carries about its own place in the fan-out,
    -- so a log line or a stuck row reads without joining back to the parent.
    if (v_c9.input#>>'{batch,index}', v_c9.input#>>'{batch,size}') <> ('9','10') then
        raise exception 'batch metadata is wrong: %', v_c9.input->'batch';
    end if;
    if jsonb_typeof(v_c9.input#>'{batch,key}') <> 'null' then
        raise exception 'an unpartitioned batch has a partition key: %',
            v_c9.input#>'{batch,key}';
    end if;

    -- fanout and rows are DIFFERENT numbers now, and both are reported. An
    -- aggregate reporting "100 processed" off a count of children would be
    -- wrong by a factor of batch_size, and would look right.
    if (v_fan.output#>>'{result,fanout}', v_fan.output#>>'{result,rows}')
       <> ('10','100') then
        raise exception 'the matrix output does not distinguish children from rows: %',
            v_fan.output->'result';
    end if;
end $$;

do $$ begin
    raise notice 'workflow/10: 100 rows at batch_size 10 expand to ten children, each holding its ten rows in order';
end $$;

-- ---------------------------------------------------------------------
-- 2. NO ROW IS LOST OR DUPLICATED, and the last batch is short rather than
--    absent. 100 rows at batch_size 30 is 30/30/30/10 -- the case where an
--    off-by-one drops ten rows and the run still reports success.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
('t_bx_thirty', '{"steps":[
    {"key":"fan", "kind":"matrix", "queue":"bx", "input":{
        "rows":       {"function":"t_bx_hundred", "args":[]},
        "max_fanout": 1000,
        "batch_size": 30,
        "template":   {"queue":"bx-work", "kind":"work"}}}
 ]}');

do $$
declare
    v_run   uuid;
    v_fan   uuid;
    v_sizes int[];
    v_all   jsonb;
begin
    v_run := workflow.start_workflow('t_bx_thirty', '{}'::jsonb);
    select id into v_fan from workflow.tasks where run_id = v_run and step_key = 'fan';

    select array_agg(jsonb_array_length(input->'items') order by created_at, step_key)
    into v_sizes from workflow.tasks where matrix_parent_id = v_fan;
    if v_sizes <> array[30,30,30,10] then
        raise exception 'the remainder batch is wrong: %', v_sizes;
    end if;

    -- The row set, reassembled from the children: every row exactly once, in
    -- the order the row function produced them.
    select jsonb_agg(r order by t.created_at, t.step_key, r_ord) into v_all
    from workflow.tasks t
    cross join lateral jsonb_array_elements(t.input->'items') with ordinality x(r, r_ord)
    where t.matrix_parent_id = v_fan;

    if jsonb_array_length(v_all) <> 100 then
        raise exception 'batching lost or duplicated rows: % of 100 survived',
            jsonb_array_length(v_all);
    end if;
    if exists (select 1 from jsonb_array_elements(v_all) with ordinality e(v, ord)
               where (v->>'n')::int <> ord::int) then
        raise exception 'the reassembled row set is not the row set, in order';
    end if;
end $$;

do $$ begin
    raise notice 'workflow/10: 100 rows at batch_size 30 is 30/30/30/10 -- the remainder is short, not missing';
end $$;

-- ---------------------------------------------------------------------
-- 3. matrix_rows() returns the ROW SET, flattened -- because batching is a
--    decision about who executes the snapshot, not about what it is. A caller
--    wanting the batch boundaries wanted matrix_outputs.
--
--    Called with a real identity, the way 04-matrix §1 does, because both
--    shipped bodies authorize against the run.
-- ---------------------------------------------------------------------
do $$
declare v_run uuid; v_fan uuid; v_owner uuid; v_rows jsonb;
begin
    v_run := workflow.start_workflow('t_bx_ten', '{}'::jsonb, 'bx-rows');
    select id into v_fan from workflow.tasks where run_id = v_run and step_key = 'fan';

    if to_regprocedure('workflow.assert_run_access(uuid,text)') is not null then
        v_owner := gen_random_uuid();
        insert into rbac.users (id, email) values (v_owner, 'bx-owner@test.com');
        update workflow.runs set owner_id = v_owner where id = v_run;
        perform set_config('request.jwt.claims',
            json_build_object('sub', v_owner::text)::text, true);
    end if;

    v_rows := workflow.matrix_rows(v_fan);
    perform set_config('request.jwt.claims', '', true);

    if jsonb_array_length(v_rows) <> 100 then
        raise exception
            'matrix_rows returned % entries for a batched fan-out -- it returns the row '
            'set, not the children', jsonb_array_length(v_rows);
    end if;
    if (v_rows#>>'{0,n}', v_rows#>>'{99,n}') <> ('1','100') then
        raise exception 'the flattened row set is not in expansion order';
    end if;
end $$;

do $$ begin
    raise notice 'workflow/10: matrix_rows flattens the batches back to the row set it recorded';
end $$;

-- ---------------------------------------------------------------------
-- 4. THE FAN-IN STILL COUNTS CHILDREN. §20's rewire puts an edge from every
--    successor onto every child; batching changes how many children there
--    are, and this asserts the two stayed in step. An aggregate released
--    after one of ten batches is §20's original failure with a bigger blast
--    radius.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
('t_bx_join', '{"steps":[
    {"key":"fan", "kind":"matrix", "queue":"bj", "input":{
        "rows":       {"function":"t_bx_hundred", "args":[]},
        "max_fanout": 1000,
        "batch_size": 10,
        "template":   {"queue":"bj-work", "kind":"work"}}},
    {"key":"rollup", "kind":"work", "queue":"bj", "depends_on":["fan"]}
 ]}');

do $$
declare v_run uuid; v_fan uuid; v_roll workflow.tasks; v_kid uuid;
begin
    v_run := workflow.start_workflow('t_bx_join', '{}'::jsonb);
    select id into v_fan from workflow.tasks where run_id = v_run and step_key = 'fan';

    select * into v_roll from workflow.tasks where run_id = v_run and step_key = 'rollup';
    if v_roll.pending_deps <> 10 then
        raise exception
            'rollup waits on % dependencies, expected one per BATCH (10). The rewire and '
            'the batching disagree about what a child is.', v_roll.pending_deps;
    end if;
    if v_roll.status <> 'pending' then
        raise exception 'rollup is % before any batch ran', v_roll.status;
    end if;

    -- Nine of ten. The aggregate must not move.
    for v_kid in select id from workflow.tasks
        where matrix_parent_id = v_fan order by created_at, step_key limit 9
    loop
        update workflow.tasks set status = 'running', claimed_by = 'w' where id = v_kid;
        perform workflow.complete_task(v_kid, '{"result": "ok"}'::jsonb);
    end loop;

    select * into v_roll from workflow.tasks where run_id = v_run and step_key = 'rollup';
    if v_roll.status <> 'pending' or v_roll.pending_deps <> 1 then
        raise exception
            'rollup is %/% after 9 of 10 batches -- an aggregate released over ninety '
            'rows of a hundred is the failure this rewire exists to stop',
            v_roll.status, v_roll.pending_deps;
    end if;

    select id into v_kid from workflow.tasks
     where matrix_parent_id = v_fan order by created_at, step_key offset 9 limit 1;
    update workflow.tasks set status = 'running', claimed_by = 'w' where id = v_kid;
    perform workflow.complete_task(v_kid, '{"result": "ok"}'::jsonb);

    select * into v_roll from workflow.tasks where run_id = v_run and step_key = 'rollup';
    if v_roll.status <> 'ready' then
        raise exception 'rollup is % after all ten batches', v_roll.status;
    end if;
end $$;

do $$ begin
    raise notice 'workflow/10: the fan-in waits for every BATCH -- nine of ten releases nothing';
end $$;

-- ---------------------------------------------------------------------
-- 5. THE REDUCE HALF, END TO END. A batched `sql` fan-out running with
--    nothing deployed: ten children, each handed its ten rows through
--    {{items}}, each landing them in one statement. A hundred rows in, a
--    hundred rows landed, from TEN calls -- and that last number is the one
--    that would still read as success if batching silently degraded to one
--    row per child.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
('t_bx_landing', '{"steps":[
    {"key":"fan", "kind":"matrix", "queue":"none", "input":{
        "rows":       {"function":"t_bx_hundred", "args":[]},
        "max_fanout": 1000,
        "batch_size": 10,
        "template":   {"queue":"none", "kind":"sql",
                       "input":{"function":"t_bx_land", "args":["{{items}}"]}}}}
 ]}');

do $$
declare v_run uuid; v_fan uuid; v_landed int; v_calls int; v_min int;
begin
    v_run := workflow.start_workflow('t_bx_landing', '{}'::jsonb);
    select id into v_fan from workflow.tasks where run_id = v_run and step_key = 'fan';

    if (select status from workflow.runs where id = v_run) <> 'completed' then
        raise exception 'a batched sql fan-out did not complete in-transaction: %',
            (select status from workflow.runs where id = v_run);
    end if;

    select count(*) into v_landed from t_bx_landed;
    if v_landed <> 100 then
        raise exception '% of 100 rows reached the reduce function', v_landed;
    end if;
    if (select count(distinct n) from t_bx_landed) <> 100 then
        raise exception 'a row was landed twice -- the batches overlap';
    end if;

    select count(*), min((output#>>'{result,landed}')::int) into v_calls, v_min
    from workflow.tasks where matrix_parent_id = v_fan and status = 'done';
    if v_calls <> 10 then
        raise exception 'the reduce ran % times, expected once per batch (10)', v_calls;
    end if;
    if v_min <> 10 then
        raise exception 'a batch landed % rows, expected 10', v_min;
    end if;
end $$;

do $$ begin
    raise notice 'workflow/10: a hundred rows land from TEN sql calls -- {{items}} hands each child its batch';
end $$;

-- ---------------------------------------------------------------------
-- 6. partition_by. Rows sharing a key stay in one child, partitions come out
--    in order of first appearance, and the key column -- constant across the
--    batch by construction -- substitutes into the template. That last part
--    is why partition_by is a partition and not a sort.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
('t_bx_part', '{"steps":[
    {"key":"fan", "kind":"matrix", "queue":"bp", "input":{
        "rows":         {"function":"t_bx_tenants", "args":[]},
        "max_fanout":   100,
        "partition_by": ["tenant"],
        "template":     {"queue":"bp-work", "kind":"work",
                         "input":{"url":"https://x/t/{{item.tenant}}"}}}}
 ]}');

do $$
declare v_run uuid; v_fan uuid; r record; v_seen text[] := '{}';
begin
    v_run := workflow.start_workflow('t_bx_part', '{}'::jsonb);
    select id into v_fan from workflow.tasks where run_id = v_run and step_key = 'fan';

    if (select count(*) from workflow.tasks where matrix_parent_id = v_fan) <> 3 then
        raise exception 'expected one child per tenant, got %',
            (select count(*) from workflow.tasks where matrix_parent_id = v_fan);
    end if;

    for r in select step_key, input from workflow.tasks
             where matrix_parent_id = v_fan order by created_at, step_key
    loop
        -- Every row in the child shares the key...
        if (select count(distinct e->>'tenant')
            from jsonb_array_elements(r.input->'items') e) <> 1 then
            raise exception 'child % spans more than one tenant: %',
                r.step_key, r.input->'items';
        end if;
        -- ...which is exactly what makes {{item.tenant}} legal on a batch.
        if r.input->>'url' <> 'https://x/t/' || (r.input#>>'{items,0,tenant}') then
            raise exception 'the constant column did not substitute: %', r.input->>'url';
        end if;
        if r.input#>>'{batch,key,tenant}' is distinct from (r.input#>>'{items,0,tenant}') then
            raise exception 'batch.key does not name the partition: %', r.input->'batch';
        end if;
        v_seen := v_seen || (r.input#>>'{items,0,tenant}');
    end loop;

    -- First appearance, not alphabetical and not hash order: the child keys
    -- have to be a deterministic function of the row set, because that is
    -- what the re-expansion hash assumes.
    if v_seen <> array['acme','beta','ceta'] then
        raise exception 'partitions are not in order of first appearance: %', v_seen;
    end if;
    -- Uneven on purpose: 3/2/1.
    if (select array_agg(jsonb_array_length(input->'items') order by created_at, step_key)
        from workflow.tasks where matrix_parent_id = v_fan) <> array[3,2,1] then
        raise exception 'the partitions are the wrong sizes';
    end if;
end $$;

do $$ begin
    raise notice 'workflow/10: partition_by keeps a tenant whole, in first-appearance order, and its key substitutes into the template';
end $$;

-- ---------------------------------------------------------------------
-- 7. A COLUMN THAT VARIES WITHIN THE BATCH IS REFUSED, before any child
--    exists. Substituting the first row's value would produce a task that
--    processes three rows and addresses one of them -- and would pass every
--    test written at a batch size of one.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
('t_bx_vary', '{"steps":[
    {"key":"fan", "kind":"matrix", "queue":"bv", "input":{
        "rows":       {"function":"t_bx_tenants", "args":[]},
        "max_fanout": 100,
        "batch_size": 3,
        "template":   {"queue":"bv-work", "kind":"work",
                       "input":{"url":"https://x/d/{{item.doc}}"}}}}
 ]}');

do $$
declare v_run uuid; v_fan workflow.tasks;
begin
    v_run := workflow.start_workflow('t_bx_vary', '{}'::jsonb);
    select * into v_fan from workflow.tasks where run_id = v_run and step_key = 'fan';

    if v_fan.status <> 'failed' then
        raise exception
            'a template naming a column that varies within the batch expanded anyway '
            '(status %) -- three rows addressed as one', v_fan.status;
    end if;
    if (select count(*) from workflow.tasks where matrix_parent_id = v_fan.id) <> 0 then
        raise exception 'children exist under a matrix that failed to expand';
    end if;
    if v_fan.error->>'error' not like '%VARIES%' then
        raise exception 'the failure does not say the column varies: %', v_fan.error;
    end if;
    if v_fan.error->>'error' not like '%partition_by%' then
        raise exception 'the failure does not name the remedy: %', v_fan.error;
    end if;
end $$;

do $$ begin
    raise notice 'workflow/10: {{item.*}} on a column that varies within the batch fails the step before any child exists';
end $$;

-- ---------------------------------------------------------------------
-- 8. partition_by + batch_size compose: partition first, then cap. "Group by
--    tenant, but no task swallows more than two" -- acme's three rows become
--    2 + 1, and the cap never merges two tenants to fill a batch.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
('t_bx_both', '{"steps":[
    {"key":"fan", "kind":"matrix", "queue":"bb", "input":{
        "rows":         {"function":"t_bx_tenants", "args":[]},
        "max_fanout":   100,
        "partition_by": ["tenant"],
        "batch_size":   2,
        "template":     {"queue":"bb-work", "kind":"work"}}}
 ]}');

do $$
declare v_run uuid; v_fan uuid; v_shape text;
begin
    v_run := workflow.start_workflow('t_bx_both', '{}'::jsonb);
    select id into v_fan from workflow.tasks where run_id = v_run and step_key = 'fan';

    select string_agg((input#>>'{items,0,tenant}') || ':' ||
                      jsonb_array_length(input->'items'), ' ' order by created_at, step_key)
    into v_shape from workflow.tasks where matrix_parent_id = v_fan;

    if v_shape <> 'acme:2 acme:1 beta:2 ceta:1' then
        raise exception
            'partition_by and batch_size do not compose -- expected the cap applied '
            'WITHIN each partition, got: %', v_shape;
    end if;
end $$;

do $$ begin
    raise notice 'workflow/10: partition_by and batch_size compose -- the cap applies within a partition, never across two';
end $$;

-- ---------------------------------------------------------------------
-- 9. max_fanout COUNTS ROWS, not children. Letting it count children would
--    have been the easy reading -- children are what get inserted -- and it
--    would slip a runaway cross join past the ceiling by declaring a big
--    batch_size. The rows still have to be carried somewhere.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
('t_bx_ceiling', '{"steps":[
    {"key":"fan", "kind":"matrix", "queue":"bc", "input":{
        "rows":       {"function":"t_bx_hundred", "args":[]},
        "max_fanout": 50,
        "batch_size": 10,
        "template":   {"queue":"bc-work", "kind":"work"}}}
 ]}');

do $$
declare v_run uuid; v_fan workflow.tasks;
begin
    v_run := workflow.start_workflow('t_bx_ceiling', '{}'::jsonb);
    select * into v_fan from workflow.tasks where run_id = v_run and step_key = 'fan';

    if v_fan.status <> 'failed' then
        raise exception
            'a 100-row set passed a max_fanout of 50 because it batched to ten children '
            '-- the ceiling stopped guarding the row set (status %)', v_fan.status;
    end if;
    if v_fan.error->>'error' not like '%100 rows%' then
        raise exception 'the ceiling message does not name the row count: %', v_fan.error;
    end if;
end $$;

do $$ begin
    raise notice 'workflow/10: max_fanout still counts rows -- a big batch_size does not smuggle a cross join past the ceiling';
end $$;

-- ---------------------------------------------------------------------
-- 10. What is refused at REGISTRATION. A spec can arrive as JSON without
--     passing the compiler, and `batch_size: 0` is a definition that can only
--     ever fail at 3am.
-- ---------------------------------------------------------------------
do $$
declare v_case record; v_ok boolean;
begin
    for v_case in
        select * from (values
            ('batch_size: 0',
             '{"steps":[{"key":"f","kind":"matrix","queue":"q","input":{
                 "items":[], "max_fanout":10, "batch_size":0,
                 "template":{"kind":"work"}}}]}'),
            ('partition_by as a bare string',
             '{"steps":[{"key":"f","kind":"matrix","queue":"q","input":{
                 "items":[], "max_fanout":10, "partition_by":"tenant",
                 "template":{"kind":"work"}}}]}'),
            ('partition_by: []',
             '{"steps":[{"key":"f","kind":"matrix","queue":"q","input":{
                 "items":[], "max_fanout":10, "partition_by":[],
                 "template":{"kind":"work"}}}]}')
        ) as t(what, spec)
    loop
        v_ok := false;
        begin
            insert into workflow.definitions (name, spec)
            values ('t_bx_bad_' || md5(v_case.what), v_case.spec::jsonb);
        exception when others then
            v_ok := true;
        end;
        if not v_ok then
            raise exception 'a definition with % was REGISTERED', v_case.what;
        end if;
    end loop;
end $$;

-- A partition key that is not a column of the row set cannot be caught at
-- registration -- the row set does not exist yet -- so it fails at expansion,
-- with the columns that ARE there in the message, the same courtesy
-- {{item.typo}} already gets.
insert into workflow.definitions (name, spec) values
('t_bx_nokey', '{"steps":[
    {"key":"fan", "kind":"matrix", "queue":"bk", "input":{
        "rows":         {"function":"t_bx_tenants", "args":[]},
        "max_fanout":   100,
        "partition_by": ["tenannt"],
        "template":     {"queue":"bk-work", "kind":"work"}}}
 ]}');

do $$
declare v_run uuid; v_fan workflow.tasks;
begin
    v_run := workflow.start_workflow('t_bx_nokey', '{}'::jsonb);
    select * into v_fan from workflow.tasks where run_id = v_run and step_key = 'fan';
    if v_fan.status <> 'failed' then
        raise exception 'a partition key that is not a column expanded anyway: %',
            v_fan.status;
    end if;
    if v_fan.error->>'error' not like '%doc, tenant%' then
        raise exception 'the message does not say which columns exist: %', v_fan.error;
    end if;
    if (select count(*) from workflow.tasks where matrix_parent_id = v_fan.id) <> 0 then
        raise exception 'children exist under a matrix that failed to expand';
    end if;
end $$;

do $$ begin
    raise notice 'workflow/10: batch_size 0 and a malformed partition_by are refused at registration; an unknown key at expansion, before any child';
end $$;

-- ---------------------------------------------------------------------
-- 11. {{items}} is bound on EVERY fan-out child, batched or not -- an array
--     of one when the step does not batch. That is what keeps batch_size a
--     number an author can turn up or down without rewriting the function
--     underneath it, which is most of what makes it worth having as a knob.
--
--     And {{item.*}} on a batched child raises rather than picking the first.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
('t_bx_one', '{"steps":[
    {"key":"fan", "kind":"matrix", "queue":"none", "input":{
        "rows":       {"function":"t_bx_tenants", "args":[]},
        "max_fanout": 100,
        "template":   {"queue":"none", "kind":"sql",
                       "input":{"function":"t_bx_width", "args":["{{items}}"]}}}}
 ]}');

do $$
declare v_run uuid; v_widths int[];
begin
    v_run := workflow.start_workflow('t_bx_one', '{}'::jsonb);
    select array_agg((output#>>'{result,width}')::int order by step_key)
    into v_widths from workflow.tasks
    where run_id = v_run and kind = 'sql' and status = 'done';

    if v_widths is distinct from array[1,1,1,1,1,1] then
        raise exception
            '{{items}} on an UNBATCHED child did not resolve to its one row, wrapped: %',
            v_widths;
    end if;
end $$;

-- ...and as a whole VALUE in any template, not just a sql argument. A batched
-- `rest` child POSTing its ten records as the request body is the headline
-- case for batching over a network, and it works because {{items}} binds at
-- expansion: the child's recorded input holds the rows, so a worker never
-- learns the task was fanned out, let alone batched.
insert into workflow.definitions (name, spec) values
('t_bx_body', '{"steps":[
    {"key":"fan", "kind":"matrix", "queue":"bo", "input":{
        "rows":       {"function":"t_bx_tenants", "args":[]},
        "max_fanout": 100,
        "batch_size": 4,
        "template":   {"queue":"bo-work", "kind":"work",
                       "input":{"url":"https://x/bulk", "body":"{{items}}"}}}}
 ]}');

do $$
declare v_run uuid; v_fan uuid; v_c0 jsonb;
begin
    v_run := workflow.start_workflow('t_bx_body', '{}'::jsonb);
    select id into v_fan from workflow.tasks where run_id = v_run and step_key = 'fan';
    select input into v_c0 from workflow.tasks
     where matrix_parent_id = v_fan and step_key = 'fan[0]';

    if jsonb_typeof(v_c0->'body') <> 'array' then
        raise exception
            '{{items}} did not bind to an array in a work template -- a worker would '
            'receive the literal string: %', v_c0->'body';
    end if;
    if v_c0->'body' is distinct from v_c0->'items' then
        raise exception 'the bound body is not the batch: %', v_c0->'body';
    end if;
    if jsonb_array_length(v_c0->'body') <> 4 then
        raise exception 'the bound body holds % rows, expected 4',
            jsonb_array_length(v_c0->'body');
    end if;
end $$;

-- Embedded in a larger string it is refused, not rendered. A column is a
-- scalar and interpolates; a batch is an array, and splicing its JSON text
-- into a URL produces a request that is wrong in a way no status code reports.
insert into workflow.definitions (name, spec) values
('t_bx_embed', '{"steps":[
    {"key":"fan", "kind":"matrix", "queue":"be", "input":{
        "rows":       {"function":"t_bx_tenants", "args":[]},
        "max_fanout": 100,
        "batch_size": 3,
        "template":   {"queue":"be-work", "kind":"work",
                       "input":{"url":"https://x/bulk?rows={{items}}"}}}}
 ]}');

do $$
declare v_run uuid; v_fan workflow.tasks;
begin
    v_run := workflow.start_workflow('t_bx_embed', '{}'::jsonb);
    select * into v_fan from workflow.tasks where run_id = v_run and step_key = 'fan';
    if v_fan.status <> 'failed' then
        raise exception 'an embedded {{items}} expanded anyway: %', v_fan.status;
    end if;
    if v_fan.error->>'error' not like '%embedded%' then
        raise exception 'the refusal does not say why: %', v_fan.error;
    end if;
end $$;

do $$ begin
    raise notice 'workflow/10: {{items}} binds at expansion on every child -- an array of one when unbatched, a request body when batched, and refused inside a string';
end $$;

-- ---------------------------------------------------------------------
-- 12. THE PAYLOAD CAP, named as a batch_size problem. N rows in one task
--     input is the only place in this engine where a number in a spec
--     directly multiplies a stored payload, so the generic "reduce the
--     payload" message would send the author looking for the wrong thing.
-- ---------------------------------------------------------------------
create function t_bx_fat() returns jsonb as $fn$
    select jsonb_agg(jsonb_build_object('n', i, 'blob', repeat('x', 4000)) order by i)
    from generate_series(1, 40) i;
$fn$ language sql stable;
select workflow.register_step_function('t_bx_fat', 't_bx_fat', '{}');

insert into workflow.definitions (name, spec) values
('t_bx_fat', '{"steps":[
    {"key":"fan", "kind":"matrix", "queue":"bf", "input":{
        "rows":       {"function":"t_bx_fat", "args":[]},
        "max_fanout": 100,
        "batch_size": 40,
        "template":   {"queue":"bf-work", "kind":"work"}}}
 ]}');

do $$
declare v_run uuid; v_fan workflow.tasks;
begin
    v_run := workflow.start_workflow('t_bx_fat', '{}'::jsonb);
    select * into v_fan from workflow.tasks where run_id = v_run and step_key = 'fan';

    if v_fan.status <> 'failed' then
        raise exception 'a batch over the payload cap was stored anyway: %', v_fan.status;
    end if;
    if v_fan.error->>'error' not like '%batch_size%' then
        raise exception
            'the cap failure does not name the number the author has to change: %',
            v_fan.error->>'error';
    end if;
    if (select count(*) from workflow.tasks where matrix_parent_id = v_fan.id) <> 0 then
        raise exception 'a partial fan-out survived an oversized batch';
    end if;
end $$;

do $$ begin
    raise notice 'workflow/10: an oversized batch fails naming batch_size, not "reduce the payload", and leaves no children behind';
end $$;

-- ---------------------------------------------------------------------
-- 13. Re-expansion is still a replay. The recorded snapshot is the ROW SET,
--     so its hash is over the rows and not over the chunking of them -- and a
--     second expansion of the same set is a no-op rather than a hundred more
--     rows.
-- ---------------------------------------------------------------------
do $$
declare v_run uuid; v_fan uuid; v_after int;
begin
    v_run := workflow.start_workflow('t_bx_ten', '{}'::jsonb, 'bx-replay');
    select id into v_fan from workflow.tasks where run_id = v_run and step_key = 'fan';

    -- Forced the way a reaper would, and the way 04-matrix §7 does: the update
    -- into 'ready' is what fires the autorun trigger, so this IS the
    -- re-expansion path rather than a direct call standing in for it.
    update workflow.tasks set status = 'ready', run_after = now() where id = v_fan;

    select count(*) into v_after from workflow.tasks where matrix_parent_id = v_fan;
    if v_after <> 10 then
        raise exception 're-expanding a batched matrix re-chunked it: % children', v_after;
    end if;
    if (select status from workflow.tasks where id = v_fan) <> 'done' then
        raise exception 'a re-expanded matrix did not settle back to done: %',
            (select status from workflow.tasks where id = v_fan);
    end if;
    if (select pending_deps from workflow.tasks
        where run_id = v_run and step_key = 'rollup') <> 10 then
        raise exception 'a re-expansion double-counted the fan-in over batches';
    end if;
end $$;

do $$ begin
    raise notice 'workflow/10: re-expanding a batched matrix is a no-op -- the snapshot is the row set, not the chunking of it';
end $$;

-- ---------------------------------------------------------------------
-- 14. THE COMPILER HALF. §22c exists because the SQL half of a matrix feature
--     shipped without the YAML half, and the error then described a syntax
--     problem in a correct document. Batching is that shape exactly, so it is
--     in the capability probe -- and this asserts the probe reports on it at
--     all, which is the part that would otherwise rot.
-- ---------------------------------------------------------------------
do $$
declare v_caps jsonb;
begin
    v_caps := workflow.compiler_capabilities();
    if not coalesce((v_caps->>'available')::boolean, false) then
        raise notice 'workflow/10: no compiler installed -- batching authoring not probed';
        return;
    end if;
    if not (v_caps->'accepts' ? 'batching') then
        raise exception 'the capability probe does not report on batching at all';
    end if;
    if coalesce((v_caps#>>'{accepts,batching}')::boolean, false) then
        raise notice 'workflow/10: the installed compiler accepts batch_size and partition_by';
    else
        raise notice
            'workflow/10: SQL half of batching is installed, compiler half is NOT -- '
            'p8_compile_workflow refuses batch_size (the parser .so needs rebuilding); '
            'JSON specs run, YAML does not compile';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 15. AUTHORED IN YAML, end to end. §14 asks whether the compiler ACCEPTS
--     batch_size; this asks whether what it emits is a fan-out this engine
--     actually batches. Skipped, loudly, where the compiler half is not
--     installed -- which is the state §22c exists to make visible rather than
--     to hide.
-- ---------------------------------------------------------------------
do $$
declare v_run uuid; v_fan uuid; v_shape text;
begin
    if not coalesce((workflow.compiler_capabilities()#>>'{accepts,batching}')::boolean, false) then
        raise notice 'workflow/10: compiler half absent -- YAML authoring of a batch not exercised';
        return;
    end if;

    perform workflow.define_yaml($y$
name: t_bx_yaml
steps:
  - id: fan
    queue: none
    matrix:
      rows: {function: t_bx_tenants}
      max_fanout: 100
      partition_by: tenant
      batch_size: 2
      template:
        queue: none
        sql: {function: t_bx_width, args: ['{{items}}']}
$y$);

    v_run := workflow.start_workflow('t_bx_yaml', '{}'::jsonb);
    select id into v_fan from workflow.tasks where run_id = v_run and step_key = 'fan';

    -- partition_by written as a bare string, normalised to an array on the
    -- way through the compiler -- and the widths prove the engine read it.
    select string_agg((output#>>'{result,width}'), ' ' order by step_key)
    into v_shape from workflow.tasks
    where matrix_parent_id = v_fan and status = 'done';

    if v_shape is distinct from '2 1 2 1' then
        raise exception
            'a YAML-authored batch did not run as 2/1/2/1 across three tenants: %',
            coalesce(v_shape, '<nothing ran>');
    end if;
    if (select status from workflow.runs where id = v_run) <> 'completed' then
        raise exception 'a YAML-authored batched fan-out did not complete';
    end if;
    raise notice 'workflow/10: a batch authored in YAML compiles, expands and reduces -- both halves are installed and agree';
end $$;

rollback;

do $$ begin
    raise notice 'workflow/10: batching gives the map half a granularity -- ten workers owning ten rows each, declared on the step';
end $$;
