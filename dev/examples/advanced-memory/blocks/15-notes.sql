insert into content.channels (name, kind, visibility) values ('notes', 'manual', 'public') on conflict do nothing;
select content.install_text_embed_workflow('text-embedding-3-small');

select content.register_text('notes', 'standup-0303', $j$[{"content":
  "Standup, 3 March. P. Raman: the berth log scans are too slow in Postgres; DuckDB read a year of them in four seconds. Wants to try it for the harbour analytics."}]$j$) ->> 'resource_id' as standup;
select content.register_text('notes', 'review-0420', $j$[{"content":
  "Ops review, 20 April. Keep the berth logs in Postgres: the permissions live there, and a second store doubles the access rules. Revisit after the Tide Dashboard ships."}]$j$) ->> 'resource_id' as review;

select workflow.start_workflow('embed_text', jsonb_build_object('resource_id', id)) as embed_run
  from content.resources where external_id in ('standup-0303', 'review-0420');

select workflow.define_yaml($y$
name: ask_notes
steps:
  - id: search
    p8ql: 'SEARCH "{{run.question}}" FROM chunks USING text-embedding-3-small LIMIT 1'
  - id: questions
    p8ql: 'SEMANTIC "{{run.question}}" FROM questions USING text-embedding-3-small LIMIT 2'
$y$);
