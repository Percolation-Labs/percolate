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

    -- If the token is not set, fetch it
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