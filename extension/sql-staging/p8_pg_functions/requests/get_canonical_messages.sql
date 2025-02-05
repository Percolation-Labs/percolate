CREATE OR REPLACE FUNCTION p8.get_canonical_messages(
    session_id_in UUID,  
    question TEXT DEFAULT NULL,  
    override_system_prompt TEXT DEFAULT NULL  
) 
RETURNS TABLE(messages JSON, last_role TEXT, last_updated_at TIMESTAMP WITHOUT TIME ZONE) 
LANGUAGE plpgsql
COST 100
VOLATILE 
PARALLEL UNSAFE
ROWS 1000 
AS $BODY$
DECLARE
    recovered_session_id TEXT;
    user_id TEXT;
    recovered_agent TEXT;
    recovered_question TEXT;
    generated_system_prompt TEXT;
BEGIN

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

    -- 3. Construct the response messages
    RETURN QUERY
    WITH session_data AS (
        -- Fetch session data for the specified session_id
        SELECT content, role, tool_calls, tool_eval_data, created_at
        FROM p8."AIResponse" a
        WHERE a.session_id = session_id_in
    ),
    max_session_data AS (
        -- Get the last role and most recent timestamp
        SELECT role AS last_role, created_at AS last_updated_at
        FROM session_data
        ORDER BY created_at DESC
        LIMIT 1
    ),
    extracted_messages AS (
        -- Extract all messages in a structured way while keeping order
        SELECT NULL::TIMESTAMP as created_at, 'system' AS role, 
               COALESCE(override_system_prompt, generated_system_prompt) AS content, 
               NULL::TEXT AS tool_call_id,
			   NULL::JSON as tool_calls,
			   0 as rank
        UNION ALL
        SELECT NULL::TIMESTAMP as created_at, 'user' AS role, 
               COALESCE(question, recovered_question) AS content, 
               NULL::TEXT AS tool_call_id,
			    NULL::JSON as tool_calls,
			   1 as rank
        UNION ALL
        SELECT created_at, 'assistant' AS role, 
               'Calling ' || (el->>'function')::TEXT AS content,
               el->>'id' AS tool_call_id,
			   tool_calls,
			   2 as rank
        FROM session_data, 
             LATERAL jsonb_array_elements(tool_calls::JSONB) el
        WHERE tool_calls IS NOT NULL
         UNION ALL
        -- Extract tool responses
        SELECT created_at, 'tool' AS role,
               'Responded ' || (el->>'data')::TEXT AS content,
               el->>'id' AS tool_call_id,
			   NULL::JSON as tool_calls,
			   2 as rank
        FROM session_data, 
             LATERAL jsonb_array_elements(tool_eval_data::JSONB) el
        WHERE tool_eval_data IS NOT NULL
    ),
    ordered_messages AS (
        -- Order all extracted messages by created_at
        SELECT role, content, tool_calls, tool_call_id
        FROM extracted_messages
        ORDER BY rank, created_at ASC
    ),
    jsonrow AS (
        -- Convert ordered messages into JSON
        SELECT json_agg(row_to_json(ordered_messages)) AS messages
        FROM ordered_messages
    )
    -- Return JSON messages with metadata
    SELECT * 
    FROM jsonrow 
    LEFT JOIN max_session_data ON true;

END;
$BODY$;
