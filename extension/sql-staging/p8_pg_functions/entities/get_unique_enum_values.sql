CREATE OR REPLACE FUNCTION p8.get_unique_enum_values(
	table_name text,
	max_limit integer DEFAULT 250)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    schema_name TEXT;
    table_name_only TEXT;
    col RECORD;
    unique_values JSONB = '{}'::JSONB;
	column_unique_values JSONB;
    sql_query TEXT;
BEGIN
    -- Split the fully qualified table name into schema and table name
    schema_name := split_part(table_name, '.', 1);
    table_name_only := split_part(table_name, '.', 2);

    FOR col IN
        SELECT   attname  
		FROM   pg_stats
		WHERE   schemaname = schema_name     AND tablename = table_name_only and n_distinct between 1 and max_limit  

	    LOOP
	        -- Prepare dynamic SQL to count distinct values in each column
	        sql_query := format(
	            'SELECT jsonb_agg(%I) FROM (SELECT DISTINCT %I FROM %I."%I" ) AS subquery',
	            col.attname, col.attname, schema_name, table_name_only
	        );
			--RAISE NOTICE '%', sql_query;
	        -- Execute the dynamic query and store the result in the JSON object
	        EXECUTE sql_query INTO column_unique_values;

	        -- Add the unique values for the column to the JSON object
	        -- The key is the column name, the value is the array of unique values
	        unique_values := unique_values || jsonb_build_object(col.attname, column_unique_values);
	    END LOOP;

    -- Return the JSON object with unique values for each column
    RETURN unique_values;
END;
$BODY$;