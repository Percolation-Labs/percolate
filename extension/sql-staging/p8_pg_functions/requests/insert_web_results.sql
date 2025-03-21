DROP FUNCTION IF EXISTS p8.insert_web_search_results;

CREATE OR REPLACE FUNCTION p8.insert_web_search_results(
    query TEXT,
    session_id UUID DEFAULT p8.json_to_uuid(jsonb_build_object('proxy_uri', 'http://percolate-api:5008')::JSONB),
    api_endpoint TEXT DEFAULT 'https://api.tavily.com/search',
    search_limit INT DEFAULT 5
) RETURNS VOID AS $$
DECLARE
    result RECORD;
    resource_id UUID;
    task_resource_id UUID;
BEGIN
    -- Example usage:
    -- SELECT p8.insert_web_search_results('latest tech news');
    
    -- Loop through search results
    FOR result IN 
        SELECT * FROM p8.run_web_search(query, search_limit, TRUE)
    LOOP
        -- Generate deterministic resource ID
        SELECT p8.json_to_uuid(jsonb_build_object('uri', result.url)::JSONB) INTO resource_id;
        
        -- Upsert into Resources table
        INSERT INTO p8."Resources" (id, name, category, content, summary, ordinal, uri, metadata, graph_paths)
        VALUES (
            resource_id,
            result.title,
            'web', -- Default category
            result.content,
            result.summary,
            0,
            result.url,
            jsonb_build_object('score', result.score, 'images', result.images),
            NULL
        )
        ON CONFLICT (id) DO UPDATE SET
            name = EXCLUDED.name,
            content = EXCLUDED.content,
            summary = EXCLUDED.summary,
            metadata = EXCLUDED.metadata;
        
        -- Generate deterministic TaskResource ID
        SELECT p8.json_to_uuid(jsonb_build_object('session_id', session_id, 'resource_id', resource_id)::JSONB) INTO task_resource_id;
        
        -- Insert into TaskResource table (ignore conflicts)
        INSERT INTO p8."TaskResource" (id, resource_id, session_id)
        VALUES (task_resource_id, resource_id, session_id)
        ON CONFLICT DO NOTHING;
    END LOOP;
END;
$$ LANGUAGE plpgsql;