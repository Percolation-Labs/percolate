DROP FUNCTION IF EXISTS p8.add_weighted_edges;

CREATE OR REPLACE FUNCTION p8.add_weighted_edges(
    node_data jsonb,  -- JSON array containing multiple nodes with their respective edges
    table_name text DEFAULT NULL,
    edge_name text DEFAULT 'semref'
)
RETURNS void
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    node_name text;
    edge jsonb;
    neighbor_name text;
    edge_weight float;
    cypher_query text;
    sql text;
    schema_name text;
    pure_table_name text;
    formatted_node_name text;
BEGIN
    /*
    Adds weighted edges for nodes provided in the `node_data` JSON array.
    This is used to build KKN edges. Note that semantic search finds a neighborhood anyway
    but this can be used if we want to probe sparsely and then fill in the detail.
    A worker processes can add KNN or balltree neighborhoods.
    
    The input `node_data` should contain a JSON array where each item represents a node with a "name" and an "edges" array.
    Each node's "edges" array should be a list of objects, each containing a "name" for the neighbor node and a "weight" for the edge.

    Example input format:
    SELECT p8.add_weighted_edges(
    '[
        {
            "name": "page127_moby",
            "edges": [
                {"name": "page126_moby", "weight": 0.5},
                {"name": "page128_moby", "weight": 0.8}
            ]
        }
    ]'::jsonb,
    'public.Chapter'
    );

    This function will loop through each node in the array and for each node, loop through its "edges" array
    to add a relationship between the node and the neighboring nodes.

	--retrieve related nodes
	SELECT * FROM cypher('percolate', $$ 
	MATCH (a{name:'page127_moby'})-[r:semref]->(b)
	RETURN a.name AS node1, b.name AS node2, r.weight AS edge_weight
	$$) AS (node1 text, node2 text, edge_weight float);

    */

    LOAD 'age';
    SET search_path = ag_catalog, "$user", public;

    -- Loop through each node in the "node_data" JSON array
    FOR node_data IN SELECT * FROM jsonb_array_elements(node_data)
    LOOP
        -- Extract the node name from the current node JSON object
        node_name := node_data->>'name';

        -- If table_name is provided, split it into schema and table format
        IF table_name IS NOT NULL THEN
            schema_name := lower(split_part(table_name, '.', 1));
            pure_table_name := split_part(table_name, '.', 2);
            formatted_node_name := schema_name || '__' || pure_table_name;
        ELSE
            formatted_node_name := node_name; -- Default to node_name if no table_name is provided
        END IF;

        -- Loop through each neighbor in the "edges" array of the current node
        FOR edge IN SELECT * FROM jsonb_array_elements(node_data->'edges')
        LOOP
            -- Extract the neighbor's name and weight
            neighbor_name := edge->>'name';
            edge_weight := (edge->>'weight')::float;

            -- Construct the Cypher query to add the weighted edge
            cypher_query := format(
                'MERGE (a:%s {name: ''%s''})
                 MERGE (b:%s {name: ''%s''})
                 MERGE (a)-[r:%I {weight: %s}]->(b)',
                formatted_node_name, node_name, formatted_node_name, neighbor_name, edge_name, edge_weight
            );
	
            -- Format SQL statement for Cypher execution
            sql := format(
                'SELECT * FROM cypher(''percolate'', $$ %s $$) AS (v agtype);',
                cypher_query
            );

            BEGIN
                -- Execute the Cypher query to create the edge
                EXECUTE sql;
            EXCEPTION
                WHEN OTHERS THEN
                    -- Handle errors if any
                    RAISE NOTICE 'Error while adding edge between % and %: %', node_name, neighbor_name, SQLERRM;
            END;
        END LOOP;
    END LOOP;
END;
$BODY$;
