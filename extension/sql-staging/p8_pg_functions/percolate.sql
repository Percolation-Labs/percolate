-- DROP function percolate; 
-- DROP FUNCTION percolate_with_tools;
-- DROP FUNCTION percolate_with_agent;

CREATE OR REPLACE FUNCTION public.percolate(
    text TEXT,
    model VARCHAR(100) DEFAULT 'gpt-4o-mini',
    tool_names_in TEXT[] DEFAULT NULL,
    system_prompt TEXT DEFAULT 'Respond to the users query using tools and functions as required',
    token_override TEXT DEFAULT NULL,
    temperature FLOAT DEFAULT 0.01
)
RETURNS TABLE(message_response TEXT, tool_calls JSONB, tool_call_result JSONB) AS $$
BEGIN
    RETURN QUERY 
    SELECT * FROM p8.ask_with_prompt_and_tools(
        text, 
        tool_names_in, 
        system_prompt, 
        model, 
        token_override, 
        temperature
    );
END;
$$ LANGUAGE plpgsql;

-- Wrapper function `percolate_with_tools`
CREATE OR REPLACE FUNCTION public.percolate_with_tools(
    question TEXT,
    tool_names_in TEXT[],
    model_key VARCHAR(100) DEFAULT 'gpt-4o-mini',
    system_prompt TEXT DEFAULT 'Respond to the users query using tools and functions as required',
    token_override TEXT DEFAULT NULL,
    temperature FLOAT DEFAULT 0.01
)
RETURNS TABLE(message_response TEXT, tool_calls JSONB, tool_call_result JSONB) AS $$
BEGIN
    RETURN QUERY 
    SELECT * FROM p8.ask_with_prompt_and_tools(
        question, 
        tool_names_in, 
        system_prompt, 
        model_key, 
        token_override, 
        temperature
    );
END;
$$ LANGUAGE plpgsql;

-- Wrapper function `percolate_with_agent`


	
CREATE OR REPLACE FUNCTION public.percolate_with_agent(
    question TEXT,
    agent TEXT,
    tool_names_in TEXT[] DEFAULT NULL,
    system_prompt TEXT DEFAULT 'Respond to the users query using tools and functions as required',
    model_key VARCHAR(100) DEFAULT 'gpt-4o-mini',
    token_override TEXT DEFAULT NULL,
    temperature FLOAT DEFAULT 0.01
)
RETURNS TABLE(message_response TEXT, tool_calls JSONB, tool_call_result JSONB) AS $$
DECLARE
    generated_system_prompt TEXT; 
    tool_names_array TEXT[]; 
BEGIN
	/*

	An agent that is registered from Python in the examples with external functions can be used;
	select * from percolate_with_agent('list some pets that were sold', 'p8.MyFirstAgent');
	*/

    -- Generate the system prompt using the `p8.generate_markdown_prompt` function
	-- 200 is a magic number we use to generate enums TODO: think about how we might want to deal more generally
    SELECT p8.generate_markdown_prompt(agent, 200)
    INTO generated_system_prompt;

    -- Select tool names from the "Agent" table and convert them into a text array
    SELECT ARRAY(
        SELECT jsonb_object_keys(a.functions::JSONB)
        FROM p8."Agent" a
        WHERE a.name = agent and a.functions is not null
    ) INTO tool_names_array;

    -- Use generated system prompt and tool names in the main function call
    RETURN QUERY 
    SELECT * FROM p8.ask_with_prompt_and_tools(
        question, 
        COALESCE(tool_names_array, tool_names_in),
        COALESCE(generated_system_prompt, system_prompt), 
        model_key, 
        token_override, 
        temperature
    );
END;
$$ LANGUAGE plpgsql;


 