DROP FUNCTION IF EXISTS p8.query_entity;
CREATE OR REPLACE FUNCTION p8.query_entity(
    question TEXT,
    table_name TEXT,
    user_id UUID DEFAULT NULL,
    semantic_only BOOLEAN DEFAULT FALSE,
    vector_search_function TEXT DEFAULT 'vector_search_entity',
    min_confidence NUMERIC DEFAULT 0.7
)
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
    ack_http_timeout BOOLEAN;
BEGIN

    /*
    first crude look at merging multiple together
    we will spend time on this later with a proper fast parallel index

    select * from p8.nl2sql('current place of residence', 'p8.UserFact' )
    select * from p8.query_entity('what is my favourite color', 'p8.UserFact', 'e9c56a28-1d09-5253-af36-4b9d812f6bfa')
    select * from p8.query_entity('what is my favourite color', 'p8.UserFact', '10e0a97d-a064-553a-9043-3c1f0a6e6725')

    select * from p8.query_entity('what sql queries do we have for generating uuids from json', 'p8.PercolateAgent')
    */

    -- Extract schema and table name
    schema_name := split_part(table_name, '.', 1);
    table_without_schema := split_part(table_name, '.', 2);
    full_table_name := FORMAT('%I."%I"', schema_name, table_without_schema);

    select http_set_curlopt('CURLOPT_TIMEOUT','8000') into ack_http_timeout;
    RAISE NOTICE 'THE HTTP TIMEOUT IS HARDCODED TO 8000ms';  

    -- Initialize error and result variables
    sql_error := NULL;
    sql_query_result := NULL;
    vector_search_result := NULL;

    IF NOT semantic_only THEN
        -- Call the nl2sql function to get the SQL query and confidence
        SELECT "query", nq.confidence INTO query_to_execute, query_confidence  
        FROM p8.nl2sql(question, table_name) nq;

        -- Replace 'YOUR_TABLE' in the query with the actual table name
        query_to_execute := REPLACE(query_to_execute, 'YOUR_TABLE', full_table_name);

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
    ELSE
        -- Skip SQL query generation and execution
        query_to_execute := NULL;
        query_confidence := 0;
        sql_query_result := '[]'::jsonb;
    END IF;

    -- Get the embedding for the question
    SELECT p8.get_embedding_for_text(question) INTO embedding_for_text;

    -- Use the selected vector search function to perform the vector search
    -- update this to filter by user id if its provided
    BEGIN
        IF user_id IS NOT NULL THEN
            EXECUTE FORMAT(
                'SELECT jsonb_agg(row_to_json(result)) 
                 FROM (
                     SELECT b.*, a.vdistance 
                     FROM p8.%I(%L, %L) a
                     JOIN %I.%I b ON b.id = a.id  
                     WHERE (b.userid IS NULL OR b.userid = %L)
                     ORDER BY a.vdistance
                 ) result',
                vector_search_function, question, table_name,
                schema_name, table_without_schema, user_id
            ) INTO vector_search_result;
        ELSE
            EXECUTE FORMAT(
                'SELECT jsonb_agg(row_to_json(result)) 
                 FROM (
                     SELECT b.*, a.vdistance 
                     FROM p8.%I(%L, %L) a
                     JOIN %I.%I b ON b.id = a.id  
                     ORDER BY a.vdistance
                 ) result',
                vector_search_function, question, table_name,
                schema_name, table_without_schema
            ) INTO vector_search_result;
        END IF;
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
