
DROP FUNCTION IF EXISTS p8.deep_search;

CREATE OR REPLACE FUNCTION p8.deep_search(
    query_text TEXT,
    table_entity_name TEXT,
    content_column TEXT DEFAULT 'content'
)
RETURNS TABLE (
    id UUID,
    vector_distance DOUBLE PRECISION,
    entity_name TEXT,
    content TEXT,
    related_paths JSONB
)
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    schema_name TEXT;
    table_name TEXT;
    dynamic_query TEXT;
BEGIN

	/*
	select * rom p8.deep_search('tell me about harpoons', 'public.Chapter')	
	*/

    -- Load necessary extensions and set search path
    LOAD 'age';
    SET search_path = ag_catalog, "$user", public;

    schema_name := split_part(table_entity_name, '.', 1);
    table_name := split_part(table_entity_name, '.', 2);

    -- Perform vector search and gather the entity IDs, distances, and content
    RETURN QUERY EXECUTE format(
        'WITH vector_results AS (
            SELECT v.id, v.vdistance, c.name AS entity_name, c.%I AS content
            FROM %I.%I c
            JOIN p8.vector_search_entity($1, $2) v
            ON c.id = v.id
        ),
        path_data AS (
            SELECT 
                origin_node AS entity_name,
                jsonb_agg(
                    jsonb_build_object(
                        ''path_node_labels'', path_node_labels
                    )
                ) AS related_paths
            FROM vector_results
            CROSS JOIN LATERAL p8.get_paths(ARRAY[vector_results.entity_name], 3)
            GROUP BY origin_node
        )
        SELECT vr.id, vr.vdistance, vr.entity_name, vr.content, COALESCE(pd.related_paths, ''[]''::jsonb)
        FROM vector_results vr
        LEFT JOIN path_data pd ON vr.entity_name = pd.entity_name;',
        content_column, schema_name, table_name
    ) USING query_text, table_entity_name;
END;
$BODY$;

