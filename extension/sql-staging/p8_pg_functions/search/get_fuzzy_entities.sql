DROP FUNCTION IF EXISTS p8.get_fuzzy_entities;

CREATE OR REPLACE FUNCTION p8.get_fuzzy_entities(
    search_terms TEXT[],
    similarity_threshold REAL DEFAULT 0.5,
    userid TEXT DEFAULT NULL,
    max_matches_per_term INT DEFAULT 5
)
RETURNS JSONB
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    unique_keys TEXT[];
    result JSONB;
BEGIN
    /*
    Optimized function to fuzzy match multiple search terms and return entities that match
    
    1. Function performs fuzzy matching on multiple search terms and returns the expected entities.
    2. Default threshold of 0.5 is appropriate because:
        - At 0.5, it matches exact terms and very close variations
        - For "Agent" search, it matches both "agent" and "p8.Agent" (scores 1.0 and 0.67)
        - For "Resource" search, it matches "resource_id" (0.75) and "p8.Resources" (0.57)
        - It filters out weak matches like "resource_timestamp" (0.47)
    3. Threshold behavior:
        - 0.3-0.4: Too permissive, includes weak matches like "resource_timestamp"
        - 0.5: Good balance (current default)
        - 0.6: More restrictive, drops "p8.Resources"
        - 0.7: Very restrictive, only matches "agent" and "resource_id"
    4. Performance characteristics:
        - Uses single optimized query with CROSS JOIN
        - Limits matches per term (default 5)
        - Deduplicates results before passing to get_entities
        - Properly handles case-insensitive matching

    Parameters:
    - search_terms: Array of strings to search for
    - similarity_threshold: Minimum similarity score (0.0-1.0) to consider a match (default: 0.5)
    - userid: Optional user ID for filtering results (deprecated, will be removed)
    - max_matches_per_term: Maximum number of matches to return per search term (default: 5)
    
    Example usage:
    -- Search for multiple terms (uses default threshold 0.5)
    SELECT p8.get_fuzzy_entities(ARRAY['customer', 'order', 'product']);
    
    -- Search with custom threshold
    SELECT p8.get_fuzzy_entities(ARRAY['customer', 'order'], 0.6);
    
    -- Search with user filter (deprecated, will be removed)
    SELECT p8.get_fuzzy_entities(ARRAY['customer', 'order'], 0.6, 'user123');
    
    -- Search with all parameters
    SELECT p8.get_fuzzy_entities(ARRAY['customer', 'order'], 0.7, 'user123', 10);
    
    Returns:
    {
        "search_metadata": {
            "search_terms": ["customer", "order"],
            "similarity_threshold": 0.5,
            "max_matches_per_term": 5,
            "matched_keys_count": 4,
            "matched_keys": ["Customer", "CustomerOrder", "Order", "OrderItem"]
        },
        "entities": {
            "Customer": {...},
            "Order": {...},
            ...
        }
    }
    */
    
    -- Ensure pg_trgm extension is available
    --CREATE EXTENSION IF NOT EXISTS pg_trgm;
    
    -- Get all fuzzy matches in a single optimized query
    WITH all_matches AS (
        SELECT DISTINCT
            json_data->>'key' AS key,
            search_term,
            similarity(json_data->>'key', search_term) AS similarity_score,
            ROW_NUMBER() OVER (PARTITION BY search_term ORDER BY similarity(json_data->>'key', search_term) DESC) as rank
        FROM (
            SELECT id, properties::json AS json_data
            FROM percolate._ag_label_vertex
        ) vertices
        CROSS JOIN unnest(search_terms) AS search_term
        WHERE similarity(json_data->>'key', search_term) > similarity_threshold
    ),
    ranked_matches AS (
        SELECT key
        FROM all_matches
        WHERE rank <= max_matches_per_term
    )
    SELECT ARRAY_AGG(DISTINCT key)
    INTO unique_keys
    FROM ranked_matches;
    
    -- If we have matched keys, get the entities
    IF unique_keys IS NOT NULL AND array_length(unique_keys, 1) > 0 THEN
        -- Call get_entities with the matched keys
        result := p8.get_entities(unique_keys, userid);
    ELSE
        -- Return empty result if no matches found
        result := '{}'::JSONB;
    END IF;
    
    -- Add metadata about the search
    result := jsonb_build_object(
        'search_metadata', jsonb_build_object(
            'search_terms', search_terms,
            'similarity_threshold', similarity_threshold,
            'max_matches_per_term', max_matches_per_term,
            'matched_keys_count', COALESCE(array_length(unique_keys, 1), 0),
            'matched_keys', unique_keys
        ),
        'entities', result
    );
    
    RETURN result;
END;
$BODY$;

-- Grant execute permission to public
GRANT EXECUTE ON FUNCTION p8.get_fuzzy_entities(TEXT[], REAL, TEXT, INT) TO public;

-- Add comment for documentation
COMMENT ON FUNCTION p8.get_fuzzy_entities IS 'Optimized fuzzy match for multiple search terms. Returns entities that match any of the provided search terms with a similarity score above the threshold. Uses a single query for efficiency.';

-- Create an index to improve fuzzy matching performance if it doesn't exist
-- Note: This should be run once on the actual database, not in the function
-- CREATE INDEX IF NOT EXISTS idx_vertex_key_trgm ON percolate._ag_label_vertex USING gin ((properties::json->>'key') gin_trgm_ops);