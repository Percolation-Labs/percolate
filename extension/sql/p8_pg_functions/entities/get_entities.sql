CREATE OR REPLACE FUNCTION p8.get_entities(
    keys text[]
)
RETURNS jsonb
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    result JSONB := '{}'::JSONB;
BEGIN
	/*
	import p8 get_graph_nodes_by_id 

	example: selects any entity by its business key by going to the graph for the index and then joining the table
	this example happens to have a table name which is an entity also in the agents table.
	
	select * from p8.get_entities(ARRAY['p8.Agent']);
	*/

    -- Load nodes based on keys, returning the associated entity type and key
    WITH nodes AS (
        SELECT id, entity_type FROM p8.get_graph_nodes_by_id(keys)
    ),
    grouped_records AS (
        SELECT 
            CASE 
                WHEN strpos(entity_type, '__') > 0 THEN replace(entity_type, '__', '.')
                ELSE entity_type
            END AS entity_type,
            array_agg(id) AS keys
        FROM nodes
        GROUP BY entity_type
    )
    -- Combine grouped records with their table data using a JOIN and aggregate the result
    SELECT jsonb_object_agg(
                entity_type, 
                p8.get_records_by_keys(entity_type, grouped_records.keys)
           )
    INTO result
    FROM grouped_records;

    -- Return the final JSON object
    RETURN result;
END;
$BODY$;
