/*we map all function call args to string for canonical*/

-- FUNCTION: p8.anthropic_to_open_ai_response(jsonb)

DROP FUNCTION IF EXISTS p8.anthropic_to_open_ai_response ;

CREATE OR REPLACE FUNCTION p8.anthropic_to_open_ai_response(
	api_response jsonb)
    RETURNS TABLE(msg text, tool_calls_out jsonb, tokens_in integer, tokens_out integer, finish_reason text, api_error text) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
BEGIN
    /*
    Example anthropic response message usage:
    select * from p8.anthropic_to_open_ai_response('{
  "id": "msg_015kdLpARvtbRqDSmJKiamSB",
  "type": "message",
  "role": "assistant",
  "model": "claude-3-5-sonnet-20241022",
  "content": [
    {"type": "text", "text": "Ill help you check the weather in Paris for tomorrow. Let me use the get_weather function with tomorrows date."},
    {"type": "tool_use", "id": "toolu_01GV5rqVypHCQ6Yhrfsz8qhQ", "name": "get_weather", "input": {"city": "Paris", "date": "2024-01-16"}}
  ],
  "stop_reason": "tool_use",
  "stop_sequence": null,
  "usage": {
    "input_tokens": 431,
    "cache_creation_input_tokens": 0,
    "cache_read_input_tokens": 0,
    "output_tokens": 101
  }
}'::JSONB)
    */

	 IF api_response ? 'error' THEN
        RETURN QUERY 
        SELECT api_response->>'error', NULL::JSONB, NULL::INTEGER, NULL::INTEGER, NULL, api_response->>'error';
        RETURN;
    END IF;
	
    RETURN QUERY
    WITH r AS (
        SELECT jsonb_array_elements(api_response->'content') AS el
    ),
    msg AS (
        SELECT el->>'text' AS msg
        FROM r
        WHERE el->>'type' = 'text'
    ),
    tool_calls AS (
        SELECT json_build_array(
                    json_build_object(
                        'id', el->>'id',
                        'type', 'function',
                        'function', json_build_object(
                            'name', el->>'name',
                            'arguments', (el->>'input')::TEXT
                        )
                    )
                ) AS tool_calls
        FROM r
        WHERE el->>'type' = 'tool_use'
    ),
    tokens AS (
        SELECT 
            (api_response->'usage'->>'input_tokens')::INTEGER AS tokens_in,
            (api_response->'usage'->>'output_tokens')::INTEGER AS tokens_out
    ),
    finish AS (
        SELECT 
            api_response->>'stop_reason' AS finish_reason
    ),
    error AS (
        SELECT api_response->>'error' AS api_error
    )
    SELECT
        msg.msg::TEXT, --in case null
        tool_calls.tool_calls::JSONB,
        tokens.tokens_in,
        tokens.tokens_out,
        lower(finish.finish_reason),
        error.api_error
    FROM msg
    FULL OUTER JOIN tool_calls ON TRUE
    CROSS JOIN tokens
    CROSS JOIN finish
    CROSS JOIN error;
END;
$BODY$;

ALTER FUNCTION p8.anthropic_to_open_ai_response(jsonb)
    OWNER TO postgres;
-----

-- FUNCTION: p8.google_to_open_ai_response(jsonb)

-- DROP FUNCTION IF EXISTS p8.google_to_open_ai_response(jsonb);

CREATE OR REPLACE FUNCTION p8.google_to_open_ai_response(
	api_response jsonb)
    RETURNS TABLE(msg text, tool_calls_out jsonb, tokens_in integer, tokens_out integer, finish_reason text, api_error TEXT) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    function_call jsonb; -- Variable to hold the function call JSON
BEGIN
    /*
    Example Google response message usage:
    select * from p8.google_to_open_ai_response('{
        "candidates": [
            {
                "content": {
                    "parts": [
                        {
                            "functionCall": {
                                "name": "get_weather",
                                "args": {"date": "2024-07-27", "city": "Paris"}
                            }
                        }
                    ],
                    "role": "model"
                },
                "finishReason": "STOP",
                "avgLogprobs": -0.004642472602427006
            }
        ],
        "usageMetadata": {
            "promptTokenCount": 83,
            "candidatesTokenCount": 16,
            "totalTokenCount": 99
        },
        "modelVersion": "gemini-1.5-flash"
    }'::JSONB)
    */

    -- Capture the function call from the JSON
    function_call := api_response->'candidates'->0->'content'->'parts'->0->'functionCall';

    -- Extract token usage and finish reason
    tokens_in := (api_response->'usageMetadata'->>'promptTokenCount')::INTEGER;
    tokens_out := (api_response->'usageMetadata'->>'candidatesTokenCount')::INTEGER;
    finish_reason := lower((api_response->'candidates'->0->>'finishReason')::TEXT);

    -- Capture any API errors
    api_error := api_response->>'error';

    -- Return the message and mapped tool calls
    RETURN QUERY
    SELECT
        (api_response->'candidates'->0->'content'->'parts'->0->>'text')::TEXT AS msg,
        CASE
            WHEN function_call IS NOT NULL THEN
                json_build_array(
                    json_build_object(
                        'id', function_call->>'name', -- Use the name as the ID
                        'type', 'function',
                        'function', json_build_object(
                            'name', function_call->>'name',
                            'arguments', (function_call->'args')::TEXT
                        )
                    )
                )::JSONB
            ELSE NULL
        END AS tool_calls_out,
        tokens_in,
        tokens_out,
        finish_reason,
        api_error;
END;
$BODY$;

ALTER FUNCTION p8.google_to_open_ai_response(jsonb)
    OWNER TO postgres;
