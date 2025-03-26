DROP FUNCTION IF EXISTS p8.get_connected_nodes;
CREATE OR REPLACE FUNCTION p8.get_connected_nodes(
    node_type TEXT,
    source_node_name TEXT,
	target_type TEXT DEFAULT NULL,
    max_length INT DEFAULT 3
) RETURNS TABLE(node_id TEXT, node_label TEXT, node_name TEXT, path_length INT)
AS $BODY$
DECLARE
    cypher_query TEXT;
    sql TEXT;
	schema_name TEXT;
    pure_table_name TEXT;
BEGIN

	/*
		select * from p8.get_connected_nodes('public.Chapter', 'page62_moby')

		select * from p8.get_connected_nodes('public.Chapter', 'page62_moby', 'public.Chapter')

	*/
	
	LOAD  'age'; SET search_path = ag_catalog, "$user", public;

	schema_name := lower(split_part(node_type, '.', 1));
    pure_table_name := split_part(node_type, '.', 2);
	--formatted as we do for graph nodes 
	node_type := schema_name || '__' || pure_table_name;

	if target_type IS NOT NULL THEN
		schema_name := lower(split_part(target_type, '.', 1));
	    pure_table_name := split_part(target_type, '.', 2);
		--formatted as we do for graph nodes 
		target_type := schema_name || '__' || pure_table_name;

	END IF;
    -- Construct Cypher query dynamically
    cypher_query := format(
        'MATCH path = (start:%s {name: ''%s''})-[:ref*1..%s]-(ch%s%s)
         RETURN ch, length(path) AS path_length',
        node_type, source_node_name, max_length,
        CASE WHEN target_type IS NULL THEN '' ELSE ':' END, 
        COALESCE(target_type, '')
    );

    -- Debug output
    RAISE NOTICE '%', cypher_query;

    -- Format SQL statement
    sql := format(
        'SELECT 
            (ch::json)->>''id'' AS node_id, 
            (ch::json)->>''label'' AS node_label, 
            ((ch::json)->''properties''->>''name'') AS node_name,
            path_length 
        FROM cypher(''percolate'', $$ %s $$) AS (ch agtype, path_length int);',
        cypher_query
    );

    -- Execute the SQL and return the result
    RETURN QUERY EXECUTE sql;
END;
$BODY$ LANGUAGE plpgsql;
