-- Check available resources
SELECT 
    uri,
    name,
    category,
    userid,
    COUNT(*) as chunk_count,
    MIN(ordinal) as min_ordinal,
    MAX(ordinal) as max_ordinal,
    resource_timestamp::date as date
FROM p8."Resources"
GROUP BY uri, name, category, userid, resource_timestamp::date
ORDER BY resource_timestamp DESC
LIMIT 10;

-- Check available file uploads
SELECT 
    id,
    filename,
    content_type,
    total_size,
    status,
    user_id,
    tags,
    resource_id,
    created_at
FROM public."TusFileUpload"
ORDER BY created_at DESC
LIMIT 10;

-- Check if any resources have embeddings
SELECT 
    COUNT(*) as total_resources,
    COUNT(content_embedding) as resources_with_embeddings
FROM p8."Resources";

-- Check resource-upload associations
SELECT 
    t.filename,
    t.status,
    t.resource_id,
    COUNT(r.id) as resource_chunks
FROM public."TusFileUpload" t
LEFT JOIN p8."Resources" r ON r.resource_id = t.resource_id
WHERE t.resource_id IS NOT NULL
GROUP BY t.filename, t.status, t.resource_id
LIMIT 10;