--select * from p8."LanguageModelApi"



DROP function if exists p8.request_openai;
CREATE OR REPLACE FUNCTION p8.request_openai(
    message_payload JSON,
    functions_in JSON DEFAULT NULL,
    model_name TEXT DEFAULT 'gpt-4o-mini',
    endpoint_uri TEXT DEFAULT 'https://api.openai.com/v1/chat/completions',
    api_token TEXT DEFAULT NULL
)
RETURNS TABLE(
    message_content TEXT, 
    tool_calls_out JSONB, 
    tokens_in INTEGER, 
    tokens_out INTEGER, 
    finish_reason TEXT, 
    api_error TEXT
) AS
$$
DECLARE
    api_response JSONB;
    result_set TEXT;
    tool_calls JSONB;
    selected_model TEXT;
    api_error JSONB;
    tokens_in INTEGER;
    tokens_out INTEGER;
    finish_reason TEXT;
BEGIN
    -- If api_token is NULL, retrieve values from the LanguageModelApi table
    IF api_token IS NULL THEN
        SELECT completions_uri, 
               COALESCE(token, api_token), 
               model
        INTO endpoint_uri, api_token, selected_model
        FROM p8."LanguageModelApi"
        WHERE scheme = 'openai'
        LIMIT 1;
    END IF;

    -- Ensure model_name defaults to the selected model if not provided
    IF model_name IS NULL THEN
        model_name := selected_model;
    END IF;

    -- Make the HTTP request and retrieve the response
    SELECT content
        INTO api_response
        FROM public.http(
		  (
            'POST',
            endpoint_uri,
            ARRAY[public.http_header('Authorization', 'Bearer ' || api_token)],
            'application/json',
            json_build_object(
                'model', model_name,
                'messages', message_payload,
                'tools', CASE 
                        WHEN functions_in IS NULL OR functions_in::TEXT = '[]' THEN NULL
                        ELSE functions_in 
                     END-- functions have been mapped for the scheme
            )::jsonb
		   )::http_request
        );

    -- Log the API response for debugging
    RAISE NOTICE 'API Response: % from functions', api_response, functions_in;

    -- Extract tool calls from the response
    tool_calls := (api_response->'choices'->0->'message'->>'tool_calls')::JSONB;
    result_set := (api_response->'choices'->0->'message'->>'content')::TEXT;
    api_error := (api_response->>'error')::TEXT;

    -- Handle token usage
    tokens_in := (api_response->'usage'->>'prompt_tokens')::INTEGER;
    tokens_out := (api_response->'usage'->>'completion_tokens')::INTEGER;
    finish_reason := (api_response->'choices'->0->>'finish_reason')::TEXT;
	
RAISE NOTICE 'WE HAVE % %', result_set, finish_reason;

    -- Return the results
    RETURN QUERY
    SELECT result_set::TEXT, tool_calls::JSONB, tokens_in::INTEGER, tokens_out::INTEGER, finish_reason::TEXT, api_error::TEXT;

END;
$$ LANGUAGE plpgsql;

-------------
DROP function if exists p8.request_anthropic;
CREATE OR REPLACE FUNCTION p8.request_anthropic(
    message_payload JSON,
    functions_in JSON DEFAULT NULL,
    model_name TEXT DEFAULT 'claude-3-5-sonnet-20241022',
    endpoint_uri TEXT DEFAULT 'https://api.anthropic.com/v1/messages',
	api_token TEXT DEFAULT NULL
)
RETURNS TABLE(
    message_content TEXT, 
    tool_calls_out JSONB, 
    tokens_in INTEGER, 
    tokens_out INTEGER, 
    finish_reason TEXT, 
    api_error TEXT
) AS
$$
DECLARE
    api_response JSONB;
    result_set JSONB;
    selected_model TEXT;
    selected_scheme TEXT;
    system_messages TEXT;
BEGIN
    -- If api_token is NULL, retrieve values from the LanguageModelApi table
    IF api_token IS NULL THEN
        SELECT completions_uri, 
               COALESCE(token, api_token), 
               model, 
               scheme
        INTO endpoint_uri, api_token, selected_model, selected_scheme
        FROM p8."LanguageModelApi"
        WHERE scheme = 'anthropic'
        LIMIT 1;
    END IF;

    -- Ensure model_name defaults to the selected model if not provided
    IF model_name IS NULL THEN
        model_name := selected_model;
    END IF;

    -- Extract and concatenate all system messages into system_messages variable
    SELECT string_agg(message->>'content', ' ') 
    INTO system_messages
    FROM jsonb_array_elements(message_payload::JSONB) AS msg(message)
    WHERE msg.message->>'role' = 'system';

    -- Filter out system messages from message_payload
    message_payload := (
        SELECT jsonb_agg(msg.message) 
        FROM jsonb_array_elements(message_payload::JSONB) AS msg(message)
        WHERE msg.message->>'role' != 'system'
    );

    -- Make the HTTP request and retrieve the response
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
                'messages', message_payload,
                'system', system_messages,  
                'max_tokens', 8192, --TODO set this per model
                'tools', COALESCE(functions_in, '[]'::JSON),
                'model', model_name
            )::jsonb
		   )::http_request
        );

    -- Log the API response for debugging
    RAISE NOTICE 'API Response: %', api_response;

    -- Return the processed result in canonical form
    RETURN QUERY 
    SELECT * from p8.anthropic_to_open_ai_response(api_response);

END;
$$ LANGUAGE plpgsql;

--------------------------------------------------------
drop function if exists p8.request_google;
-- FUNCTION: p8.request_google(json, json, text, text, text)

-- DROP FUNCTION IF EXISTS p8.request_google(json, json, text, text, text);

CREATE OR REPLACE FUNCTION p8.request_google(
	message_payload json,
	functions_in json DEFAULT NULL::json,
	model_name text DEFAULT 'gemini-1.5-flash'::text,
	endpoint_uri text DEFAULT 'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent'::text,
	api_token text DEFAULT NULL::text)
    RETURNS TABLE(message_content text, tool_calls_out jsonb, tokens_in integer, tokens_out integer, finish_reason text, api_error text) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    api_response JSONB;
    system_messages TEXT;
    result_set JSONB;
    selected_model TEXT;
    selected_scheme TEXT;
BEGIN
    -- If api_token is NULL, retrieve values from the LanguageModelApi table
    IF api_token IS NULL THEN
        SELECT completions_uri, 
               COALESCE(token, api_token), 
               model, 
               scheme
        INTO endpoint_uri, api_token, selected_model, selected_scheme
        FROM p8."LanguageModelApi"
        WHERE scheme = 'google'
        LIMIT 1;
    END IF;

    -- Ensure model_name defaults to the selected model if not provided
    IF model_name IS NULL THEN
        model_name := selected_model;
    END IF;

    -- Extract and concatenate all system messages into system_messages variable
    SELECT string_agg(message->>'content', ' ') 
    INTO system_messages
    FROM jsonb_array_elements(message_payload::JSONB) AS msg(message)
    WHERE msg.message->>'role' = 'system';

    -- Filter out system messages from message_payload
    message_payload := (
        SELECT jsonb_agg(msg.message) 
        FROM jsonb_array_elements(message_payload::JSONB) AS msg(message)
        WHERE msg.message->>'role' != 'system'
    );

    -- Make the HTTP request and retrieve the response

	
    SELECT content
        INTO api_response
        FROM public.http(
		  (
            'POST',
            endpoint_uri || '?key=' || api_token,
            NULL,
            'application/json',
            json_build_object(
                'contents', message_payload,
                'system_instruction',  system_messages,  -- Add concatenated system text
                -- 'tool_config', json_build_object(
                --     'function_calling_config', json_build_object(
                --         'mode', 
                --         CASE 
                --             WHEN functions_in IS NOT NULL THEN 'ANY' 
                --             ELSE 'NONE' 
                --         END
                --     )
                -- ),
                'tools', functions_in,
                'model', model_name
            )::jsonb
		   )::http_request
        );

    -- Log the API response for debugging
    RAISE NOTICE 'API Response: %', api_response;

    -- Return the processed result in canonical form
    RETURN QUERY 
    SELECT * from p8.google_to_open_ai_response(api_response);

END;
$BODY$;

ALTER FUNCTION p8.request_google(json, json, text, text, text)
    OWNER TO postgres;
