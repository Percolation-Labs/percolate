-- Tutorial four's two helpers. In psql, from dev/examples/advanced-walk:  \i harness/walk.sql

-- walk(question, channel): walk a question and return when the walk has ended, with its run id.
-- A sample's question id (QA:1:...) walks it from the verdicts the sample recorded, with no key;
-- any other text is walked live, and Jev judges it.
create or replace procedure walk(question text, channel text, inout run uuid default null) language plpgsql as $$
begin
  select workflow.start_workflow('walk', jsonb_strip_nulls(jsonb_build_object(
           'question', coalesce((select jsonb_build_object('node_id', n.id, 'text', q.title)
                                   from content.resources q join aiq.nodes n on n.entity_id = q.id
                                  where q.external_id = 'question:' || question), jsonb_build_object('text', question)),
           'channel', channel,
           'replay', (select id from content.resources where external_id = 'replay:' || question),
           'offline', exists (select from content.resources where external_id = 'replay:' || question),
           'settings', '{"travel":"topk","topk":3,"gate":0.5,"travel_cap":10,"order":"p","waves":2}'::jsonb)))
    into run;
  commit;
  while (select status from workflow.runs where id = run) = 'running' loop perform pg_sleep(1); commit; end loop;
end $$;

-- answers: each sample question's evidence, from the benchmarks' answer keys, for counting what a walk found.
-- No walk reads it. It lasts as long as this psql session.
create temp table answer_key (j jsonb);
\copy answer_key from 'samples/qasper/questions.jsonl' with (format csv, quote e'\x01', delimiter e'\x02')
\copy answer_key from 'samples/beam/questions.jsonl' with (format csv, quote e'\x01', delimiter e'\x02')
create temp view answers as select j->>'qid' as question, jsonb_array_elements_text(j->'gold') as doc from answer_key;
