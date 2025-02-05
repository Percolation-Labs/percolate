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
        SELECT role AS last_role, created_at AS last_updated_at
        FROM session_data
        ORDER BY created_at DESC
        LIMIT 1
    ),
    extracted_messages AS (
        -- Extract all messages, interleaving tool calls and user/assistant content while preserving the data structure
        SELECT NULL::TIMESTAMP as created_at, 'system' AS role, 
               json_build_array(
                   jsonb_build_object('type', 'text', 'text', COALESCE(agent_or_system_prompt, generated_system_prompt))
               ) AS content,
               0 AS rank
        UNION ALL
        SELECT NULL::TIMESTAMP as created_at, 'user' AS role, 
               json_build_array(
                   jsonb_build_object('type', 'text', 'text', COALESCE(question, recovered_question))
               ) AS content,
               1 AS rank
        UNION ALL
        SELECT created_at, 'assistant' AS role,
               jsonb_build_array(
                   jsonb_build_object(
                       'name', el->'function'->>'name',
                       'id', el->>'id',
                       'input', (el->'function'->>'arguments')::JSON,
                       'type', 'tool_use'
                   )
               )::JSON AS content,
               2 AS rank
        FROM session_data, 
             LATERAL jsonb_array_elements(tool_calls::JSONB) el
        WHERE tool_calls IS NOT NULL
        UNION ALL
        SELECT created_at, 'user' AS role,
               jsonb_build_array(
                   jsonb_build_object(
                       'type', 'tool_result',
                       'tool_use_id', el->>'id',
                       'content', el->>'data'
                   )
               )::JSON AS content,
               2 AS rank
        FROM session_data, 
             LATERAL jsonb_array_elements(tool_eval_data::JSONB) el
        WHERE tool_eval_data IS NOT NULL
    ),
    ordered_messages AS (
        -- Order the extracted messages by rank (to maintain the interleaving order) and created_at timestamp
        SELECT role, content
        FROM extracted_messages
        ORDER BY rank, created_at ASC
    ),
    jsonrow AS (
        -- Convert ordered messages into JSON
        SELECT json_agg(row_to_json(ordered_messages)) AS messages
        FROM ordered_messages
    )
    -- Return the ordered JSON messages along with metadata
    SELECT jsonrow.messages, max_session_data.last_role, max_session_data.last_updated_at
    FROM jsonrow 
    LEFT JOIN max_session_data ON true; -- Ensures at least one row is returned
END;
$BODY$;

ALTER FUNCTION p8.get_anthropic_messages(uuid, text, text)
    OWNER TO postgres;
