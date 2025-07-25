CREATE OR REPLACE FUNCTION p8.cypher_entity_match(
	keys text[])
    RETURNS TABLE(entity_type text, node_keys text[]) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    sql TEXT;
	keys_string TEXT;
BEGIN
	SET search_path = ag_catalog, "$user", public; 
	
	SELECT string_agg(format('''%s''', k), ', ') INTO keys_string
	FROM unnest(keys) AS k;

    -- Dynamically create the Cypher query string
    sql := format($c$
	 ------

	   WITH nodes AS (
		SELECT * FROM cypher('percolate', $$ 
			MATCH (v)
			WHERE v.uid IN [%s]
			RETURN v, v.key
		    $$) AS (v agtype, key agtype)
	    ),
	    records AS (
	        SELECT 
	            key::text, 
	            (v::json)->>'label' AS entity_type
	        FROM nodes
	    ),
	    grouped_records AS (
	        SELECT 
	            CASE 
	                WHEN strpos(entity_type, '__') > 0 THEN replace(entity_type, '__', '.')
	                ELSE entity_type
	            END AS entity_type,
	            array_agg(key) AS keys
	        FROM records
	        GROUP BY entity_type
	    )
		select * from grouped_records
	 ------
	 $c$, keys_string -- this goes into the s in the cypher
    );

    -- Execute the dynamic query
    RETURN QUERY EXECUTE sql;
END;
$BODY$;