CREATE OR REPLACE FUNCTION p8.get_agent_tools(
    recovered_agent TEXT,
    selected_scheme TEXT DEFAULT  'openai',
    add_percolate_tools BOOLEAN DEFAULT FALSE
)
RETURNS JSONB AS $$
DECLARE
    tool_names_array TEXT[];
    functions JSONB;
BEGIN
    -- Get tool names from Agent functions
    SELECT ARRAY(
        SELECT jsonb_object_keys(a.functions::JSONB)
        FROM p8."Agent" a
        WHERE a.name = recovered_agent AND a.functions IS NOT NULL
    ) INTO tool_names_array;

    -- Fetch tool data if tool names exist
    IF tool_names_array IS NOT NULL THEN
        SELECT p8.get_tools_by_name(tool_names_array, selected_scheme)
        INTO functions;
    ELSE
        functions := '[]'::JSONB;
    END IF;

    -- Add percolate tools if the parameter is true
    IF add_percolate_tools THEN
        -- Assuming there's a function to add percolate tools, like:
        -- SELECT p8.get_tools_by_name(ARRAY['percolate_tool'], selected_scheme) INTO percolate_tools;
        -- functions := functions || percolate_tools;
        -- Example assuming the percolate tools are added as an array of JSONB objects:
        functions := functions || '[{"tool_name": "percolate_tool", "details": "added percolate tool"}]'::JSONB;
    END IF;

    -- Return the final tools data
    RETURN functions;
END;
$$ LANGUAGE plpgsql;

