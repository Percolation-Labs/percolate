
DROP FUNCTION IF EXISTS p8.get_graph_nodes_by_id;
CREATE OR REPLACE FUNCTION p8.get_graph_nodes_by_id(
    keys bigint[]
)
RETURNS TABLE(id text, entity_type text) 
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    sql_query text;
    keys_str text;
BEGIN
    /*

    we can use an alt function to get by the business key but this function queries by the AGE BIG INT id
    This can be useful for low level functions that resolves arbitrary entities of different types and we can resolve the json of the actual entity using another function e.g. as done in get_entities

    Example usage:
    SELECT * FROM p8.get_graph_nodes_by_id(ARRAY[844424930131969]);
    */

    -- Convert the array to a Cypher-friendly list format
    keys_str := array_to_string(keys, ', '); -- Converts [id1, id2] → "id1, id2"

    -- Construct the Cypher query dynamically
    sql_query := format(
        'WITH nodes AS (
            SELECT * 
            FROM cypher(''percolate'', $$ 
                MATCH (v)
                WHERE id(v) IN [%s]
                RETURN v 
            $$) AS (v agtype)
        ), 
        records AS (
            SELECT 
                (v::json)->>''id'' AS id,  -- Extracting the node ID
                (v::json)->>''label'' AS entity_type -- Extracting the label
            FROM nodes
        )
        SELECT id, entity_type FROM records',
        keys_str
    );

    -- Execute the dynamic SQL and return the result
    RETURN QUERY EXECUTE sql_query;
END;
$BODY$;