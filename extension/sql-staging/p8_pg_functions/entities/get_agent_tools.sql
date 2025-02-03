DROP FUNCTION IF EXISTS p8.get_agent_tools;
CREATE OR REPLACE FUNCTION p8.get_agent_tools(
    recovered_agent TEXT,
    selected_scheme TEXT DEFAULT  'openai',
    add_percolate_tools BOOLEAN DEFAULT TRUE
)
RETURNS JSONB AS $$
DECLARE
    tool_names_array TEXT[];
    functions JSONB;
BEGIN

/*
select * from p8.get_agent_tools('p8.Agent', NULL, FALSE)
select * from p8.get_agent_tools('p8.Agent', NULL, TRUE)
select * from p8.get_agent_tools('p8.Agent', 'google')


*/
    -- Get tool names from Agent functions
    SELECT ARRAY(
        SELECT jsonb_object_keys(a.functions::JSONB)
        FROM p8."Agent" a
        WHERE a.name = recovered_agent AND a.functions IS NOT NULL
    ) INTO tool_names_array;

     -- Add percolate tools if the parameter is true
    IF add_percolate_tools THEN
        -- Augment the tool_names_array with the percolate tools
        tool_names_array := tool_names_array || ARRAY[
            'help', 
            'get_entities', 
            'search', 
            'announce_generate_large_output'
        ];
    END IF;
    
    -- Fetch tool data if tool names exist
    IF tool_names_array IS NOT NULL THEN
        SELECT p8.get_tools_by_name(tool_names_array, COALESCE(selected_scheme,'openai'))
        INTO functions;
    ELSE
        functions := '[]'::JSONB;
    END IF;

    -- Return the final tools data
    RETURN functions;
END;
$$ LANGUAGE plpgsql;

