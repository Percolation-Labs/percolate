CREATE OR REPLACE FUNCTION p8.get_tools_by_name(
    names text[],
    scheme text DEFAULT 'openai'::text
)
RETURNS jsonb
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    record_count INT;
BEGIN
    -- Check the count of records matching the names
    SELECT COUNT(*) INTO record_count
    FROM p8."Function"
    WHERE name = ANY(names);

    -- If no records match, return an empty JSON array
    IF record_count = 0 THEN
        RETURN NULL;--'[]'::JSONB;
    END IF;

    -- Handle the scheme and return the appropriate JSON structure
    IF scheme = 'google' THEN
        RETURN (
            SELECT JSON_AGG(
                SELECT JSON_BUILD_ARRAY(
                    JSON_BUILD_OBJECT('function_declarations', JSON_AGG(function_spec::JSON))
                )
            )
            FROM p8."Function"
            WHERE name = ANY(names)
        );
    ELSIF scheme = 'anthropic' THEN
        RETURN (
            SELECT JSON_AGG(
                JSON_BUILD_OBJECT(
                    'name', name,
                    'description', function_spec->>'description',
                    'input_schema', (function_spec->>'parameters')::JSON
                )
            )
            FROM p8."Function"
            WHERE name = ANY(names)
        );
    ELSE
        -- Default to openai
        RETURN (
            SELECT JSON_AGG(
                JSON_BUILD_OBJECT(
                    'type', 'function',
                    'function', function_spec::JSON
                )
            )
            FROM p8."Function"
            WHERE name = ANY(names)
        );
    END IF;
END;
$BODY$;

ALTER FUNCTION p8.get_tools_by_name(text[], text)
    OWNER TO postgres;
