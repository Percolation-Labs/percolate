insert into content.channels (name, kind, visibility) values ('notes', 'manual', 'public') on conflict do nothing;
select content.register_text('notes', 'standup-0303', $j$[{"content":
  "Standup, 3 March. P. Raman: the berth log scans are too slow in Postgres; DuckDB read a year of them in four seconds. Wants to try it for the harbour analytics."}]$j$) ->> 'resource_id' as standup;
select content.register_text('notes', 'review-0420', $j$[{"content":
  "Ops review, 20 April. Keep the berth logs in Postgres: the permissions live there, and a second store doubles the access rules. Revisit after the Tide Dashboard ships."}]$j$) ->> 'resource_id' as review;

select aiq.queue_source_embedding('two notes') ->> 'queued' as embedding;

select workflow.define_yaml($y$
name: ask_notes
steps:
  - id: search
    p8ql: 'SEARCH "{{run.question}}" FROM chunks USING bge-small-en-v1.5 LIMIT 3'
  - id: questions
    p8ql: 'SEMANTIC "{{run.question}}" FROM questions USING bge-small-en-v1.5 LIMIT 2'
$y$);
