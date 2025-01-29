-- FUNCTION: p8.get_canonical_messages(text, text, text)

-- DROP FUNCTION IF EXISTS p8.get_canonical_messages(text, text, text);

CREATE OR REPLACE FUNCTION p8.get_canonical_messages(
	question text,
	session_id_in text,
	agent_or_system_prompt text DEFAULT NULL::text)
    RETURNS TABLE(messages json, last_role text, last_updated_at timestamp without time zone) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
BEGIN
    RETURN QUERY
    WITH session_data AS (
        -- Fetch session data for the specified session_id
        SELECT content, role, tool_calls, tool_eval_data, created_at
        FROM p8."AIResponse" a
        WHERE a.session_id::text = session_id_in
    ),
    max_session_data AS (
        -- Get the last role and most recent timestamp
        SELECT role AS last_role, created_at AS last_message_at
        FROM session_data
        ORDER BY created_at DESC
        LIMIT 1
    ),
    message_data AS (
        -- Combine system, user, and session data
        SELECT 'system' AS role, agent_or_system_prompt AS content, NOW() AS created_at, 
		     NULL::JSON as tool_calls , NULL::JSON  as tool_eval_data, NULL::TEXT as tool_call_id
		   WHERE agent_or_system_prompt IS NOT NULL
        UNION ALL
        SELECT 'user' AS role, question AS content, NOW() AS created_at,  
		   NULL::JSON as tool_calls , NULL::JSON  as tool_eval_data, NULL::TEXT as tool_call_id
			WHERE question IS NOT NULL
        UNION ALL
        SELECT  role, content,  created_at, tool_calls, tool_eval_data, tool_eval_data->>'id' as tool_call_id
		  FROM session_data
    ),
    jsonrow as(
        select json_agg(row_to_json(message_data)) as messages
		from message_data
	)
	select * from jsonrow cross join max_session_data;
END;
$BODY$;

ALTER FUNCTION p8.get_canonical_messages(text, text, text)
    OWNER TO postgres;
