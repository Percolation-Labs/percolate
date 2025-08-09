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
    safe_key_list TEXT[];    -- Safely processed key list
BEGIN
    -- Ensure clean search path to avoid session variable interference
    SET LOCAL search_path = p8, public;
    
    schema_name := lower(split_part(table_name, '.', 1));
    pure_table_name := split_part(table_name, '.', 2);

    -- Debug: Log what we received
    RAISE NOTICE 'get_records_by_keys: table=%, input_keys=%, input_type=%', table_name, key_list, pg_typeof(key_list);

    -- Check if key_list is empty, null, or contains only empty strings
    IF key_list IS NULL OR array_length(key_list, 1) IS NULL OR array_length(key_list, 1) = 0 THEN
        result := '[]'::jsonb;
    ELSE
        -- Filter out empty strings and null values from key_list
        safe_key_list := array_remove(array_remove(key_list, ''), NULL);
        
        -- Check again after filtering
        IF safe_key_list IS NULL OR array_length(safe_key_list, 1) IS NULL OR array_length(safe_key_list, 1) = 0 THEN
            result := '[]'::jsonb;
        ELSE
            -- Debug: Log what we're about to query
            RAISE NOTICE 'get_records_by_keys: filtered_keys=%, array_length=%', safe_key_list, array_length(safe_key_list, 1);
            
            -- Use a safer approach: build the query with explicit array handling
            query := format('SELECT jsonb_agg(to_jsonb(t)) FROM %I."%s" t WHERE t.%I::TEXT = ANY($1::TEXT[])', schema_name, pure_table_name, key_column);
            
            -- Execute the dynamic query with the safe key list
            EXECUTE query USING safe_key_list INTO result;
        END IF;
    END IF;
    
    -- Fetch metadata if include_entity_metadata is TRUE
    IF include_entity_metadata THEN
        -- Initialize metadata to NULL first
        metadata := NULL;
        
        -- Try to fetch metadata from Agent table
        BEGIN
            SELECT jsonb_build_object(
                'description', COALESCE(a.description, ''),
                'functions', a.functions
            )
            INTO metadata
            FROM p8."Agent" a
            WHERE a.name = table_name;
        EXCEPTION 
            WHEN OTHERS THEN
                -- If any error occurs (including JSON casting errors), set metadata to NULL
                metadata := NULL;
        END;
    ELSE
        metadata := NULL;
    END IF;
    
    -- Return JSONB object containing both data and metadata
    RETURN jsonb_build_object('data', result,
								'metadata', metadata, 
								'instruction', 'you can request to activate new functions by name to use them as tools');
END;
$BODY$;
