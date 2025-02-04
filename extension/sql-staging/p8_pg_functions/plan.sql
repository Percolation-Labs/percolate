CREATE OR REPLACE FUNCTION public.plan(
    question text,
    model_key character varying DEFAULT 'gpt-4o-mini'::character varying,
    token_override text DEFAULT NULL::text,
    user_id uuid DEFAULT NULL::uuid
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
    endpoint_uri TEXT;
    api_token TEXT;
    selected_model TEXT;
    selected_scheme TEXT;
    functions JSON;
    message_payload JSON;
    created_session_id uuid;
    recovered_system_prompt TEXT;
    additional_message JSON;
BEGIN

    IF question IS NULL THEN
        RAISE EXCEPTION 'No question provided to the plan function - check parameters names are propagated';
    END IF;

    -- Create session and store session ID
    SELECT create_session FROM p8.create_session(user_id, question, 'p8.PlanModel')
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
        RAISE EXCEPTION 'Missing required API details for request. Model request is %s, scheme=%s', selected_model, selected_scheme;
    END IF;

    -- Recover system prompt
    SELECT coalesce(p8.generate_markdown_prompt('p8.PlanModel'), 'Respond to the users query using tools and functions as required')
    INTO recovered_system_prompt;

    -- Get the initial message payload
    SELECT * INTO message_payload FROM p8.get_canonical_messages(created_session_id, question, recovered_system_prompt);

    -- Ensure message payload was successfully fetched
    IF message_payload IS NULL THEN
        RAISE EXCEPTION 'Failed to retrieve message payload for session %', created_session_id;
    END IF;

    -- Retrieve functions and format as an additional user message
	SELECT json_build_object(
	    'role', 'user',
	    'content', json_agg(json_build_object('name', f.name, 'desc', f.description))::TEXT
	)
	INTO additional_message
	FROM p8."Function" f;


    -- Append the additional message correctly (handling array case)
    IF additional_message IS NOT NULL THEN
        message_payload = (message_payload::JSONB || jsonb_build_array(additional_message))::JSON;
    END IF;

    RAISE NOTICE 'Ask request for agent % using language model - % - messages %', 'p8.PlanModel', model_key, message_payload;

    -- Call p8.ask with tools set to NULL (can be updated later)
    RETURN QUERY 
    SELECT * FROM p8.ask(
        message_payload::json, 
        created_session_id, 
        NULL,  -- Tools can be fetched, but we pass NULL for now
        model_key, 
        token_override, 
        user_id
    );
END;
$BODY$;
