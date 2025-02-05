
DROP FUNCTION IF EXISTS p8.get_session_functions;
CREATE OR REPLACE FUNCTION p8.get_session_functions(
	session_id_in uuid,
	functions_names text[],
	selected_scheme text DEFAULT 'openai'::text)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    existing_functions TEXT[];
    merged_functions TEXT[];
    result JSONB;
BEGIN
    /*
    Retrieves the function stack from p8.AIResponse, merges it with additional function names,
    and returns the corresponding tool information.
    
    Example Usage:
    
    SELECT p8.get_session_functions(
        '42e80e20-6b9e-02f4-8af7-76d4f1ef049f'::UUID, 
        ARRAY['get_entities'], 
        'openai'
    );
    */

    -- Fetch the existing function stack from the last session message but we need to think about this
    SELECT COALESCE(function_stack, ARRAY[]::TEXT[])
    INTO existing_functions
    FROM p8."AIResponse"
    WHERE session_id = session_id_in
	order by created_at DESC
	LIMIT 1 ;

    -- Merge existing functions with new ones, removing duplicates
    merged_functions := ARRAY(
        SELECT DISTINCT unnest(existing_functions || functions_names)
    );

	RAISE NOTICE 'Session functions for response % are % after merging existing % ', session_id_in, merged_functions, existing_functions;
	
    -- Get tool information for the merged function names
    SELECT p8.get_tools_by_name(merged_functions, selected_scheme) INTO result;

    RETURN result;
END;
$BODY$;

