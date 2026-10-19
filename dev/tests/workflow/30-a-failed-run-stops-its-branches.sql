-- A FAILED RUN STOPS ITS OTHER BRANCHES (REM-980).
--
-- A failing step cancelled only the steps that depended on it. Its siblings on other branches carried on: a ready
-- one was still claimed, a running one finished, and its answer released its own successors, so a run reading
-- `failed` kept working (REM-957's third fresh reader: compare `failed`, story still `running`). A failed run is now
-- over, as a cancelled one is, except for its compensations.
--
--   1  three parallel steps: one fails while one runs and one waits; the waiting one is cancelled at once
--   2  the running one is asked to stop, and its late answer lands as cancelled, releasing nothing
--   3  a ready step of a failed run is never claimed
--   4  a failed saga's compensation still runs and finishes under the failed run
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

create function pg_temp.check(p_ok boolean, p_what text) returns void as $$
begin
    if p_ok is not true then
        raise exception 'failed run: %', p_what;
    end if;
end $$ language plpgsql;

create function pg_temp.status(p_run uuid, p_step text) returns text as $$
    select status from workflow.tasks where run_id = p_run and step_key like p_step
$$ language sql;

create function pg_temp.claim(p_run uuid, p_step text) returns uuid as $$
    -- claim_task takes the oldest ready task on the queue; each step here has a queue of its own.
    select id from workflow.claim_task('wf30_' || p_step, 'wf30-worker') where run_id = p_run
$$ language sql;

select workflow.define_yaml($y$
name: wf30_compare
steps:
  - {id: joke,  work: true, queue: wf30_joke}
  - {id: story, work: true, queue: wf30_story}
  - {id: poem,  work: true, queue: wf30_poem}
  - id: combine
    needs: [joke, story, poem]
    work: true
    queue: wf30_combine
$y$);


-- 1, 2, 3 ------------------------------------------------------------------------------------------------------
do $$
declare
    r     uuid := workflow.start_workflow('wf30_compare', '{}');
    joke  uuid := pg_temp.claim(r, 'joke');
    story uuid := pg_temp.claim(r, 'story');
begin
    perform pg_temp.check(pg_temp.status(r, 'poem') = 'ready', '1 poem is ready, not yet claimed');

    perform workflow.fail_task(joke, '{"error": "provider refused the key"}', true, 'wf30-worker');
    perform pg_temp.check((select status from workflow.runs where id = r) = 'failed', '1 the run fails');
    perform pg_temp.check(pg_temp.status(r, 'poem') = 'cancelled',
        '1 the waiting sibling is cancelled with it: ' || pg_temp.status(r, 'poem'));
    perform pg_temp.check(pg_temp.status(r, 'combine') = 'cancelled', '1 and so is the join');

    perform pg_temp.check(pg_temp.status(r, 'story') = 'running'
        and (select cancel_requested from workflow.tasks where id = story),
        '2 the running sibling is asked to stop');
    perform pg_temp.check(workflow.heartbeat_task(story, 'wf30-worker') is false,
        '2 its heartbeat says stop');
    perform workflow.complete_task(story, '{"result": "a late story"}', 'wf30-worker');
    perform pg_temp.check(pg_temp.status(r, 'story') = 'cancelled',
        '2 its late answer lands as cancelled: ' || pg_temp.status(r, 'story'));
    perform pg_temp.check((select output from workflow.tasks where id = story) is null,
        '2 and the answer is not kept');
    perform pg_temp.check((select status from workflow.runs where id = r) = 'failed', '2 the run is still failed');

    perform pg_temp.check(not exists (select 1 from workflow.claim_task('wf30_poem', 'wf30-worker') where run_id = r),
        '3 nothing of the failed run is claimable');
end $$;


-- 4 ------------------------------------------------------------------------------------------------------------
create table public.wf30_holds (run_id uuid, what text);
grant select, insert, delete on public.wf30_holds to authenticated;

select workflow.define_yaml($y$
name: wf30_saga
steps:
  - id: reserve
    sql: {statement: "insert into public.wf30_holds values ('{{run.$id}}'::uuid, 'berth')", write: true}
    compensate_with: release
    saga_group: booking
  - id: confirm
    needs: [reserve]
    sql: "select 1 / 0"
    saga_group: booking
  - id: release
    work: true
    queue: wf30_release
$y$);

do $$
declare
    r   uuid := workflow.start_workflow('wf30_saga', '{}');
    rel uuid;
begin
    perform pg_temp.check((select status || '/' || compensation_state from workflow.runs where id = r)
                          = 'failed/compensating', '4 the saga fails and starts compensating');
    select id into rel from workflow.claim_task('wf30_release', 'wf30-worker') where run_id = r;
    perform pg_temp.check(rel is not null, '4 its compensation is still claimable under the failed run');
    perform workflow.complete_task(rel, '{"result": "released"}', 'wf30-worker');
    perform pg_temp.check((select status from workflow.tasks where id = rel) = 'succeeded',
        '4 and its answer is kept');
    perform pg_temp.check((select compensation_state from workflow.runs where id = r) = 'compensated',
        '4 so the run reads compensated');
end $$;

rollback;
