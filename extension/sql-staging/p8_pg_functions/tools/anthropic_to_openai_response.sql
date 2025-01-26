
CREATE OR REPLACE FUNCTION p8.anthropic_to_open_ai_response(
	api_response jsonb)
    RETURNS TABLE(msg text, tool_calls_out json) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
BEGIN
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
	                        'arguments', (el->>'input')::JSON
	                    )
	                )
	            ) AS tool_calls
	    FROM r
	    WHERE el->>'type' = 'tool_use'
	)
	SELECT
	    msg.msg,
	    tool_calls.tool_calls
	FROM msg
	FULL OUTER JOIN tool_calls ON TRUE;
END;
$BODY$;
