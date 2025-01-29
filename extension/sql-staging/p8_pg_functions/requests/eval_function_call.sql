-- FUNCTION: p8.eval_function_call(jsonb)

-- DROP FUNCTION IF EXISTS p8.eval_function_call(jsonb);

CREATE OR REPLACE FUNCTION p8.eval_function_call(
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
	--LOAD  'age'; SET search_path = ag_catalog, "$user", public;
	
    -- Lookup endpoint metadata
    SELECT endpoint, proxy_uri, verb
    INTO metadata
    FROM p8."Function"
    WHERE "name" = function_name;

	IF metadata.proxy_uri = 'native' THEN
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

		RAISE NOTICE 'ENDPOINT METADATA %', metadata ;
	    -- Construct the URI root and call URI
	    uri_root := metadata.proxy_uri;--split_part(metadata.proxy_uri, '/', 1) || '//' || split_part(metadata.proxy_uri, '/', 3);
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
	

	    IF api_token IS NULL THEN
			api_token:= 'dummy';
			--	        RAISE EXCEPTION 'API token is not configured';
	    END IF;
	
	    -- Make the HTTP call
		RAISE NOTICE 'Invoke % with % AND encoded %', call_uri, final_args, public.encode_url_query(final_args);
		BEGIN
		    IF UPPER(metadata.verb) = 'GET' THEN
		        -- For GET requests, append query parameters to the URL
				/*
				select * from public.urlencode('{"status": ["sold"]}'::JSON) from https://petstore.swagger.io/v2/pet/findByStatus with 
				*/
		        call_uri := call_uri || '?' || public.encode_url_query(final_args);
				RAISE NOTICE 'Invoke encoded %', call_uri;
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

ALTER FUNCTION p8.eval_function_call(jsonb)
    OWNER TO postgres;
