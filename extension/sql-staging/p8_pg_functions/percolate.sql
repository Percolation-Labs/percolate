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




--drop function percolate_with_agent
drop function percolate_with_agent;
CREATE OR REPLACE FUNCTION public.percolate_with_agent(
    question TEXT,
    agent TEXT,
    tool_names_in TEXT[] DEFAULT NULL,
    system_prompt TEXT DEFAULT 'Respond to the users query using tools and functions as required',
    model_key VARCHAR(100) DEFAULT 'gpt-4o-mini',
    token_override TEXT DEFAULT NULL,
    user_id UUID DEFAULT NULL,
    temperature FLOAT DEFAULT 0.01
)
RETURNS TABLE(message_response text, tool_calls jsonb, tool_call_result jsonb, session_id_out uuid, status TEXT)  AS $$
DECLARE
    generated_system_prompt TEXT;
    tool_names_array TEXT[];
    endpoint_uri TEXT;
    api_token TEXT;
    selected_model TEXT;
    selected_scheme TEXT;
    functions JSON;
    message_payload JSON;
	created_session_id uuid;
BEGIN

	/*
	this wraps the inner function for ask (currently this is the canonical one for testing and we generalize for schemes)
	it takes in an agent and a question which defines the LLM request from the data
	--if you have follow the python guide this agent will exist or try another agent
	select * from percolate_with_agent('list some pets that str sold', 'MyFirstAgent'); 
	--first turn retrieves data from tools and provides a session id which you can resume
	*/

	select create_session from p8.create_session(user_id, question, agent)
	into created_session_id;
	
    SELECT completions_uri, COALESCE(token, token_override), model, scheme
    INTO endpoint_uri, api_token, selected_model, selected_scheme
    FROM p8."LanguageModelApi"
    WHERE "name" = model_key
    LIMIT 1;

    -- Default public schema for agent if not provided
    SELECT CASE 
        WHEN agent NOT LIKE '%.%' THEN 'public.' || agent 
        ELSE agent 
    END INTO agent;

    -- Generate system prompt
    SELECT p8.generate_markdown_prompt(agent, 200)
    INTO generated_system_prompt;

    -- Fetch tool names associated with the agent
    SELECT ARRAY(
        SELECT jsonb_object_keys(a.functions::JSONB)
        FROM p8."Agent" a
        WHERE a.name = agent AND a.functions IS NOT NULL
    ) INTO tool_names_array;

    -- (B) If tool names exist, fetch tool data
    IF tool_names_array IS NOT NULL THEN
        SELECT p8.get_tools_by_name(tool_names_array, selected_scheme)
        INTO functions;
    ELSE
        functions := '[]'::JSON;
    END IF;

    SELECT jsonb_build_array(
        jsonb_build_object('role', 'system', 'content', coalesce(generated_system_prompt,system_prompt)),
        jsonb_build_object('role', 'user', 'content', question)::JSON
    ) INTO message_payload;

    IF message_payload IS NULL OR model_key IS NULL OR api_token IS NULL THEN
        RAISE EXCEPTION 'Missing required parameters for canonical_ask';
    END IF;

    -- Invoke the main function 
    RETURN QUERY 
    SELECT * FROM p8.canonical_ask(
        message_payload,
        created_session_id,  
        functions,
        model_key,
        token_override,
        user_id
        --,temperature
    );

END;
$$ LANGUAGE plpgsql;
