DROP FUNCTION IF EXISTS p8.get_google_messages;
CREATE OR REPLACE FUNCTION p8.get_google_messages(
    session_id_in UUID,
    question TEXT DEFAULT NULL,
    agent_or_system_prompt TEXT DEFAULT NULL
)
RETURNS TABLE(messages JSON, last_role TEXT, last_updated_at TIMESTAMP WITHOUT TIME ZONE) 
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
    https://cloud.google.com/vertex-ai/generative-ai/docs/multimodal/function-calling

    select messages from p8.get_google_messages('619857d3-434f-fa51-7c88-6518204974c9');

    call parts should be 

    {
        "functionCall": {
            "name": "get_current_weather",
            "args": {
                "location": "San Francisco"
            }
        }
    }
    
    response parts should be

    {
        "functionResponse": {
            "name": "get_current_weather",
            "response": {
                "temperature": 30.5,
                "unit": "C"
            }
        }
    }
    */

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
    ),
    max_session_data AS (
        -- Get the last role and most recent timestamp
        SELECT role AS last_role, created_at AS last_updated_at
        FROM session_data
        ORDER BY created_at DESC
        LIMIT 1
    ),
    message_data AS (
        -- Combine system, user, and session data
        SELECT 'system' AS role, json_build_array(json_build_object('text',
            COALESCE(agent_or_system_prompt, generated_system_prompt)
        )) AS parts
        UNION ALL
        SELECT 'user' AS role, json_build_array(json_build_object('text',
            COALESCE(question, recovered_question)
        )) AS parts
        UNION ALL
        -- Generate one row for assistant tool call summary
        SELECT 'model' AS role,
            json_build_array(
                json_build_object(
                    'functionCall', json_build_object(
                        'name', el->'function'->>'name',
                        'args', (el->'function'->>'arguments')::json
                    )
                )
            ) AS parts
        FROM session_data, 
             LATERAL jsonb_array_elements(tool_calls::JSONB) el
        UNION ALL
        -- Generate multiple rows from tool_eval_data JSON array with a tool call id on each
        SELECT 'user' AS role,
            json_build_array(
                json_build_object(
                    'functionResponse',
                    json_build_object(
                        'name', el->>'id',
                        'response', json_build_object(
                            'name', el->>'id',
                            -- experiment with json or text
                            'content', (el->'data')::TEXT
                        )
                    )
                )
            ) AS parts
        FROM session_data, 
             LATERAL jsonb_array_elements(tool_eval_data::JSONB) el
    ),
    jsonrow AS (
        SELECT json_agg(row_to_json(message_data)) AS messages
        FROM message_data
    )
    SELECT * 
    FROM jsonrow 
    LEFT JOIN max_session_data ON true;  -- Ensure a row is returned even if no session data is found

END;
$BODY$;

ALTER FUNCTION p8.get_google_messages(UUID, text, text)
OWNER TO postgres;
