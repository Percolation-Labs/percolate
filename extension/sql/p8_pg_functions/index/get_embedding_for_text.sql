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
    -- Step 1: Retrieve the API token for now im hard foding to open ai token 
    SELECT "token"
    INTO api_token
    FROM p8."LanguageModelApi"
    WHERE "name" = 'gpt-4o-mini'; --embedding_model;

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