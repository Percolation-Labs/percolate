select c.content as note, h.value ->> 'semantic_rank' as semantic_rank, h.value ->> 'lexical_rank' as lexical_rank
  from workflow.tasks t
  cross join jsonb_array_elements(t.output -> 'result' -> 'rows') h
  join content.resource_chunks c on c.id = (h.value ->> 'chunk_id')::uuid
 where t.step_key = 'search'
   and t.run_id = (select r.id from workflow.runs r join workflow.definitions d on d.id = r.workflow_def_id
                    where d.name = 'ask_notes' order by r.created_at desc limit 1);

select q.phrasing, round((h.value ->> 'distance')::numeric, 3) as distance
  from workflow.tasks t
  cross join jsonb_array_elements(t.output -> 'result' -> 'rows') h
  join claims.questions q on q.id = (h.value ->> 'chunk_id')::uuid
 where t.step_key = 'questions'
   and t.run_id = (select r.id from workflow.runs r join workflow.definitions d on d.id = r.workflow_def_id
                    where d.name = 'ask_notes' order by r.created_at desc limit 1);
