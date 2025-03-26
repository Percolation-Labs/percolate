CREATE OR REPLACE FUNCTION p8.get_graph_nodes_by_key(
    keys text[]
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
    sql_query := 'WITH nodes AS (
                    SELECT * 
                    FROM cypher(''percolate'', $$ 
                        MATCH (v)
                        WHERE v.key IN [' || array_to_string(ARRAY(SELECT quote_literal(k) FROM unnest(keys) AS k), ', ') || '] 
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