CREATE OR REPLACE FUNCTION p8.eval_native_function(
    function_name TEXT,
    args JSONB
)
RETURNS JSONB AS $$
DECLARE
	declare KEYS text[];
    result JSONB;
BEGIN
    /*
    working on a way to eval native functions with kwargs and hard coding for now

    this would be used for example if we did this
    select * from percolate_with_agent('get the description of the entity called p8.PercolateAgent', 'p8.PercolateAgent' ) 

    examples are

    SELECT p8.eval_native_function(
    'get_entities', 
    '{"keys": ["p8.Agent", "p8.PercolateAgent"]}'::JSONB
    );

    SELECT p8.eval_native_function(
    'activate_functions_by_name', 
    '{"estimated_length": 20000}'::JSONB
    );

    SELECT p8.eval_native_function(
    'search', 
    '{"question": "i need an agent about agents", "entity_table_name":"p8.Agent"}'::JSONB
    );  

    */
    CASE function_name
        -- NB the args here need to match how we define the native function interface in python or wherever
        -- If function_name is 'get_entities', call p8.get_entities with the given argument
        WHEN 'get_entities' THEN
            -- Extract the keys array from JSONB and cast it to a PostgreSQL TEXT array
            keys := ARRAY(SELECT jsonb_array_elements_text(args->'keys')::TEXT);
        
            SELECT p8.get_entities(keys) INTO result;

        -- If function_name is 'search', call p8.query_entity with the given arguments
        WHEN 'search' THEN
            SELECT p8.query_entity(args->>'question', args->>'entity_table_name') INTO result;

        -- If function_name is 'help', call p8.plan with the given argument
        WHEN 'help' THEN
            SELECT p8.plan(args->>'question') INTO result;

        -- If function_name is 'activate_functions_by_name', return a message and estimated_length
        WHEN 'activate_functions_by_name' THEN
            RETURN jsonb_build_object(
                'message', 'acknowledged',
                'estimated_length', args->>'estimated_length'
            );

        -- Default case for an unknown function_name
        ELSE
            RAISE EXCEPTION 'Function name "%" is unknown for args: %', function_name, args;
    END CASE;

    -- Return the result of the function called
    RETURN result;
END;
$$ LANGUAGE plpgsql;