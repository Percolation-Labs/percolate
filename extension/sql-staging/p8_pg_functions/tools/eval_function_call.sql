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
