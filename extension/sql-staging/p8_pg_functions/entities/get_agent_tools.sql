
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

    SELECT p8.get_agent_tool_names(recovered_agent,selected_scheme,add_percolate_tools) into tool_names_array;

    
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

