-- FUNCTION: p8.resume_session(uuid, text)

-- DROP FUNCTION IF EXISTS p8.resume_session(uuid, text);
-- select * from p8.get_agent_tools('public.MyFirstAgent', 'openai', FALSE)

CREATE OR REPLACE FUNCTION p8.resume_session(
	session_id uuid,
	token_override text DEFAULT NULL::text)
	--TODO we could override some hings like scheme too
    RETURNS TABLE(message_response text, tool_calls jsonb, tool_call_result jsonb, session_id_out uuid, status_out text) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    recovered_session_id uuid;
    user_id uuid;
    recovered_agent text;
    recovered_question text;
    selected_scheme text;
    model_key text;
    last_session_status text;
    functions jsonb;
    message_payload json;
    tool_eval_data_recovered jsonb;
BEGIN

	/*
	to test this generate a session and then select the id into the resume

	select * from percolate_with_agent('what pets are sold', 'MyFirstAgent');
	
	select * from p8.resume_session('075b3126-326c-d62d-db5d-506764babf09') --openai
	select * from p8.resume_session('6cf58a04-1650-9aae-8097-60f449274a70') --anthropic
	select * from p8.resume_session('619857d3-434f-fa51-7c88-6518204974c9') --google
	
 
	  -- select messages from p8.get_canonical_messages('583060b2-70c6-478c-a483-2292870a980a');
	  -- select messages from p8.get_anthropic_messages('6cf58a04-1650-9aae-8097-60f449274a70');
	  -- select messages from p8.get_google_messages('619857d3-434f-fa51-7c88-6518204974c9');
	  -- select * from p8."AIResponse" where session_id = '583060b2-70c6-478c-a483-2292870a980a'

	    --try this and resume from canonical 
	select * from percolate_with_agent('list some pets that str sold', 'MyFirstAgent', NULL, NULL, 'gemini-1.5-flash'); 
    select * from percolate_with_agent('list some pets that str sold', 'MyFirstAgent', NULL, NULL, 'claude-3-5-sonnet-20241022');
 
	*/
	
    -- 1. Get session details from p8.Session
    SELECT s.id, s.userid, s.agent, s.query INTO 
        recovered_session_id, user_id, recovered_agent, recovered_question
    FROM p8."Session" s
    WHERE s.id = session_id;

    -- Check if session exists
    IF recovered_session_id IS NULL THEN
        RETURN QUERY 
            SELECT 'No matching session'::text, NULL::jsonb, NULL::jsonb, session_id, NULL::text;
        RETURN;
    END IF;

    -- 2. Get the model key and last session status from p8.AIResponse
    SELECT r.model_name, r.status, a.scheme INTO 
        model_key, last_session_status, selected_scheme
    FROM p8."AIResponse" r
    JOIN p8."LanguageModelApi" a ON r.model_name = a.model
    WHERE r.session_id = recovered_session_id
    ORDER BY r.created_at DESC
    LIMIT 1;

    -- 3. Get the messages for the correct scheme
    IF selected_scheme = 'anthropic' THEN
        -- Select into message payload from p8.get_anthropic_messages
        SELECT messages INTO message_payload FROM p8.get_anthropic_messages(recovered_session_id);
    ELSIF selected_scheme = 'google' THEN
        -- Select into message payload from p8.get_google_messages
        SELECT messages INTO message_payload FROM p8.get_google_messages(recovered_session_id);
    ELSE
        -- Select into message payload from p8.get_canonical_messages
        SELECT messages INTO message_payload FROM p8.get_canonical_messages(recovered_session_id);
    END IF;

	--	RAISE NOTICE 'For session % and scheme %, we have Messages %', recovered_session_id, selected_scheme, message_payload;

    -- In case message_payload is NULL, log and return a generic response
    IF message_payload IS NULL THEN
        RETURN QUERY 
            SELECT 'No message payload found'::text, NULL::jsonb, NULL::jsonb, session_id, last_session_status;
        RETURN;
    END IF;

	 -- Default public schema for agent if not provided
    SELECT CASE 
        WHEN recovered_agent NOT LIKE '%.%' THEN 'public.' || recovered_agent 
        ELSE recovered_agent 
    END INTO recovered_agent;
	
    -- 4. Handle tool evaluation data recovery (using get_agent_tools function)
    BEGIN
        -- Call the get_agent_tools function to fetch tools for the agent
        SELECT p8.get_agent_tools(recovered_agent, selected_scheme, FALSE) INTO functions;
        
        -- If functions is NULL, log error and return
        IF functions IS NULL THEN
            RETURN QUERY 
                SELECT format('Error: Failed to retrieve agent tools for agent "%s" with scheme "%s"', recovered_agent, selected_scheme)::text,
				  NULL::jsonb, NULL::jsonb, session_id, last_session_status;
            RETURN;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        -- Error handling in case get_agent_tools fails
        RETURN QUERY 
            SELECT 'Error: ' || SQLERRM, NULL::jsonb, NULL::jsonb, session_id, last_session_status;
        RETURN;
    END;


	
    -- 5. Return the results using p8.ask function
    RETURN QUERY 
    SELECT * 
    FROM p8.ask(
        message_payload::json, 
        recovered_session_id, 
        functions::json, 
        model_key, 
        token_override, 
        user_id
    );
END;
$BODY$;

ALTER FUNCTION p8.resume_session(uuid, text)
    OWNER TO postgres;
