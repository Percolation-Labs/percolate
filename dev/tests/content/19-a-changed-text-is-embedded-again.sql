-- A CHANGED TEXT IS EMBEDDED AGAIN (REM-1107).
--
-- register_text rewrites a resource's chunks when its text changes, and the new
-- chunks have new ids. It then starts the channel's ingest workflow under the
-- external id `text:<resource>`, which start_workflow treats as idempotent. So
-- once the first run had finished, every later save of changed text got that
-- finished run back, and nothing embedded the new chunks. On production on
-- 20 Oct, 135 chunks of 18 readings had no vector, and every one of them was
-- created after its resource's only run had finished.
--
-- The run is now keyed by the text as well:
--
--   1. a save starts a run;
--   2. a save of changed text, after that run finished, starts another;
--   3. a save of the same text again starts nothing (`unchanged`).
--
-- One transaction, rolled back. The workflow is a no-op of the test's own.

\set ON_ERROR_STOP on
begin;

insert into workflow.definitions (name, spec) values ('t_rem1107_embed', '{"steps": [{"key": "embed", "kind": "work",
    "queue": "t-rem1107", "input": {"op": "noop", "resource_id": "{{run.resource_id}}"}}]}');
insert into content.channels (name, kind, org_id, visibility, config)
    values ('rem1107', 'manual', rbac.shared_org_id(), 'public', '{"ingest_workflow": "t_rem1107_embed"}');

create temp table rem1107 (k text primary key, v jsonb);

-- 1. The first save starts a run.
insert into rem1107 select 'first', content.register_text('rem1107', 'note-1', '[{"content": "The pilot boarded at the outer buoy."}]');
do $$
declare r jsonb := (select v from rem1107 where k = 'first');
begin
    if r->>'status' is distinct from 'queued' or r->>'run_id' is null then
        raise exception 'the first save should start a run, got %', r;
    end if;
end $$;
-- That run finishes, as the worker would finish it.
update workflow.runs set status = 'succeeded', completed_at = now()
 where id = (select (v->>'run_id')::uuid from rem1107 where k = 'first');

-- 2. Changed text, after the first run finished: a new run, for the new chunks.
insert into rem1107 select 'changed', content.register_text('rem1107', 'note-1', '[{"content": "The pilot boarded at the inner buoy."}]');
do $$
declare
    a jsonb := (select v from rem1107 where k = 'first');
    b jsonb := (select v from rem1107 where k = 'changed');
begin
    if b->>'status' is distinct from 'queued' or b->>'run_id' is null then
        raise exception 'a changed text should start a run, got %', b;
    end if;
    if b->>'run_id' = a->>'run_id' then
        raise exception 'a changed text got the finished run back, so its new chunks are never embedded: %', b;
    end if;
    if (select status from workflow.runs where id = (b->>'run_id')::uuid) is distinct from 'running' then
        raise exception 'the run for the changed text should be running';
    end if;
end $$;

-- 3. The same text again: nothing to embed, and no run.
insert into rem1107 select 'same', content.register_text('rem1107', 'note-1', '[{"content": "The pilot boarded at the inner buoy."}]');
do $$
declare r jsonb := (select v from rem1107 where k = 'same');
begin
    if r->>'status' is distinct from 'unchanged' or r ? 'run_id' then
        raise exception 'an unchanged save should start nothing, got %', r;
    end if;
end $$;

rollback;
