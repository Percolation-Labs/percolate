-- FUNCTION: p8.ask(json, uuid, json, text, text, uuid)

-- DROP FUNCTION IF EXISTS p8.ask(json, uuid, json, text, text, uuid);

CREATE OR REPLACE FUNCTION p8.ask(
	message_payload json,
	session_id uuid DEFAULT NULL::uuid,
	functions_in json DEFAULT NULL::json,
	model_name text DEFAULT 'gpt-4o-mini'::text,
	token_override text DEFAULT NULL::text,
	user_id uuid DEFAULT NULL::uuid)
    RETURNS TABLE(message_response text, tool_calls jsonb, tool_call_result jsonb, session_id_out uuid, status text) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    -- Declare variables
    endpoint_uri TEXT;
    api_token TEXT;
    selected_model TEXT;
    selected_scheme TEXT;
    api_response JSON;
    result_set TEXT;
    api_error TEXT;
    tool_calls JSONB;
    tool_call JSONB;
    tool_results JSONB := '[]'; --aggregates
    tool_result JSONB;
    tool_error TEXT;
    status_audit TEXT;
    finish_reason TEXT;
    tokens_in INTEGER;
    tokens_out INTEGER;
    response_id UUID;
BEGIN
	/*
	take in a message payload etc and call the correct request for each scheme
	each scheme maps to canonical which we store
	note, when calling these schemes again we read back messages in their format
	we also want to audit everything in this function

	select * from percolate_with_agent('list some pets that str sold', 'MyFirstAgent');
	*/

    -- Fetch endpoint and API token from LanguageModelApi
    SELECT completions_uri, coalesce(token, token_override), model, scheme
    INTO endpoint_uri, api_token, selected_model, selected_scheme
    FROM p8."LanguageModelApi"
    WHERE "name" = model_name 
    LIMIT 1;

    -- Ensure both the URI and token are available
    IF endpoint_uri IS NULL OR api_token IS NULL THEN
        RAISE EXCEPTION 'Missing API endpoint or token for model: %', selected_model;
    END IF;

    -- If session does not exist, create a new session UUID (using JSON uuid creation)
    IF session_id IS NULL THEN
        SELECT p8.json_to_uuid(json_build_object('date', current_date::text, 'user_id', coalesce(user_id,''))::JSONB)
        INTO session_id;
    END IF;

    -- Determine functions if none provided
    IF functions_in IS NULL THEN
        SELECT json_agg(spec)
        INTO functions_in
        FROM p8.get_tools_by_description(message_payload::TEXT);
    END IF;

    -- Make the API request based on scheme
    --we return RETURNS TABLE(message_response text, tool_calls jsonb, tool_call_result jsonb, session_id_out uuid, status TEXT)
    --RETURNS TABLE(content TEXT,tool_calls_out JSON,tokens_in INTEGER,tokens_out INTEGER,finish_reason TEXT,api_error JSONB) AS
    IF selected_scheme = 'google' THEN
        SELECT * FROM p8.request_google(message_payload, functions_in, selected_model, endpoint_uri, api_token)
        INTO result_set, tool_calls, tokens_in, tokens_out, finish_reason, api_error;
    ELSIF selected_scheme = 'anthropic' THEN
        SELECT * FROM p8.request_anthropic(message_payload, functions_in, selected_model, endpoint_uri, api_token)
        INTO result_set, tool_calls, tokens_in, tokens_out, finish_reason, api_error;
    ELSE
        -- Default case for other schemes
        SELECT * FROM p8.request_openai(message_payload, functions_in, selected_model, endpoint_uri, api_token)
        INTO result_set, tool_calls, tokens_in, tokens_out, finish_reason, api_error;
    END IF;

	RAISE notice '------------';
    -- Handle finish reason and status
    status_audit := 'TOOL_CALL_RESPONSE';
    IF finish_reason = 'stop' THEN
        status_audit := 'COMPLETED';
    END IF;

    -- Iterate through each tool call
    FOR tool_call IN SELECT * FROM JSONB_ARRAY_ELEMENTS(tool_calls)
    LOOP
        BEGIN
            RAISE NOTICE 'calling %', tool_call;
            -- Attempt to call the function
            tool_result := json_build_object('id', tool_call->>'id', 'data', p8.eval_function_call(tool_call)); -- This will be saved in tool_eval_data
            tool_error := NULL; -- No error
            -- Aggregate tool_result into tool_results array
            tool_results := tool_results || tool_result;
        EXCEPTION WHEN OTHERS THEN
            -- Capture the error if the function call fails
            tool_result := NULL;
            tool_error := SQLSTATE || ': ' || SQLERRM;
            RAISE NOTICE 'tool_error %', tool_error;
        END;

        -- Set status based on tool result or error
        IF tool_error IS NOT NULL THEN
            status_audit := 'TOOL_ERROR';
            result_set := tool_error;
        ELSE
            -- Set status to ERROR if tool_eval failed
        END IF;
    END LOOP;

    -- Generate a new response UUID using session_id and content ID
    SELECT p8.json_to_uuid(json_build_object('sid', session_id, 'id', api_response->'id')::JSONB)
    INTO response_id;

    IF api_error IS NOT NULL THEN
        result_set := api_error;
        status_audit := 'ERROR';
    END IF;

    -- Insert into p8.AIResponse table
    INSERT INTO p8."AIResponse" 
    (id, model_name, content, tokens_in, tokens_out, session_id, role, status, tool_calls, tool_eval_data)
    VALUES 
    (response_id, selected_model, coalesce(result_set,''), coalesce(tokens_in,0), coalesce(tokens_out,0), session_id, 'assistant', status_audit, tool_calls, tool_results);

    -- Return results
    RETURN QUERY
    SELECT result_set::TEXT, tool_calls::JSONB, tool_results::JSONB, session_id, status_audit;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'ASK API call failed: % %', SQLERRM, result_set;
END;
$BODY$;

ALTER FUNCTION p8.ask(json, uuid, json, text, text, uuid)
    OWNER TO postgres;
