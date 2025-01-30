-- FUNCTION: p8.generate_markdown_prompt(text, integer)

-- DROP FUNCTION IF EXISTS p8.generate_markdown_prompt(text, integer);

CREATE OR REPLACE FUNCTION public.percolate_with_agent(
    question text,
    agent text,
    tool_names_in text[] DEFAULT NULL::text[],
    system_prompt text DEFAULT 'Respond to the users query using tools and functions as required'::text,
    model_key character varying DEFAULT 'gpt-4o-mini'::character varying,
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
    recovered_system_prompt text;
BEGIN

    -- Ensure that question and agent are provided
    IF question IS NULL OR question = '' THEN
        RAISE EXCEPTION 'Question cannot be NULL or empty';
    END IF;

    IF agent IS NULL OR agent = '' THEN
        RAISE EXCEPTION 'Agent cannot be NULL or empty';
    END IF;


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
    WHERE "name" = model_key
    LIMIT 1;

    -- Ensure API details were found
    IF api_token IS NULL OR selected_model IS NULL OR selected_scheme IS NULL THEN
        RAISE EXCEPTION 'Missing required API details for request';
    END IF;

    -- Default public schema for agent if not provided
    SELECT CASE 
        WHEN agent NOT LIKE '%.%' THEN 'public.' || agent 
        ELSE agent 
    END INTO agent;

    -- Fetch tools for the agent by calling the new function
    SELECT p8.get_tools_for_agent(agent, selected_scheme) INTO functions;
    
    -- Ensure tools were fetched successfully
    IF functions IS NULL THEN
        RAISE EXCEPTION 'No tools found for agent % in scheme %', agent, selected_scheme;
    END IF;

    -- Recover system prompt using agent name
    SELECT p8.generate_markdown_prompt(agent) INTO recovered_system_prompt;
    

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
