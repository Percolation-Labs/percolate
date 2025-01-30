-- FUNCTION: p8.get_google_messages(text, text, text)

-- DROP FUNCTION IF EXISTS p8.get_google_messages(text, text, text);

CREATE OR REPLACE FUNCTION p8.get_google_messages(
	session_id_in UUID,
	question text DEFAULT NULL,
	agent_or_system_prompt text DEFAULT NULL::text)
    RETURNS TABLE(messages json, last_role text, last_updated_at timestamp without time zone) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
BEGIN
/*https://cloud.google.com/vertex-ai/generative-ai/docs/multimodal/function-calling*/
    RETURN QUERY
    WITH session_data AS (
        -- Fetch session data for the specified session_id
        SELECT content, role, tool_calls, tool_eval_data, created_at
        FROM p8."AIResponse" a
        WHERE a.session_id = session_id_in
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
        SELECT 'system' AS role, json_build_array(json_build_object('text',agent_or_system_prompt)) AS parts
		   WHERE agent_or_system_prompt IS NOT NULL
        UNION ALL
        SELECT 'user' AS role, json_build_array(json_build_object('text',question)) AS parts
			WHERE question IS NOT NULL
        UNION ALL
        SELECT  case when role = 'user' or role = 'tool' then 'user' else 'model' end as role,
		   CASE 
		       -- case the content - its a normal part unless there is a tool call
				WHEN (tool_eval_data->'id') IS NOT NULL THEN 
					json_build_array(
						json_build_object(
							'functionResponse',
							json_build_object(
								'name', tool_eval_data->'name',
								'response', json_build_object(
									'name', tool_eval_data->'name',
									'content', content::TEXT
								)
							)
						)
						)
				WHEN tool_calls is not null then
				--TODO: currently only supports one tool call
					jsonb_build_array(
				        jsonb_build_object(
				            'functionCall', jsonb_build_object(
				                'name', tool_calls->0->'function'->> 'name',
				                'args', (tool_calls->0->'function'->> 'arguments')::json
				            )
				        )
				    )::JSON						
				ELSE 
					json_build_array( json_build_object('text', content::TEXT) )
			END AS parts
		  FROM session_data
    ),
    jsonrow as(
        select json_agg(row_to_json(message_data)) as messages
		from message_data
	)
	  SELECT * 
    FROM jsonrow 
    LEFT JOIN max_session_data ON true;  -- Use LEFT JOIN to ensure rows are returned even if no session data is found

END;
$BODY$;

ALTER FUNCTION p8.get_google_messages(text, text, text)
    OWNER TO postgres;
