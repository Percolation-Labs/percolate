DROP FUNCTION IF EXISTS p8.fuzzy_match_node_key;

CREATE OR REPLACE FUNCTION p8.fuzzy_match_node_key(
    match_text TEXT,
    similarity_threshold REAL DEFAULT 0.4
)
RETURNS TABLE (
    id TEXT,
    key TEXT,
    similarity_score REAL
)
LANGUAGE SQL
AS $$

	/*
	CREATE EXTENSION IF NOT EXISTS pg_trgm;

	select * from p8.fuzzy_match_node_key('100012')
	*/
    SELECT 
        id,
        json_data->>'key' AS key,
        similarity(json_data->>'key', match_text) AS similarity_score
    FROM (
        SELECT id, properties::json AS json_data
        FROM percolate._ag_label_vertex
    ) AS sub
    WHERE similarity(json_data->>'key', match_text) > similarity_threshold
    ORDER BY similarity_score DESC;
$$;