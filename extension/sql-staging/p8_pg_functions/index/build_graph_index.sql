DROP FUNCTION IF EXISTS p8.build_graph_index;
CREATE OR REPLACE FUNCTION p8.build_graph_index(
    entity_name TEXT,
    graph_path_column TEXT DEFAULT 'graph_paths'
)
RETURNS TABLE (graph_element TEXT) AS $$
DECLARE
    paths_json jsonb;
    table_name TEXT;
    schema_name TEXT;
    quoted_table TEXT;
BEGIN
    /*
        Example usage:
        SELECT * FROM p8.build_graph_index('public.Chapter', 'concept_graph_paths');

				select * from p8.get_connected_nodes('public.Chapter', 'page3_moby', 'public.Chapter')

		
    */

    SET search_path = ag_catalog, "$user", public;


    schema_name := lower(split_part(entity_name, '.', 1));
    table_name := split_part(entity_name, '.', 2);
    
    -- Quote the schema and table name properly
    quoted_table := format('%s.%I', schema_name, table_name);
    
    -- Construct the JSON array of paths in the format name/path/tail
    EXECUTE format(
        'SELECT jsonb_agg(name || ''/'' || path) 
         FROM (SELECT name, unnest(%I) AS path FROM %s 
               WHERE name IS NOT NULL AND %I IS NOT NULL) sub',
        graph_path_column, quoted_table, graph_path_column
    )
    INTO paths_json;

	 -- Execute the graph creation function with the generated paths
    EXECUTE format(
        'SELECT p8.create_graph_from_paths(%L::jsonb);', paths_json
    );
	
    -- Return the list of elements extracted from the JSON array
    RETURN QUERY 
    SELECT jsonb_array_elements_text(paths_json);
END;
$$ LANGUAGE plpgsql;
