
CREATE OR REPLACE FUNCTION p8.google_to_open_ai_response(
	api_response jsonb)
    RETURNS TABLE(msg text, tool_calls_out json) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    function_call jsonb; -- Variable to hold the function call JSON
BEGIN
    -- Capture the function call from the JSON
    function_call := api_response->'candidates'->0->'content'->'parts'->0->'functionCall';

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
                            'arguments', function_call->'args'
                        )
                    )
                )
            ELSE NULL
        END AS tool_calls_out;
END;
$BODY$;
