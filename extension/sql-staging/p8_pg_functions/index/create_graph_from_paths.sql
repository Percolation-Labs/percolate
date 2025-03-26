DROP FUNCTION IF EXISTS p8.create_graph_from_paths;

CREATE OR REPLACE FUNCTION p8.create_graph_from_paths(
	paths_json jsonb,
	path_source_node_type text DEFAULT 'public.Chapter'::text,
	graph_path_relation text DEFAULT 'ref'::text,
	graph_category_node text DEFAULT 'Category'::text)
    RETURNS TABLE (path TEXT, status TEXT, error_message TEXT)
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    path text;
    path_elements text[];
    task_name text;
    category1_name text;
    category2_name text;
    cypher_query text;
    schema_name TEXT;
    pure_table_name TEXT;
    graph_path_node TEXT;
    sql text;
    results jsonb := '[]'::jsonb;  -- Initialize an empty JSON array to store results
BEGIN
    /*

    You can create a typed path along typed nodes from any source node
    The source node should follow the node conventions for table names and they key should be the first part of the path
    
    Example usage:
    SELECT p8.create_graph_from_paths('["page62_moby/B/C", "page47_moby/B/C", "TX/B/D"]'::jsonb);
    SELECT p8.create_graph_from_paths('["page62_moby/B/C"]'::jsonb);
    
    If these have been added, you can connect page 47 to page 62 via node Category:C
    
    Sample Cypher Queries:
    SELECT * FROM cypher('percolate', $$ MATCH path = (a:P8_Task {name: 'TX'})-[:ref]->(b:Category)-[:ref]->(c:Category) RETURN path $$) AS (path agtype);
    SELECT * FROM cypher('percolate', $$ MATCH path = (start:public__Chapter {name: 'page62_moby'})-[:ref*1..3]-(ch:public__Chapter) RETURN ch, length(path) AS path_length $$) AS (ch agtype, path_length int);
    
    */
    
    -- Load AGE extension and set search path
    LOAD 'age';
    SET search_path = ag_catalog, "$user", public;

    -- Extract the schema and table names for the source node
    schema_name := lower(split_part(path_source_node_type, '.', 1));
    pure_table_name := split_part(path_source_node_type, '.', 2);
    graph_path_node := schema_name || '__' || pure_table_name;

    -- Iterate over each path in the JSON array and process
    FOR path IN SELECT jsonb_array_elements_text(paths_json)
    LOOP
        -- Split the path into its components
        path_elements := string_to_array(path, '/');
        
        -- Ensure path has exactly three elements (Task -> Category1 -> Category2)
        IF array_length(path_elements, 1) = 3 THEN
            task_name := path_elements[1];
            category1_name := path_elements[2];
            category2_name := path_elements[3];

            -- Construct the Cypher query with dynamic parameters
            cypher_query := format(
                'MERGE (a:%s {name: ''%s''})
                 MERGE (b:%s {name: ''%s''})
                 MERGE (c:%s {name: ''%s''})
                 MERGE (a)-[:%I]->(b)
                 MERGE (b)-[:%I]->(c)',
                graph_path_node, REPLACE(task_name, '''', ''), graph_category_node, category1_name, graph_category_node, category2_name,
                graph_path_relation, graph_path_relation
            );

            -- Format the SQL statement for Cypher execution
            sql := format(
                'SELECT * FROM cypher(''percolate'', $$ %s $$) AS (v agtype);',
                cypher_query
            );

            BEGIN
                -- Execute the Cypher query
                EXECUTE sql;

                -- Accumulate success result in the JSON array
                results := results || jsonb_build_object('path', path, 'status', 'success', 'error_message', NULL);
            EXCEPTION
                WHEN OTHERS THEN
                    -- Accumulate failure result with error message in the JSON array
                    results := results || jsonb_build_object('path', path, 'status', 'failure', 'error_message', SQLERRM);
            END;
        ELSE
            -- If path format is invalid (not exactly 3 elements), accumulate failure result
            results := results || jsonb_build_object('path', path, 'status', 'failure', 'error_message', 'Invalid path format');
        END IF;
    END LOOP;

    -- Return all results at once as a single table
    RETURN QUERY 
    SELECT * FROM jsonb_to_recordset(results) AS (path TEXT, status TEXT, error_message TEXT);

END;
$BODY$;
