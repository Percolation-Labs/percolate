CREATE OR REPLACE FUNCTION p8.get_canonical_messages(
    session_id_in UUID,  -- Normal usage: use the question and prompt from the session
    question TEXT DEFAULT NULL,  -- This can override the question
    override_system_prompt TEXT DEFAULT NULL  -- This can override the system prompt or match an agent
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
        -- Return null values for the session-related fields if session does not exist
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
        ORDER BY created_at ASC
    ),
    max_session_data AS (
        -- Get the last role and most recent timestamp
        SELECT role AS last_role, created_at AS last_updated_at
        FROM session_data
        ORDER BY created_at DESC
        LIMIT 1
    ),
    message_data AS (
        -- Construct system, user, and session messages
        SELECT 'system' AS role, 
               COALESCE(override_system_prompt, generated_system_prompt) AS content, 
               NULL::JSON AS tool_calls, 
               NULL::TEXT AS tool_call_id
        UNION ALL
        SELECT 'user' AS role, 
               COALESCE(question, recovered_question) AS content, 
               NULL::JSON AS tool_calls, 
               NULL::TEXT AS tool_call_id
        UNION ALL
        -- Generate one row for assistant tool call summary
        SELECT 'assistant' AS role,
               'tools called...' AS content,
               tool_calls,
               NULL AS tool_call_id
        FROM session_data 
        WHERE tool_calls IS NOT NULL
        UNION ALL
        -- Generate multiple rows from tool_eval_data JSON array with a tool call id on each
        SELECT 'tool' AS role,
               el->>'data' AS content,
               NULL AS tool_calls,
               el->>'id' AS tool_call_id
        FROM session_data, 
             LATERAL jsonb_array_elements(tool_eval_data::JSONB) el  -- Properly extracting JSON array elements
        WHERE tool_eval_data IS NOT NULL
    ),
    jsonrow AS (
        SELECT json_agg(row_to_json(message_data)) AS messages
        FROM message_data
    )
    SELECT * 
    FROM jsonrow 
    LEFT JOIN max_session_data ON true;  -- Use LEFT JOIN to ensure rows are returned even if no session data is found

END;
$BODY$;
