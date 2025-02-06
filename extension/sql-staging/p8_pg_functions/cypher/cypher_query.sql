
drop function if exists public.cypher_query;
CREATE OR REPLACE FUNCTION public.cypher_query(
    cypher_query TEXT,
    return_columns TEXT DEFAULT 'result agtype', -- may just take names if they are all agtypes
    graph_name TEXT DEFAULT 'percolate'   
)
RETURNS TABLE(result JSONB)  -- Adapt dynamically based on return_columns
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    sql_query TEXT;
BEGIN
	/*
	run a cypher query against the graph
	you need to name your select columns for multiple results
		 
 	select * from public.cypher_query('MATCH (v) RETURN v');
	*/

    LOAD 'age';
    SET search_path = ag_catalog, "$user", public;

    -- Use the dynamic graph_name in the query
    sql_query := 'WITH cypher_result AS (
                    SELECT * FROM cypher(''' || graph_name || ''', $$' || cypher_query || '$$) 
                    AS (' || return_columns || ')
                  )
                  SELECT to_jsonb(cypher_result) FROM cypher_result;';

    RETURN QUERY EXECUTE sql_query;
END;
$BODY$;
