DROP FUNCTION IF EXISTS get_node_property_names;
CREATE OR REPLACE FUNCTION p8.get_node_property_names(path_nodes json)
RETURNS text[] AS $$
DECLARE
    result text[];
BEGIN
	/*
	
	SELECT p8.get_node_property_names(
    '[{"id": 3659174697238668, "label": "public__Chapter", "properties": {"name": "page47_moby"}}, 
      {"id": 4222124650660157, "label": "Category", "properties": {"name": "Chance"}}, 
      {"id": 4222124650660039, "label": "Category", "properties": {"name": "Philosophy"}}, 
      {"id": 3659174697238783, "label": "public__Chapter", "properties": {"name": "page114_moby"}}]'
	);
	*/
    -- Extract the 'name' properties from the JSON array and store them in the result array
    SELECT array_agg((node->'properties'->>'name')::text)
    INTO result
    FROM json_array_elements(path_nodes) AS node;

    -- Return the result array of names
    RETURN result;
END;
$$ LANGUAGE plpgsql;