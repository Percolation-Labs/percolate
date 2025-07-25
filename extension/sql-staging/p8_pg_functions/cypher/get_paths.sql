
DROP FUNCTION IF EXISTS p8.get_paths;

CREATE OR REPLACE FUNCTION p8.get_paths(
	names text[],
	max_length integer DEFAULT 3,
	max_paths integer DEFAULT 10
	)
    RETURNS TABLE(path_length integer, origin_node text, target_node text, target_node_id bigint, path_node_labels text[]) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    cypher_query text;
    sql text;
BEGIN

	/*

    This is used as the basis of getting nodes related by paths as this can be used by graphwalkers

	Example usage:
	select * from p8.get_paths(ARRAY['page47_moby'])
	*/
    -- Format the Cypher query string with the input names

		SET search_path = ag_catalog, "$user", public;


    cypher_query := format(
        'MATCH p = (a:public__Chapter)-[:ref*1..%s]-(b:public__Chapter)
         WHERE a.name IN [%s]
         RETURN 
		 		length(p) AS path_length, 
                a.name AS origin_node, 
                b.name AS target_node, 
				id(b) as target_node_id,
                nodes(p) AS path_nodes',
				max_length,
            array_to_string(array(
            SELECT quote_literal(name)
            FROM unnest(names) AS name
        ), ', ')  -- Comma-separated quoted strings
    );

    -- Format the SQL statement for Cypher execution
    sql := format(
        '
		 WITH data as(
		 SELECT
		 path_length,
		 origin_node::TEXT,
		 target_node::TEXT,
		 target_node_id,
		 path_nodes::JSON
		   FROM cypher(''percolate'', $$ %s $$) AS (path_length int, origin_node agtype, target_node agtype, target_node_id BIGINT, path_nodes agtype)
		)
		-- Use the helper function get_node_property_names to extract the "name" field from the path_nodes JSON
		select 
            path_length,
            origin_node,
            target_node,
			target_node_id,
            p8.get_node_property_names(path_nodes) AS path_node_labels
		from data limit %L;
		',
        cypher_query, max_paths
    );

    -- Execute the dynamic SQL and return the result
    RETURN QUERY EXECUTE sql;
END;
$BODY$;


