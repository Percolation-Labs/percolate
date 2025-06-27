-- TusFileUpload Analytics View
-- Shows upload status and associated resource chunk counts per user
-- This view aggregates TUS upload data with resource creation status

CREATE OR REPLACE VIEW p8.tus_upload_analytics AS
WITH upload_resource_stats AS (
    SELECT 
        t.id as upload_id,
        t.userid,
        u.name as user_name,
        u.email as user_email,
        t.filename,
        t.content_type,
        t.total_size,
        t.uploaded_size,
        t.status as upload_status,
        t.s3_uri,
        t.resource_id,
        t.created_at as upload_created_at,
        t.updated_at as upload_updated_at,
        t.project_name,
        t.tags,
        -- Calculate upload progress percentage
        CASE 
            WHEN t.total_size > 0 THEN 
                ROUND((t.uploaded_size::numeric / t.total_size::numeric) * 100, 2)
            ELSE 0 
        END as upload_progress_pct,
        -- Count resources linked to this upload
        COUNT(DISTINCT r.id) as resource_count,
        -- Count resource chunks (by ordinal)
        COUNT(r.id) as resource_chunk_count,
        -- Get resource creation status
        CASE 
            WHEN t.s3_uri IS NULL THEN 'no_upload_uri'
            WHEN t.resource_id IS NULL AND COUNT(r.id) = 0 THEN 'no_resources_created'
            WHEN COUNT(r.id) > 0 THEN 'resources_created'
            ELSE 'resource_creation_pending'
        END as resource_status,
        -- Get first and last resource creation times
        MIN(r.created_at) as first_resource_created_at,
        MAX(r.created_at) as last_resource_created_at,
        -- Get resource categories
        ARRAY_AGG(DISTINCT r.category) FILTER (WHERE r.category IS NOT NULL) as resource_categories
    FROM 
        public."TusFileUpload" t
    LEFT JOIN 
        p8."User" u ON t.userid = u.id
    LEFT JOIN 
        p8."Resources" r ON (
            -- Join on resource_id if available
            (t.resource_id IS NOT NULL AND r.id = t.resource_id)
            OR 
            -- Also join on S3 URI match in case resource_id wasn't updated
            (t.s3_uri IS NOT NULL AND r.uri = t.s3_uri)
        )
    WHERE 
        -- Note: In this system, both TusFileUpload and Resources have deleted_at set immediately
        -- So we include all records regardless of deleted_at status
        1=1
    GROUP BY 
        t.id, t.userid, u.name, u.email, t.filename, t.content_type, t.total_size, 
        t.uploaded_size, t.status, t.s3_uri, t.resource_id, 
        t.created_at, t.updated_at, t.project_name, t.tags
),
user_aggregates AS (
    SELECT 
        userid,
        COUNT(DISTINCT upload_id) as total_uploads,
        COUNT(DISTINCT upload_id) FILTER (WHERE upload_status = 'completed') as completed_uploads,
        COUNT(DISTINCT upload_id) FILTER (WHERE upload_status = 'failed') as failed_uploads,
        COUNT(DISTINCT upload_id) FILTER (WHERE upload_status IN ('initiated', 'in_progress')) as in_progress_uploads,
        COUNT(DISTINCT upload_id) FILTER (WHERE resource_status = 'resources_created') as uploads_with_resources,
        COUNT(DISTINCT upload_id) FILTER (WHERE resource_status = 'resource_creation_failed') as uploads_without_resources,
        SUM(resource_chunk_count) as total_resource_chunks,
        SUM(total_size) as total_bytes_uploaded,
        AVG(upload_progress_pct) as avg_upload_progress,
        MIN(upload_created_at) as first_upload_at,
        MAX(upload_created_at) as last_upload_at
    FROM 
        upload_resource_stats
    WHERE 
        userid IS NOT NULL
    GROUP BY 
        userid
)
SELECT 
    urs.*,
    ua.total_uploads as user_total_uploads,
    ua.completed_uploads as user_completed_uploads,
    ua.failed_uploads as user_failed_uploads,
    ua.in_progress_uploads as user_in_progress_uploads,
    ua.uploads_with_resources as user_uploads_with_resources,
    ua.uploads_without_resources as user_uploads_without_resources,
    ua.total_resource_chunks as user_total_resource_chunks,
    -- Calculate time to resource creation
    CASE 
        WHEN urs.first_resource_created_at IS NOT NULL THEN
            EXTRACT(EPOCH FROM (urs.first_resource_created_at - urs.upload_created_at))
        ELSE NULL
    END as seconds_to_first_resource,
    -- Calculate upload duration
    EXTRACT(EPOCH FROM (urs.upload_updated_at - urs.upload_created_at)) as upload_duration_seconds
FROM 
    upload_resource_stats urs
LEFT JOIN 
    user_aggregates ua ON urs.userid = ua.userid
ORDER BY 
    urs.upload_created_at DESC;

-- Create index for better query performance
CREATE INDEX IF NOT EXISTS idx_tus_upload_analytics_userid 
    ON public."TusFileUpload" (userid);

CREATE INDEX IF NOT EXISTS idx_tus_upload_analytics_resource_id 
    ON public."TusFileUpload" (resource_id) 
    WHERE resource_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_tus_upload_analytics_s3_uri 
    ON public."TusFileUpload" (s3_uri) 
    WHERE s3_uri IS NOT NULL;

-- Grant appropriate permissions (only if role exists)
DO $$ 
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        GRANT SELECT ON p8.tus_upload_analytics TO authenticated;
    END IF;
END $$;

-- Add helpful comments
COMMENT ON VIEW p8.tus_upload_analytics IS 'Analytics view for TUS file uploads showing upload status, progress, and associated resource creation metrics';
COMMENT ON COLUMN p8.tus_upload_analytics.upload_progress_pct IS 'Upload progress as percentage (0-100)';
COMMENT ON COLUMN p8.tus_upload_analytics.resource_status IS 'Status of resource creation: no_upload_uri, no_resources_created, resources_created, or resource_creation_pending';
COMMENT ON COLUMN p8.tus_upload_analytics.resource_chunk_count IS 'Total number of resource chunks created from this upload';
COMMENT ON COLUMN p8.tus_upload_analytics.seconds_to_first_resource IS 'Time in seconds from upload creation to first resource creation';
COMMENT ON COLUMN p8.tus_upload_analytics.user_total_uploads IS 'Total number of uploads by this user';
COMMENT ON COLUMN p8.tus_upload_analytics.user_uploads_with_resources IS 'Number of uploads by this user that successfully created resources';