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


---------

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


DROP FUNCTION IF EXISTS public.percolate_with_agent;
CREATE OR REPLACE FUNCTION public.percolate_with_agent(
    question text,
    agent text DEFAULT 'p8.PercolateAgent',
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
    function_names TEXT[];
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

    select * from percolate_with_agent('how does percolate manage to work with google, openai and anthropic schemes seamlessly in the database - give sql examples', 'p8.PercolateAgent', 

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
        RAISE EXCEPTION 'Missing required API details for request. Model request is %s, scheme=%s',selected_model, selected_scheme;
    END IF;

    -- Default public schema for agent if not provided
    SELECT CASE 
        WHEN agent NOT LIKE '%.%' THEN 'public.' || agent 
        ELSE agent 
    END INTO agent;

    -- Fetch tools for the agent by calling the new function (we could add extra tool_names_in)
    SELECT p8.get_agent_tool_names(agent, selected_scheme, TRUE) INTO function_names;
             
    -- Ensure tools were fetched successfully
    IF function_names IS NULL THEN
        RAISE EXCEPTION 'No tools found for agent % in scheme %', agent, selected_scheme;
    END IF;

    -- Recover system prompt using agent name
    SELECT coalesce(p8.generate_markdown_prompt(agent), system_prompt) INTO recovered_system_prompt;
    
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

    --RAISE NOTICE 'Ask request with tools % for agent % using language model %', function_names, agent, model_key;

    -- Return the results using p8.ask function
    RETURN QUERY 
    SELECT * FROM p8.ask(
        message_payload::json, 
        created_session_id, 
        function_names, 
        model_key, 
        token_override, 
        user_id
    );
END;
$BODY$;


---------

DROP FUNCTION IF EXISTS p8.eval_native_function;
CREATE OR REPLACE FUNCTION p8.eval_native_function(
	function_name text,
	args jsonb,
    response_id UUID DEFAULT NULL
    )
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
	declare KEYS text[];
    result JSONB;
BEGIN
    /*
    working on a way to eval native functions with kwargs and hard coding for now

    this would be used for example if we did this
    select * from percolate_with_agent('get the description of the entity called p8.PercolateAgent', 'p8.PercolateAgent' ) 

    examples are

    SELECT p8.eval_native_function(
    'get_entities', 
    '{"keys": ["p8.Agent", "p8.PercolateAgent"]}'::JSONB
    );

    SELECT p8.eval_native_function(
    'activate_functions_by_name', 
    '{"estimated_length": 20000}'::JSONB
    );

    SELECT p8.eval_native_function(
    'search', 
    '{"question": "i need an agent about agents", "entity_table_name":"p8.Agent"}'::JSONB
    );  
	--basically does select * from p8.query_entity('i need an agent about agents', 'p8.Agent')

     SELECT p8.eval_native_function(
        'activate_functions_by_name', 
        '{"function_names": ["p8.Agent", "p8.PercolateAgent"]}'::JSONB,
        '42e80e20-6b9e-02f4-8af7-76d4f1ef049f'::UUID
        );  
        
  
    */
    CASE function_name
        WHEN 'activate_functions_by_name' THEN
            keys := ARRAY(SELECT jsonb_array_elements_text(args->'function_names')::TEXT);
           
			-- Call activate_functions_by_name and convert the TEXT[] into a JSON array
            SELECT jsonb_agg(value) 
            INTO result
            FROM unnest(p8.activate_functions_by_name(keys, response_id)) AS value;

        -- NB the args here need to match how we define the native function interface in python or wherever
        -- If function_name is 'get_entities', call p8.get_entities with the given argument
        WHEN 'get_entities' THEN
            -- Extract the keys array from JSONB and cast it to a PostgreSQL TEXT array
            keys := ARRAY(SELECT jsonb_array_elements_text(args->'keys')::TEXT);
        
            SELECT p8.get_entities(keys) INTO result;

        -- If function_name is 'search', call p8.query_entity with the given arguments
        WHEN 'search' THEN
            SELECT jsonb_agg(row) 
			INTO result
			FROM (
			    SELECT p8.query_entity(args->>'question', args->>'entity_table_name')
			) AS row;

        -- If function_name is 'help', call p8.plan with the given argument
        WHEN 'help' THEN
            SELECT jsonb_agg(row) 
			INTO result
			FROM (
			     SELECT public.plan(COALESCE(args->>'questions',args->>'question'))
			) AS row;

        -- If function_name is 'activate_functions_by_name', return a message and estimated_length
        WHEN 'announce_generate_large_output' THEN
            RETURN jsonb_build_object(
                'message', 'acknowledged',
                'estimated_length', args->>'estimated_length'
            );

        -- Default case for an unknown function_name
        ELSE
            RAISE EXCEPTION 'Function name "%" is unknown for args: %', function_name, args;
    END CASE;

    -- Return the result of the function called
    RETURN result;
END;
$BODY$;

 

---------

CREATE OR REPLACE FUNCTION p8.get_tools_by_description(
    description_text text,
    limit_results integer DEFAULT 5)
RETURNS TABLE(name character varying, spec json, distance double precision) 
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
ROWS 1000
AS $BODY$
DECLARE
    embedded_question VECTOR; -- Variable to store the computed embedding
BEGIN
    -- Compute the embedding once and store it in the variable
    SELECT embedding
    INTO embedded_question
    FROM p8.get_embedding_for_text(description_text);

    -- Check if embedding calculation returned NULL
    IF embedded_question IS NULL THEN
        RAISE EXCEPTION 'Embedding calculation failed for input: %', description_text;
    END IF;

    -- Perform the query only if embedding is valid
    RETURN QUERY
    WITH records AS (
        SELECT 
            b.name,
            MIN(a.embedding_vector <-> embedded_question) AS vdistance
        FROM p8_embeddings."p8_Function_embeddings" a
        JOIN p8."Function" b ON b.id = a.source_record_id
        WHERE a.embedding_vector <-> embedded_question <= 0.75
        GROUP BY b.name
    )
    SELECT 
        CAST(r.name AS character varying) AS name,
        f.function_spec,
        r.vdistance
    FROM records r
    JOIN p8."Function" f ON r.name = f.name
    ORDER BY r.vdistance ASC
    LIMIT limit_results;

    -- Optional: Return an empty result set if no matches are found
    RETURN;
END;
$BODY$;

ALTER FUNCTION p8.get_tools_by_description(text, integer)
OWNER TO postgres;


---------


DROP FUNCTION IF EXISTS p8.get_session_functions;
CREATE OR REPLACE FUNCTION p8.get_session_functions(
	session_id_in uuid,
	functions_names text[],
	selected_scheme text DEFAULT 'openai'::text)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    existing_functions TEXT[];
    merged_functions TEXT[];
    result JSONB;
BEGIN
    /*
    Retrieves the function stack from p8.AIResponse, merges it with additional function names,
    and returns the corresponding tool information.
    
    Example Usage:
    
    SELECT p8.get_session_functions(
        '42e80e20-6b9e-02f4-8af7-76d4f1ef049f'::UUID, 
        ARRAY['get_entities'], 
        'openai'
    );
    */

    -- Fetch the existing function stack from the last session message but we need to think about this
    SELECT COALESCE(function_stack, ARRAY[]::TEXT[])
    INTO existing_functions
    FROM p8."AIResponse"
    WHERE session_id = session_id_in
	order by created_at DESC
	LIMIT 1 ;

    -- Merge existing functions with new ones, removing duplicates
    merged_functions := ARRAY(
        SELECT DISTINCT unnest(existing_functions || functions_names)
    );

	RAISE NOTICE 'Session functions for response % are % after merging existing % ', session_id_in, merged_functions, existing_functions;
	
    -- Get tool information for the merged function names
    SELECT p8.get_tools_by_name(merged_functions, selected_scheme) INTO result;

    RETURN result;
END;
$BODY$;



---------

CREATE OR REPLACE FUNCTION p8.get_tools_by_name(
    names text[],
    scheme text DEFAULT 'openai'::text
)
RETURNS jsonb
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    record_count INT;
BEGIN
    -- Check the count of records matching the names
    SELECT COUNT(*) INTO record_count
    FROM p8."Function"
    WHERE name = ANY(names);

    -- If no records match, return an empty JSON array
    IF record_count = 0 THEN
        RETURN '[]'::JSONB;
    END IF;

    -- Handle the scheme and return the appropriate JSON structure
    IF scheme = 'google' THEN
        RETURN (
            SELECT JSON_BUILD_ARRAY(
                JSON_BUILD_OBJECT('function_declarations', JSON_AGG(function_spec::JSON))
            )
            FROM p8."Function"
            WHERE name = ANY(names)
        );
    ELSIF scheme = 'anthropic' THEN
        RETURN (
            SELECT JSON_AGG(
                JSON_BUILD_OBJECT(
                    'name', name,
                    'description', function_spec->>'description',
                    'input_schema', (function_spec->>'parameters')::JSON
                )
            )
            FROM p8."Function"
            WHERE name = ANY(names)
        );
    ELSE
        -- Default to openai
        RETURN (
            SELECT JSON_AGG(
                JSON_BUILD_OBJECT(
                    'type', 'function',
                    'function', function_spec::JSON
                )
            )
            FROM p8."Function"
            WHERE name = ANY(names)
        );
    END IF;
END;
$BODY$;



---------

/*
TODO: need to resolve the percolate or other API token 
*/

CREATE OR REPLACE FUNCTION p8.eval_function_call(
	function_call jsonb,
    response_id UUID DEFAULT NULL )
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    -- Variables to hold extracted data
    function_name TEXT;
    args JSONB;
    metadata RECORD;
    uri_root TEXT;
    call_uri TEXT;
    params JSONB;
    kwarg TEXT;
    matches TEXT[];
    final_args JSONB;
    api_response JSONB;
    api_token TEXT;
	query_arg TEXT[];
    native_result JSONB;
	--
	v_state   TEXT;
    v_msg     TEXT;
    v_detail  TEXT;
    v_hint    TEXT;
    v_context TEXT;
BEGIN

	/*
	--if you added the pet store example functions
	 select * from p8.eval_function_call('{"function": {"name": "get_pet_findByStatus", "arguments": "{\"status\":[\"sold\"]}"}}'::JSONB)
	 
	*/

    -- This is a variant of fn_construct_api_call but higher level - 
	-- we can refactor this into multilple modules but for now we will check for native calls inline
    IF function_call IS NULL OR NOT function_call ? 'function' THEN
        RAISE EXCEPTION 'Invalid input: function_call must contain a "function" key';
    END IF;

    function_name := function_call->'function'->>'name';
    IF function_name IS NULL THEN
        RAISE EXCEPTION 'Invalid input: "function" must have a "name"';
    END IF;

    args := (function_call->'function'->>'arguments')::JSON;
    IF args IS NULL THEN
        args := '{}';
    END IF;

	--temp savefty
	LOAD  'age'; SET search_path = ag_catalog, "$user", public;
	
    -- Lookup endpoint metadata
    SELECT endpoint, proxy_uri, verb
    INTO metadata
    FROM p8."Function"
    WHERE "name" = function_name;

	IF metadata.proxy_uri = 'native' THEN
		RAISE notice 'native query with args % % and response id %',  function_name, args,response_id;
        SELECT * FROM p8.eval_native_function(function_name,args::JSONB,response_id)
        INTO native_result;
        RETURN native_result;
	ELSE
	    -- If no matching endpoint is found, raise an exception
	    IF NOT FOUND THEN
	        RAISE EXCEPTION 'No metadata found for function %', function_name;
	    END IF;
	
	    -- Construct the URI root and call URI
	    uri_root :=  metadata.proxy_uri;
	    call_uri := uri_root || metadata.endpoint;
	    final_args := args;
	
	    -- Ensure API token is available
	    
		api_token := (SELECT api_token FROM p8."ApiProxy" LIMIT 1); 
	
	    -- Make the HTTP call
		RAISE NOTICE 'Invoke % with %', call_uri, final_args;
		BEGIN
		    IF UPPER(metadata.verb) = 'GET' THEN
		        -- For GET requests, append query parameters to the URL
		        call_uri := call_uri || '?' || p8.encode_url_query(final_args);
				RAISE NOTICE 'encoded %', call_uri;
		        SELECT content
		        INTO api_response
		        FROM http(
		            (
		                'GET', 
		                call_uri, 
		                ARRAY[http_header('Authorization', 'Bearer ' || api_token)], -- Add Bearer token
		                'application/json', 
		                NULL -- No body for GET requests
		            )::http_request
		        );
		    ELSE
		        -- For POST requests, include the body
		        SELECT content
		        INTO api_response
		        FROM http(
		            (
		                UPPER(metadata.verb), 
		                call_uri, 
		                ARRAY[http_header('Authorization', 'Bearer ' || api_token)], -- Add Bearer token
		                'application/json', 
		                final_args -- Pass the body for POST or other verbs
		            )::http_request
		        );
		    END IF;
		EXCEPTION WHEN OTHERS THEN
		    RAISE EXCEPTION 'HTTP request failed: %', SQLERRM;
		END;

		RAISE NOTICE 'tool response api %', api_response;
	
	    -- Return the API response
	    RETURN api_response;
	END IF;

EXCEPTION WHEN OTHERS THEN 
    GET STACKED DIAGNOSTICS
        v_state   = RETURNED_SQLSTATE,
        v_msg     = MESSAGE_TEXT,
        v_detail  = PG_EXCEPTION_DETAIL,
        v_hint    = PG_EXCEPTION_HINT,
        v_context = PG_EXCEPTION_CONTEXT;

    RAISE EXCEPTION E'Got exception:
        state  : %
        message: %
        detail : %
        hint   : %
        context: %', 
        v_state, v_msg, v_detail, v_hint, v_context;
END;
$BODY$;


---------

DROP FUNCTION IF EXISTS p8.activate_functions_by_name;
CREATE OR REPLACE FUNCTION p8.activate_functions_by_name(
    names TEXT[], 
    response_id UUID
) RETURNS TEXT[] AS $$
DECLARE
    updated_functions TEXT[];
BEGIN
    /*
    Merges the list of activated functions in the dialogue and returns the updated function stack.

    Example usage:
	SELECT * FROM p8.activate_functions_by_name(ARRAY[ 'Test', 'Other'], '42e80e20-6b9e-02f4-8af7-76d4f1ef049f'::UUID);
    SELECT * FROM p8.activate_functions_by_name(ARRAY[ 'New'], '42e80e20-6b9e-02f4-8af7-76d4f1ef049f'::UUID);
    */

    INSERT INTO p8."AIResponse" (id, model_name, content, role, function_stack)
    VALUES (
        response_id, 
        'percolate', 
        '', 
        '', 
        names
    )
    ON CONFLICT (id) DO UPDATE 
    SET 
        model_name = EXCLUDED.model_name,
        content = EXCLUDED.content,
        role = EXCLUDED.role,
        function_stack = ARRAY(SELECT DISTINCT unnest(p8."AIResponse".function_stack || EXCLUDED.function_stack))
    RETURNING function_stack INTO updated_functions;

    RETURN updated_functions;
END;
$$ LANGUAGE plpgsql;


---------

-- FUNCTION: p8.encode_url_query(jsonb)

-- DROP FUNCTION IF EXISTS p8.encode_url_query(jsonb);

CREATE OR REPLACE FUNCTION p8.encode_url_query(
	json_input jsonb)
    RETURNS text
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    key TEXT;
    value JSONB;
    query_parts TEXT[] := ARRAY[]::TEXT[];
    formatted_value TEXT;
BEGIN
/*
for example  select public.encode_url_query('{"status": ["sold", "available"]}') -> status=sold,available
*/
    -- Iterate through each key-value pair in the JSONB object
    FOR key, value IN SELECT * FROM jsonb_each(json_input)
    LOOP
        -- Check if the value is an array
        IF jsonb_typeof(value) = 'array' THEN
            -- Convert the array to a comma-separated string
            formatted_value := array_to_string(ARRAY(
                SELECT jsonb_array_elements_text(value)
            ), ',');
        ELSE
            -- Convert other types to text
            formatted_value := value::TEXT;
        END IF;

        -- Append the key-value pair to the query parts
        query_parts := query_parts || (key || '=' || formatted_value);
    END LOOP;

    -- Combine the query parts into a single string separated by '&'
    RETURN array_to_string(query_parts, '&');
END;
$BODY$;

ALTER FUNCTION p8.encode_url_query(jsonb)
    OWNER TO postgres;


---------

CREATE OR REPLACE FUNCTION p8.update_session(
    id UUID,
    user_id UUID,
    query TEXT
)
RETURNS VOID AS $$
BEGIN
    INSERT INTO p8."Session" (id, userid, query)
    VALUES (id, userid, query)
    ON CONFLICT (id) 
    DO UPDATE SET query = EXCLUDED.query;
END;
$$ LANGUAGE plpgsql;


 
CREATE OR REPLACE FUNCTION p8.create_session(
    user_id UUID,
    query TEXT,
    agent TEXT DEFAULT NULL,
	parent_session_id UUID DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    session_id UUID;
BEGIN
    -- Generate session ID from user_id and current timestamp
    session_id := p8.json_to_uuid(
        json_build_object('timestamp', current_timestamp::text, 'user_id', user_id)::JSONB
    );

    -- Upsert into p8.Session
    INSERT INTO p8."Session" (id, userid, query, parent_session_id, agent)
    VALUES (session_id, user_id, query, parent_session_id, agent)
    ON CONFLICT (id) DO UPDATE
    SET userid = EXCLUDED.userid,
        query = EXCLUDED.query,
        parent_session_id = EXCLUDED.parent_session_id,
        agent = EXCLUDED.agent;

    RETURN session_id;
END;
$$ LANGUAGE plpgsql;


---------

DROP FUNCTION IF EXISTS p8.get_google_messages;
CREATE OR REPLACE FUNCTION p8.get_google_messages(
    session_id_in UUID,
    question TEXT DEFAULT NULL,
    agent_or_system_prompt TEXT DEFAULT NULL
)
RETURNS TABLE(messages JSON, last_role TEXT, last_updated_at TIMESTAMP WITHOUT TIME ZONE) 
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
ROWS 1000
AS $BODY$
DECLARE
    recovered_session_id UUID;
    user_id UUID;
    recovered_agent TEXT;
    recovered_question TEXT;
    generated_system_prompt TEXT;
BEGIN
    /*
    https://cloud.google.com/vertex-ai/generative-ai/docs/multimodal/function-calling

    select messages from p8.get_google_messages('619857d3-434f-fa51-7c88-6518204974c9');

    call parts should be 

    {
        "functionCall": {
            "name": "get_current_weather",
            "args": {
                "location": "San Francisco"
            }
        }
    }
    
    response parts should be

    {
        "functionResponse": {
            "name": "get_current_weather",
            "response": {
                "temperature": 30.5,
                "unit": "C"
            }
        }
    }
    */

    -- 1. Get session details from p8."Session"
    SELECT s.id, s.userid, s.agent, s.query 
    INTO recovered_session_id, user_id, recovered_agent, recovered_question
    FROM p8."Session" s
    WHERE s.id = session_id_in;

    -- Check if session exists
    IF recovered_session_id IS NULL THEN
        -- Return null values for the session-related fields if session does not exist
        RETURN QUERY 
        SELECT NULL::JSON, NULL::TEXT, NULL::TIMESTAMP;
        RETURN;
    END IF;

    -- 2. Generate system prompt based on the recovered agent
    SELECT p8.generate_markdown_prompt(recovered_agent) 
    INTO generated_system_prompt;

    -- If no generated system prompt, fall back to using the agent directly
    IF generated_system_prompt IS NULL THEN
        generated_system_prompt := recovered_agent;
    END IF;

    -- 3. Construct the response messages
    RETURN QUERY
    WITH session_data AS (
        -- Fetch session data for the specified session_id
        SELECT content, role, tool_calls, tool_eval_data, created_at
        FROM p8."AIResponse" a
        WHERE a.session_id = session_id_in
    ),
    max_session_data AS (
        -- Get the last role and most recent timestamp
        SELECT role AS last_role, created_at AS last_updated_at
        FROM session_data
        ORDER BY created_at DESC
        LIMIT 1
    ),
    message_data AS (
        -- Combine system, user, and session data
        SELECT 'system' AS role, json_build_array(json_build_object('text',
            COALESCE(agent_or_system_prompt, generated_system_prompt)
        )) AS parts
        UNION ALL
        SELECT 'user' AS role, json_build_array(json_build_object('text',
            COALESCE(question, recovered_question)
        )) AS parts
        UNION ALL
        -- Generate one row for assistant tool call summary
        SELECT 'model' AS role,
            json_build_array(
                json_build_object(
                    'functionCall', json_build_object(
                        'name', el->'function'->>'name',
                        'args', (el->'function'->>'arguments')::json
                    )
                )
            ) AS parts
        FROM session_data, 
             LATERAL jsonb_array_elements(tool_calls::JSONB) el
        UNION ALL
        -- Generate multiple rows from tool_eval_data JSON array with a tool call id on each
        SELECT 'user' AS role,
            json_build_array(
                json_build_object(
                    'functionResponse',
                    json_build_object(
                        'name', el->>'id',
                        'response', json_build_object(
                            'name', el->>'id',
                            -- experiment with json or text
                            'content', (el->'data')::TEXT
                        )
                    )
                )
            ) AS parts
        FROM session_data, 
             LATERAL jsonb_array_elements(tool_eval_data::JSONB) el
    ),
    jsonrow AS (
        SELECT json_agg(row_to_json(message_data)) AS messages
        FROM message_data
    )
    SELECT * 
    FROM jsonrow 
    LEFT JOIN max_session_data ON true;  -- Ensure a row is returned even if no session data is found

END;
$BODY$;

ALTER FUNCTION p8.get_google_messages(UUID, text, text)
OWNER TO postgres;


---------

DROP FUNCTION IF EXISTS run;
CREATE OR REPLACE FUNCTION run(
    question text,
    agent text DEFAULT 'p8.PercolateAgent',
    model text DEFAULT 'gpt-4o-mini',
    limit_iterations int DEFAULT 2
) RETURNS TABLE (
    message_response text,
    tool_calls jsonb,
    tool_call_result jsonb,
    session_id_out uuid,
    status text
) AS $$
DECLARE
    session_id_captured uuid;
    current_row record;  -- To capture the row from resume_session
    iterations int := 1;
BEGIN
    /*
    this function is just for test/poc
    just because we can do this does not mean we should as it presents long running queries
    this would be implemented in practice with a bounder against the API.
    The client would then consume from an API that ways for the result
    Nonetheless, for testing purposes its good to test that the session does resolve as we resume to a limit

    Here is an example if you have registered the tool example for swagger/pets

    select * from run('please activate function get_pet_findByStatus and find two pets that are sold')

    this requires multiple turns - first it realizes it needs the function so activates, then it runs the function (keep in mind we eval tool calls in each turn)
    then it finally generates the answer
    */

    -- First, call percolate_with_agent function
    SELECT p.session_id_out INTO session_id_captured
    FROM percolate_with_agent(question, agent, model) p;
    
    -- Get the function_stack (just an example)
    SELECT function_stack INTO message_response
    FROM p8."AIResponse" r
    WHERE r.session_id = session_id_captured;

    -- Loop to iterate until limit_iterations or status = 'COMPLETED'
    LOOP
		RAISE NOTICE 'resuming session iteration %', iterations;
        -- Call resume_session to resume the session and get the row
        SELECT * INTO current_row
        FROM p8.resume_session(session_id_captured);
        
        -- Check if the status is 'COMPLETED' or iteration limit reached
        IF current_row.status = 'COMPLETED' OR iterations >= limit_iterations THEN
            EXIT;
        END IF;
        
        iterations := iterations + 1;
    END LOOP;
    
    -- Return the final row from resume_session
    RETURN QUERY
    SELECT current_row.message_response,
           current_row.tool_calls,
           current_row.tool_call_result,
           current_row.session_id_out,
           current_row.status;
END;
$$ LANGUAGE plpgsql;


---------

CREATE OR REPLACE FUNCTION p8.get_anthropic_messages(
    session_id_in uuid,
    question text DEFAULT NULL::text,
    agent_or_system_prompt text DEFAULT NULL::text)
    RETURNS TABLE(messages json, last_role text, last_updated_at timestamp without time zone) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000
AS $BODY$
DECLARE
    recovered_session_id UUID;
    user_id UUID;
    recovered_agent TEXT;
    recovered_question TEXT;
    generated_system_prompt TEXT;
BEGIN
    -- 1. Get session details from p8."Session"
    SELECT s.id, s.userid, s.agent, s.query 
    INTO recovered_session_id, user_id, recovered_agent, recovered_question
    FROM p8."Session" s
    WHERE s.id = session_id_in;

    -- Check if session exists
    IF recovered_session_id IS NULL THEN
        RETURN QUERY 
        SELECT NULL::JSON, NULL::TEXT, NULL::TIMESTAMP;
        RETURN;
    END IF;

    -- 2. Generate system prompt based on the recovered agent
    SELECT p8.generate_markdown_prompt(recovered_agent) 
    INTO generated_system_prompt;

    -- If no generated system prompt, fall back to using the agent directly
    IF generated_system_prompt IS NULL THEN
        generated_system_prompt := recovered_agent;
    END IF;

    RETURN QUERY
    WITH session_data AS (
        -- Fetch session data for the specified session_id
        SELECT content, role, tool_calls, tool_eval_data, created_at
        FROM p8."AIResponse" a
        WHERE a.session_id = session_id_in
    ),
    max_session_data AS (
        -- Get the last role and most recent timestamp
        SELECT role AS last_role, created_at AS last_updated_at
        FROM session_data
        ORDER BY created_at DESC
        LIMIT 1
    ),
    extracted_messages AS (
        -- Extract all messages, interleaving tool calls and user/assistant content while preserving the data structure
        SELECT NULL::TIMESTAMP as created_at, 'system' AS role, 
               json_build_array(
                   jsonb_build_object('type', 'text', 'text', COALESCE(agent_or_system_prompt, generated_system_prompt))
               ) AS content,
               0 AS rank
        UNION ALL
        SELECT NULL::TIMESTAMP as created_at, 'user' AS role, 
               json_build_array(
                   jsonb_build_object('type', 'text', 'text', COALESCE(question, recovered_question))
               ) AS content,
               1 AS rank
        UNION ALL
        SELECT created_at, 'assistant' AS role,
               jsonb_build_array(
                   jsonb_build_object(
                       'name', el->'function'->>'name',
                       'id', el->>'id',
                       'input', (el->'function'->>'arguments')::JSON,
                       'type', 'tool_use'
                   )
               )::JSON AS content,
               2 AS rank
        FROM session_data, 
             LATERAL jsonb_array_elements(tool_calls::JSONB) el
        WHERE tool_calls IS NOT NULL
        UNION ALL
        SELECT created_at, 'user' AS role,
               jsonb_build_array(
                   jsonb_build_object(
                       'type', 'tool_result',
                       'tool_use_id', el->>'id',
                       'content', el->>'data'
                   )
               )::JSON AS content,
               2 AS rank
        FROM session_data, 
             LATERAL jsonb_array_elements(tool_eval_data::JSONB) el
        WHERE tool_eval_data IS NOT NULL
    ),
    ordered_messages AS (
        -- Order the extracted messages by rank (to maintain the interleaving order) and created_at timestamp
        SELECT role, content
        FROM extracted_messages
        ORDER BY rank, created_at ASC
    ),
    jsonrow AS (
        -- Convert ordered messages into JSON
        SELECT json_agg(row_to_json(ordered_messages)) AS messages
        FROM ordered_messages
    )
    -- Return the ordered JSON messages along with metadata
    SELECT jsonrow.messages, max_session_data.last_role, max_session_data.last_updated_at
    FROM jsonrow 
    LEFT JOIN max_session_data ON true; -- Ensures at least one row is returned
END;
$BODY$;

ALTER FUNCTION p8.get_anthropic_messages(uuid, text, text)
    OWNER TO postgres;


---------

--select * from p8."LanguageModelApi"



DROP function if exists p8.request_openai;
CREATE OR REPLACE FUNCTION p8.request_openai(
    message_payload JSON,
    functions_in JSON DEFAULT NULL,
    model_name TEXT DEFAULT 'gpt-4o-mini',
    endpoint_uri TEXT DEFAULT 'https://api.openai.com/v1/chat/completions',
    api_token TEXT DEFAULT NULL
)
RETURNS TABLE(
    message_content TEXT, 
    tool_calls_out JSONB, 
    tokens_in INTEGER, 
    tokens_out INTEGER, 
    finish_reason TEXT, 
    api_error TEXT
) AS
$$
DECLARE
    api_response JSONB;
    result_set TEXT;
    tool_calls JSONB;
    selected_model TEXT;
    api_error JSONB;
    tokens_in INTEGER;
    tokens_out INTEGER;
    finish_reason TEXT;
BEGIN
    -- If api_token is NULL, retrieve values from the LanguageModelApi table
    IF api_token IS NULL THEN
        SELECT completions_uri, 
               COALESCE(token, api_token), 
               model
        INTO endpoint_uri, api_token, selected_model
        FROM p8."LanguageModelApi"
        WHERE scheme = 'openai'
        LIMIT 1;
    END IF;

    -- Ensure model_name defaults to the selected model if not provided
    IF model_name IS NULL THEN
        model_name := selected_model;
    END IF;

    -- Make the HTTP request and retrieve the response
    SELECT content
        INTO api_response
        FROM public.http(
		  (
            'POST',
            endpoint_uri,
            ARRAY[public.http_header('Authorization', 'Bearer ' || api_token)],
            'application/json',
            json_build_object(
                'model', model_name,
                'messages', message_payload,
                'tools', CASE 
                        WHEN functions_in IS NULL OR functions_in::TEXT = '[]' THEN NULL
                        ELSE functions_in 
                     END-- functions have been mapped for the scheme
            )::jsonb
		   )::http_request
        );

    -- Log the API response for debugging
    --RAISE NOTICE 'API Response: % from functions %', api_response, functions_in;

    -- Extract tool calls from the response
    tool_calls := (api_response->'choices'->0->'message'->>'tool_calls')::JSONB;
    result_set := (api_response->'choices'->0->'message'->>'content')::TEXT;
    api_error := (api_response->>'error')::TEXT;

    -- Handle token usage
    tokens_in := (api_response->'usage'->>'prompt_tokens')::INTEGER;
    tokens_out := (api_response->'usage'->>'completion_tokens')::INTEGER;
    finish_reason := (api_response->'choices'->0->>'finish_reason')::TEXT;
	
    --RAISE NOTICE 'WE HAVE % %', result_set, finish_reason;

    -- Return the results
    RETURN QUERY
    SELECT result_set::TEXT, tool_calls::JSONB, tokens_in::INTEGER, tokens_out::INTEGER, finish_reason::TEXT, api_error::TEXT;

END;
$$ LANGUAGE plpgsql;

-------------
DROP function if exists p8.request_anthropic;
CREATE OR REPLACE FUNCTION p8.request_anthropic(
    message_payload JSON,
    functions_in JSON DEFAULT NULL,
    model_name TEXT DEFAULT 'claude-3-5-sonnet-20241022',
    endpoint_uri TEXT DEFAULT 'https://api.anthropic.com/v1/messages',
	api_token TEXT DEFAULT NULL
)
RETURNS TABLE(
    message_content TEXT, 
    tool_calls_out JSONB, 
    tokens_in INTEGER, 
    tokens_out INTEGER, 
    finish_reason TEXT, 
    api_error TEXT
) AS
$$
DECLARE
    api_response JSONB;
    result_set JSONB;
    selected_model TEXT;
    selected_scheme TEXT;
    system_messages TEXT;
BEGIN
    -- If api_token is NULL, retrieve values from the LanguageModelApi table
    IF api_token IS NULL THEN
        SELECT completions_uri, 
               COALESCE(token, api_token), 
               model, 
               scheme
        INTO endpoint_uri, api_token, selected_model, selected_scheme
        FROM p8."LanguageModelApi"
        WHERE scheme = 'anthropic'
        LIMIT 1;
    END IF;

    -- Ensure model_name defaults to the selected model if not provided
    IF model_name IS NULL THEN
        model_name := selected_model;
    END IF;

    -- Extract and concatenate all system messages into system_messages variable
    SELECT string_agg(message->>'content', ' ') 
    INTO system_messages
    FROM jsonb_array_elements(message_payload::JSONB) AS msg(message)
    WHERE msg.message->>'role' = 'system';

    -- Filter out system messages from message_payload
    message_payload := (
        SELECT jsonb_agg(msg.message) 
        FROM jsonb_array_elements(message_payload::JSONB) AS msg(message)
        WHERE msg.message->>'role' != 'system'
    );

    -- Make the HTTP request and retrieve the response
    SELECT content
        INTO api_response
        FROM public.http(
		   (
            'POST',
            endpoint_uri,
             ARRAY[
                    public.http_header('x-api-key', api_token),
                    public.http_header('anthropic-version', '2023-06-01')
                ],
            'application/json',
            json_build_object(
                'messages', message_payload,
                'system', system_messages,  
                'max_tokens', 8192, --TODO set this per model
                'tools', COALESCE(functions_in, '[]'::JSON),
                'model', model_name
            )::jsonb
		   )::http_request
        );

    -- Log the API response for debugging
    RAISE NOTICE 'API Response: %', api_response;

    -- Return the processed result in canonical form
    RETURN QUERY 
    SELECT * from p8.anthropic_to_open_ai_response(api_response);

END;
$$ LANGUAGE plpgsql;

--------------------------------------------------------
drop function if exists p8.request_google;
-- FUNCTION: p8.request_google(json, json, text, text, text)

-- DROP FUNCTION IF EXISTS p8.request_google(json, json, text, text, text);

CREATE OR REPLACE FUNCTION p8.request_google(
	message_payload json,
	functions_in json DEFAULT NULL::json,
	model_name text DEFAULT 'gemini-1.5-flash'::text,
	endpoint_uri text DEFAULT 'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent'::text,
	api_token text DEFAULT NULL::text)
    RETURNS TABLE(message_content text, tool_calls_out jsonb, tokens_in integer, tokens_out integer, finish_reason text, api_error text) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    api_response JSONB;
    system_messages TEXT;
    result_set JSONB;
    selected_model TEXT;
    selected_scheme TEXT;
BEGIN
    -- If api_token is NULL, retrieve values from the LanguageModelApi table
    IF api_token IS NULL THEN
        SELECT completions_uri, 
               COALESCE(token, api_token), 
               model, 
               scheme
        INTO endpoint_uri, api_token, selected_model, selected_scheme
        FROM p8."LanguageModelApi"
        WHERE scheme = 'google'
        LIMIT 1;
    END IF;

    -- Ensure model_name defaults to the selected model if not provided
    IF model_name IS NULL THEN
        model_name := selected_model;
    END IF;

    -- Extract and concatenate all system messages into system_messages variable
    SELECT string_agg(message->>'content', ' ') 
    INTO system_messages
    FROM jsonb_array_elements(message_payload::JSONB) AS msg(message)
    WHERE msg.message->>'role' = 'system';

    -- Filter out system messages from message_payload
    message_payload := (
        SELECT jsonb_agg(msg.message) 
        FROM jsonb_array_elements(message_payload::JSONB) AS msg(message)
        WHERE msg.message->>'role' != 'system'
    );

    -- Make the HTTP request and retrieve the response

	
    SELECT content
        INTO api_response
        FROM public.http(
		  (
            'POST',
            endpoint_uri || '?key=' || api_token,
            NULL,
            'application/json',
            json_build_object(
                'contents', message_payload,
                'system_instruction',  system_messages,  -- Add concatenated system text
                -- 'tool_config', json_build_object(
                --     'function_calling_config', json_build_object(
                --         'mode', 
                --         CASE 
                --             WHEN functions_in IS NOT NULL THEN 'ANY' 
                --             ELSE 'NONE' 
                --         END
                --     )
                -- ),
                'tools', functions_in,
                'model', model_name
            )::jsonb
		   )::http_request
        );

    -- Log the API response for debugging
    RAISE NOTICE 'API Response: %', api_response;

    -- Return the processed result in canonical form
    RETURN QUERY 
    SELECT * from p8.google_to_open_ai_response(api_response);

END;
$BODY$;

ALTER FUNCTION p8.request_google(json, json, text, text, text)
    OWNER TO postgres;


---------

-- FUNCTION: p8.resume_session(uuid, text)

-- DROP FUNCTION IF EXISTS p8.resume_session(uuid, text);

CREATE OR REPLACE FUNCTION p8.resume_session(
	session_id uuid,
	token_override text DEFAULT NULL::text)
    RETURNS TABLE(message_response text, tool_calls jsonb, tool_call_result jsonb, session_id_out uuid, status text) 
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
    functions text[];
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
        SELECT p8.get_agent_tool_names(recovered_agent, selected_scheme, TRUE) INTO functions;
        
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
        functions, 
        model_key, 
        token_override, 
        user_id
    );
END;
$BODY$;

ALTER FUNCTION p8.resume_session(uuid, text)
    OWNER TO postgres;


---------

-- FUNCTION: p8.ask(json, uuid, json, text, text, uuid)

DROP FUNCTION IF EXISTS p8.ask;

CREATE OR REPLACE FUNCTION p8.ask(
	message_payload json,
	session_id uuid DEFAULT NULL::uuid,
	functions_names TEXT[] DEFAULT NULL::TEXT[],
	model_name text DEFAULT 'gpt-4o-mini'::text,
	token_override text DEFAULT NULL::text,
	user_id uuid DEFAULT NULL::uuid)
    RETURNS TABLE(message_response text, tool_calls jsonb, tool_call_result jsonb, session_id_out uuid, status text) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    -- Declare variables
    endpoint_uri TEXT;
    api_token TEXT;
    selected_model TEXT;
    selected_scheme TEXT;
    api_response JSON;
    result_set TEXT;
    api_error TEXT;
    tool_calls JSONB;
    tool_call JSONB;
    tool_results JSONB := '[]'; --aggregates
    tool_result JSONB;
    tool_error TEXT;
    status_audit TEXT;
    finish_reason TEXT;
    tokens_in INTEGER;
    tokens_out INTEGER;
    response_id UUID;
	ack_http_timeout BOOLEAN;
    functions_in JSON;
BEGIN
	/*
	take in a message payload etc and call the correct request for each scheme
	each scheme maps to canonical which we store
	note, when calling these schemes again we read back messages in their format
	we also want to audit everything in this function

	select * from percolate_with_agent('list some pets that str sold', 'MyFirstAgent');
	*/

    -- Fetch endpoint and API token from LanguageModelApi
    SELECT completions_uri, coalesce(token, token_override), model, scheme
    INTO endpoint_uri, api_token, selected_model, selected_scheme
    FROM p8."LanguageModelApi"
    WHERE "name" = model_name 
    LIMIT 1;

    -- Ensure both the URI and token are available
    IF endpoint_uri IS NULL OR api_token IS NULL THEN
        RAISE EXCEPTION 'Missing API endpoint or token for model: %', selected_model;
    END IF;

    -- If session does not exist, create a new session UUID (using JSON uuid creation)
    IF session_id IS NULL THEN
        SELECT p8.json_to_uuid(json_build_object('date', current_date::text, 'user_id', coalesce(user_id,''))::JSONB)
        INTO session_id;
    END IF;

    -- Generate a new response UUID using session_id and content ID
    SELECT p8.json_to_uuid(json_build_object('sid', session_id, 'ts',CURRENT_TIMESTAMP::TEXT)::JSONB)
    INTO response_id;

    --get the functions requested for the agent and including merging in from the session
    functions_in = p8.get_session_functions(session_id, functions_names, selected_scheme);

    RAISE NOTICE 'scheme %: we have functions % ', selected_scheme, functions_names;
    -- Make the API request based on scheme
    --we return RETURNS TABLE(message_response text, tool_calls jsonb, tool_call_result jsonb, session_id_out uuid, status TEXT)
    --RETURNS TABLE(content TEXT,tool_calls_out JSON,tokens_in INTEGER,tokens_out INTEGER,finish_reason TEXT,api_error JSONB) AS

    --TODO we will read this from a setting in future
    select http_set_curlopt('CURLOPT_TIMEOUT','5000') into ack_http_timeout;
    RAISE NOTICE 'THE HTTP TIMEOUT IS HARDCODED TO 5000ms';
   
    IF selected_scheme = 'google' THEN
        SELECT * FROM p8.request_google(message_payload,  functions_in, selected_model, endpoint_uri, api_token)
        INTO result_set, tool_calls, tokens_in, tokens_out, finish_reason, api_error;
    ELSIF selected_scheme = 'anthropic' THEN
        SELECT * FROM p8.request_anthropic(message_payload, functions_in, selected_model, endpoint_uri, api_token)
        INTO result_set, tool_calls, tokens_in, tokens_out, finish_reason, api_error;
    ELSE
        -- Default case for other schemes
        SELECT * FROM p8.request_openai(message_payload, functions_in, selected_model, endpoint_uri, api_token)
        INTO result_set, tool_calls, tokens_in, tokens_out, finish_reason, api_error;
    END IF;


    --TODO: i think i need to check how the response is cast from json
    -- Handle finish reason and status
    status_audit := 'TOOL_CALL_RESPONSE';
    IF finish_reason ilike '%stop%' or finish_reason ilike '%end_turn%' THEN 
        status_audit := 'COMPLETED';
    END IF;


    
	--RAISE NOTICE 'LLM Gave finish reason and tool calls %, % - we set status %', finish_reason, tool_calls, status_audit;
	
    -- Iterate through each tool call
    FOR tool_call IN SELECT * FROM JSONB_ARRAY_ELEMENTS(tool_calls)
    LOOP
        BEGIN
            RAISE NOTICE 'calling %', tool_call;
            -- Attempt to call the function - the response id is added for context
            tool_result := json_build_object('id', tool_call->>'id', 'data', p8.eval_function_call(tool_call,response_id)); -- This will be saved in tool_eval_data
            tool_error := NULL; -- No error
            -- Aggregate tool_result into tool_results array
            tool_results := tool_results || tool_result;
        EXCEPTION WHEN OTHERS THEN
            -- Capture the error if the function call fails
            tool_result := NULL;
            tool_error := SQLSTATE || ': ' || SQLERRM;
            RAISE NOTICE 'tool_error %', tool_error;
        END;

        -- Set status based on tool result or error
        IF tool_error IS NOT NULL THEN
            status_audit := 'TOOL_ERROR';
            result_set := tool_error;
        ELSE
            -- Set status to ERROR if tool_eval failed
        END IF;
    END LOOP;

--	RAISE notice 'generated response id % from % and %', response_id,session_id,api_response->>'id';

    IF api_error IS NOT NULL THEN
        result_set := api_error;
        status_audit := 'ERROR';
    END IF;

    -- Insert into p8.AIResponse table
    INSERT INTO p8."AIResponse" 
        (id, model_name, content, tokens_in, tokens_out, session_id, role, status, tool_calls, tool_eval_data,function_stack)
    VALUES 
        (response_id, selected_model, COALESCE(result_set, ''), COALESCE(tokens_in, 0), COALESCE(tokens_out, 0), 
        session_id, 'assistant', status_audit, tool_calls, tool_results,functions_names)
    ON CONFLICT (id) DO UPDATE SET
        model_name    = EXCLUDED.model_name, 
        content       = EXCLUDED.content,
        tokens_in     = EXCLUDED.tokens_in,
        tokens_out    = EXCLUDED.tokens_out,
        session_id    = EXCLUDED.session_id,
        role          = EXCLUDED.role,
        status        = EXCLUDED.status,
        tool_calls    = EXCLUDED.tool_calls,
        tool_eval_data = EXCLUDED.tool_eval_data,
		 function_stack = ARRAY(SELECT DISTINCT unnest(p8."AIResponse".function_stack || EXCLUDED.function_stack));


    -- Return results
    RETURN QUERY
    SELECT result_set::TEXT, tool_calls::JSONB, tool_results::JSONB, session_id, status_audit;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'ASK API call failed: % % response id %', SQLERRM, result_set, api_response->'id';
END;
$BODY$;
 

---------

CREATE OR REPLACE FUNCTION p8.ask_with_prompt_and_tools(
	question text,
	tool_names_in text[] DEFAULT NULL::text[],
	system_prompt text DEFAULT 'Respond to the users query using tools and functions as required'::text,
	model_key character varying DEFAULT 'gpt-4o-mini'::character varying,
	token_override text DEFAULT NULL::text,
	temperature double precision DEFAULT 0.01)
    RETURNS TABLE(message_response text, tool_calls jsonb, tool_call_result jsonb) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    api_response JSON; -- Variable to store the API response
    endpoint_uri TEXT; -- URL of the API endpoint
    api_token TEXT; -- API token for authorization
    selected_model TEXT; -- Match model from key - sometimes they are the same
    selected_scheme TEXT; -- Scheme (e.g., openai, google, anthropic)
    tool_calls JSONB; -- Extracted tool calls
    processed_tool_calls JSONB := '[]'::JSONB; -- Initialize as an empty JSON array
    tool_call JSONB; -- Individual tool call
    tool_result JSONB;
    tool_error TEXT;
	result_set TEXT DEFAULT NULL;
BEGIN
	/*
    imports
	p8.get_tools_by_description
	p8.get_tools_by_name
	p8.google_to_open_ai_response
	p8.anthropic_to_open_ai_response
	p8.eval_function_call
	*/
    -- Fetch the model-specific API endpoint, token, and scheme
    SELECT completions_uri, coalesce(token,token_override), model, scheme
    INTO endpoint_uri, api_token, selected_model, selected_scheme
    FROM p8."LanguageModelApi"
    WHERE "name" = model_key
    LIMIT 1;

    -- Ensure both the URI and token are available
    IF endpoint_uri IS NULL OR api_token IS NULL THEN
        RAISE EXCEPTION 'Missing API endpoint or token for model: %', selected_model;
    END IF;

    -- Try searching for tools if not specified
    IF tool_names_in IS NULL OR array_length(tool_names_in, 1) = 0 THEN
        -- Auto-determine tools from the question
        SELECT ARRAY_AGG(name)
        INTO tool_names_in
        FROM p8.get_tools_by_description(question, 5); -- Adjust the limit as needed
    END IF;

    -- Prepare the tools and payload based on the scheme
    IF selected_scheme = 'openai' THEN
        -- OpenAI-specific payload
        SELECT content
        INTO api_response
        FROM public.http(
            (
                'POST',
                endpoint_uri,
                ARRAY[public.http_header('Authorization', 'Bearer ' || api_token)],
                'application/json',
                json_build_object(
                    'model', selected_model,
                    'messages', json_build_array(
                        json_build_object('role', 'system', 'content', system_prompt),
                        json_build_object('role', 'user', 'content', question)
                    ),
                    'tools', (SELECT p8.get_tools_by_name(tool_names_in, selected_scheme)), -- Fetch tools by names with scheme
                    'temperature', temperature
                )
            )::public.http_request
        );

		raise notice '%', api_response;
		 -- Extract tool calls from the response
	    tool_calls := (api_response->'choices'->0->'message'->>'tool_calls')::JSON;
		result_set := (api_response->'choices'->0->'message'->>'content')::TEXT;
		
    ELSIF selected_scheme = 'google' THEN
        -- Google-specific payload
        SELECT content
        INTO api_response
        FROM public.http(
            (
                'POST',
                endpoint_uri || '?key=' || api_token,
				NULL,
				 'application/json',
                json_build_object(
                    'contents', json_build_array(
                        json_build_object('role', 'user', 'parts', json_build_object('text', question))
                    ),
                    'tool_config', json_build_object(
                        'function_calling_config', json_build_object('mode', 'ANY')
                    ),
                    'tools', (SELECT p8.get_tools_by_name(tool_names_in, selected_scheme)) -- Fetch tools by names with scheme
                )
            )::public.http_request
        );

		 SELECT msg, tool_calls_out as tc
		    INTO result_set, tool_calls
		    FROM p8.google_to_open_ai_response(api_response::JSONB);

			raise notice '%', api_response;
    ELSIF selected_scheme = 'anthropic' THEN
        -- Anthropic-specific payload
		 
        SELECT content
        INTO api_response
        FROM public.http(
            (
                'POST',
                endpoint_uri,
                ARRAY[
                    public.http_header('x-api-key', api_token),
                    public.http_header('anthropic-version', '2023-06-01')
                ],
                'application/json',
                json_build_object(
                    'model', selected_model,
                    'max_tokens', 1024,
                    'messages', json_build_array(
                        json_build_object('role', 'user', 'content', question)
                    ),
                    'tools', (SELECT p8.get_tools_by_name(tool_names_in, selected_scheme)) -- Fetch tools by names with scheme
                )
            )::public.http_request
        );

		raise notice '%', api_response;

		---------
		 -- Extract content and tool use for the 'anthropic' scheme
		 SELECT msg, tool_calls_out as tc
		    INTO result_set, tool_calls
		    FROM p8.anthropic_to_open_ai_response(api_response::JSONB);

		----------

    ELSE
        RAISE EXCEPTION 'Unsupported scheme: %', selected_scheme;
    END IF;
 
	
    -- Iterate through each tool call
    FOR tool_call IN SELECT * FROM JSONB_ARRAY_ELEMENTS(tool_calls)
    LOOP
        BEGIN
            -- Attempt to call the function
            tool_result := p8.eval_function_call(tool_call);
            tool_error := NULL; -- No error
        EXCEPTION WHEN OTHERS THEN
            -- Capture the error if the function call fails
            tool_result := NULL;
            tool_error := SQLSTATE || ': ' || SQLERRM;
        END;

        -- Add the result or error to processed_tool_calls
        processed_tool_calls := processed_tool_calls || JSONB_BUILD_OBJECT(
            'tool_call', tool_call,
            'result', tool_result,
            'error', tool_error
        );
    END LOOP;

    -- Return the API response and processed tool calls
    RETURN QUERY
    SELECT coalesce(result_set,'')::TEXT,
           tool_calls,
           processed_tool_calls;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'API call failed: % %', SQLERRM, result_set;
END;
$BODY$;

ALTER FUNCTION p8.ask_with_prompt_and_tools(text, text[], text, character varying, text, double precision)
    OWNER TO postgres;


---------

/*we map all function call args to string for canonical*/

-- FUNCTION: p8.anthropic_to_open_ai_response(jsonb)

DROP FUNCTION IF EXISTS p8.anthropic_to_open_ai_response ;

CREATE OR REPLACE FUNCTION p8.anthropic_to_open_ai_response(
	api_response jsonb)
    RETURNS TABLE(msg text, tool_calls_out jsonb, tokens_in integer, tokens_out integer, finish_reason text, api_error text) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
BEGIN
    /*
    Example anthropic response message usage:
    select * from p8.anthropic_to_open_ai_response('{
  "id": "msg_015kdLpARvtbRqDSmJKiamSB",
  "type": "message",
  "role": "assistant",
  "model": "claude-3-5-sonnet-20241022",
  "content": [
    {"type": "text", "text": "Ill help you check the weather in Paris for tomorrow. Let me use the get_weather function with tomorrows date."},
    {"type": "tool_use", "id": "toolu_01GV5rqVypHCQ6Yhrfsz8qhQ", "name": "get_weather", "input": {"city": "Paris", "date": "2024-01-16"}}
  ],
  "stop_reason": "tool_use",
  "stop_sequence": null,
  "usage": {
    "input_tokens": 431,
    "cache_creation_input_tokens": 0,
    "cache_read_input_tokens": 0,
    "output_tokens": 101
  }
}'::JSONB)
    */

	 IF api_response ? 'error' THEN
        RETURN QUERY 
        SELECT api_response->>'error', NULL::JSONB, NULL::INTEGER, NULL::INTEGER, NULL, api_response->>'error';
        RETURN;
    END IF;
	
    RETURN QUERY
    WITH r AS (
        SELECT jsonb_array_elements(api_response->'content') AS el
    ),
    msg AS (
        SELECT el->>'text' AS msg
        FROM r
        WHERE el->>'type' = 'text'
    ),
    tool_calls AS (
        SELECT json_build_array(
                    json_build_object(
                        'id', el->>'id',
                        'type', 'function',
                        'function', json_build_object(
                            'name', el->>'name',
                            'arguments', (el->>'input')::TEXT
                        )
                    )
                ) AS tool_calls
        FROM r
        WHERE el->>'type' = 'tool_use'
    ),
    tokens AS (
        SELECT 
            (api_response->'usage'->>'input_tokens')::INTEGER AS tokens_in,
            (api_response->'usage'->>'output_tokens')::INTEGER AS tokens_out
    ),
    finish AS (
        SELECT 
            api_response->>'stop_reason' AS finish_reason
    ),
    error AS (
        SELECT api_response->>'error' AS api_error
    )
    SELECT
        msg.msg::TEXT, --in case null
        tool_calls.tool_calls::JSONB,
        tokens.tokens_in,
        tokens.tokens_out,
        lower(finish.finish_reason),
        error.api_error
    FROM msg
    FULL OUTER JOIN tool_calls ON TRUE
    CROSS JOIN tokens
    CROSS JOIN finish
    CROSS JOIN error;
END;
$BODY$;

ALTER FUNCTION p8.anthropic_to_open_ai_response(jsonb)
    OWNER TO postgres;
-----

-- FUNCTION: p8.google_to_open_ai_response(jsonb)

-- DROP FUNCTION IF EXISTS p8.google_to_open_ai_response(jsonb);

CREATE OR REPLACE FUNCTION p8.google_to_open_ai_response(
	api_response jsonb)
    RETURNS TABLE(msg text, tool_calls_out jsonb, tokens_in integer, tokens_out integer, finish_reason text, api_error TEXT) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    function_call jsonb; -- Variable to hold the function call JSON
BEGIN
    /*
    Example Google response message usage:
    select * from p8.google_to_open_ai_response('{
        "candidates": [
            {
                "content": {
                    "parts": [
                        {
                            "functionCall": {
                                "name": "get_weather",
                                "args": {"date": "2024-07-27", "city": "Paris"}
                            }
                        }
                    ],
                    "role": "model"
                },
                "finishReason": "STOP",
                "avgLogprobs": -0.004642472602427006
            }
        ],
        "usageMetadata": {
            "promptTokenCount": 83,
            "candidatesTokenCount": 16,
            "totalTokenCount": 99
        },
        "modelVersion": "gemini-1.5-flash"
    }'::JSONB)
    */

    -- Capture the function call from the JSON
    function_call := api_response->'candidates'->0->'content'->'parts'->0->'functionCall';

    -- Extract token usage and finish reason
    tokens_in := (api_response->'usageMetadata'->>'promptTokenCount')::INTEGER;
    tokens_out := (api_response->'usageMetadata'->>'candidatesTokenCount')::INTEGER;
    finish_reason := lower((api_response->'candidates'->0->>'finishReason')::TEXT);

    -- Capture any API errors
    api_error := api_response->>'error';

    -- Return the message and mapped tool calls
    RETURN QUERY
    SELECT
        (api_response->'candidates'->0->'content'->'parts'->0->>'text')::TEXT AS msg,
        CASE
            WHEN function_call IS NOT NULL THEN
                json_build_array(
                    json_build_object(
                        'id', function_call->>'name', -- Use the name as the ID
                        'type', 'function',
                        'function', json_build_object(
                            'name', function_call->>'name',
                            'arguments', (function_call->'args')::TEXT
                        )
                    )
                )::JSONB
            ELSE NULL
        END AS tool_calls_out,
        tokens_in,
        tokens_out,
        finish_reason,
        api_error;
END;
$BODY$;

ALTER FUNCTION p8.google_to_open_ai_response(jsonb)
    OWNER TO postgres;


---------

CREATE OR REPLACE FUNCTION p8.get_canonical_messages(
    session_id_in UUID,  
    question TEXT DEFAULT NULL,  
    override_system_prompt TEXT DEFAULT NULL  
) 
RETURNS TABLE(messages JSON, last_role TEXT, last_updated_at TIMESTAMP WITHOUT TIME ZONE) 
LANGUAGE plpgsql
COST 100
VOLATILE 
PARALLEL UNSAFE
ROWS 1000 
AS $BODY$
DECLARE
    recovered_session_id TEXT;
    user_id TEXT;
    recovered_agent TEXT;
    recovered_question TEXT;
    generated_system_prompt TEXT;
BEGIN

    -- 1. Get session details from p8."Session"
    SELECT s.id, s.userid, s.agent, s.query 
    INTO recovered_session_id, user_id, recovered_agent, recovered_question
    FROM p8."Session" s
    WHERE s.id = session_id_in;

    -- Check if session exists
    IF recovered_session_id IS NULL THEN
        RETURN QUERY 
        SELECT NULL::JSON, NULL::TEXT, NULL::TIMESTAMP;
        RETURN;
    END IF;

    -- 2. Generate system prompt based on the recovered agent
    SELECT p8.generate_markdown_prompt(recovered_agent) 
    INTO generated_system_prompt;

    -- If no generated system prompt, fall back to using the agent directly
    IF generated_system_prompt IS NULL THEN
        generated_system_prompt := recovered_agent;
    END IF;

    -- 3. Construct the response messages
    RETURN QUERY
    WITH session_data AS (
        -- Fetch session data for the specified session_id
        SELECT content, role, tool_calls, tool_eval_data, created_at
        FROM p8."AIResponse" a
        WHERE a.session_id = session_id_in
    ),
    max_session_data AS (
        -- Get the last role and most recent timestamp
        SELECT role AS last_role, created_at AS last_updated_at
        FROM session_data
        ORDER BY created_at DESC
        LIMIT 1
    ),
    extracted_messages AS (
        -- Extract all messages in a structured way while keeping order
        SELECT NULL::TIMESTAMP as created_at, 'system' AS role, 
               COALESCE(override_system_prompt, generated_system_prompt) AS content, 
               NULL::TEXT AS tool_call_id,
			   NULL::JSON as tool_calls,
			   0 as rank
        UNION ALL
        SELECT NULL::TIMESTAMP as created_at, 'user' AS role, 
               COALESCE(question, recovered_question) AS content, 
               NULL::TEXT AS tool_call_id,
			    NULL::JSON as tool_calls,
			   1 as rank
        UNION ALL
        SELECT created_at, 'assistant' AS role, 
               'Calling ' || (el->>'function')::TEXT AS content,
               el->>'id' AS tool_call_id,
			   tool_calls,
			   2 as rank
        FROM session_data, 
             LATERAL jsonb_array_elements(tool_calls::JSONB) el
        WHERE tool_calls IS NOT NULL
         UNION ALL
        -- Extract tool responses
        SELECT created_at, 'tool' AS role,
               'Responded ' || (el->>'data')::TEXT AS content,
               el->>'id' AS tool_call_id,
			   NULL::JSON as tool_calls,
			   2 as rank
        FROM session_data, 
             LATERAL jsonb_array_elements(tool_eval_data::JSONB) el
        WHERE tool_eval_data IS NOT NULL
    ),
    ordered_messages AS (
        -- Order all extracted messages by created_at
        SELECT role, content, tool_calls, tool_call_id
        FROM extracted_messages
        ORDER BY rank, created_at ASC
    ),
    jsonrow AS (
        -- Convert ordered messages into JSON
        SELECT json_agg(row_to_json(ordered_messages)) AS messages
        FROM ordered_messages
    )
    -- Return JSON messages with metadata
    SELECT * 
    FROM jsonrow 
    LEFT JOIN max_session_data ON true;

END;
$BODY$;


---------

-- FUNCTION: p8.nl2sql(text, character varying, character varying, character varying, double precision)

-- DROP FUNCTION IF EXISTS p8.nl2sql(text, character varying, character varying, character varying, double precision);

CREATE OR REPLACE FUNCTION p8.nl2sql(
	question text,
	agent_name character varying,
	model_in character varying DEFAULT 'gpt-4o-2024-08-06'::character varying,
	api_token character varying DEFAULT NULL::character varying,
	temperature double precision DEFAULT 0.01)
    RETURNS TABLE(response jsonb, query text, confidence numeric) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    table_schema_prompt TEXT;
    api_response JSON;
BEGIN
	/*
	imports
	p8.generate_markdown_prompt
	*/

    --default public schema
	SELECT 
        CASE 
            WHEN agent_name NOT LIKE '%.%' THEN 'public.' || agent_name 
            ELSE agent_name 
        END 
    INTO agent_name;

    -- Generate the schema prompt for the table
    SELECT generate_markdown_prompt INTO table_schema_prompt FROM p8.generate_markdown_prompt(agent_name);

	IF table_schema_prompt IS NULL THEN
        --RAISE EXCEPTION 'Agent with name "%" not found.', agent_name;
        --we default to this for robustness TODO: think about how this could cause confusion
        table_schema_prompt:= 'p8.PercolateAgent';
    END IF;
	
    IF api_token IS NULL THEN    
        SELECT token into api_token
            FROM p8."LanguageModelApi"
            WHERE "name" = model_in
            LIMIT 1;
    END IF;

    -- API call to OpenAI with the necessary headers and payload
    WITH T AS(
        SELECT 'system' AS "role", 
		   'you will generate a PostgreSQL query for the provided table metadata that can '
		|| ' query that table (but replace table with YOUR_TABLE) to answer the users question and respond in json format'
		|| 'responding with the query and confidence - escape characters so that the json can be loaded in postgres.' 
		AS "content" 
        UNION
        SELECT 'system' AS "role", table_schema_prompt AS "content" 
        UNION
        SELECT 'user' AS "role", question AS "content"
    )
    SELECT content FROM http(
        ('POST', 
         'https://api.openai.com/v1/chat/completions', 
         ARRAY[http_header('Authorization', 'Bearer ' || api_token)],
         'application/json',
         json_build_object(
             'model', model_in,
             'response_format', json_build_object('type', 'json_object'),
             'messages', (SELECT JSON_AGG(t) FROM T AS t),
             'temperature', temperature
         )
        )::http_request
    ) INTO api_response;

	RAISE NOTICE 'Table Schema Prompt: %', api_response;

    -- Parse the response content into JSON and extract query and confidence values
    RETURN QUERY
    SELECT 
        -- Parse the JSON response string to JSONB and extract the content
        (api_response->'choices'->0->'message'->>'content')::JSONB AS response,  -- Content as JSONB
        ((api_response->'choices'->0->'message'->>'content')::JSONB->>'query')::TEXT AS query,  -- Extract query
        ((api_response->'choices'->0->'message'->>'content')::JSONB->>'confidence')::NUMERIC AS confidence;  -- Extract confidence

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'API call failed: %', SQLERRM;
END;
$BODY$;

ALTER FUNCTION p8.nl2sql(text, character varying, character varying, character varying, double precision)
    OWNER TO postgres;


---------

-- FUNCTION: p8.insert_entity_embeddings(text, text)

-- DROP FUNCTION IF EXISTS p8.insert_entity_embeddings(text, text);

CREATE OR REPLACE FUNCTION p8.insert_entity_embeddings(
	param_entity_name text,
	param_token text DEFAULT NULL::text)
    RETURNS TABLE(field_id uuid, entity_name_out text, records_affected integer) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    field_record RECORD;
    rows_affected INTEGER;
    total_records INTEGER;
BEGIN

	/*
	import 
	p8.insert_generated_embeddings
	*/

    --we just need a token so any OpenAI model or whatever the embedding is
    IF param_token IS NULL THEN
        SELECT token into param_token
            FROM p8."LanguageModelApi"
            WHERE "name" = 'gpt-4o-mini'
            LIMIT 1;
    END IF;
 
    -- Loop through the fields in the table for the specified entity
    FOR field_record IN 
        SELECT id, name, field_type, embedding_provider
        FROM p8."ModelField"
        WHERE entity_name = param_entity_name
		 and embedding_provider is not null
    LOOP
        -- Initialize the total records affected for this field
        total_records := 0;

        -- Continue calling the insert_generated_embeddings function until no records are affected
        LOOP
            rows_affected := p8.insert_generated_embeddings(
                param_entity_name, 
                field_record.name, 
                field_record.embedding_provider, 
                param_token
            );

            -- Add to the total records count
            total_records := total_records + rows_affected;

            -- Exit the loop if no rows were affected
            IF rows_affected = 0 THEN
                EXIT;
            END IF;
        END LOOP;

        -- Return the metadata for this field
        RETURN QUERY SELECT 
            field_record.id,
			param_entity_name,
            total_records;
    END LOOP;
END;
$BODY$;

ALTER FUNCTION p8.insert_entity_embeddings(text, text)
    OWNER TO postgres;


---------

-- FUNCTION: p8.generate_and_fetch_embeddings(text, text, text, text, integer)

-- DROP FUNCTION IF EXISTS p8.generate_and_fetch_embeddings(text, text, text, text, integer);

CREATE OR REPLACE FUNCTION p8.generate_and_fetch_embeddings(
	param_table text,
	param_column text,
	param_embedding_model text DEFAULT 'default'::text,
	param_token text DEFAULT NULL::text,
	param_limit_fetch integer DEFAULT 1000)
    RETURNS TABLE(id uuid, source_id uuid, embedding_id text, column_name text, embedding vector) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    resolved_model text;
BEGIN
	/*
	imports
	p8.generate_requests_for_embeddings

	example

	select * from p8.generate_and_fetch_embeddings('p8.AgentModel', 'description')
	*/

    -- Set the model to 'text-embedding-ada-002' if it's 'default'
    resolved_model := CASE 
        WHEN param_embedding_model = 'default' THEN 'text-embedding-ada-002'
        ELSE param_embedding_model 
    END;

    -- If the token is not set, fetch it
    IF param_token IS NULL THEN
        SELECT token
        INTO param_token 
        FROM p8."LanguageModelApi"
        WHERE "name" = 'gpt-4o-mini';
    END IF;

    -- Execute the main query
    RETURN QUERY EXECUTE format(
        $sql$
		--first request anything that needs embeddings
		WITH request AS (
			SELECT *  FROM p8.generate_requests_for_embeddings(%L,%L,%L) LIMIT %L
		),
		payload AS (
			--the payload is an array of cells with a description ->JSONB
			SELECT jsonb_agg(description) AS aggregated_data
			--SELECT jsonb_build_array(description) AS aggregated_data
			FROM request
		),
		--we then pass these to some openai model for now - could be a more generalized model for embeddings
        embedding_result AS (
            SELECT 
                embedding,
                ROW_NUMBER() OVER () AS idx
            FROM p8.fetch_openai_embeddings(
				(SELECT aggregated_data FROM payload),
                %L,            
                %L
            )
        )
		--by joining the ids we match the original table index to the result from open ai 
		-- we are assuming all descriptinos have some text or fails
        SELECT 
            request.bid AS id,
            request.source_id,
            request.embedding_id,
            request.column_name,
            embedding_result.embedding
        FROM embedding_result
        JOIN request ON request.idx = embedding_result.idx
        $sql$,
        param_table,
        param_column,
        resolved_model,
        param_limit_fetch,
        param_token,
        resolved_model
    );
END;
$BODY$;

ALTER FUNCTION p8.generate_and_fetch_embeddings(text, text, text, text, integer)
    OWNER TO postgres;


---------

CREATE OR REPLACE FUNCTION p8.add_nodes(
	table_name text)
    RETURNS integer
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    cypher_query TEXT;
    row RECORD;
    sql TEXT;
    schema_name TEXT;
    pure_table_name TEXT;
    nodes_created_count INTEGER := 0; -- Tracks the number of nodes created
BEGIN

    LOAD  'age'; SET search_path = ag_catalog, "$user", public; 

    -- Initialize the Cypher query
    cypher_query := 'CREATE ';
    schema_name := lower(split_part(table_name, '.', 1));
    pure_table_name := split_part(table_name, '.', 2);

    -- Loop through each row in the table - graph assumed to be 'one' here
    FOR row IN
        EXECUTE format('SELECT uid, key FROM p8."vw_%s_%s" WHERE gid IS NULL LIMIT 1660', 
            schema_name, pure_table_name
        )
    LOOP
        -- Append Cypher node creation for each row
        cypher_query := cypher_query || format(
            '(:%s__%s {uid: "%s", key: "%s"}), ',
            schema_name, pure_table_name, row.uid, row.key
        );

        -- Increment the counter for each node
        nodes_created_count := nodes_created_count + 1;
    END LOOP;

    IF nodes_created_count > 0 THEN
        -- Remove the trailing comma and space
        cypher_query := left(cypher_query, length(cypher_query) - 2);

        -- Debug: Optionally print the Cypher query for audit
        -- RAISE NOTICE 'Generated Cypher Query: %s', cypher_query;

        -- Execute the Cypher query using the cypher function
        sql := format(
            'SELECT * FROM cypher(''percolate'', $$ %s $$) AS (v agtype);',
            cypher_query
        );

        -- Execute the query
        EXECUTE sql;

        -- Return the number of rows processed
        RETURN nodes_created_count;
    ELSE
        -- No rows to process
        RAISE NOTICE 'Nothing to do';
        RETURN 0;
    END IF;
END;
$BODY$;


 

CREATE OR REPLACE FUNCTION p8.insert_entity_nodes(
	entity_table text)
    RETURNS TABLE(entity_name text, total_records_affected integer) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    records_affected INTEGER := 0;
    total_records_affected INTEGER := 0;
BEGIN
	/*imports p8.add_nodes*/
    -- Loop until no more records are affected
    LOOP
        -- Call p8_add_nodes and get the number of records affected
        SELECT add_nodes INTO records_affected FROM p8.add_nodes(entity_table);

        -- If no records are affected, exit the loop
        IF records_affected = 0 THEN
            EXIT;
        END IF;

        -- Add the current records affected to the total
        total_records_affected := total_records_affected + records_affected;
    END LOOP;

    -- Return the entity name and total records affected
    RETURN QUERY SELECT entity_table AS entity_name, total_records_affected;
END;
$BODY$;

---------

-- FUNCTION: p8.insert_generated_embeddings(text, text, text, text)

-- DROP FUNCTION IF EXISTS p8.insert_generated_embeddings(text, text, text, text);

CREATE OR REPLACE FUNCTION p8.insert_generated_embeddings(
    param_table text,
    param_column text,
    param_embedding_model text DEFAULT 'default',
    param_token text DEFAULT NULL)
    RETURNS integer
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    schema_name TEXT;
    table_name TEXT;
    sanitized_table TEXT;
    affected_rows INTEGER;
    table_exists BOOLEAN DEFAULT TRUE;
    resolved_model TEXT;
    resolved_token TEXT;
BEGIN
/*
imports p8.generate_and_fetch_embeddings
example
select * from p8.insert_generated_embeddings('p8.Agent', 'description')
returns non 0 if it needed to insert somethign
caller e.g. p8.insert_entity_embeddings('p8.Agent') can flush all required embeddings
*/
    -- Resolve the model name, defaulting to 'text-embedding-ada-002' if 'default' is provided
    resolved_model := CASE 
        WHEN param_embedding_model = 'default' THEN 'text-embedding-ada-002'
        ELSE param_embedding_model
    END;

    -- Resolve the token, fetching it if NULL
    IF param_token IS NULL THEN
        SELECT token
        INTO resolved_token
        FROM p8."LanguageModelApi"
        WHERE "name" = 'gpt-4o-mini';
    ELSE
        resolved_token := param_token;
    END IF;

    -- Sanitize the table name
    sanitized_table := REPLACE(param_table, '.', '_');

    -- Check if the target embedding table exists
    SELECT EXISTS (
        SELECT *
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'p8_embeddings' AND c.relname = sanitized_table || '_embeddings'
    )
    INTO table_exists;

    -- Construct and execute the insertion if the table exists
    IF table_exists THEN
        EXECUTE format(
            $sql$
            INSERT INTO p8_embeddings."%s_embeddings" (id, source_record_id, embedding_name, column_name, embedding_vector)
            SELECT * 
            FROM p8.generate_and_fetch_embeddings(
                %L,
                %L,
                %L,
                %L
            )
            $sql$,
            sanitized_table,    -- Target embedding table
            param_table,        -- Passed to the function
            param_column,       -- Column to embed
            resolved_model,     -- Resolved embedding model
            resolved_token      -- Resolved API token
        );

        -- Get the number of affected rows
        GET DIAGNOSTICS affected_rows = ROW_COUNT;
        RETURN affected_rows;
    END IF;

    RETURN 0;
END;
$BODY$;

ALTER FUNCTION p8.insert_generated_embeddings(text, text, text, text)
    OWNER TO postgres;


---------

CREATE OR REPLACE FUNCTION p8.get_embedding_for_text(
	description_text text,
	embedding_model text DEFAULT 'text-embedding-ada-002'::text)
    RETURNS TABLE(embedding vector) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    api_token TEXT;
    embedding_response JSONB;
BEGIN
    -- Step 1: Retrieve the API token for now im hard coding to open ai token 
    SELECT "token"
    INTO api_token
    FROM p8."LanguageModelApi"
    WHERE "name" = 'gpt-4o-mini'; --embedding_model hint - any model that uses the same key;

    IF api_token IS NULL THEN
        RAISE EXCEPTION 'Token not found for the provided model or open ai default: %', api_token;
    END IF;

    -- Step 2: Make the HTTP request to OpenAI API
    SELECT content::JSONB
    INTO embedding_response
    FROM public.http(
        (
            'POST',
            'https://api.openai.com/v1/embeddings',
            ARRAY[
                public.http_header('Authorization', 'Bearer ' || api_token)
                --,http_header('Content-Type', 'application/json')
            ],
            'application/json',
            jsonb_build_object(
                'input', ARRAY[description_text],  -- Single description in this case
                'model', embedding_model,
                'encoding_format', 'float'
            )
        )::public.http_request
    );

    -- Step 3: Extract the embedding and convert it to a PG vector
    RETURN QUERY
    SELECT
        VECTOR((embedding_response->'data'->0->'embedding')::text) AS embedding;

END;
$BODY$;

---------

-- FUNCTION: p8.generate_requests_for_embeddings(text, text, text)

-- DROP FUNCTION IF EXISTS p8.generate_requests_for_embeddings(text, text, text);

CREATE OR REPLACE FUNCTION p8.generate_requests_for_embeddings(
	param_table text,
	param_description_col text,
	param_embedding_model text)
    RETURNS TABLE(eid uuid, source_id uuid, description text, bid uuid, column_name text, embedding_id text, idx bigint) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    sanitized_table TEXT;
    PSCHEMA TEXT;
    PTABLE TEXT;
BEGIN
/*
if there are records in the table for this embedding e.g. the table like p8.Agents has unfilled records 
select * from p8.
*/
    -- Sanitize the table name
    sanitized_table := REPLACE(PARAM_TABLE, '.', '_');
    PSCHEMA := split_part(PARAM_TABLE, '.', 1);
    PTABLE := split_part(PARAM_TABLE, '.', 2);

    -- Return query dynamically constructs the required output
    RETURN QUERY EXECUTE format(
        $sql$
        SELECT 
            b.id AS eid, 
            a.id AS source_id, 
            COALESCE(a.%I, '')::TEXT AS description, -- Dynamically replace the description column
            p8.json_to_uuid(json_build_object(
                'embedding_id', %L,
                'column_name', %L,
                'source_record_id', a.id
            )::jsonb) AS id,
            %L AS column_name,
            %L AS embedding_id,
            ROW_NUMBER() OVER () AS idx
        FROM %I.%I a
        LEFT JOIN p8_embeddings."%s_embeddings" b 
            ON b.source_record_id = a.id 
            AND b.column_name = %L
        WHERE b.id IS NULL
 
        $sql$,
        PARAM_DESCRIPTION_COL,         -- %I for the description column
        PARAM_EMBEDDING_MODEL,         -- %L for the embedding model
        PARAM_DESCRIPTION_COL,         -- %L for the column name
        PARAM_DESCRIPTION_COL,         -- %L for the column name again
        PARAM_EMBEDDING_MODEL,         -- %L for the embedding model
        PSCHEMA,                       -- %I for schema name
        PTABLE,                        -- %I for table name
        sanitized_table,               -- %I for sanitized embedding table
        PARAM_DESCRIPTION_COL          -- %L for the column name in the join condition
    );
END;
$BODY$;

ALTER FUNCTION p8.generate_requests_for_embeddings(text, text, text)
    OWNER TO postgres;


---------

CREATE OR REPLACE FUNCTION p8.fetch_openai_embeddings(
    param_array_data jsonb,
	param_token text DEFAULT NULL,
    param_model text DEFAULT 'default')
    RETURNS TABLE(embedding vector) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    resolved_model text;
    resolved_token text;
BEGIN
    -- Set the model to 'text-embedding-ada-002' if it's 'default'
    resolved_model := CASE 
        WHEN param_model = 'default' THEN 'text-embedding-ada-002'
        ELSE param_model
    END;

    -- If the token is not set, fetch it - we dont have to use the model below to select just any model that uses the same key
    IF param_token IS NULL THEN
        SELECT token
        INTO resolved_token
        FROM p8."LanguageModelApi"
        WHERE "name" = 'gpt-4o-mini';
    ELSE
        resolved_token := param_token;
    END IF;

    -- Execute HTTP request to fetch embeddings and return the parsed embeddings as pgvector
    RETURN QUERY
    SELECT VECTOR((item->'embedding')::TEXT) AS embedding
    FROM (
        SELECT jsonb_array_elements(content::JSONB->'data') AS item
        FROM http((
            'POST', 
            'https://api.openai.com/v1/embeddings', 
            ARRAY[http_header('Authorization', 'Bearer ' || resolved_token)],
            'application/json',
            jsonb_build_object(
                'input', param_array_data,
                'model', resolved_model,
                'encoding_format', 'float'
            )
        )::http_request)
    ) subquery;
END;
$BODY$;

---------


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



---------

DROP FUNCTION IF EXISTS p8.get_records_by_keys;
CREATE OR REPLACE FUNCTION p8.get_records_by_keys(
    table_name TEXT,
    key_list TEXT[],
    key_column TEXT DEFAULT 'id'::TEXT,
    include_entity_metadata BOOLEAN DEFAULT TRUE
)
RETURNS JSONB
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    result JSONB;            -- The JSON result to be returned
    metadata JSONB;          -- The metadata JSON result
    query TEXT;              -- Dynamic query to execute
    schema_name VARCHAR;
    pure_table_name VARCHAR;
BEGIN
    schema_name := lower(split_part(table_name, '.', 1));
    pure_table_name := split_part(table_name, '.', 2);

    -- Construct the dynamic query to select records from the specified table
    query := format('SELECT jsonb_agg(to_jsonb(t)) FROM %I."%s" t WHERE t.%I::TEXT = ANY($1)', schema_name, pure_table_name, key_column);

    -- Execute the dynamic query with the provided key_list as parameter
    EXECUTE query USING key_list INTO result;
    
    -- Fetch metadata if include_entity_metadata is TRUE
    IF include_entity_metadata THEN
        SELECT jsonb_build_object('description', a.description, 'functions', a.functions)
        INTO metadata
        FROM p8."Agent" a
        WHERE a.name = table_name;
    ELSE
        metadata := NULL;
    END IF;
    
    -- Return JSONB object containing both data and metadata
    RETURN jsonb_build_object('data', result,
								'metadata', metadata, 
								'instruction', 'you can request to activate new functions by name to use them as tools');
END;
$BODY$;


---------

-- FUNCTION: p8.register_entities(text, boolean, text)

-- DROP FUNCTION IF EXISTS p8.register_entities(text, boolean, text);

CREATE OR REPLACE FUNCTION p8.register_entities(
	qualified_table_name text,
	plan boolean DEFAULT false,
	graph_name text DEFAULT 'percolate'::text)
    RETURNS TABLE(load_and_cypher_script text, view_script text) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    schema_name TEXT;
    table_name TEXT;
    graph_node TEXT;
    view_name TEXT;
BEGIN
    -- Split schema and table name
    schema_name := split_part(qualified_table_name, '.', 1);
    table_name := split_part(qualified_table_name, '.', 2);
    graph_node := format('%s__%s', schema_name, table_name);
    view_name := format('vw_%s_%s', schema_name, table_name);

    -- Create the LOAD and Cypher script
    load_and_cypher_script := format(
        $CY$
        LOAD 'age';
        SET search_path = ag_catalog, "$user", public;
        SELECT * 
        FROM cypher('%s', $$
            CREATE (:%s{key:'ref', uid: 'ref'})
        $$) as (v agtype);
        $CY$,
        graph_name, graph_node
    );

    -- Create the VIEW script
    view_script := format(
        $$
        CREATE OR REPLACE VIEW p8."%s" AS (

            WITH G AS (
                SELECT id AS gid,
                       (properties::json->>'uid')::VARCHAR AS node_uid,
                       (properties::json->>'key')::VARCHAR AS node_key
                FROM %s."%s" g
            )
            -- In future we might join user id and deleted at metadata - its assumed the 'entity' interface implemented and name exists
            SELECT t.name AS key,
                   t.id::VARCHAR(50) AS uid,
                   t.updated_at,
                   t.created_at,
                   G.*
            FROM %s."%s" t
                 LEFT JOIN g ON t.id::character varying(50)::text = g.node_uid::character varying(50)::text 
        );
        $$,
        view_name, graph_name, graph_node, schema_name, table_name
    );

	IF NOT plan THEN
        EXECUTE load_and_cypher_script;
        EXECUTE view_script;
    END IF;

    RETURN QUERY SELECT load_and_cypher_script, view_script;
END;
$BODY$;

ALTER FUNCTION p8.register_entities(text, boolean, text)
    OWNER TO postgres;


---------

 
DROP FUNCTION IF EXISTS p8.vector_search_entity;

CREATE OR REPLACE FUNCTION p8.vector_search_entity(
    question TEXT,
    entity_name TEXT,
    distance_threshold NUMERIC DEFAULT 0.75,
    limit_results INTEGER DEFAULT 3 --TODO think about this, this is very low
)
RETURNS TABLE(id uuid, vdistance double precision) 
LANGUAGE 'plpgsql'
AS $BODY$
DECLARE
    embedding_for_text TEXT;
    schema_name TEXT;
    table_name TEXT;
    vector_search_query TEXT;
BEGIN
    /*
	This is a generic model search that resturns ids which can be joined with the original table
	we dont do it ine one because we want to dedup and take min distance on multiple embeddings 
	
	select  * from p8.vector_search_entity('what sql queries do we have for generating uuids from json', 'p8.PercolateAgent')
	*/
    -- Format the entity name to include the schema if not already present
    SELECT CASE 
        WHEN entity_name NOT LIKE '%.%' THEN 'public.' || entity_name 
        ELSE entity_name 
    END INTO entity_name;

    -- Compute the embedding for the question
    embedding_for_text := p8.get_embedding_for_text(question);

    -- Extract schema and table name from the entity name (assuming format schema.table)
    schema_name := split_part(entity_name, '.', 1);
    table_name := split_part(entity_name, '.', 2);

    -- Construct the dynamic query using a CTE to order by vdistance and limit results
    vector_search_query := FORMAT(
        'WITH vector_search_results AS (
            SELECT b.id, MIN(a.embedding_vector <-> %L) AS vdistance
            FROM p8_embeddings."%s_%s_embeddings" a
            JOIN %s.%I b ON b.id = a.source_record_id
            WHERE a.embedding_vector <-> %L <= %L
            GROUP BY b.id
        )
        SELECT id, vdistance
        FROM vector_search_results
        ORDER BY vdistance
        LIMIT %s',
        embedding_for_text, schema_name, table_name, schema_name, table_name, embedding_for_text, distance_threshold, limit_results
    );

    -- Execute the query and return the results
    RETURN QUERY EXECUTE vector_search_query;
END;
$BODY$;


---------

CREATE OR REPLACE FUNCTION p8.get_entities(
    keys text[]
)
RETURNS jsonb
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    result JSONB := '{}'::JSONB;
BEGIN
	/*
	import p8 get_graph_nodes_by_id 

	example: selects any entity by its business key by going to the graph for the index and then joining the table
	this example happens to have a table name which is an entity also in the agents table.
	
	select * from p8.get_entities(ARRAY['p8.Agent']);
	*/

    LOAD  'age'; SET search_path = ag_catalog, "$user", public;
	
    -- Load nodes based on keys, returning the associated entity type and key
    WITH nodes AS (
        SELECT id, entity_type FROM p8.get_graph_nodes_by_id(keys)
    ),
    grouped_records AS (
        SELECT 
            CASE 
                WHEN strpos(entity_type, '__') > 0 THEN replace(entity_type, '__', '.')
                ELSE entity_type
            END AS entity_type,
            array_agg(id) AS keys
        FROM nodes
        GROUP BY entity_type
    )
    -- Combine grouped records with their table data using a JOIN and aggregate the result
    SELECT jsonb_object_agg(
                entity_type, 
                p8.get_records_by_keys(entity_type, grouped_records.keys)
           )
    INTO result
    FROM grouped_records;

    -- Return the final JSON object
    RETURN result;
END;
$BODY$;


---------

CREATE OR REPLACE FUNCTION p8.get_entity_ids_by_description(
    description_text text,
    entity_name text,  -- The entity/table name to search
    limit_results integer DEFAULT 5
)
RETURNS TABLE(id uuid) 
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
ROWS 1000
AS $BODY$
DECLARE
    embedded_question VECTOR; -- Variable to store the computed embedding
    sql_query text;  -- Variable to store dynamic SQL query
	schema_name text;
	table_name_only text;
BEGIN
	/*
	you can use this function to get the ids of the entity and then join those in
	sql query to select e.g
    
	select a.* from p8.get_entity_ids_by_description('something about langauge models', 'p8.Agent', 1) idx
	 join p8."Agent" a on a.id = idx.id
	*/

    -- Compute the embedding once and store it in the variable
    SELECT embedding 
    INTO embedded_question
    FROM p8.get_embedding_for_text(description_text);

	schema_name := split_part(entity_name, '.', 1);
    table_name_only := split_part(entity_name, '.', 2);
	
    -- Construct the dynamic SQL query
    sql_query := format('
        WITH records AS (
            SELECT b.id, 
                   min(a.embedding_vector <-> $1) AS vdistance
            FROM p8_embeddings.%I a
            JOIN %s."%s" b ON b.id = a.source_record_id
            WHERE a.embedding_vector <-> $1 <= 0.75
            GROUP BY b.id
        )
        SELECT a.id
        FROM records a
        ORDER BY vdistance ASC
        LIMIT $2;
    ', REPLACE(entity_name, '.', '_') || '_embeddings', 
	   schema_name, table_name_only,
	   schema_name, table_name_only );

    -- Execute the dynamic SQL and return the result
    RETURN QUERY EXECUTE sql_query USING embedded_question, limit_results;
END;
$BODY$;


---------

CREATE OR REPLACE FUNCTION p8.cypher_entity_match(
	keys text[])
    RETURNS TABLE(entity_type text, node_keys text[]) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    sql TEXT;
	keys_string TEXT;
BEGIN
	LOAD  'age'; SET search_path = ag_catalog, "$user", public; 
	
	SELECT string_agg(format('''%s''', k), ', ') INTO keys_string
	FROM unnest(keys) AS k;

    -- Dynamically create the Cypher query string
    sql := format($c$
	 ------

	   WITH nodes AS (
		SELECT * FROM cypher('percolate', $$ 
			MATCH (v)
			WHERE v.uid IN [%s]
			RETURN v, v.key
		    $$) AS (v agtype, key agtype)
	    ),
	    records AS (
	        SELECT 
	            key::text, 
	            (v::json)->>'label' AS entity_type
	        FROM nodes
	    ),
	    grouped_records AS (
	        SELECT 
	            CASE 
	                WHEN strpos(entity_type, '__') > 0 THEN replace(entity_type, '__', '.')
	                ELSE entity_type
	            END AS entity_type,
	            array_agg(key) AS keys
	        FROM records
	        GROUP BY entity_type
	    )
		select * from grouped_records
	 ------
	 $c$, keys_string -- this goes into the s in the cypher
    );

    -- Execute the dynamic query
    RETURN QUERY EXECUTE sql;
END;
$BODY$;

---------

CREATE OR REPLACE FUNCTION p8.get_graph_nodes_by_id(
    keys text[]
)
RETURNS TABLE(id text, entity_type text) -- Returning both id and entity_type
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    sql_query text;
BEGIN
    -- Construct the dynamic SQL with quoted keys and square brackets
    sql_query := 'WITH nodes AS (
                    SELECT * 
                    FROM cypher(''percolate'', $$ 
                        MATCH (v)
                        WHERE v.key IN [' || array_to_string(ARRAY(SELECT quote_literal(k) FROM unnest(keys) AS k), ', ') || '] 
                        RETURN v, v.uid 
                    $$) AS (v agtype, key agtype)
                  ), 
                  records AS (
                    SELECT 
                        key::text, 
                        (v::json)->>''label'' AS entity_type
                    FROM nodes
                  )
                  SELECT key, entity_type
                  FROM records';
    
    -- Execute the dynamic SQL and return the result
    RETURN QUERY EXECUTE sql_query;
END;
$BODY$;

---------

-- FUNCTION: public.generate_markdown_prompt(text, integer)

-- DROP FUNCTION IF EXISTS public.generate_markdown_prompt(text, integer);

CREATE OR REPLACE FUNCTION p8.generate_markdown_prompt(
	table_entity_name text,
	max_enum_entries integer DEFAULT 200)
    RETURNS text
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    markdown_prompt TEXT;
    field_info RECORD;
    field_descriptions TEXT := '';
    enum_values TEXT := '';
	column_unique_values JSONB;
    p8_system_prompt TEXT := '';
BEGIN
/*
select * from p8.generate_markdown_prompt('p8.Agent')
*/
    SELECT CASE 
        WHEN table_entity_name NOT LIKE '%.%' THEN 'public.' || table_entity_name 
        ELSE table_entity_name 
    END INTO table_entity_name;

    SELECT value 
    into p8_system_prompt from p8."Settings" where key = 'P8_SYS_PROMPT' limit 1;


    -- Add entity name and description to the markdown
    SELECT COALESCE(p8_system_prompt,'') || E'\n\n' || 
           '## Agent Name: ' || b.name || E'\n\n' || 
           '### Description: ' || E'\n\n' || COALESCE(b.description, 'No description provided.') || E'\n\n'
    INTO markdown_prompt
    FROM p8."Agent" b
    WHERE b.name = table_entity_name;

    -- Add field descriptions in a table format
    FOR field_info IN
        SELECT a.name AS field_name, 
               a.field_type, 
               COALESCE(a.description, '') AS field_description
        FROM p8."ModelField" a
        WHERE a.entity_name = table_entity_name
    LOOP
        field_descriptions := field_descriptions || 
            '| ' || field_info.field_name || ' | ' || field_info.field_type || 
            ' | ' || field_info.field_description || ' |' || E'\n';
    END LOOP;

    IF field_descriptions <> '' THEN
        markdown_prompt := markdown_prompt || 
            '### Field Descriptions' || E'\n\n' ||
            '| Field Name | Field Type | Description |' || E'\n' ||
            '|------------|------------|-------------|' || E'\n' ||
            field_descriptions || E'\n';
    END IF;

    -- Check for enums and add them if they are below the max_enum_entries threshold
    -- create some sort of enums view from metadata

	select get_unique_enum_values into column_unique_values from p8.get_unique_enum_values(table_entity_name);
	-- create an example repository for the table
	
    -- Add space for examples and functions
    markdown_prompt := markdown_prompt || 
        '### Examples' || E'\n\n' ||
        'in future we will add examples that match the question via vector search' || E'\n\n'  ||
		'### The unique distinct same values for some columns ' || E'\n\n' ||
		column_unique_values || E'\n';

		

    RETURN markdown_prompt;
END;
$BODY$;



---------

CREATE OR REPLACE FUNCTION p8.get_unique_enum_values(
	table_name text,
	max_limit integer DEFAULT 250)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    schema_name TEXT;
    table_name_only TEXT;
    col RECORD;
    unique_values JSONB = '{}'::JSONB;
	column_unique_values JSONB;
    sql_query TEXT;
BEGIN
    -- Split the fully qualified table name into schema and table name
    schema_name := split_part(table_name, '.', 1);
    table_name_only := split_part(table_name, '.', 2);

    FOR col IN
        SELECT   attname  
		FROM   pg_stats
		WHERE   schemaname = schema_name     AND tablename = table_name_only and n_distinct between 1 and max_limit  

	    LOOP
	        -- Prepare dynamic SQL to count distinct values in each column
	        sql_query := format(
	            'SELECT jsonb_agg(%I) FROM (SELECT DISTINCT %I FROM %I."%s" ) AS subquery',
	            col.attname, col.attname, schema_name, table_name_only
	        );
			--RAISE NOTICE '%', sql_query;
	        -- Execute the dynamic query and store the result in the JSON object
	        EXECUTE sql_query INTO column_unique_values;

	        -- Add the unique values for the column to the JSON object
	        -- The key is the column name, the value is the array of unique values
	        unique_values := unique_values || jsonb_build_object(col.attname, column_unique_values);
	    END LOOP;

    -- Return the JSON object with unique values for each column
    RETURN unique_values;
END;
$BODY$;

---------

 

DROP FUNCTION IF EXISTS p8.query_entity;
CREATE OR REPLACE FUNCTION p8.query_entity(
    question TEXT,
    table_name TEXT,
    min_confidence NUMERIC DEFAULT 0.7)
RETURNS TABLE(
    query_text TEXT,
    confidence NUMERIC,
    relational_result JSONB,
    vector_result JSONB,
    error_message TEXT
) 
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
ROWS 1000
AS $BODY$
DECLARE
    query_to_execute TEXT;
    query_confidence NUMERIC;
    schema_name TEXT;
    table_without_schema TEXT;
    full_table_name TEXT;
    sql_query_result JSONB;
    sql_error TEXT;
    vector_search_result JSONB;
	embedding_for_text VECTOR;
BEGIN

	/*
	first crude look at merging multipe together
	we will spend time on this later with a proper fast parallel index

	select * from p8.query_entity('what sql queries do we have for generating uuids from json', 'p8.PercolateAgent')


	*/

    -- Extract schema and table name
    schema_name := split_part(table_name, '.', 1);
    table_without_schema := split_part(table_name, '.', 2);
    full_table_name := FORMAT('%I."%I"', schema_name, table_without_schema);

    -- Get the embedding for the question
    SELECT p8.get_embedding_for_text(question) INTO embedding_for_text;

    -- Call the nl2sql function to get the SQL query and confidence
    SELECT "query", nq.confidence INTO query_to_execute, query_confidence  
    FROM p8.nl2sql(question, table_name) nq;

    -- Replace 'YOUR_TABLE' in the query with the actual table name
    query_to_execute := REPLACE(query_to_execute, 'YOUR_TABLE', full_table_name);

    -- Initialize error variables
    sql_error := NULL;
    sql_query_result := NULL;
    vector_search_result := NULL;

    -- Execute the SQL query if confidence is high enough
    IF query_confidence >= min_confidence THEN
        BEGIN
            query_to_execute := rtrim(query_to_execute, ';');
            EXECUTE FORMAT('SELECT jsonb_agg(row_to_json(t)) FROM (%s) t', query_to_execute)
            INTO sql_query_result;
        EXCEPTION
            WHEN OTHERS THEN
                sql_error := SQLERRM; -- Capture the error message
                sql_query_result := NULL;
        END;
    END IF;

    -- Use the vector_search_entity utility function to perform the vector search
    BEGIN
        EXECUTE FORMAT(
            'SELECT jsonb_agg(row_to_json(result)) 
             FROM (
                 SELECT b.*, a.vdistance 
                 FROM p8.vector_search_entity(%L, %L) a
                 JOIN %s.%I b ON b.id = a.id 
                 ORDER BY a.vdistance
             ) result',
            question, table_name, schema_name, table_without_schema
        ) INTO vector_search_result;
    EXCEPTION
        WHEN OTHERS THEN
            sql_error := COALESCE(sql_error, '') || '; Vector search error: ' || SQLERRM;
            vector_search_result := NULL;
    END;

    -- Return results as separate columns
    RETURN QUERY 
    SELECT 
        query_to_execute AS query_text,
        query_confidence AS confidence,
        sql_query_result AS relational_result,
        vector_search_result AS vector_result,
        sql_error AS error_message;
END;
$BODY$;


---------

CREATE OR REPLACE FUNCTION p8.get_grouped_records(
	keys text[])
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    result JSONB := '{}'::JSONB;
BEGIN
    WITH nodes AS (
        SELECT * FROM cypher('percolate', $$
            MATCH (v)
            WHERE v.uid IN %L
            RETURN v, v.key
        $$, keys) AS (v agtype, key agtype)
    ),
    records AS (
        SELECT 
            key::text, 
            (v::json)->>'label' AS entity_type
        FROM nodes
    ),
    grouped_records AS (
        SELECT 
            CASE 
                WHEN strpos(entity_type, '__') > 0 THEN replace(entity_type, '__', '.')
                ELSE entity_type
            END AS entity_type,
            array_agg(key) AS keys
        FROM records
        GROUP BY entity_type
    )
    SELECT jsonb_agg(jsonb_build_object('entity_type', entity_type, 'keys', keys))
    INTO result
    FROM grouped_records;

    RETURN result;
END;
$BODY$;

---------


DROP FUNCTION IF EXISTS p8.get_agent_tool_names;
CREATE OR REPLACE FUNCTION p8.get_agent_tool_names(
    recovered_agent TEXT,
    selected_scheme TEXT DEFAULT  'openai',
    add_percolate_tools BOOLEAN DEFAULT TRUE
)
RETURNS TEXT[] AS $$
DECLARE
    tool_names_array TEXT[];
    functions JSONB;
BEGIN

/*
select * from p8.get_agent_tool_names('p8.Agent', NULL, FALSE)
select * from p8.get_agent_tool_names('p8.Agent', NULL, TRUE)
select * from p8.get_agent_tool_names('p8.Agent', 'google')

*/
    -- Get tool names from Agent functions
    SELECT ARRAY(
        SELECT jsonb_object_keys(a.functions::JSONB)
        FROM p8."Agent" a
        WHERE a.name = recovered_agent AND a.functions IS NOT NULL
    ) INTO tool_names_array;

     -- Add percolate tools if the parameter is true
    IF add_percolate_tools THEN
        -- Augment the tool_names_array with the percolate tools
        -- These are the standard percolate tools that are added unless the entity deactivates them
        tool_names_array := tool_names_array || ARRAY[
            'help', 
            'get_entities', 
            'search', 
            'announce_generate_large_output',
            'activate_functions_by_name'
        ];
    END IF;
    
    RETURN tool_names_array;
END;
$$ LANGUAGE plpgsql;



---------

