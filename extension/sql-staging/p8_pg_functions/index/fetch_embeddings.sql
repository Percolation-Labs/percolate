DROP FUNCTION IF EXISTS p8.fetch_embeddings;

CREATE OR REPLACE FUNCTION p8.fetch_embeddings(
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
    response jsonb;
    status_code int;
    request_url text;
    use_ollama BOOLEAN;
BEGIN
/*
-- Example calls 
   1 OLLAMA case for a dockerized ollama:
	-- for small hardware making the request directly is slow so we can set a timeout
   select http_set_curlopt('CURLOPT_TIMEOUT','20000') into ack_http_timeout;
   SELECT * FROM p8.fetch_embeddings(
    '["Hello world", "How are you?"]'::jsonb,
    NULL,
    'bge-m3'
);

SELECT * FROM p8.fetch_embeddings(
    '["Hello world", "How are you?"]'::jsonb,
    NULL,
    'text-embedding-ada-002'
);
*/
    -- Set the model to 'text-embedding-ada-002' if it's 'default'
    resolved_model := CASE 
        WHEN param_model = 'default' THEN 'text-embedding-ada-002'
        ELSE param_model
    END;

    -- Check if the model should use Ollama
    use_ollama := resolved_model IN ('bge-m3');

    IF use_ollama THEN
        request_url := 'http://ollama:11434/api/embed';
        resolved_token := ''; -- No API token required for Ollama
    ELSE
        -- If the token is not set, fetch it
        IF param_token IS NULL THEN
            SELECT token INTO resolved_token
            FROM p8."LanguageModelApi"
            WHERE "name" = 'gpt-4o-mini';
        ELSE
            resolved_token := param_token;
        END IF;

        request_url := 'https://api.openai.com/v1/embeddings';
    END IF;

    BEGIN
        -- Execute HTTP request
        SELECT content::jsonb INTO response
        FROM http( (
            'POST', 
            request_url, 
            ARRAY[http_header('Authorization', 'Bearer ' || resolved_token)],
            'application/json',
            jsonb_build_object(
                'input', param_array_data,
                'model', resolved_model,
                'encoding_format', 'float'
            )
        )::http_request);
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'HTTP request failed: %', SQLERRM;
    END;

    IF response IS NULL THEN
        RAISE EXCEPTION 'API response is null, request might have failed';
    END IF;

    status_code := response->>'status';

    IF status_code >= 400 THEN
        RAISE EXCEPTION 'API request failed with status: %, response: %', status_code, response;
    END IF;

    -- Return embeddings if no errors
	IF use_ollama THEN
		RETURN QUERY
		--not sure in general yet what the interfaces are but at least embeddings is plural for ollama
	    SELECT VECTOR(item::TEXT) AS embedding
	    FROM jsonb_array_elements(response->'embeddings') AS item;
	ELSE
	    RETURN QUERY
	    SELECT VECTOR((item->'embedding')::TEXT) AS embedding
	    FROM jsonb_array_elements(response->'data') AS item;
	END IF;
END;
$BODY$;