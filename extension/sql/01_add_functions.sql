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
	
   RETURN QUERY
   with records as(
    SELECT b.name,   min(a.embedding_vector <-> embedded_question) as vdistance
    FROM p8_embeddings."p8_Function_embeddings" a
    JOIN p8."Function" b ON b.id = a.source_record_id
    WHERE a.embedding_vector <-> embedded_question <= 0.75
	GROUP BY b.name 
    --ORDER BY a.embedding_vector <-> embedded_question ASC 
 	
	) select a.name, b.function_spec, a.vdistance from records a
	 join p8."Function" b on a.name = b.name
	order by vdistance 
	asc limit limit_results; 
	
END;
$BODY$;


---------


CREATE OR REPLACE FUNCTION p8.anthropic_to_open_ai_response(
	api_response jsonb)
    RETURNS TABLE(msg text, tool_calls_out json) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
BEGIN
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
	                        'arguments', (el->>'input')::JSON
	                    )
	                )
	            ) AS tool_calls
	    FROM r
	    WHERE el->>'type' = 'tool_use'
	)
	SELECT
	    msg.msg,
	    tool_calls.tool_calls
	FROM msg
	FULL OUTER JOIN tool_calls ON TRUE;
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

ALTER FUNCTION p8.get_tools_by_name(text[], text)
    OWNER TO postgres;


---------

/*
TODO: need to resolve the percolate or other API token 
*/

CREATE OR REPLACE FUNCTION public.eval_function_call(
	function_call jsonb)
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
BEGIN
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
    SELECT endpoint, group_id, verb
    INTO metadata
    FROM p8."Function"
    WHERE "name" = function_name;

	IF metadata.group_id = 'native' THEN
		RAISE notice 'native query with args % % query %',  function_name, args, jsonb_typeof(args->'query');
		--the native result is a function call for database functions
		-- Assume there is one argument 'query' which can be a string or a list of strings
        IF jsonb_typeof(args->'query') = 'string' THEN
            query_arg := ARRAY[args->>'query'];
        ELSIF jsonb_typeof(args->'query') = 'array' THEN
			query_arg := ARRAY(SELECT jsonb_array_elements_text((args->'query')::JSONB));
        ELSE
            RAISE EXCEPTION 'Invalid query argument in eval_function_call: must be a string or an array of strings';
        END IF;

		RAISE NOTICE '%', format(  'SELECT jsonb_agg(t) FROM %I(%s) as t',   metadata.endpoint, query_arg  );
		
        -- Execute the native function and aggregate results as JSON
        EXECUTE format(
            'SELECT jsonb_agg(t) FROM %I(%L) as t', --formatted for a text array
            metadata.endpoint,
			query_arg
        )
        INTO native_result;
        RETURN native_result;
	ELSE
	    -- If no matching endpoint is found, raise an exception
	    IF NOT FOUND THEN
	        RAISE EXCEPTION 'No metadata found for function %', function_name;
	    END IF;
	
	    -- Construct the URI root and call URI
	    uri_root := split_part(metadata.group_id, '/', 1) || '//' || split_part(metadata.group_id, '/', 3);
	    call_uri := uri_root || metadata.endpoint;
	
	    final_args := args;
	
	    -- Iterate over matches for placeholders in the URI
	    FOR matches IN SELECT regexp_matches(call_uri, '\{(\w+)\}', 'g') LOOP
	        kwarg := matches[1];
	        IF final_args ? kwarg THEN
	            -- Replace placeholder with argument value and remove from final_args
	            call_uri := regexp_replace(call_uri, '\{' || kwarg || '\}', final_args->>kwarg);
	            final_args := jsonb_strip_nulls(final_args - kwarg);
	        ELSE
	            RAISE EXCEPTION 'Missing required URI parameter: %', kwarg;
	        END IF;
	    END LOOP;
	
	    -- Ensure API token is available
	    
		api_token := '';--(SELECT api_token FROM public."ApiConfig" LIMIT 1); 
	    IF api_token IS NULL THEN
	        RAISE EXCEPTION 'API token is not configured';
	    END IF;
	
	    -- Make the HTTP call
		RAISE NOTICE 'Invoke % with %', call_uri, final_args;
		BEGIN
		    IF UPPER(metadata.verb) = 'GET' THEN
		        -- For GET requests, append query parameters to the URL
		        call_uri := call_uri || '?' || public.urlencode(final_args);
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
	
	    -- Return the API response
	    RETURN api_response;
	END IF;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Function execution failed: %', SQLERRM;
END;
$BODY$;


---------


CREATE OR REPLACE FUNCTION p8.google_to_open_ai_response(
	api_response jsonb)
    RETURNS TABLE(msg text, tool_calls_out json) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    function_call jsonb; -- Variable to hold the function call JSON
BEGIN
    -- Capture the function call from the JSON
    function_call := api_response->'candidates'->0->'content'->'parts'->0->'functionCall';

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
                            'arguments', function_call->'args'
                        )
                    )
                )
            ELSE NULL
        END AS tool_calls_out;
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
    -- Generate the schema prompt for the table
    SELECT generate_markdown_prompt INTO table_schema_prompt FROM p8.generate_markdown_prompt(agent_name);

	IF table_schema_prompt IS NULL THEN
        RAISE EXCEPTION 'Agent with name "%" not found.', agent_name;
    END IF;
	
    IF api_token IS NULL THEN
        
    SELECT token into api_token
	    FROM p8."LanguageModelApi"
	    WHERE "name" = model_in
	    LIMIT 1;
    END IF;
    -- API call to OpenAI with the necessary headers and payload
    WITH T AS(
        SELECT 'system' AS "role", 'you will generate a PostgreSQL query for the table metadata provided and respond in json format with the query and confidence - escape characters so that the json can be loaded in postgres ' AS "content" 
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
        EXECUTE format('SELECT uid, key FROM p8.vw_%s_%s WHERE gid IS NULL LIMIT 1660', 
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
        PERFORM EXECUTE sql;

        -- Return the number of rows processed
        RETURN nodes_created_count;
    ELSE
        -- No rows to process
        RAISE NOTICE 'Nothing to do';
        RETURN 0;
    END IF;
END;
$BODY$;



-- FUNCTION: public.insert_entity_nodes(text)

-- DROP FUNCTION IF EXISTS public.insert_entity_nodes(text);

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
        RAISE EXCEPTION 'Token not found for the provided name: %', token_name;
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

CREATE OR REPLACE FUNCTION  p8.get_records_by_keys(
	table_name text,
	key_list text[],
	key_column text DEFAULT 'id'::text)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    result JSONB;            -- The JSON result to be returned
    query TEXT;              -- Dynamic query to execute
	schema_name VARCHAR;
	pure_table_name VARCHAR;
BEGIN

	schema_name := lower(split_part(table_name, '.', 1));
    pure_table_name := split_part(table_name, '.', 2);

    -- Construct the dynamic query to select records from the specified table
    query := format('SELECT jsonb_agg(to_jsonb(t)) FROM %I."%s" t WHERE t.%I::TEXT = ANY($1)', schema_name, pure_table_name, key_column);

	raise notice '%', query;
    -- Execute the dynamic query with the provided key_list as parameter
    EXECUTE query USING key_list INTO result;

    -- Return the resulting JSONB list
    RETURN result;
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
BEGIN

	/*
	import
	p8.get_unique_enum_values(table_entity_name);
	*/
    -- Add entity name and description to the markdown
    SELECT '## Agent Name: ' || b.name || E'\n\n' || 
           '### Description: ' || COALESCE(b.description, 'No description provided.') || E'\n\n'
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
		'### The unique distinct same values for some columns ' || '\n\n' ||
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
	            'SELECT jsonb_agg(%I) FROM (SELECT DISTINCT %I FROM %I."%I" ) AS subquery',
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

CREATE OR REPLACE FUNCTION p8.query_entity(
	question text,
	table_name text,
	min_confidence numeric DEFAULT 0.7)
    RETURNS TABLE(table_result jsonb) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    query_to_execute TEXT;
    query_confidence NUMERIC;
BEGIN

	/*
	imports p8.nl2sql
	*/
    -- Call the fn_nl2sql function to get the response and confidence
    SELECT   "query", "confidence" INTO query_to_execute, query_confidence FROM p8.nl2sql(question, table_name);

	--RAISE NOTICE 'query: %', query_to_execute;
    -- Check if the confidence is greater than or equal to the minimum threshold
    IF query_confidence >= min_confidence THEN
        -- Execute the dynamic SQL query if confidence is high enough
		query_to_execute := rtrim(query_to_execute, ';');
		
         RETURN QUERY EXECUTE 
            'SELECT jsonb_agg(row_to_json(t)) FROM (' || query_to_execute || ') t';
    ELSE
        -- If the confidence is not high enough, return an error or appropriate message
        RAISE EXCEPTION 'Confidence level too low: %', query_confidence;
    END IF;
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

