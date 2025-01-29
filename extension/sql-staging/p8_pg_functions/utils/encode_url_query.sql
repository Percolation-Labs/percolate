-- FUNCTION: p8.encode_url_query(jsonb)

-- DROP FUNCTION IF EXISTS p8.encode_url_query(jsonb);

CREATE OR REPLACE FUNCTION p8.encode_url_query(
	json_input jsonb)
    RETURNS text
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    key TEXT;
    value JSONB;
    query_parts TEXT[] := ARRAY[]::TEXT[];
    formatted_value TEXT;
BEGIN
/*
for example  select public.encode_url_query('{"status": ["sold", "available"]}') -> status=sold,available
*/
    -- Iterate through each key-value pair in the JSONB object
    FOR key, value IN SELECT * FROM jsonb_each(json_input)
    LOOP
        -- Check if the value is an array
        IF jsonb_typeof(value) = 'array' THEN
            -- Convert the array to a comma-separated string
            formatted_value := array_to_string(ARRAY(
                SELECT jsonb_array_elements_text(value)
            ), ',');
        ELSE
            -- Convert other types to text
            formatted_value := value::TEXT;
        END IF;

        -- Append the key-value pair to the query parts
        query_parts := query_parts || (key || '=' || formatted_value);
    END LOOP;

    -- Combine the query parts into a single string separated by '&'
    RETURN array_to_string(query_parts, '&');
END;
$BODY$;

ALTER FUNCTION p8.encode_url_query(jsonb)
    OWNER TO postgres;
