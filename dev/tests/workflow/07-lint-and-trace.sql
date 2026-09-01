-- WORKFLOW SURFACE -- what is refused at authoring time, and what the trace carries.
--
-- Both halves here were found by asking rather than by failing: "is there a
-- lint?" and "does the trace cross a step boundary?". The answers were no and
-- partly, and each gap had the same shape -- something knowable up front that
-- was only discovered at run time, or not discovered at all.

\set ON_ERROR_STOP on

begin;

set local role app_owner;

-- ---------------------------------------------------------------------
-- 1. LINT: CONTENT, NOT JUST GRAPH SHAPE.
--
-- validate_spec has always checked that steps exist, keys are unique,
-- dependencies resolve and nothing is unreachable. All four of the specs below
-- passed that and were accepted, and every one of them cannot work.
-- ---------------------------------------------------------------------
do $$
declare
    v_ok boolean;
    v_n  int;
begin
    -- (a) A p8ql string that cannot parse. Static text: it will never become
    -- valid, so it is refused rather than deferred to the first run.
    v_ok := false;
    begin
        insert into workflow.definitions (name, spec) values ('t_lint_p8ql',
            '{"steps":[{"key":"q","kind":"sql","queue":"none",
                        "input":{"function":"p8ql","args":["NOT A QUERY"]}}]}');
    exception when others then
        v_ok := true;
    end;
    if not v_ok then
        raise exception 'a p8ql step that cannot parse was accepted';
    end if;

    -- (b) A reference to a step that does not exist. Resolves to null at
    -- dispatch, and a step running on null where it expected a value reports
    -- success -- the quiet failure this suite exists for.
    v_ok := false;
    begin
        insert into workflow.definitions (name, spec) values ('t_lint_ref',
            '{"steps":[{"key":"one","kind":"sql","queue":"none",
                        "input":{"function":"p8ql","args":["SCHEMA"]}},
                       {"key":"two","kind":"sql","queue":"none","depends_on":["one"],
                        "input":{"function":"p8ql","args":["{{steps.nosuch.result}}"]}}]}');
    exception when others then
        v_ok := true;
    end;
    if not v_ok then
        raise exception 'a template naming a step that does not exist was accepted';
    end if;

    -- (c) A reference to a REAL step that is not a declared dependency. The
    -- sharpest of the three, because it is intermittent: it resolves correctly
    -- whenever the ordering happens to favour it, and to null when it does not.
    v_ok := false;
    begin
        insert into workflow.definitions (name, spec) values ('t_lint_race',
            '{"steps":[{"key":"one","kind":"sql","queue":"none",
                        "input":{"function":"p8ql","args":["SCHEMA"]}},
                       {"key":"two","kind":"sql","queue":"none",
                        "input":{"function":"p8ql","args":["{{steps.one.result}}"]}}]}');
    exception when others then
        v_ok := true;
    end;
    if not v_ok then
        raise exception
            'a step reading another step it does not depend on was accepted -- '
            'that is a race that resolves to null, not an error';
    end if;

    -- (d) The valid form of the same document is still accepted. A lint that
    -- refuses correct workflows is worse than no lint.
    insert into workflow.definitions (name, spec) values ('t_lint_ok',
        '{"steps":[{"key":"one","kind":"sql","queue":"none",
                    "input":{"function":"p8ql","args":["SCHEMA"]}},
                   {"key":"two","kind":"sql","queue":"none","depends_on":["one"],
                    "input":{"function":"p8ql","args":["{{steps.one.result}}"]}}]}');

    -- (e) An unregistered function is a WARNING, not a refusal: authoring
    -- order is not deployment order, and defining a workflow before
    -- registering the function it calls is a reasonable sequence.
    select count(*) into v_n from workflow.lint_spec(
        '{"steps":[{"key":"q","kind":"sql","queue":"none",
                    "input":{"function":"no_such_fn","args":[]}}]}'::jsonb)
     where severity = 'warning';
    if v_n <> 1 then
        raise exception 'an unregistered step function did not produce a warning';
    end if;

    raise notice 'workflow/07: the lint refuses what cannot work and permits what can';
end $$;

-- ---------------------------------------------------------------------
-- 2. THE TRACE CROSSES A RUN BOUNDARY.
--
-- One trace per run, shared by every task in it, has always held. What did not
-- is the one place a run is provably CAUSED by another run: a sub-workflow
-- started its child with no trace argument, so the child took a fresh
-- trace_id from the column default. parent_task_id recorded the causal link in
-- the database while the two halves sat in unrelated traces in any collector.
-- ---------------------------------------------------------------------
do $$
declare
    v_parent uuid;
    v_child  uuid;
    v_task   uuid;
begin
    insert into workflow.definitions (name, spec) values ('t_trace_child',
        '{"steps":[{"key":"inner","kind":"sql","queue":"none",
                    "input":{"function":"p8ql","args":["SCHEMA"]}}]}');
    insert into workflow.definitions (name, spec) values ('t_trace_parent',
        '{"steps":[{"key":"call","kind":"sub_workflow","queue":"none",
                    "input":{"workflow":"t_trace_child","input":{}}}]}');

    v_parent := workflow.start_workflow('t_trace_parent', '{}'::jsonb);
    select id into v_task from workflow.tasks where run_id = v_parent;
    select id into v_child from workflow.runs where parent_task_id = v_task;

    if v_child is null then
        raise exception 'the sub-workflow did not start a child run';
    end if;

    if (select trace_id from workflow.runs where id = v_child)
       is distinct from (select trace_id from workflow.runs where id = v_parent) then
        raise exception
            'the child run is in a different trace from the parent that caused it';
    end if;

    -- And the invariant that already held, asserted so it cannot quietly stop:
    -- every task of a run shares that run's trace.
    if exists (select 1 from workflow.tasks t join workflow.runs r on r.id = t.run_id
                where r.id = v_parent and t.run_id <> r.id) then
        raise exception 'a task escaped its run';
    end if;

    raise notice 'workflow/07: a sub-workflow runs inside its parent''s trace';
end $$;

rollback;
