CREATE OR REPLACE FUNCTION p8.get_graph_nodes_by_key(
    keys text[],
    userid text DEFAULT NULL
)
RETURNS TABLE(id text, entity_type text) -- Returning both id and entity_type
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    sql_query text;
BEGIN
    -- Construct the dynamic SQL with quoted keys and square brackets
    -- Build the dynamic SQL for retrieving graph nodes, optionally filtering by user_id
    -- Start building the Cypher match, filtering by business key
    sql_query := 'WITH nodes AS (
                    SELECT * 
                    FROM cypher(''percolate'', $$ 
                        MATCH (v)
                        WHERE v.key IN ['
                 || array_to_string(ARRAY(SELECT quote_literal(k) FROM unnest(keys) AS k), ', ')
                 || ']';
    
    IF userid IS NOT NULL THEN
        -- Include public nodes and those owned by the given user
        sql_query := sql_query || ' AND (v.user_id IS NULL OR v.user_id = ' || quote_literal(userid) || ')';
    ELSE
        -- With no user filter, include only public nodes
        sql_query := sql_query || ' AND v.user_id IS NULL';
    END IF;

    sql_query := sql_query || ' 
                        RETURN v, v.uid 
                    $$) AS (v agtype, key agtype)
                  ), 
                  records AS (
                    SELECT 
                        key::text, 
                        (v::json)->>''label'' AS entity_type
                    FROM nodes
                  )
                  SELECT key, entity_type
                  FROM records';
    
    -- Execute the dynamic SQL and return the result
    RETURN QUERY EXECUTE sql_query;
END;
$BODY$;