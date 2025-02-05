
DROP FUNCTION IF EXISTS p8.get_agent_tool_names;
CREATE OR REPLACE FUNCTION p8.get_agent_tool_names(
    recovered_agent TEXT,
    selected_scheme TEXT DEFAULT  'openai',
    add_percolate_tools BOOLEAN DEFAULT TRUE
)
RETURNS TEXT[] AS $$
DECLARE
    tool_names_array TEXT[];
    functions JSONB;
BEGIN

/*
select * from p8.get_agent_tool_names('p8.Agent', NULL, FALSE)
select * from p8.get_agent_tool_names('p8.Agent', NULL, TRUE)
select * from p8.get_agent_tool_names('p8.Agent', 'google')

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
        -- These are the standard percolate tools that are added unless the entity deactivates them
        tool_names_array := tool_names_array || ARRAY[
            'help', 
            'get_entities', 
            'search', 
            'announce_generate_large_output',
            'activate_functions_by_name'
        ];
    END IF;
    
    RETURN tool_names_array;
END;
$$ LANGUAGE plpgsql;

