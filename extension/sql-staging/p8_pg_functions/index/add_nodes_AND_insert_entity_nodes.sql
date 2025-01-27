CREATE OR REPLACE FUNCTION p8.add_nodes(
	table_name text)
    RETURNS integer
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    cypher_query TEXT;
    row RECORD;
    sql TEXT;
    schema_name TEXT;
    pure_table_name TEXT;
    nodes_created_count INTEGER := 0; -- Tracks the number of nodes created
BEGIN

    LOAD  'age'; SET search_path = ag_catalog, "$user", public; 

    -- Initialize the Cypher query
    cypher_query := 'CREATE ';
    schema_name := lower(split_part(table_name, '.', 1));
    pure_table_name := split_part(table_name, '.', 2);

    -- Loop through each row in the table - graph assumed to be 'one' here
    FOR row IN
        EXECUTE format('SELECT uid, key FROM p8."vw_%s_%s" WHERE gid IS NULL LIMIT 1660', 
            schema_name, pure_table_name
        )
    LOOP
        -- Append Cypher node creation for each row
        cypher_query := cypher_query || format(
            '(:%s__%s {uid: "%s", key: "%s"}), ',
            schema_name, pure_table_name, row.uid, row.key
        );

        -- Increment the counter for each node
        nodes_created_count := nodes_created_count + 1;
    END LOOP;

    IF nodes_created_count > 0 THEN
        -- Remove the trailing comma and space
        cypher_query := left(cypher_query, length(cypher_query) - 2);

        -- Debug: Optionally print the Cypher query for audit
        -- RAISE NOTICE 'Generated Cypher Query: %s', cypher_query;

        -- Execute the Cypher query using the cypher function
        sql := format(
            'SELECT * FROM cypher(''percolate'', $$ %s $$) AS (v agtype);',
            cypher_query
        );

        -- Execute the query
        EXECUTE sql;

        -- Return the number of rows processed
        RETURN nodes_created_count;
    ELSE
        -- No rows to process
        RAISE NOTICE 'Nothing to do';
        RETURN 0;
    END IF;
END;
$BODY$;



-- FUNCTION: public.insert_entity_nodes(text)

-- DROP FUNCTION IF EXISTS public.insert_entity_nodes(text);

CREATE OR REPLACE FUNCTION p8.insert_entity_nodes(
	entity_table text)
    RETURNS TABLE(entity_name text, total_records_affected integer) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    records_affected INTEGER := 0;
    total_records_affected INTEGER := 0;
BEGIN
	/*imports p8.add_nodes*/
    -- Loop until no more records are affected
    LOOP
        -- Call p8_add_nodes and get the number of records affected
        SELECT add_nodes INTO records_affected FROM p8.add_nodes(entity_table);

        -- If no records are affected, exit the loop
        IF records_affected = 0 THEN
            EXIT;
        END IF;

        -- Add the current records affected to the total
        total_records_affected := total_records_affected + records_affected;
    END LOOP;

    -- Return the entity name and total records affected
    RETURN QUERY SELECT entity_table AS entity_name, total_records_affected;
END;
$BODY$;