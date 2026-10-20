select u.email as asked_by, tc->'content'->>'mode' as mode, tc->'content'->'plan'->>'arg' as arg,
       jsonb_array_length(tc->'content'->'rows') as rows, tc->'content'->'unresolved' as unresolved
  from agentic.messages m
  join agentic.sessions s on s.id = m.session_id
  join rbac.users u on u.id = s.owner_id
  cross join lateral jsonb_array_elements(m.tool_calls) tc
 where tc->>'tool_name' = 'query'
 order by m.seq;
