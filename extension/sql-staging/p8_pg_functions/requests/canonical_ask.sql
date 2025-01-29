-- FUNCTION: p8.canonical_ask(json, uuid, json, text, text, uuid)

-- DROP FUNCTION IF EXISTS p8.canonical_ask(json, uuid, json, text, text, uuid);

CREATE OR REPLACE FUNCTION p8.canonical_ask(
	message_payload json,
	session_id uuid DEFAULT NULL::uuid,
	functions_in json DEFAULT NULL::json,
	model_name text DEFAULT 'gpt-4o-mini'::text,
	token_override text DEFAULT NULL::text,
	user_id uuid DEFAULT NULL::uuid)
    RETURNS TABLE(message_response text, tool_calls jsonb, tool_call_result jsonb, session_id_out uuid, status TEXT) 
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
	api_error JSONB;
    tool_calls JSONB;
    tool_call JSONB;
    tool_result JSONB;
    tool_error TEXT;
	status_audit TEXT;
	finish_reason TEXT;
    tokens_in INTEGER;
    tokens_out INTEGER;
    response_id UUID;
BEGIN
	/*
	
	this is a lower lever function that allows other functions to build message stack and functions
	the function names would be convenient but often functions are determine from agents or search
	so its better to just wrap this in whatever method searches for functions and builds messages
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

	-- if someone is feeling lucky they will not add functions to this method 
	-- we can assume no one wants to call this particular thing without functions as there are others for that but also Percolate is better with tools
	--select json_agg(spec) from p8.get_tools_by_description('tools for getting pets that have a sold status');
	--
	--we would need to be scheme aware here
	-- IF functions_in IS NULL THEN
	-- 	select json_agg(spec) 
	-- 	into functions_in
	-- 	from p8.get_tools_by_description(message_payload::TEXT);
	-- END IF;
	
    -- Make the API request to the model
    SELECT content
        INTO api_response
        FROM public.http(
            (
                'POST',
                endpoint_uri,
                ARRAY[public.http_header('Authorization', 'Bearer ' || api_token)],
                'application/json',
                json_build_object(
                    'model', selected_model,
                    'messages', message_payload,
                    'tools', functions_in -- functions have been mapped for the scheme
                )
            )::public.http_request
        );

    -- Log the API response for debugging
    RAISE NOTICE '%', api_response;

    -- Extract tool calls from the response
    tool_calls := (api_response->'choices'->0->'message'->>'tool_calls')::JSONB;
    result_set := (api_response->'choices'->0->'message'->>'content')::TEXT;
	api_error := (api_response->'error')::JSONB;
	-- Handle token usage
	tokens_in := (api_response->'usage'->>'prompt_tokens')::INTEGER;
	tokens_out := (api_response->'usage'->>'completion_tokens')::INTEGER;
	finish_reason:= (api_response->'choices'->0->'finish_reason')::TEXT;
	
	--TODO looking for a finish reason of done
	
	status_audit:= 'TOOL_CALL_RESPONSE';
	IF finish_reason = 'stop' THEN
		status_audit:= 'COMPLETED';
	END IF;
	
    -- Iterate through each tool call
    FOR tool_call IN SELECT * FROM JSONB_ARRAY_ELEMENTS(tool_calls)
    LOOP
        BEGIN
			RAISE NOTICE 'calling %', tool_call;
            -- Attempt to call the function
            tool_result := p8.eval_function_call(tool_call); -- This will be saved in tool_eval_data
            tool_error := NULL; -- No error
        EXCEPTION WHEN OTHERS THEN
            -- Capture the error if the function call fails
            tool_result := NULL;
            tool_error := SQLSTATE || ': ' || SQLERRM;
			RAISE NOTICE 'tool_error %', tool_error;
        END;

        -- Set status based on tool result or error
        IF tool_error IS NOT NULL THEN
            status_audit:= 'TOOL_ERROR';
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
		status_audit:= 'ERROR';
	END IF;

	-- Insert into p8.AIResponse table
	INSERT INTO p8."AIResponse" 
	(id, model_name, content, tokens_in, tokens_out, session_id, role, status, tool_calls, tool_eval_data)
	VALUES 
	(response_id, selected_model, coalesce(result_set,''), coalesce(tokens_in,0), coalesce(tokens_out,0), session_id, 'assistant', status_audit, tool_calls, tool_result);

    -- Return results
    RETURN QUERY
    SELECT result_set, tool_calls, tool_result, session_id, status_audit;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'API call failed: % %', SQLERRM, result_set;
END;
$BODY$;

ALTER FUNCTION p8.canonical_ask(json, uuid, json, text, text, uuid)
    OWNER TO postgres;
