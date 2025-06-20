
DROP FUNCTION IF EXISTS p8.generate_requests_for_embeddings;

CREATE OR REPLACE FUNCTION p8.generate_requests_for_embeddings(
	param_table text,
	param_description_col text,
	param_embedding_model text,
	max_length integer DEFAULT 10000)
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
WE are filtering out cases where there is a null or blank description column

		select * from p8.generate_requests_for_embeddings('p8.Resources', 'content', 'text-embedding-ada-002')
		select * from p8.generate_requests_for_embeddings('p8.Agent', 'description', 'text-embedding-ada-002')
				select * from p8.generate_requests_for_embeddings('design.bodies', 'generated_garment_description', 'text-embedding-ada-002')
				select * from p8.generate_requests_for_embeddings('p8.PercolateAgent', 'content', 'text-embedding-ada-002')

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
            LEFT(COALESCE(a.%I, 'no desc'), %s)::TEXT AS description, -- Truncate description to max_length - NOTE its important that we chunk upstream!!!! but this stops a blow up downstream           
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
		and %I IS NOT NULL
		and %I <> ''
 
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
        PARAM_DESCRIPTION_COL,          -- %L for the column name in the join condition
		PARAM_DESCRIPTION_COL,
		PARAM_DESCRIPTION_COL
    );
END;
$BODY$;

 