DROP FUNCTION IF EXISTS p8.get_entities;
CREATE OR REPLACE FUNCTION p8.get_entities(
    keys text[],
    userid text DEFAULT NULL
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
	import p8 get_graph_nodes_by_key

	example: selects any entity by its business key by going to the graph for the index and then joining the table
	this example happens to have a table name which is an entity also in the agents table.
	
		-- Example without user filter (returns all matching entities)
		-- select * from p8.get_entities(ARRAY['p8.Agent']);
		-- Example with user filter (returns only public or user-specific entities)
		-- select * from p8.get_entities(ARRAY['p8.Agent'], 'user123');
	*/

    SET search_path = ag_catalog, "$user", public;
	
    -- Load nodes based on keys, returning the associated entity type and key
    WITH nodes AS (
        SELECT id, entity_type FROM p8.get_graph_nodes_by_key(keys)
    ),
    grouped_records AS (
        SELECT 
            CASE 
                WHEN strpos(entity_type, '__') > 0 THEN replace(entity_type, '__', '.')
                ELSE entity_type
            END AS entity_type,
            array_agg(id) FILTER (WHERE id IS NOT NULL AND id != '') AS keys
        FROM nodes
        WHERE id IS NOT NULL AND entity_type IS NOT NULL AND id != ''
        GROUP BY entity_type
        HAVING array_length(array_agg(id) FILTER (WHERE id IS NOT NULL AND id != ''), 1) > 0
    )
    -- Combine grouped records with their table data using a JOIN and aggregate the result
    -- Use COALESCE to handle empty results
    SELECT COALESCE(
        jsonb_object_agg(
            entity_type, 
            p8.get_records_by_keys(entity_type, grouped_records.keys)
        ), 
        '{}'::jsonb
    )
    INTO result
    FROM grouped_records;

    -- Return the final JSON object
    RETURN result;
END;
$BODY$;
