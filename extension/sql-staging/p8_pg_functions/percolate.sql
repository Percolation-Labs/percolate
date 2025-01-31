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
-- FUNCTION: public.percolate_with_agent

-- DROP FUNCTION IF EXISTS public.percolate_with_agent;

-- FUNCTION: public.percolate_with_agent

-- DROP FUNCTION IF EXISTS public.percolate_with_agent;
CREATE OR REPLACE FUNCTION public.percolate_with_agent(
    question text,
    agent text,
    model_key character varying DEFAULT 'gpt-4o-mini'::character varying,
    tool_names_in text[] DEFAULT NULL::text[],
    system_prompt text DEFAULT 'Respond to the users query using tools and functions as required'::text,
    token_override text DEFAULT NULL::text,
    user_id uuid DEFAULT NULL::uuid,
    temperature double precision DEFAULT 0.01
)
RETURNS TABLE(
    message_response text,
    tool_calls jsonb,
    tool_call_result jsonb,
    session_id_out uuid,
    status text
) 
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
ROWS 1000
AS $BODY$
DECLARE
    tool_names_array TEXT[];
    endpoint_uri TEXT;
    api_token TEXT;
    selected_model TEXT;
    selected_scheme TEXT;
    functions JSON;
    message_payload JSON;
    created_session_id uuid;
    	recovered_system_prompt TEXT;
BEGIN

    /*
    This wraps the inner function for ask (currently this is the canonical one for testing and we generalize for schemes)
    It takes in an agent and a question which defines the LLM request from the data.
    -- If you have followed the python guide, this agent will exist or try another agent.
    -- Example usage:
    -- select * from percolate_with_agent('list some pets that str sold', 'MyFirstAgent');
    -- First turn retrieves data from tools and provides a session id which you can resume.
    -- To test with other schemes:
    -- select * from percolate_with_agent('list some pets that str sold', 'MyFirstAgent', NONE, NONE, 'gemini-1.5-flash'); 
    -- select * from percolate_with_agent('list some pets that str sold', 'MyFirstAgent', NONE, NONE, 'claude-3-5-sonnet-20241022');

	-- select * from p8.get_canonical_messages('8d4357de-eb78-8df5-2182-ef4d85969bc5', 'test', 'test');
	-- select * from p8.get_google_messages('8d4357de-eb78-8df5-2182-ef4d85969bc5', 'test', 'test');
	-- select * from p8.get_canonical_messages('8d4357de-eb78-8df5-2182-ef4d85969bc5', 'test', 'test');
    */

   
    -- Create session and store session ID
    SELECT create_session FROM p8.create_session(user_id, question, agent)
    INTO created_session_id;

    -- Ensure session creation was successful
    IF created_session_id IS NULL THEN
        RAISE EXCEPTION 'Failed to create session';
    END IF;

    -- Retrieve API details
    SELECT completions_uri, COALESCE(token, token_override), model, scheme
    INTO endpoint_uri, api_token, selected_model, selected_scheme
    FROM p8."LanguageModelApi"
    WHERE "name" = COALESCE(model_key, 'gpt-4o-mini')
    LIMIT 1;

    -- Ensure API details were found
    IF api_token IS NULL OR selected_model IS NULL OR selected_scheme IS NULL THEN
        RAISE EXCEPTION format('Missing required API details for request. Model request is %s, scheme=%s',selected_model, selected_scheme);
    END IF;

    -- Default public schema for agent if not provided
    SELECT CASE 
        WHEN agent NOT LIKE '%.%' THEN 'public.' || agent 
        ELSE agent 
    END INTO agent;

    -- Fetch tools for the agent by calling the new function
    SELECT p8.get_agent_tools(agent, selected_scheme) INTO functions;
     
    -- Ensure tools were fetched successfully
    IF functions IS NULL THEN
        RAISE EXCEPTION 'No tools found for agent % in scheme %', agent, selected_scheme;
    END IF;

    -- Recover system prompt using agent name
    SELECT coalesce(p8.generate_markdown_prompt(agent),system_prompt) INTO recovered_system_prompt;
    
    -- Get the messages for the correct scheme
    IF selected_scheme = 'anthropic' THEN
        -- Select into message payload from p8.get_anthropic_messages
        SELECT * INTO message_payload FROM p8.get_anthropic_messages(created_session_id, question, recovered_system_prompt);
    ELSIF selected_scheme = 'google' THEN
        -- Select into message payload from p8.get_google_messages
        SELECT * INTO message_payload FROM p8.get_google_messages(created_session_id, question, recovered_system_prompt);
    ELSE
        -- Select into message payload from p8.get_canonical_messages
        SELECT * INTO message_payload FROM p8.get_canonical_messages(created_session_id, question, recovered_system_prompt);
    END IF;

    -- Ensure message payload was successfully fetched
    IF message_payload IS NULL THEN
        RAISE EXCEPTION 'Failed to retrieve message payload for session %', created_session_id;
    END IF;

    -- Return the results using p8.ask function
    RETURN QUERY 
    SELECT * FROM p8.ask(
        message_payload::json, 
        created_session_id, 
        functions::json, 
        model_key, 
        token_override, 
        user_id
    );
END;
$BODY$;

ALTER FUNCTION public.percolate_with_agent(
    text, text, text[], text, character varying, text, uuid, double precision
)
OWNER TO postgres;
