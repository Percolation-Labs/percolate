/*
this file contains two queries that go together. 
1] The first contains the main logic to add a graph node using a view over entities of type X
2] the second just iterates to flush batches
*/

DROP FUNCTION IF EXISTS   p8.add_nodes;
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
    view_name TEXT;
    view_exists BOOLEAN;
    nodes_created_count INTEGER := 0;  
BEGIN

    /*
    Adding nodes uses a contractual view over age nodes
    we keep track of any Percolate entity in the graph with a graph id, label (key) and user id if given
    */
    --we always need this when using AGE from postgres 
    LOAD  'age'; SET search_path = ag_catalog, "$user", public; 

    schema_name := lower(split_part(table_name, '.', 1));
    pure_table_name := split_part(table_name, '.', 2);
    view_name := format('p8."vw_%s_%s"', schema_name, pure_table_name);
    
    -- Check if the view exists before attempting to query it
    EXECUTE format('
        SELECT EXISTS (
            SELECT FROM information_schema.views 
            WHERE table_schema = ''p8'' 
            AND table_name = ''vw_%s_%s''
        )', schema_name, pure_table_name) 
    INTO view_exists;
    
    -- If view doesn't exist, log a message and return 0
    IF NOT view_exists THEN
        RAISE NOTICE 'View % does not exist - skipping node creation', view_name;
        RETURN 0;
    END IF;

    cypher_query := 'CREATE ';

    -- Loop through each row in the table  
    FOR row IN
        EXECUTE format('SELECT uid, key, userid FROM %s WHERE gid IS NULL LIMIT 1660', view_name)
    LOOP
        -- Append Cypher node creation for each row (include user_id only when present)
        IF row.userid IS NULL THEN
            cypher_query := cypher_query || format(
                '(:%s__%s {uid: "%s", key: "%s"}), ',
                schema_name, pure_table_name, row.uid, row.key
            );
        ELSE
            cypher_query := cypher_query || format(
                '(:%s__%s {uid: "%s", key: "%s", user_id: "%s"}), ',
                schema_name, pure_table_name, row.uid, row.key, row.userid
            );
        END IF;

        nodes_created_count := nodes_created_count + 1;
    END LOOP;

    --run the batch
    IF nodes_created_count > 0 THEN
        cypher_query := left(cypher_query, length(cypher_query) - 2);

        sql := format(
            'SELECT * FROM cypher(''percolate'', $$ %s $$) AS (v agtype);',
            cypher_query
        );

        EXECUTE sql;

        RETURN nodes_created_count;
    ELSE
        -- No rows to process
        RAISE NOTICE 'Nothing to do in add_nodes for this batch - all good';
        RETURN 0;
    END IF;
END;
$BODY$;


/*
------------------------------------------------
Below is the query for managing batches of inserts
------------------------------------------------
*/

DROP FUNCTION IF EXISTS   p8.insert_entity_nodes;

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