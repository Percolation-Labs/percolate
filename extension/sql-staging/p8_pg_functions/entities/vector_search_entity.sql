 
DROP FUNCTION IF EXISTS p8.vector_search_entity;

CREATE OR REPLACE FUNCTION p8.vector_search_entity(
    question TEXT,
    entity_name TEXT,
    distance_threshold NUMERIC DEFAULT 0.75,
    limit_results INTEGER DEFAULT 5
)
RETURNS TABLE(id uuid, vdistance double precision) 
LANGUAGE 'plpgsql'
AS $BODY$
DECLARE
    embedding_for_text TEXT;
    schema_name TEXT;
    table_name TEXT;
    vector_search_query TEXT;
BEGIN
    /*
	This is a generic model search that resturns ids which can be joined with the original table
	we dont do it ine one because we want to dedup and take min distance on multiple embeddings 
	
	select  * from p8.vector_search_entity('what sql queries do we have for generating uuids from json', 'p8.PercolateAgent')
	*/
    -- Format the entity name to include the schema if not already present
    SELECT CASE 
        WHEN entity_name NOT LIKE '%.%' THEN 'public.' || entity_name 
        ELSE entity_name 
    END INTO entity_name;

    -- Compute the embedding for the question
    embedding_for_text := p8.get_embedding_for_text(question);

    -- Extract schema and table name from the entity name (assuming format schema.table)
    schema_name := split_part(entity_name, '.', 1);
    table_name := split_part(entity_name, '.', 2);

    -- Construct the dynamic query using a CTE to order by vdistance and limit results
    vector_search_query := FORMAT(
        'WITH vector_search_results AS (
            SELECT b.id, MIN(a.embedding_vector <-> %L) AS vdistance
            FROM p8_embeddings."%s_%s_embeddings" a
            JOIN %s.%I b ON b.id = a.source_record_id
            WHERE a.embedding_vector <-> %L <= %L
            GROUP BY b.id
        )
        SELECT id, vdistance
        FROM vector_search_results
        ORDER BY vdistance
        LIMIT %s',
        embedding_for_text, schema_name, table_name, schema_name, table_name, embedding_for_text, distance_threshold, limit_results
    );

    -- Execute the query and return the results
    RETURN QUERY EXECUTE vector_search_query;
END;
$BODY$;
