CREATE OR REPLACE FUNCTION p8.get_entity_ids_by_description(
    description_text text,
    entity_name text,  -- The entity/table name to search
    limit_results integer DEFAULT 5
)
RETURNS TABLE(id uuid) 
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
ROWS 1000
AS $BODY$
DECLARE
    embedded_question VECTOR; -- Variable to store the computed embedding
    sql_query text;  -- Variable to store dynamic SQL query
	schema_name text;
	table_name_only text;
BEGIN
	/*
	you can use this function to get the ids of the entity and then join those in
	sql query to select e.g
    
	select a.* from p8.get_entity_ids_by_description('something about langauge models', 'p8.Agent', 1) idx
	 join p8."Agent" a on a.id = idx.id
	*/

    -- Compute the embedding once and store it in the variable
    SELECT embedding 
    INTO embedded_question
    FROM p8.get_embedding_for_text(description_text);

	schema_name := split_part(entity_name, '.', 1);
    table_name_only := split_part(entity_name, '.', 2);
	
    -- Construct the dynamic SQL query
    sql_query := format('
        WITH records AS (
            SELECT b.id, 
                   min(a.embedding_vector <-> $1) AS vdistance
            FROM p8_embeddings.%I a
            JOIN %s."%s" b ON b.id = a.source_record_id
            WHERE a.embedding_vector <-> $1 <= 0.75
            GROUP BY b.id
        )
        SELECT a.id
        FROM records a
        ORDER BY vdistance ASC
        LIMIT $2;
    ', REPLACE(entity_name, '.', '_') || '_embeddings', 
	   schema_name, table_name_only,
	   schema_name, table_name_only );

    -- Execute the dynamic SQL and return the result
    RETURN QUERY EXECUTE sql_query USING embedded_question, limit_results;
END;
$BODY$;
