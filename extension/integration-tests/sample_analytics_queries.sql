-- Sample Analytics Queries for Upload and Sync Analysis

-- ============================================
-- TUS UPLOAD ANALYTICS QUERIES
-- ============================================

-- 1. Get all uploads with their resource creation status
SELECT 
    upload_id,
    user_name,
    user_email,
    filename,
    upload_status,
    resource_status,
    resource_chunk_count,
    upload_progress_pct,
    upload_created_at
FROM 
    p8.tus_upload_analytics
WHERE 
    upload_created_at >= CURRENT_DATE - INTERVAL '7 days'
ORDER BY 
    upload_created_at DESC
LIMIT 100;

-- 2. User upload summary - success rates and resource creation
SELECT 
    userid,
    user_name,
    user_email,
    user_total_uploads,
    user_completed_uploads,
    user_failed_uploads,
    user_uploads_with_resources,
    user_uploads_without_resources,
    user_total_resource_chunks,
    ROUND(
        (user_uploads_with_resources::numeric / NULLIF(user_completed_uploads, 0)) * 100, 
        2
    ) as resource_creation_success_rate
FROM 
    p8.tus_upload_analytics
WHERE 
    userid IS NOT NULL
GROUP BY 
    userid, user_name, user_email, user_total_uploads, user_completed_uploads, 
    user_failed_uploads, user_uploads_with_resources, user_uploads_without_resources,
    user_total_resource_chunks
ORDER BY 
    user_total_uploads DESC;

-- 3. Failed uploads that need attention
SELECT 
    upload_id,
    user_name,
    user_email,
    filename,
    upload_status,
    resource_status,
    upload_progress_pct,
    upload_created_at,
    upload_duration_seconds
FROM 
    p8.tus_upload_analytics
WHERE 
    upload_status = 'failed' 
    OR resource_status = 'resource_creation_failed'
ORDER BY 
    upload_created_at DESC;

-- 4. Large file uploads analysis
SELECT 
    upload_id,
    user_name,
    filename,
    pg_size_pretty(total_size) as file_size,
    upload_progress_pct,
    upload_status,
    resource_chunk_count,
    ROUND(seconds_to_first_resource::numeric / 60, 2) as minutes_to_first_resource,
    upload_created_at
FROM 
    p8.tus_upload_analytics
WHERE 
    total_size > 10 * 1024 * 1024  -- Files larger than 10MB
ORDER BY 
    total_size DESC;

-- 5. Upload performance metrics by project
SELECT 
    project_name,
    COUNT(DISTINCT upload_id) as total_uploads,
    COUNT(DISTINCT upload_id) FILTER (WHERE upload_status = 'completed') as completed_uploads,
    COUNT(DISTINCT upload_id) FILTER (WHERE resource_status = 'resources_created') as successful_resources,
    AVG(upload_duration_seconds) as avg_upload_duration_seconds,
    AVG(seconds_to_first_resource) as avg_seconds_to_resource,
    SUM(resource_chunk_count) as total_chunks_created
FROM 
    p8.tus_upload_analytics
WHERE 
    project_name IS NOT NULL
GROUP BY 
    project_name
ORDER BY 
    total_uploads DESC;

-- ============================================
-- SYNC FILE ANALYTICS QUERIES
-- ============================================

-- 6. Get all synced resources for a specific user
SELECT * FROM p8.get_synced_resources(
    entity_name := 'p8.Resources',
    user_id := NULL,  -- Replace with actual user UUID
    since_date := CURRENT_DATE - INTERVAL '30 days'
);

-- 7. Sync statistics per user
SELECT * FROM p8.get_sync_statistics(
    user_id := NULL,
    since_date := CURRENT_DATE - INTERVAL '30 days'
)
ORDER BY total_sync_files DESC;

-- 8. Failed sync files that need retry
SELECT 
    sync_file_id,
    user_name,
    remote_name,
    sync_status,
    sync_attempts,
    error_message,
    last_sync_at,
    config_name,
    provider_type
FROM 
    p8.get_synced_resources()
WHERE 
    sync_status = 'failed'
    AND sync_attempts < 5
ORDER BY 
    last_sync_at DESC;

-- 9. Sync performance by provider type
SELECT 
    provider_type,
    COUNT(DISTINCT sync_file_id) as total_files,
    COUNT(DISTINCT sync_file_id) FILTER (WHERE sync_status = 'synced') as synced_files,
    COUNT(DISTINCT sync_file_id) FILTER (WHERE ingested = true) as ingested_files,
    SUM(resource_chunk_count) as total_chunks_created,
    AVG(sync_attempts) as avg_sync_attempts,
    COUNT(DISTINCT userid) as unique_users
FROM 
    p8.get_synced_resources()
GROUP BY 
    provider_type
ORDER BY 
    total_files DESC;

-- 10. Resource creation success rate by sync config
SELECT 
    config_id,
    config_name,
    provider_type,
    target_namespace || '.' || target_model_name as target_entity,
    COUNT(DISTINCT sync_file_id) as total_files,
    COUNT(DISTINCT sync_file_id) FILTER (WHERE resource_count > 0) as files_with_resources,
    SUM(resource_chunk_count) as total_chunks,
    ROUND(
        (COUNT(DISTINCT sync_file_id) FILTER (WHERE resource_count > 0)::numeric / 
         NULLIF(COUNT(DISTINCT sync_file_id), 0)) * 100, 
        2
    ) as resource_creation_rate
FROM 
    p8.get_synced_resources()
WHERE 
    sync_status = 'synced'
GROUP BY 
    config_id, config_name, provider_type, target_namespace, target_model_name
ORDER BY 
    total_files DESC;

-- ============================================
-- COMBINED ANALYTICS QUERIES
-- ============================================

-- 11. Compare TUS uploads vs Sync files resource creation
WITH tus_stats AS (
    SELECT 
        'TUS Upload' as source_type,
        COUNT(DISTINCT upload_id) as total_files,
        COUNT(DISTINCT upload_id) FILTER (WHERE resource_status = 'resources_created') as files_with_resources,
        SUM(resource_chunk_count) as total_chunks,
        AVG(seconds_to_first_resource) as avg_seconds_to_resource
    FROM 
        p8.tus_upload_analytics
    WHERE 
        upload_status = 'completed'
),
sync_stats AS (
    SELECT 
        'Sync File' as source_type,
        COUNT(DISTINCT sync_file_id) as total_files,
        COUNT(DISTINCT sync_file_id) FILTER (WHERE resource_count > 0) as files_with_resources,
        SUM(resource_chunk_count) as total_chunks,
        NULL as avg_seconds_to_resource
    FROM 
        p8.get_synced_resources()
    WHERE 
        sync_status = 'synced'
)
SELECT * FROM tus_stats
UNION ALL
SELECT * FROM sync_stats;

-- 12. Daily upload and sync activity
WITH daily_uploads AS (
    SELECT 
        DATE(upload_created_at) as activity_date,
        'TUS Upload' as activity_type,
        COUNT(DISTINCT upload_id) as file_count,
        SUM(resource_chunk_count) as chunk_count
    FROM 
        p8.tus_upload_analytics
    GROUP BY 
        DATE(upload_created_at)
),
daily_syncs AS (
    SELECT 
        DATE(sync_created_at) as activity_date,
        'Sync File' as activity_type,
        COUNT(DISTINCT sync_file_id) as file_count,
        SUM(resource_chunk_count) as chunk_count
    FROM 
        p8.get_synced_resources()
    GROUP BY 
        DATE(sync_created_at)
)
SELECT 
    activity_date,
    activity_type,
    file_count,
    chunk_count
FROM daily_uploads
UNION ALL
SELECT * FROM daily_syncs
ORDER BY 
    activity_date DESC, 
    activity_type;