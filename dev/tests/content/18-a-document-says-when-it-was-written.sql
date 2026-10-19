-- A DOCUMENT SAYS WHEN IT WAS WRITTEN, AND ITS FACTS HOLD FROM THEN (REM-1022).
--
-- register_text stores p_metadata, and a caller who knows when a text was said
-- puts it there as said_at. The ingest pipeline's lander now passes it to each
-- fact as valid_from, so a note written in January and uploaded today holds from
-- January, and an as-of read before the upload finds it. A said_at that is not
-- a time, or is in the future, is ignored, not fatal: the facts then hold from
-- when they were read, as before.
--
-- WHAT WOULD MAKE IT FAIL. Drop valid_from from land_graph_windows and §1
-- raises; pass said_at unchecked and §3 raises.
--
-- One transaction, rolled back. No model: each extractor answer is written as
-- the finished child of a matrix task, as content/02 does.

\set ON_ERROR_STOP on
begin;

create function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
    if p_ok is not true then
        raise exception 'a document says when it was written: %', p_what;
    end if;
end $$;

-- Land one extracted graph for one resource, through the real lander.
create function pg_temp.land(p_res uuid, p_name text) returns jsonb language plpgsql as $$
declare v_run uuid; v_mx uuid; v_def text := 't_rem1022_' || replace(p_name, ' ', '_');
begin
    insert into workflow.definitions (name, spec) values (v_def, jsonb_build_object(
        'steps', jsonb_build_array(jsonb_build_object(
            'key', 'graph', 'kind', 'matrix', 'queue', 't', 'input', jsonb_build_object(
                'items', jsonb_build_array(jsonb_build_object('resource_id', p_res, 'window_ordinal', 0, 'content', 'x')),
                'max_fanout', 5,
                'template', jsonb_build_object('queue', 't-rem1022', 'kind', 'work',
                                               'input', jsonb_build_object('op', 'noop')))))));
    v_run := workflow.start_workflow(v_def, '{}'::jsonb);
    select id into v_mx from workflow.tasks where run_id = v_run and step_key = 'graph';
    update workflow.tasks set status = 'running', claimed_by = 't', claimed_at = now() where matrix_parent_id = v_mx;
    perform workflow.complete_task(t.id, jsonb_build_object('result', jsonb_build_object(
        'nodes', jsonb_build_array(jsonb_build_object('k', 'person', 'n', p_name),
                                   jsonb_build_object('k', 'place',  'n', 'Leeds Rem1022')),
        'edges', jsonb_build_array(jsonb_build_object('s', 0, 't', 1, 'r', 'located_in')))))
       from workflow.tasks t where t.matrix_parent_id = v_mx;
    perform set_config('workflow.current_run_id', v_run::text, true);
    return content.land_graph_windows(v_mx);
end $$;

create function pg_temp.held_from(p_name text) returns timestamptz language sql as $$
    select e.valid_from from aiq.edges e
      join aiq.node_keys k on k.node_id = e.src_id and k.kind = 'canonical'
     where k.key = 'person/' || lower(p_name) and e.relation = 'located_in'
$$;

insert into content.channels (name, kind, visibility) values ('rem1022', 'manual', 'public');
with c as (select id from content.channels where name = 'rem1022')
insert into content.resources (channel_id, title, status, visibility, metadata)
select c.id, t.title, 'ready', 'public', t.md from c, (values
    ('dated',   '{"said_at": "2026-01-05T09:00:00Z"}'::jsonb),
    ('undated', '{}'::jsonb),
    ('future',  '{"said_at": "2099-01-01T00:00:00Z"}'::jsonb),
    ('garbled', '{"said_at": "last January"}'::jsonb)) t(title, md);

select pg_temp.land((select id from content.resources where title = 'dated'),   'Dated Rem1022') is not null;
select pg_temp.land((select id from content.resources where title = 'undated'), 'Undated Rem1022') is not null;
select pg_temp.land((select id from content.resources where title = 'future'),  'Future Rem1022') is not null;
select pg_temp.land((select id from content.resources where title = 'garbled'), 'Garbled Rem1022') is not null;

-- §1. A dated document's fact holds from when it was said.
select pg_temp.check(pg_temp.held_from('Dated Rem1022') = '2026-01-05T09:00:00Z',
    '§1: the fact holds from the document''s said_at, not from the upload: ' || coalesce(pg_temp.held_from('Dated Rem1022')::text, 'none'));
-- §2. An undated one holds from when it was read, as before.
select pg_temp.check(pg_temp.held_from('Undated Rem1022') > now() - interval '1 hour',
    '§2: an undated document''s fact holds from when it was read');
-- §3. A future or garbled said_at is ignored, and the upload still lands.
select pg_temp.check(pg_temp.held_from('Future Rem1022') > now() - interval '1 hour'
                     and pg_temp.held_from('Garbled Rem1022') > now() - interval '1 hour',
    '§3: a said_at that is not a past time is ignored, and the facts still land');

rollback;
