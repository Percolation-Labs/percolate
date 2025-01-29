
	
--drop function p8.resume_session;
CREATE OR REPLACE FUNCTION p8.resume_session(session_id uuid, token_override TEXT DEFAULT NULL)
RETURNS TABLE(message_response text, tool_calls jsonb, tool_call_result jsonb, session_id_out uuid,  status_out TEXT) AS $$
DECLARE
    recovered_session_id uuid;
    user_id uuid;
    recovered_agent text;
    generated_system_prompt text;
    recovered_question text;
    functions jsonb;
    tool_eval_data_recovered jsonb;
    model_key text;
    message_payload jsonb;
	last_session_status TEXT;
BEGIN
	/*
	import p8.canonical_ask

	we use the session and AIResponses that were saved
		The last AI response may end in a "COMPLETED" in which case there is nothing to do
	For now though, we resume with the inital agent prompt and user question + the tool response data from the session
		We may want some type of filter or limit in future although its not clear what content we really need


	--get a recent session - ideally one that ended in a tool response without errors
	select * from p8.resume_session('2de780af-4ba8-9b5e-7a53-4ef8606584cc'::UUID);

	*/

    -- 1. Get session details from p8.Session
    SELECT s.id, s.userid, s.agent, query INTO  recovered_session_id, user_id, recovered_agent,recovered_question
    FROM p8."Session" s
    WHERE s.id = session_id;

    -- Check if session exists
    IF recovered_session_id IS NULL THEN
        RETURN QUERY SELECT 'No matching session'::text, NULL::jsonb, NULL::jsonb, session_id;
        RETURN;
    END IF;

    -- 2. Select the system prompt using the agent
    SELECT p8.generate_markdown_prompt(recovered_agent, 200) INTO generated_system_prompt;
	IF generated_system_prompt IS NULL THEN
		--this is not recommended but for testing the agent can be the prompt of the agent does not exist
		generated_system_prompt:= recovered_agent;
	END IF;

    -- 3. Get the model key from p8.AIResponse
    SELECT model_name, status INTO model_key,last_session_status
    FROM p8."AIResponse" r
    WHERE r.session_id = recovered_session_id
	ORDER BY created_at DESC
    LIMIT 1;  

	--in future we can combeind 3&4 into one query for performance
    -- 4. Get the tool usage data (AI response) - this may be empty but the only reason to resume a session is if we aquired data via tools
    SELECT jsonb_agg(t) 
	INTO tool_eval_data_recovered 
    FROM (
        SELECT r.tool_eval_data, r.tool_calls
        FROM p8."AIResponse" r
        WHERE r.session_id = recovered_session_id AND r.tool_eval_data IS NOT NULL
		order by created_at DESC -- by getting the most recent first we can decide how far back to go
    ) AS t;

    -- 5. Construct the message payload (two parts)
    -- First part: system and user
    SELECT jsonb_build_array(
            jsonb_build_object('role', 'system', 'content', generated_system_prompt),
            jsonb_build_object('role', 'user', 'content', recovered_question)
        ) INTO message_payload;

    -- Check if message_payload was constructed
    IF message_payload IS NULL OR message_payload = '[]'::jsonb THEN
        RETURN QUERY SELECT 'No tool data - nothing to resume'::text, NULL::jsonb, NULL::jsonb, session_id;
        RETURN;
    END IF;

	--RAISE NOTICE '%',tool_eval_data_recovered;
	
    -- Second part: merge tool usage data with the message
	-- at the moment the content is just TEXT but we might not always wany to do that - its a just blob in text format
	-- a turn needs to play back both the tool call and the tool
	-- we are really just supporting one here and we can test more clever things
	-- a dedicated schema specific function is probably need to rebuild tool calls per session
	-- notice we are fetching just the one tool call - the tool calls are added beside content as the LLM gives it too us
    message_payload := message_payload || jsonb_build_array(
		jsonb_build_object('role', 'assistant', 'content', '', 'tool_calls', tool_eval_data_recovered->0->'tool_calls'),
        jsonb_build_object('role', 'tool', 'content', (tool_eval_data_recovered->0->'tool_eval_data')::TEXT, 'tool_call_id',
		  tool_eval_data_recovered->0->'tool_calls'->0->>'id'
		  )
    );

	--RAISE NOTICE '%', message_payload;
    -- 6. Call the p8.canonical_ask function
    RETURN QUERY 
    SELECT * FROM p8.canonical_ask(
        message_payload::JSON,
        recovered_session_id,
        functions::JSON,
        model_key,
        token_override,
        user_id
    );
END;
$$ LANGUAGE plpgsql;
