CREATE OR REPLACE FUNCTION p8.get_grouped_records(
	keys text[])
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    result JSONB := '{}'::JSONB;
BEGIN
    WITH nodes AS (
        SELECT * FROM cypher('percolate', $$
            MATCH (v)
            WHERE v.uid IN %L
            RETURN v, v.key
        $$, keys) AS (v agtype, key agtype)
    ),
    records AS (
        SELECT 
            key::text, 
            (v::json)->>'label' AS entity_type
        FROM nodes
    ),
    grouped_records AS (
        SELECT 
            CASE 
                WHEN strpos(entity_type, '__') > 0 THEN replace(entity_type, '__', '.')
                ELSE entity_type
            END AS entity_type,
            array_agg(key) AS keys
        FROM records
        GROUP BY entity_type
    )
    SELECT jsonb_agg(jsonb_build_object('entity_type', entity_type, 'keys', keys))
    INTO result
    FROM grouped_records;

    RETURN result;
END;
$BODY$;