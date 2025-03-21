DROP FUNCTION IF EXISTS p8.get_embedding_for_text;

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
    request_url TEXT;
    use_ollama BOOLEAN;
BEGIN
    /*
        for now we have a crude way of assuming ollama for open source models
        if running locally it would look like this but the url we use is the dockerized service so localhost becomes ollama
        curl http://localhost:11434/api/embed -d '{
            "model": "bge-m3",
            "input": "Hello World"
            }'
    */

    -- Step 1: Check if the model is in the list of hardcoded Ollama models
    use_ollama := embedding_model IN ('bge-m3');

    IF use_ollama THEN
        request_url := 'http://ollama:11434/api/embed';
        api_token := ''; -- No API token required for Ollama
    ELSE
        -- Retrieve API token for OpenAI models
        SELECT "token"
        INTO api_token
        FROM p8."LanguageModelApi"
        WHERE "name" = 'gpt-4o-mini'; -- embedding_model hint

        IF api_token IS NULL THEN
            RAISE EXCEPTION 'Token not found for the provided model or OpenAI default: %', api_token;
        END IF;

        request_url := 'https://api.openai.com/v1/embeddings';
    END IF;

    -- Step 2: Make the HTTP request
    SELECT content::JSONB
    INTO embedding_response
    FROM public.http(
        (
            'POST',
            request_url,
            ARRAY[
                public.http_header('Authorization', 'Bearer ' || api_token)
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