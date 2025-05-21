-- Test file for resource metrics and file upload search functions
-- This file demonstrates the usage of both functions with various scenarios

-- Test 1: Get resource metrics for all users
SELECT * FROM p8.get_resource_metrics(
    p_limit := 10
);

-- Test 2: Get resource metrics for a specific user
SELECT * FROM p8.get_resource_metrics(
    p_user_id := '123e4567-e89b-12d3-a456-426614174000',
    p_limit := 5
);

-- Test 3: Get resource metrics with semantic search
SELECT * FROM p8.get_resource_metrics(
    p_query_text := 'machine learning documentation',
    p_limit := 10
);

-- Test 4: Get resource metrics for specific user with semantic search
SELECT * FROM p8.get_resource_metrics(
    p_user_id := '123e4567-e89b-12d3-a456-426614174000',
    p_query_text := 'API reference guide',
    p_limit := 5
);

-- Test 5: Get all file uploads (most recent)
SELECT * FROM p8.file_upload_search(
    p_limit := 10
);

-- Test 6: Get file uploads for specific user
SELECT * FROM p8.file_upload_search(
    p_user_id := '123e4567-e89b-12d3-a456-426614174000',
    p_limit := 5
);

-- Test 7: Search file uploads by tags
SELECT * FROM p8.file_upload_search(
    p_tags := ARRAY['documentation', 'api'],
    p_limit := 10
);

-- Test 8: Search file uploads with semantic query (searches indexed resources)
SELECT * FROM p8.file_upload_search(
    p_query_text := 'database schema design patterns',
    p_limit := 10
);

-- Test 9: Combined search - user + tags + semantic
SELECT * FROM p8.file_upload_search(
    p_user_id := '123e4567-e89b-12d3-a456-426614174000',
    p_tags := ARRAY['technical'],
    p_query_text := 'performance optimization',
    p_limit := 5
);

-- Example query to show uploads without indexed resources
SELECT
    fu.id,
    fu.filename,
    fu.status,
    CASE
        WHEN fu.resource_id IS NULL THEN 'Not indexed'
        WHEN r.id IS NULL THEN 'Resource ID set but no chunks'
        ELSE 'Indexed with ' || COUNT(r.id) || ' chunks'
    END as indexing_status
FROM public."TusFileUpload" fu
LEFT JOIN p8."Resources" r ON r.resource_id = fu.resource_id
GROUP BY fu.id, fu.filename, fu.status, fu.resource_id, r.id
ORDER BY fu.created_at DESC
LIMIT 20;

-- Example query to show resource coverage
WITH resource_stats AS (
    SELECT
        uri,
        COUNT(DISTINCT ordinal) as chunks,
        COUNT(DISTINCT userid) as user_count,
        MIN(resource_timestamp) as first_indexed,
        MAX(resource_timestamp) as last_updated
    FROM p8."Resources"
    GROUP BY uri
)
SELECT * FROM resource_stats
ORDER BY chunks DESC, last_updated DESC
LIMIT 20;