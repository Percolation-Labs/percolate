DROP FUNCTION IF EXISTS p8.parallel_search;

CREATE OR REPLACE FUNCTION p8.parallel_search(
    query TEXT,
    entity_types TEXT[] DEFAULT NULL,
    user_id UUID DEFAULT NULL,
    max_results INTEGER DEFAULT 10,
    include_graph BOOLEAN DEFAULT TRUE,
    include_execution_stats BOOLEAN DEFAULT FALSE
)
RETURNS TABLE(
    entity_type TEXT,
    id UUID,
    score NUMERIC,
    content JSONB,
    rank INTEGER,
    execution_stats JSONB
) 
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL SAFE
ROWS 1000
AS $BODY$
DECLARE
    entity_type TEXT;
    default_entities TEXT[];
    result_data JSONB := '[]'::JSONB;
    execution_stats_data JSONB := '{}'::JSONB;
BEGIN
    /*
    A high-level parallel search across multiple entity types with unified ranking.
    Executes SQL queries, vector searches, and graph traversals in parallel.
    
    Example usage:
    -- Search across all default entities:
    SELECT * FROM p8.parallel_search('customer retention strategies');
    
    -- Search specific entities:
    SELECT * FROM p8.parallel_search('favorite color', ARRAY['p8.UserFact'], 'e9c56a28-1d09-5253-af36-4b9d812f6bfa');
    
    -- Search with execution statistics:
    SELECT * FROM p8.parallel_search('database performance', NULL, NULL, 10, true, true);
    */
    
    -- If no entity types provided, use default set of searchable entities
    IF entity_types IS NULL THEN
        SELECT ARRAY_AGG(entity_name) INTO default_entities
        FROM p8."ModelField"
        WHERE embedding_provider IS NOT NULL
        GROUP BY entity_name
        LIMIT 10; -- Limit to top 10 entity types for performance
        
        entity_types := default_entities;
    END IF;
    
    -- Process each entity type in parallel
    FOR entity_type IN SELECT unnest(entity_types) LOOP
        -- Use a separate background worker for each entity type
        PERFORM pg_background_send('
            SELECT pg_notify(
                ''parallel_search_result'', 
                json_build_object(
                    ''entity_type'', $1,
                    ''results'', (
                        SELECT json_build_object(
                            ''query_results'', q.*,
                            ''merged_results'', (
                                SELECT json_agg(m.*)
                                FROM p8.merge_search_results(
                                    q.relational_result,
                                    q.vector_result,
                                    CASE WHEN $2 THEN q.graph_result ELSE NULL END,
                                    0.4, 0.4, 0.2, $3
                                ) m
                            )
                        )
                        FROM p8.query_entity_fast($4, $1, $5) q
                    )
                )::text
            )', 
            ARRAY[entity_type, include_graph, max_results, query, user_id]
        );
    END LOOP;
    
    -- Collect results from all background workers
    DECLARE
        notification_payload JSONB;
        all_results JSONB := '[]'::JSONB;
        wait_count INTEGER := 0;
        max_wait INTEGER := 300; -- Maximum wait iterations (30 seconds at 100ms intervals)
        entity_count INTEGER := array_length(entity_types, 1);
        processed_count INTEGER := 0;
    BEGIN
        -- Listen for notifications from background workers
        LISTEN parallel_search_result;
        
        -- Wait for results or timeout
        WHILE processed_count < entity_count AND wait_count < max_wait LOOP
            -- Check for notifications
            FOR notification_payload IN
                SELECT payload::jsonb
                FROM pg_notification_queue_usage 
                WHERE channel = 'parallel_search_result'
            LOOP
                -- Process notification
                processed_count := processed_count + 1;
                
                -- Extract entity type and results
                DECLARE
                    current_entity TEXT := notification_payload->>'entity_type';
                    entity_results JSONB := notification_payload->'results'->'merged_results';
                    query_execution_stats JSONB := jsonb_build_object(
                        current_entity, 
                        notification_payload->'results'->'query_results'->'execution_time_ms'
                    );
                BEGIN
                    -- Add entity type to each result
                    SELECT jsonb_agg(
                        jsonb_set(r, '{entity_type}', to_jsonb(current_entity))
                    )
                    FROM jsonb_array_elements(entity_results) r
                    INTO entity_results;
                    
                    -- Add to overall results
                    all_results := all_results || COALESCE(entity_results, '[]'::JSONB);
                    
                    -- Add execution stats if requested
                    IF include_execution_stats THEN
                        execution_stats_data := execution_stats_data || query_execution_stats;
                    END IF;
                END;
            END LOOP;
            
            -- If not all entities processed, wait a bit
            IF processed_count < entity_count THEN
                PERFORM pg_sleep(0.1);
                wait_count := wait_count + 1;
            END IF;
        END LOOP;
        
        -- Stop listening
        UNLISTEN parallel_search_result;
        
        -- Re-rank all results across entity types
        SELECT jsonb_agg(r ORDER BY (r->>'score')::NUMERIC DESC)
        FROM jsonb_array_elements(all_results) r
        INTO result_data;
    END;
    
    -- Return final results
    RETURN QUERY 
    SELECT 
        (r->>'entity_type')::TEXT AS entity_type,
        (r->>'id')::UUID AS id,
        (r->>'score')::NUMERIC AS score,
        (r->>'content')::JSONB AS content,
        ROW_NUMBER() OVER (ORDER BY (r->>'score')::NUMERIC DESC) AS rank,
        CASE WHEN include_execution_stats THEN execution_stats_data ELSE NULL END AS execution_stats
    FROM jsonb_array_elements(COALESCE(result_data, '[]'::JSONB)) r
    ORDER BY score DESC
    LIMIT max_results;
END;
$BODY$;

COMMENT ON FUNCTION p8.parallel_search IS 
'High-level search function that executes parallel searches across multiple entity types, 
combining SQL, vector, and graph search approaches for comprehensive results.';