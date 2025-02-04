DROP FUNCTION IF EXISTS p8.get_records_by_keys;
CREATE OR REPLACE FUNCTION p8.get_records_by_keys(
    table_name TEXT,
    key_list TEXT[],
    key_column TEXT DEFAULT 'id'::TEXT,
    include_entity_metadata BOOLEAN DEFAULT TRUE
)
RETURNS JSONB
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    result JSONB;            -- The JSON result to be returned
    metadata JSONB;          -- The metadata JSON result
    query TEXT;              -- Dynamic query to execute
    schema_name VARCHAR;
    pure_table_name VARCHAR;
BEGIN
    schema_name := lower(split_part(table_name, '.', 1));
    pure_table_name := split_part(table_name, '.', 2);

    -- Construct the dynamic query to select records from the specified table
    query := format('SELECT jsonb_agg(to_jsonb(t)) FROM %I."%s" t WHERE t.%I::TEXT = ANY($1)', schema_name, pure_table_name, key_column);

    -- Execute the dynamic query with the provided key_list as parameter
    EXECUTE query USING key_list INTO result;
    
    -- Fetch metadata if include_entity_metadata is TRUE
    IF include_entity_metadata THEN
        SELECT jsonb_build_object('description', a.description, 'functions', a.functions)
        INTO metadata
        FROM p8."Agent" a
        WHERE a.name = table_name;
    ELSE
        metadata := NULL;
    END IF;
    
    -- Return JSONB object containing both data and metadata
    RETURN jsonb_build_object('data', result,
								'metadata', metadata, 
								'instruction', 'you can request to activate new functions by name to use them as tools');
END;
$BODY$;
