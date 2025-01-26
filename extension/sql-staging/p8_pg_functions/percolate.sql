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
