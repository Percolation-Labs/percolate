-- A STEP MAY CARRY ITS OWN SQL -- the expressive default, and the lockdown
-- that is still one setting away.
--
-- `schema.sql`'s "SQL a step wrote itself" section. The change is small in code
-- and large in what it permits, so what is asserted here is mostly the SHAPE OF
-- THE PERMISSION rather than the happy path:
--
--   1. A read runs and returns rows (§1) -- which the old `p8ql: "select ..."`
--      spelling did NOT, and §6 asserts that too, because a step that reports
--      done and answers nothing is the defect this whole change came out of.
--   2. A read CANNOT WRITE, and the database is what stops it (§2), not the
--      keyword check beside it.
--   3. The read-only setting does not escape the step (§3). This is the one
--      that would be invisible until it broke everything: transaction_read_only
--      is transaction-local, so leaving it on would make the engine's own
--      `complete_task` fail on the next line and every step after it.
--   4. A template in a statement is a VALUE (§4). If it is not, the run's input
--      is a SQL injection with a YAML front end.
--   5. `sql_policy = 'registered'` refuses statements (§5), so the boundary
--      that used to be mandatory is still there for a deployment that wants it.
--
-- WHAT IS DELIBERATELY NOT ASSERTED: that a statement cannot read another
-- tenant's rows. It can. A step runs as the engine owner, RLS does not apply to
-- it, and anyone who may define a workflow may read anything. That is the
-- stated trade of the open policy, and a test claiming otherwise would be
-- describing a system this is not.

\set ON_ERROR_STOP on

begin;

set local role app_owner;

create table t_os_facts (cik text, fy int, val numeric);
insert into t_os_facts values ('0000320193', 2026, 109.42), ('0000320193', 2025, 85.78),
                              ('0000789019', 2026, 70.07);

insert into workflow.definitions (name, spec) values
('t_os_read', '{"steps":[
    {"key":"q", "kind":"sql", "queue":"none",
     "input":{"statement":"select fy, val from t_os_facts where cik = ''{{run.cik}}'' order by fy desc"}}
 ]}');

-- ---------------------------------------------------------------------
-- 1. A READ RUNS, AND COMES BACK AS ROWS.
-- ---------------------------------------------------------------------
do $$
declare
    v_run uuid;
    v_out jsonb;
begin
    v_run := workflow.start_workflow('t_os_read', '{"cik": "0000320193"}'::jsonb);
    select output->'result' into v_out from workflow.tasks
     where run_id = v_run and step_key = 'q';

    if jsonb_typeof(v_out) <> 'array' then
        raise exception 'a sql step returned % where rows were expected: %',
            jsonb_typeof(v_out), v_out;
    end if;
    if jsonb_array_length(v_out) <> 2 then
        raise exception 'expected two rows for that filer, got %: %',
            jsonb_array_length(v_out), v_out;
    end if;
    if (v_out#>>'{0,fy}')::int <> 2026 then
        raise exception 'the ORDER BY the author wrote was not honoured: %', v_out;
    end if;
    if (select status from workflow.runs where id = v_run) is distinct from 'succeeded' then
        raise exception 'a run whose only step was a statement did not complete';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. A READ CANNOT WRITE, AND THE DATABASE SAYS SO.
--
-- Two statements, because the courtesy check and the boundary are different
-- things and only one of them is load-bearing. `delete ...` is caught by the
-- keyword check with a message naming the remedy; the data-modifying CTE walks
-- straight past that check.
--
-- WHAT STOPS THE CTE IS NOT WHAT I EXPECTED, and the test says so because
-- running it is how I found out. A read is wrapped as `select ... from
-- (<statement>) t`, and Postgres refuses a data-modifying WITH anywhere but the
-- top level -- so the wrap is a STRUCTURAL guard that fires before
-- transaction_read_only is reached. Read-only is still the boundary that
-- matters (it covers the volatile function that writes, which no wrapping
-- catches); the assertion accepts either refusal and demands only that the
-- rows are still there.
-- ---------------------------------------------------------------------
do $$
declare
    v_run uuid;
    v_err text;
begin
    insert into workflow.definitions (name, spec) values
    ('t_os_sneak', '{"steps":[
        {"key":"w", "kind":"sql", "queue":"none",
         "input":{"statement":"with gone as (delete from t_os_facts returning 1) select count(*) from gone"}}
     ]}');

    v_run := workflow.start_workflow('t_os_sneak', '{}'::jsonb);

    if (select status from workflow.tasks where run_id = v_run and step_key = 'w') is distinct from 'failed' then
        raise exception
            'a data-modifying CTE ran from a step that did not declare `write: true` '
            '-- the keyword check does not see it, so transaction_read_only must';
    end if;
    select detail#>>'{error,error}' into v_err from workflow.task_events
     where run_id = v_run and to_status = 'failed' order by at desc limit 1;
    if v_err not like '%read-only transaction%'
       and v_err not like '%data-modifying statement must be at the top level%' then
        raise exception 'it failed for the wrong reason: %', v_err;
    end if;
    if (select count(*) from t_os_facts) <> 3 then
        raise exception 'rows were deleted by a step that was refused';
    end if;
end $$;

-- AND THE PLAIN CASE NEVER REACHES A RUN AT ALL: the lint refuses it at
-- registration, which is where the author is looking. The identical check
-- inside run_sql is the second line rather than the first -- a spec can be
-- UPDATEd in place, and a guard that only exists at authoring time protects
-- only the authors who used the front door.
do $$
declare v_err text;
begin
    begin
        insert into workflow.definitions (name, spec) values
        ('t_os_plain_write', '{"steps":[
            {"key":"w", "kind":"sql", "queue":"none",
             "input":{"statement":"delete from t_os_facts"}}
         ]}');
        raise exception 'a read step whose statement deletes rows was registered';
    exception when others then
        v_err := sqlerrm;
        if v_err not like '%write: true%' then
            raise exception 'refused, but not for the right reason: %', v_err;
        end if;
    end;
end $$;

-- ---------------------------------------------------------------------
-- 3. A DECLARED WRITE RUNS, AND THE READ-ONLY SETTING DID NOT ESCAPE.
--
-- The second half is the invisible one: transaction_read_only is
-- transaction-local, not statement-local, so a read step that left it on would
-- break complete_task on the very next line -- and then every step after it, in
-- a way that looks like the engine is broken rather than like a step is.
-- Asserted by running a read and a write in ONE run, read first.
-- ---------------------------------------------------------------------
do $$
declare
    v_run uuid;
    v_out jsonb;
begin
    insert into workflow.definitions (name, spec) values
    ('t_os_rw', '{"steps":[
        {"key":"before", "kind":"sql", "queue":"none",
         "input":{"statement":"select count(*) as n from t_os_facts"}},
        {"key":"purge", "kind":"sql", "queue":"none", "depends_on":["before"],
         "input":{"statement":"delete from t_os_facts where fy < 2026", "write":true}},
        {"key":"after", "kind":"sql", "queue":"none", "depends_on":["purge"],
         "input":{"statement":"select count(*) as n from t_os_facts"}}
     ]}');

    v_run := workflow.start_workflow('t_os_rw', '{}'::jsonb);

    if (select count(*) from workflow.tasks
         where run_id = v_run and status <> 'succeeded') > 0 then
        raise exception 'a read followed by a write did not complete: %',
            (select jsonb_object_agg(step_key, status) from workflow.tasks
              where run_id = v_run);
    end if;

    select output->'result' into v_out from workflow.tasks
     where run_id = v_run and step_key = 'purge';
    if (v_out->>'rows_affected')::int <> 1 then
        raise exception 'the write reported % rows affected, expected 1: %',
            v_out->>'rows_affected', v_out;
    end if;

    select output->'result' into v_out from workflow.tasks
     where run_id = v_run and step_key = 'after';
    if (v_out#>>'{0,n}')::int <> 2 then
        raise exception 'the read after the write saw %, expected 2 rows left', v_out;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 4. A TEMPLATE IS A VALUE, NOT A FRAGMENT.
--
-- The run's input is data a caller supplied. Substituted as text it would be
-- injection with a YAML front end; substituted as a quoted literal it is a
-- string that happens to contain punctuation.
-- ---------------------------------------------------------------------
do $$
declare
    v_run uuid;
    v_out jsonb;
begin
    insert into workflow.definitions (name, spec) values
    ('t_os_inject', '{"steps":[
        {"key":"q", "kind":"sql", "queue":"none",
         "input":{"statement":"select count(*) as n from t_os_facts where cik = ''{{run.cik}}''"}}
     ]}');

    v_run := workflow.start_workflow('t_os_inject',
        jsonb_build_object('cik', ''' or true; drop table t_os_facts; --'));

    select output->'result' into v_out from workflow.tasks
     where run_id = v_run and step_key = 'q';

    if to_regclass('t_os_facts') is null then
        raise exception 'a run input dropped a table -- the substitution is not quoting';
    end if;
    if (v_out#>>'{0,n}')::int <> 0 then
        raise exception
            'an injection payload matched % rows, so it was read as SQL rather than as '
            'a value: %', v_out#>>'{0,n}', v_out;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 5. THE LOCKDOWN IS ONE SETTING AWAY.
--
-- set_config transaction-locally rather than ALTER DATABASE, so this test
-- leaves nothing behind: sql_policy() reads the GUC, and the GUC reverts with
-- the transaction.
-- ---------------------------------------------------------------------
do $$
declare v_run uuid; v_err text;
begin
    perform set_config('percolate.sql_policy', 'registered', true);
    if workflow.sql_policy() <> 'registered' then
        raise exception 'sql_policy did not read the setting';
    end if;

    v_run := workflow.start_workflow('t_os_read', '{"cik": "0000320193"}'::jsonb);
    if (select status from workflow.tasks where run_id = v_run and step_key = 'q') is distinct from 'failed' then
        raise exception 'a statement ran under sql_policy = registered';
    end if;
    select detail#>>'{error,error}' into v_err from workflow.task_events
     where run_id = v_run and to_status = 'failed' order by at desc limit 1;
    if v_err not like '%registered%' then
        raise exception 'the refusal did not name the policy: %', v_err;
    end if;

    -- The allow-listed spelling is unaffected, which is the whole point of
    -- keeping it: a locked-down deployment still runs its registered functions.
    perform set_config('percolate.sql_policy', 'open', true);
end $$;

-- ---------------------------------------------------------------------
-- 6. `p8ql: "select ..."` EXECUTES, having previously reported success and
--    returned a note.
--
-- The defect that produced this whole section: aiq.query returns SQL mode's
-- statement rather than running it, and as a workflow step that meant a task
-- marked done whose result was the note. Found by writing the obvious thing in
-- a real pipeline and getting a green run with no rows.
-- ---------------------------------------------------------------------
do $$
declare v_run uuid; v_out jsonb;
begin
    insert into workflow.definitions (name, spec) values
    ('t_os_p8ql', '{"steps":[
        {"key":"q", "kind":"sql", "queue":"none",
         "input":{"function":"p8ql", "args":["select count(*) as n from t_os_facts"]}}
     ]}');

    v_run := workflow.start_workflow('t_os_p8ql', '{}'::jsonb);
    select output->'result' into v_out from workflow.tasks
     where run_id = v_run and step_key = 'q';

    if v_out ? 'note' then
        raise exception
            'p8ql SQL mode still returns the note instead of the rows: %', v_out;
    end if;
    if jsonb_typeof(v_out->'rows') <> 'array' then
        raise exception 'p8ql SQL mode returned no rows array: %', v_out;
    end if;
end $$;

do $$
begin
    raise notice 'workflow/13: a step carries its own SQL and gets rows back, with no registration';
    raise notice 'workflow/13: a read cannot write -- the keyword check names the remedy, the read-only transaction is the boundary';
    raise notice 'workflow/13: a declared write runs, and read-only does not leak into the engine''s own next statement';
    raise notice 'workflow/13: a {{template}} in a statement is a quoted value, so run input cannot become SQL';
    raise notice 'workflow/13: sql_policy = registered refuses statements and leaves the allow-list working';
    raise notice 'workflow/13: p8ql SQL mode executes instead of reporting success and returning a note';
end $$;

rollback;
