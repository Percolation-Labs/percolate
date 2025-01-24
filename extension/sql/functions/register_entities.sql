CREATE OR REPLACE FUNCTION p8.register_entities(qualified_table_name TEXT, 
plan BOOLEAN DEFAULT false,
graph_name TEXT DEFAULT 'percolate') 
RETURNS TABLE(load_and_cypher_script TEXT, view_script TEXT) AS $BODY$
DECLARE
    schema_name TEXT;
    table_name TEXT;
    graph_node TEXT;
    view_name TEXT;
BEGIN
	/*
	register entities prepares supporting tables for indexing nodes and embeddings
	*/

    -- Split schema and table name
    schema_name := split_part(qualified_table_name, '.', 1);
    table_name := split_part(qualified_table_name, '.', 2);
    graph_node := format('%s__%s', schema_name, table_name);
    view_name := format('vw_%s_%s', schema_name, table_name);

    -- Create the LOAD and Cypher script
    load_and_cypher_script := format(
        $CY$
        LOAD 'age';
        SET search_path = ag_catalog, "$user", public;
        SELECT * 
        FROM cypher('%s', $$
            CREATE (:%s{key:'ref', uid: 'ref'})
        $$) as (v agtype);
        $CY$,
        graph_name, graph_node
    );

    -- Create the VIEW script
    view_script := format(
        $$
        CREATE OR REPLACE VIEW p8."%s" AS (

            WITH G AS (
                SELECT id AS gid,
                       (properties::json->>'uid')::VARCHAR AS node_uid,
                       (properties::json->>'name')::VARCHAR AS node_key
                FROM %s."%s" g
            )
            -- In future we might join user id and deleted at metadata - its assumed the 'entity' interface implemented and name exists
            SELECT t.name AS key,
                   t.id::VARCHAR(50) AS uid,
                   t.updated_at,
                   t.created_at,
                   G.*
            FROM %s."%s" t
            LEFT JOIN G ON t.name::VARCHAR = G.node_uid
        );
        $$,
        view_name, graph_name, graph_node, schema_name, table_name
    );

	IF NOT plan THEN
        EXECUTE load_and_cypher_script;
        EXECUTE view_script;
    END IF;

    RETURN QUERY SELECT load_and_cypher_script, view_script;
END;
$BODY$ LANGUAGE plpgsql;