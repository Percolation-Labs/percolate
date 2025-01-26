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
