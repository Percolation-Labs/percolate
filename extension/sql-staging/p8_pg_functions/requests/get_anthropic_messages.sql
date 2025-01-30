-- FUNCTION: p8.get_anthropic_messages(uuid, text, text)

-- DROP FUNCTION IF EXISTS p8.get_anthropic_messages(uuid, text, text);

CREATE OR REPLACE FUNCTION p8.get_anthropic_messages(
	session_id_in uuid,
	question text DEFAULT NULL::text,
	agent_or_system_prompt text DEFAULT NULL::text)
    RETURNS TABLE(messages json, last_role text, last_updated_at timestamp without time zone) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    recovered_session_id UUID;
    user_id UUID;
    recovered_agent TEXT;
    recovered_question TEXT;
    generated_system_prompt TEXT;
BEGIN
	/*
	returns something that can be safely posted to an anthtropic endpoint with multiple tool calls
	currently we add the system prompt for canon but we could add a flag to omit it.
	in our clients we tend to just filter out the system message

	tool use result blocls are 

	{
	  "role": "user",
	  "content": [
	    {
	      "type": "tool_result",
	      "tool_use_id": "toolu_01A09q90qw90lq917835lq9",
	      "content": "15 degrees"
	    }
	  ]
	}
	
	select messages from p8.get_anthropic_messages('583060b2-70c6-478c-a483-2292870a980a');
	
	*/
    -- 1. Get session details from p8."Session"
    SELECT s.id, s.userid, s.agent, s.query 
    INTO recovered_session_id, user_id, recovered_agent, recovered_question
    FROM p8."Session" s
    WHERE s.id = session_id_in;

    -- Check if session exists
    IF recovered_session_id IS NULL THEN
        RETURN QUERY 
        SELECT NULL::JSON, NULL::TEXT, NULL::TIMESTAMP;
        RETURN;
    END IF;

    -- 2. Generate system prompt based on the recovered agent
    SELECT p8.generate_markdown_prompt(recovered_agent) 
    INTO generated_system_prompt;

    -- If no generated system prompt, fall back to using the agent directly
    IF generated_system_prompt IS NULL THEN
        generated_system_prompt := recovered_agent;
    END IF;

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
        SELECT 'system' AS role, 
               json_build_array(json_build_object('type', 'text','text', COALESCE(agent_or_system_prompt, generated_system_prompt)))  AS content
        UNION ALL
        SELECT 'user' AS role, 
			json_build_array(json_build_object('type', 'text','text', COALESCE(question, recovered_question)))  AS content
        UNION ALL
     	--tool use
        SELECT 'assistant' AS role,
               jsonb_build_array(
                   jsonb_build_object(
                       'name', el->'function'->>'name',
                       'id', el->>'id',
                       'input', (el->'function'->>'arguments')::JSON,
                       'type', 'tool_use'
                   )
               )::JSON AS content
        FROM session_data, 
             LATERAL jsonb_array_elements(tool_calls::JSONB) el
        UNION ALL
        -- Generate multiple rows from tool_eval_data JSON array with a tool call id on each
		--check out our canonical schema which has tool results with id and dat
        SELECT 'user' AS role,
               jsonb_build_array(
                   jsonb_build_object(
                       'type', 'tool_result',
                       'tool_use_id', el->>'id',
                       'content', el->>'data'
                   )
               )::JSON AS content
        FROM session_data, 
             LATERAL jsonb_array_elements(tool_eval_data::JSONB) el
    ),
    jsonrow AS (
        SELECT json_agg(row_to_json(message_data)) AS messages
        FROM message_data
    )
    SELECT jsonrow.messages, max_session_data.last_role, max_session_data.last_message_at
    FROM jsonrow 
    LEFT JOIN max_session_data ON true; -- Ensures at least one row is returned

END;
$BODY$;

ALTER FUNCTION p8.get_anthropic_messages(uuid, text, text)
    OWNER TO postgres;
