CREATE OR REPLACE FUNCTION  p8.get_records_by_keys(
	table_name text,
	key_list text[],
	key_column text DEFAULT 'id'::text)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    result JSONB;            -- The JSON result to be returned
    query TEXT;              -- Dynamic query to execute
	schema_name VARCHAR;
	pure_table_name VARCHAR;
BEGIN

	schema_name := lower(split_part(table_name, '.', 1));
    pure_table_name := split_part(table_name, '.', 2);

    -- Construct the dynamic query to select records from the specified table
    query := format('SELECT jsonb_agg(to_jsonb(t)) FROM %I."%s" t WHERE t.%I::TEXT = ANY($1)', schema_name, pure_table_name, key_column);

	raise notice '%', query;
    -- Execute the dynamic query with the provided key_list as parameter
    EXECUTE query USING key_list INTO result;

    -- Return the resulting JSONB list
    RETURN result;
END;
$BODY$;
