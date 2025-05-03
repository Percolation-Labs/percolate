DROP FUNCTION IF EXISTS p8.merge_search_results;

CREATE OR REPLACE FUNCTION p8.merge_search_results(
    sql_results JSONB,
    vector_results JSONB,
    graph_results JSONB,
    sql_weight NUMERIC DEFAULT 0.4,
    vector_weight NUMERIC DEFAULT 0.4,
    graph_weight NUMERIC DEFAULT 0.2,
    max_results INTEGER DEFAULT 10
)
RETURNS TABLE(
    id UUID,
    score NUMERIC,
    content JSONB,
    source TEXT,
    rank INTEGER
) 
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL SAFE
ROWS 1000
AS $BODY$
DECLARE
    combined_results JSONB;
    sql_count INTEGER;
    vector_count INTEGER;
    graph_count INTEGER;
BEGIN
    /*
    Merges search results from different sources (SQL, vector, graph) with weighted scoring
    
    Example usage:
    SELECT * FROM p8.merge_search_results(
        query_result.relational_result, 
        query_result.vector_result, 
        query_result.graph_result
    ) FROM p8.query_entity_fast('what is my favorite color', 'p8.UserFact') AS query_result;
    */
    
    -- Initialize counters
    sql_count := CASE WHEN sql_results IS NOT NULL THEN jsonb_array_length(sql_results) ELSE 0 END;
    vector_count := CASE WHEN vector_results IS NOT NULL THEN jsonb_array_length(vector_results) ELSE 0 END;
    graph_count := CASE WHEN graph_results IS NOT NULL THEN jsonb_array_length(graph_results) ELSE 0 END;
    
    -- Create a CTE for SQL results
    RETURN QUERY WITH
    sql_data AS (
        SELECT 
            (r->>'id')::UUID AS id,
            sql_weight AS base_score,
            r AS content,
            'sql' AS source,
            idx AS original_rank
        FROM jsonb_array_elements(COALESCE(sql_results, '[]'::JSONB)) WITH ORDINALITY AS a(r, idx)
        WHERE idx <= max_results
    ),
    
    -- Create a CTE for vector results
    vector_data AS (
        SELECT 
            (r->>'id')::UUID AS id,
            vector_weight * (1 - COALESCE((r->>'vdistance')::NUMERIC, 0.5)) AS base_score,
            r AS content,
            'vector' AS source,
            idx AS original_rank
        FROM jsonb_array_elements(COALESCE(vector_results, '[]'::JSONB)) WITH ORDINALITY AS a(r, idx)
        WHERE idx <= max_results
    ),
    
    -- Create a CTE for graph results - assuming graph results have target node IDs
    graph_data AS (
        SELECT 
            (r->>'target_node_id')::UUID AS id,
            graph_weight * (1 - (r->>'path_length')::NUMERIC / 10) AS base_score,
            r AS content,
            'graph' AS source,
            idx AS original_rank
        FROM jsonb_array_elements(COALESCE(graph_results, '[]'::JSONB)) WITH ORDINALITY AS a(r, idx)
        WHERE idx <= max_results
    ),
    
    -- Union all results
    all_results AS (
        SELECT * FROM sql_data
        UNION ALL
        SELECT * FROM vector_data
        UNION ALL
        SELECT * FROM graph_data
    ),
    
    -- Group by ID to combine scores from different sources
    grouped_results AS (
        SELECT 
            id,
            SUM(base_score) AS total_score,
            jsonb_agg(jsonb_build_object('content', content, 'source', source, 'rank', original_rank)) AS all_content,
            STRING_AGG(source, ',') AS sources
        FROM all_results
        GROUP BY id
    )
    
    -- Final output with ranking
    SELECT 
        id,
        total_score AS score,
        all_content AS content,
        sources AS source,
        RANK() OVER (ORDER BY total_score DESC) AS rank
    FROM grouped_results
    ORDER BY score DESC
    LIMIT max_results;
END;
$BODY$;

COMMENT ON FUNCTION p8.merge_search_results IS 
'Merges and scores results from SQL, vector, and graph searches to provide a unified ranking.';