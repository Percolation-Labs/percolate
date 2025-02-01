 

DROP FUNCTION IF EXISTS p8.query_entity;
CREATE OR REPLACE FUNCTION p8.query_entity(
    question TEXT,
    table_name TEXT,
    min_confidence NUMERIC DEFAULT 0.7)
RETURNS TABLE(
    query_text TEXT,
    confidence NUMERIC,
    relational_result JSONB,
    vector_result JSONB,
    error_message TEXT
) 
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
ROWS 1000
AS $BODY$
DECLARE
    query_to_execute TEXT;
    query_confidence NUMERIC;
    schema_name TEXT;
    table_without_schema TEXT;
    full_table_name TEXT;
    sql_query_result JSONB;
    sql_error TEXT;
    vector_search_result JSONB;
	embedding_for_text VECTOR;
BEGIN

	/*
	first crude look at merging multipe together
	we will spend time on this later with a proper fast parallel index

	select * from p8.query_entity('what sql queries do we have for generating uuids from json', 'p8.PercolateAgent')


	*/

    -- Extract schema and table name
    schema_name := split_part(table_name, '.', 1);
    table_without_schema := split_part(table_name, '.', 2);
    full_table_name := FORMAT('%I."%I"', schema_name, table_without_schema);

    -- Get the embedding for the question
    SELECT p8.get_embedding_for_text(question) INTO embedding_for_text;

    -- Call the nl2sql function to get the SQL query and confidence
    SELECT "query", nq.confidence INTO query_to_execute, query_confidence  
    FROM p8.nl2sql(question, table_name) nq;

    -- Replace 'YOUR_TABLE' in the query with the actual table name
    query_to_execute := REPLACE(query_to_execute, 'YOUR_TABLE', full_table_name);

    -- Initialize error variables
    sql_error := NULL;
    sql_query_result := NULL;
    vector_search_result := NULL;

    -- Execute the SQL query if confidence is high enough
    IF query_confidence >= min_confidence THEN
        BEGIN
            query_to_execute := rtrim(query_to_execute, ';');
            EXECUTE FORMAT('SELECT jsonb_agg(row_to_json(t)) FROM (%s) t', query_to_execute)
            INTO sql_query_result;
        EXCEPTION
            WHEN OTHERS THEN
                sql_error := SQLERRM; -- Capture the error message
                sql_query_result := NULL;
        END;
    END IF;

    -- Use the vector_search_entity utility function to perform the vector search
    BEGIN
        EXECUTE FORMAT(
            'SELECT jsonb_agg(row_to_json(result)) 
             FROM (
                 SELECT b.*, a.vdistance 
                 FROM p8.vector_search_entity(%L, %L) a
                 JOIN %s.%I b ON b.id = a.id 
                 ORDER BY a.vdistance
             ) result',
            question, table_name, schema_name, table_without_schema
        ) INTO vector_search_result;
    EXCEPTION
        WHEN OTHERS THEN
            sql_error := COALESCE(sql_error, '') || '; Vector search error: ' || SQLERRM;
            vector_search_result := NULL;
    END;

    -- Return results as separate columns
    RETURN QUERY 
    SELECT 
        query_to_execute AS query_text,
        query_confidence AS confidence,
        sql_query_result AS relational_result,
        vector_search_result AS vector_result,
        sql_error AS error_message;
END;
$BODY$;
