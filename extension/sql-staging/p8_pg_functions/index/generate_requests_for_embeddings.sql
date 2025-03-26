-- FUNCTION: p8.generate_requests_for_embeddings(text, text, text)

DROP FUNCTION IF EXISTS p8.generate_requests_for_embeddings;

CREATE OR REPLACE FUNCTION p8.generate_requests_for_embeddings(
	param_table text,
	param_description_col text,
	param_embedding_model text,
  	max_length integer DEFAULT 30000) -- WARNING that we truncate the string for e.g. the ada model so batches dont fail but we should have an upstream chunking strategy
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

		select * from p8.generate_requests_for_embeddings('p8.Resources', 'content', 'text-embedding-ada-002')

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
            LEFT(COALESCE(a.%I, ''), %s)::TEXT AS description, -- Truncate description to max_length - NOTE its important that we chunk upstream!!!! but this stops a blow up downstream           
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
        max_length,                    -- %s for max string length truncation
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


/*
we may want to chunk but im not sure where i want to do it
we can left the text column large or created a joined chunk column and embed that 
if we leave the text large, we can create N chunk embeddings all pointing to the same large text
the difficult is we need to do a clean up
It may be that we generate the ID using a chunk and then we need some sort of vacuum for the provider length and checking the text content length
for example if the user edited the field, we would have to rebuild the chunks and the embeddings
in general a cte for chunking uses recursion like this

---
-- Define the parameter for the maximum chunk length
DECLARE @ChunkLength INT = 9;

WITH ChunkCTE AS (
    -- Anchor: Get the first chunk from each row
    SELECT
        id,
        -- Include any additional columns you want to retain
        OtherColumn,
        CAST(SUBSTRING(text, 1, @ChunkLength) AS VARCHAR(MAX)) AS ChunkText,
        1 AS ChunkRank,
        SUBSTRING(text, @ChunkLength + 1, LEN(text)) AS RemainingText
    FROM MyTable

    UNION ALL

    -- Recursive part: Process the remaining text
    SELECT
        id,
        OtherColumn,
        CAST(SUBSTRING(RemainingText, 1, @ChunkLength) AS VARCHAR(MAX)),
        ChunkRank + 1,
        SUBSTRING(RemainingText, @ChunkLength + 1, LEN(RemainingText))
    FROM ChunkCTE
    WHERE LEN(RemainingText) > 0  -- Continue as long as there’s text left to process
)
SELECT
    id,
    OtherColumn,
    ChunkRank,
    ChunkText
FROM ChunkCTE
ORDER BY id, ChunkRank
OPTION (MAXRECURSION 0);  -- Allows unlimited recursion if needed


*/