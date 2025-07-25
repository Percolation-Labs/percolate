

DROP FUNCTION IF EXISTS p8.get_connected_entities;
CREATE OR REPLACE FUNCTION p8.get_connected_entities(category_name TEXT)
RETURNS TABLE (category_hub TEXT, target_entity TEXT) AS $BODY$
DECLARE
    cypher_query text;
BEGIN
	/*

	get connected entities is for sourcing nodes connected to some theme via category nodes
	For now it can be directed connected or connected by one intermediate category hub
    This could be used to create concept summaries back into the X category but summarising connected entities 
	
	--use a target node 
	SELECT * FROM p8.get_connected_entities('Physical Endurance');
	*/
	SET search_path = ag_catalog, "$user", public;
	
 	cypher_query := format(
        'WITH gdata AS (
            SELECT * FROM cypher(''percolate'', $$
                MATCH (c:Category {name: %L})-[*1]-(m:Category)-[*1]-(n:public__Chapter)
                RETURN m AS middle_node, n AS target_node
            $$) AS (hub agtype, target_node agtype)
            UNION
            SELECT * FROM cypher(''percolate'', $$
                MATCH (c:Category {name: %L})-[*1..2]-(n:public__Chapter)
                RETURN null::agtype AS middle_node, n AS target_node
            $$) AS (hub agtype, target_node agtype)
        )
        SELECT 
            (hub::json)->''properties''->>''name'' AS category_hub,
            (target_node::json)->''properties''->>''name'' AS target_entity
        FROM gdata',
        category_name, category_name
    );
    
    RETURN QUERY EXECUTE cypher_query;
END;
$BODY$ LANGUAGE plpgsql;