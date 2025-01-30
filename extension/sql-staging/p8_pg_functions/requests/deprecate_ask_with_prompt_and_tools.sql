CREATE OR REPLACE FUNCTION p8.ask_with_prompt_and_tools(
	question text,
	tool_names_in text[] DEFAULT NULL::text[],
	system_prompt text DEFAULT 'Respond to the users query using tools and functions as required'::text,
	model_key character varying DEFAULT 'gpt-4o-mini'::character varying,
	token_override text DEFAULT NULL::text,
	temperature double precision DEFAULT 0.01)
    RETURNS TABLE(message_response text, tool_calls jsonb, tool_call_result jsonb) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    api_response JSON; -- Variable to store the API response
    endpoint_uri TEXT; -- URL of the API endpoint
    api_token TEXT; -- API token for authorization
    selected_model TEXT; -- Match model from key - sometimes they are the same
    selected_scheme TEXT; -- Scheme (e.g., openai, google, anthropic)
    tool_calls JSONB; -- Extracted tool calls
    processed_tool_calls JSONB := '[]'::JSONB; -- Initialize as an empty JSON array
    tool_call JSONB; -- Individual tool call
    tool_result JSONB;
    tool_error TEXT;
	result_set TEXT DEFAULT NULL;
BEGIN
	/*
    imports
	p8.get_tools_by_description
	p8.get_tools_by_name
	p8.google_to_open_ai_response
	p8.anthropic_to_open_ai_response
	p8.eval_function_call
	*/
    -- Fetch the model-specific API endpoint, token, and scheme
    SELECT completions_uri, coalesce(token,token_override), model, scheme
    INTO endpoint_uri, api_token, selected_model, selected_scheme
    FROM p8."LanguageModelApi"
    WHERE "name" = model_key
    LIMIT 1;

    -- Ensure both the URI and token are available
    IF endpoint_uri IS NULL OR api_token IS NULL THEN
        RAISE EXCEPTION 'Missing API endpoint or token for model: %', selected_model;
    END IF;

    -- Try searching for tools if not specified
    IF tool_names_in IS NULL OR array_length(tool_names_in, 1) = 0 THEN
        -- Auto-determine tools from the question
        SELECT ARRAY_AGG(name)
        INTO tool_names_in
        FROM p8.get_tools_by_description(question, 5); -- Adjust the limit as needed
    END IF;

    -- Prepare the tools and payload based on the scheme
    IF selected_scheme = 'openai' THEN
        -- OpenAI-specific payload
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
                    'messages', json_build_array(
                        json_build_object('role', 'system', 'content', system_prompt),
                        json_build_object('role', 'user', 'content', question)
                    ),
                    'tools', (SELECT p8.get_tools_by_name(tool_names_in, selected_scheme)), -- Fetch tools by names with scheme
                    'temperature', temperature
                )
            )::public.http_request
        );

		raise notice '%', api_response;
		 -- Extract tool calls from the response
	    tool_calls := (api_response->'choices'->0->'message'->>'tool_calls')::JSON;
		result_set := (api_response->'choices'->0->'message'->>'content')::TEXT;
		
    ELSIF selected_scheme = 'google' THEN
        -- Google-specific payload
        SELECT content
        INTO api_response
        FROM public.http(
            (
                'POST',
                endpoint_uri || '?key=' || api_token,
				NULL,
				 'application/json',
                json_build_object(
                    'contents', json_build_array(
                        json_build_object('role', 'user', 'parts', json_build_object('text', question))
                    ),
                    'tool_config', json_build_object(
                        'function_calling_config', json_build_object('mode', 'ANY')
                    ),
                    'tools', (SELECT p8.get_tools_by_name(tool_names_in, selected_scheme)) -- Fetch tools by names with scheme
                )
            )::public.http_request
        );

		 SELECT msg, tool_calls_out as tc
		    INTO result_set, tool_calls
		    FROM p8.google_to_open_ai_response(api_response::JSONB);

			raise notice '%', api_response;
    ELSIF selected_scheme = 'anthropic' THEN
        -- Anthropic-specific payload
		 
        SELECT content
        INTO api_response
        FROM public.http(
            (
                'POST',
                endpoint_uri,
                ARRAY[
                    public.http_header('x-api-key', api_token),
                    public.http_header('anthropic-version', '2023-06-01')
                ],
                'application/json',
                json_build_object(
                    'model', selected_model,
                    'max_tokens', 1024,
                    'messages', json_build_array(
                        json_build_object('role', 'user', 'content', question)
                    ),
                    'tools', (SELECT p8.get_tools_by_name(tool_names_in, selected_scheme)) -- Fetch tools by names with scheme
                )
            )::public.http_request
        );

		raise notice '%', api_response;

		---------
		 -- Extract content and tool use for the 'anthropic' scheme
		 SELECT msg, tool_calls_out as tc
		    INTO result_set, tool_calls
		    FROM p8.anthropic_to_open_ai_response(api_response::JSONB);

		----------

    ELSE
        RAISE EXCEPTION 'Unsupported scheme: %', selected_scheme;
    END IF;
 
	
    -- Iterate through each tool call
    FOR tool_call IN SELECT * FROM JSONB_ARRAY_ELEMENTS(tool_calls)
    LOOP
        BEGIN
            -- Attempt to call the function
            tool_result := p8.eval_function_call(tool_call);
            tool_error := NULL; -- No error
        EXCEPTION WHEN OTHERS THEN
            -- Capture the error if the function call fails
            tool_result := NULL;
            tool_error := SQLSTATE || ': ' || SQLERRM;
        END;

        -- Add the result or error to processed_tool_calls
        processed_tool_calls := processed_tool_calls || JSONB_BUILD_OBJECT(
            'tool_call', tool_call,
            'result', tool_result,
            'error', tool_error
        );
    END LOOP;

    -- Return the API response and processed tool calls
    RETURN QUERY
    SELECT coalesce(result_set,'')::TEXT,
           tool_calls,
           processed_tool_calls;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'API call failed: % %', SQLERRM, result_set;
END;
$BODY$;

ALTER FUNCTION p8.ask_with_prompt_and_tools(text, text[], text, character varying, text, double precision)
    OWNER TO postgres;
