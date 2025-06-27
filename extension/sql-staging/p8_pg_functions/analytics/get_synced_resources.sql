-- get_synced_resources Function
-- Analyzes synced files and their associated resources based on sync configuration
-- Supports filtering by entity name, user ID, and date range

CREATE OR REPLACE FUNCTION p8.get_synced_resources(
    entity_name TEXT DEFAULT 'p8.Resources',
    user_id UUID DEFAULT NULL,
    since_date TIMESTAMP DEFAULT NULL
)
RETURNS TABLE (
    sync_file_id UUID,
    config_id UUID,
    userid UUID,
    user_name TEXT,
    user_email TEXT,
    remote_path TEXT,
    remote_name TEXT,
    remote_type TEXT,
    remote_size BIGINT,
    s3_uri TEXT,
    sync_status TEXT,
    last_sync_at TIMESTAMP,
    sync_attempts INTEGER,
    error_message TEXT,
    ingested BOOLEAN,
    resource_id UUID,
    target_namespace TEXT,
    target_model_name TEXT,
    resource_count BIGINT,
    resource_chunk_count BIGINT,
    first_resource_created_at TIMESTAMP,
    last_resource_created_at TIMESTAMP,
    resource_categories TEXT[],
    sync_created_at TIMESTAMP,
    sync_updated_at TIMESTAMP,
    config_name TEXT,
    provider_type TEXT
) AS $$
BEGIN
    RETURN QUERY
    WITH sync_config_details AS (
        SELECT 
            sc.id as config_id,
            sc.name as config_name,
            sc.provider_type,
            sc.userid as config_userid,
            -- Extract target information from provider_metadata
            COALESCE(
                sc.provider_metadata->>'target_namespace',
                'p8'
            ) as target_namespace,
            COALESCE(
                sc.provider_metadata->>'target_model_name',
                'Resources'
            ) as target_model_name,
            sc.provider_metadata->>'folder_id' as folder_id,
            sc.provider_metadata->>'access_level' as access_level
        FROM 
            p8."SyncConfig" sc
        WHERE 
            sc.deleted_at IS NULL
            -- Filter by entity name if specified
            AND (
                entity_name IS NULL 
                OR (
                    COALESCE(sc.provider_metadata->>'target_namespace', 'p8') || '.' || 
                    COALESCE(sc.provider_metadata->>'target_model_name', 'Resources') = entity_name
                )
            )
    ),
    sync_file_resources AS (
        SELECT 
            sf.id as sync_file_id,
            sf.config_id,
            sf.userid,
            u.name as user_name,
            u.email as user_email,
            sf.remote_path,
            sf.remote_name,
            sf.remote_type,
            sf.remote_size,
            sf.s3_uri,
            sf.status as sync_status,
            sf.last_sync_at,
            sf.sync_attempts,
            sf.error_message,
            sf.ingested,
            sf.resource_id,
            scd.target_namespace,
            scd.target_model_name,
            scd.config_name,
            scd.provider_type,
            sf.created_at as sync_created_at,
            sf.updated_at as sync_updated_at,
            -- Count resources based on the target table
            CASE 
                WHEN scd.target_model_name = 'Resources' THEN (
                    SELECT COUNT(DISTINCT r.id)
                    FROM p8."Resources" r
                    WHERE (
                        (sf.resource_id IS NOT NULL AND r.id = sf.resource_id)
                        OR (sf.s3_uri IS NOT NULL AND r.uri = sf.s3_uri)
                    )
                    AND r.deleted_at IS NULL
                )
                ELSE 0
            END as resource_count,
            -- Count resource chunks
            CASE 
                WHEN scd.target_model_name = 'Resources' THEN (
                    SELECT COUNT(r.id)
                    FROM p8."Resources" r
                    WHERE (
                        (sf.resource_id IS NOT NULL AND r.id = sf.resource_id)
                        OR (sf.s3_uri IS NOT NULL AND r.uri = sf.s3_uri)
                    )
                    AND r.deleted_at IS NULL
                )
                ELSE 0
            END as resource_chunk_count,
            -- Get first resource creation time
            CASE 
                WHEN scd.target_model_name = 'Resources' THEN (
                    SELECT MIN(r.created_at)
                    FROM p8."Resources" r
                    WHERE (
                        (sf.resource_id IS NOT NULL AND r.id = sf.resource_id)
                        OR (sf.s3_uri IS NOT NULL AND r.uri = sf.s3_uri)
                    )
                    AND r.deleted_at IS NULL
                )
                ELSE NULL
            END as first_resource_created_at,
            -- Get last resource creation time
            CASE 
                WHEN scd.target_model_name = 'Resources' THEN (
                    SELECT MAX(r.created_at)
                    FROM p8."Resources" r
                    WHERE (
                        (sf.resource_id IS NOT NULL AND r.id = sf.resource_id)
                        OR (sf.s3_uri IS NOT NULL AND r.uri = sf.s3_uri)
                    )
                    AND r.deleted_at IS NULL
                )
                ELSE NULL
            END as last_resource_created_at,
            -- Get resource categories
            CASE 
                WHEN scd.target_model_name = 'Resources' THEN (
                    SELECT ARRAY_AGG(DISTINCT r.category) FILTER (WHERE r.category IS NOT NULL)
                    FROM p8."Resources" r
                    WHERE (
                        (sf.resource_id IS NOT NULL AND r.id = sf.resource_id)
                        OR (sf.s3_uri IS NOT NULL AND r.uri = sf.s3_uri)
                    )
                    AND r.deleted_at IS NULL
                )
                ELSE NULL
            END as resource_categories
        FROM 
            p8."SyncFile" sf
        INNER JOIN 
            sync_config_details scd ON sf.config_id = scd.config_id
        LEFT JOIN 
            p8."User" u ON sf.userid = u.id
        WHERE 
            sf.deleted_at IS NULL
            -- Filter by user_id if specified
            AND (user_id IS NULL OR sf.userid = user_id)
            -- Filter by since_date if specified
            AND (since_date IS NULL OR sf.created_at >= since_date)
    )
    SELECT 
        sfr.sync_file_id,
        sfr.config_id,
        sfr.userid,
        sfr.user_name,
        sfr.user_email,
        sfr.remote_path,
        sfr.remote_name,
        sfr.remote_type,
        sfr.remote_size,
        sfr.s3_uri,
        sfr.sync_status,
        sfr.last_sync_at,
        sfr.sync_attempts,
        sfr.error_message,
        sfr.ingested,
        sfr.resource_id,
        sfr.target_namespace,
        sfr.target_model_name,
        sfr.resource_count,
        sfr.resource_chunk_count,
        sfr.first_resource_created_at,
        sfr.last_resource_created_at,
        sfr.resource_categories,
        sfr.sync_created_at,
        sfr.sync_updated_at,
        sfr.config_name,
        sfr.provider_type
    FROM 
        sync_file_resources sfr
    ORDER BY 
        sfr.sync_created_at DESC;
END;
$$ LANGUAGE plpgsql;

-- Grant execute permission to authenticated users (only if role exists)
DO $$ 
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        GRANT EXECUTE ON FUNCTION p8.get_synced_resources(TEXT, UUID, TIMESTAMP) TO authenticated;
    END IF;
END $$;

-- Add helpful comments
COMMENT ON FUNCTION p8.get_synced_resources(TEXT, UUID, TIMESTAMP) IS 
'Analyzes synced files and their associated resources based on sync configuration. 
Parameters:
- entity_name: Target entity in format "namespace.model" (default: "p8.Resources")
- user_id: Filter by specific user ID (optional)
- since_date: Filter files synced since this date (optional)';

-- Create a summary function for aggregated sync statistics
CREATE OR REPLACE FUNCTION p8.get_sync_statistics(
    user_id UUID DEFAULT NULL,
    since_date TIMESTAMP DEFAULT NULL
)
RETURNS TABLE (
    userid UUID,
    user_name TEXT,
    user_email TEXT,
    total_sync_files BIGINT,
    synced_files BIGINT,
    failed_files BIGINT,
    pending_files BIGINT,
    ingested_files BIGINT,
    total_resources_created BIGINT,
    total_resource_chunks BIGINT,
    sync_configs_used BIGINT,
    provider_types TEXT[],
    target_entities TEXT[],
    first_sync_at TIMESTAMP,
    last_sync_at TIMESTAMP,
    avg_sync_attempts NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        sf.userid,
        u.name as user_name,
        u.email as user_email,
        COUNT(DISTINCT sf.id) as total_sync_files,
        COUNT(DISTINCT sf.id) FILTER (WHERE sf.status = 'synced') as synced_files,
        COUNT(DISTINCT sf.id) FILTER (WHERE sf.status = 'failed') as failed_files,
        COUNT(DISTINCT sf.id) FILTER (WHERE sf.status = 'pending') as pending_files,
        COUNT(DISTINCT sf.id) FILTER (WHERE sf.ingested = true) as ingested_files,
        COUNT(DISTINCT r.id) as total_resources_created,
        COUNT(r.id) as total_resource_chunks,
        COUNT(DISTINCT sf.config_id) as sync_configs_used,
        ARRAY_AGG(DISTINCT sc.provider_type) as provider_types,
        ARRAY_AGG(DISTINCT (
            COALESCE(sc.provider_metadata->>'target_namespace', 'p8') || '.' || 
            COALESCE(sc.provider_metadata->>'target_model_name', 'Resources')
        )) as target_entities,
        MIN(sf.created_at) as first_sync_at,
        MAX(sf.last_sync_at) as last_sync_at,
        AVG(sf.sync_attempts) as avg_sync_attempts
    FROM 
        p8."SyncFile" sf
    LEFT JOIN 
        p8."User" u ON sf.userid = u.id
    LEFT JOIN 
        p8."SyncConfig" sc ON sf.config_id = sc.id
    LEFT JOIN 
        p8."Resources" r ON (
            (sf.resource_id IS NOT NULL AND r.id = sf.resource_id)
            OR (sf.s3_uri IS NOT NULL AND r.uri = sf.s3_uri)
        )
    WHERE 
        sf.deleted_at IS NULL
        AND (sc.deleted_at IS NULL OR sc.deleted_at > CURRENT_TIMESTAMP)
        AND (r.deleted_at IS NULL OR r.deleted_at > CURRENT_TIMESTAMP)
        AND (user_id IS NULL OR sf.userid = user_id)
        AND (since_date IS NULL OR sf.created_at >= since_date)
    GROUP BY 
        sf.userid, u.name, u.email
    ORDER BY 
        total_sync_files DESC;
END;
$$ LANGUAGE plpgsql;

-- Grant execute permission to authenticated users (only if role exists)
DO $$ 
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        GRANT EXECUTE ON FUNCTION p8.get_sync_statistics(UUID, TIMESTAMP) TO authenticated;
    END IF;
END $$;

-- Add helpful comments
COMMENT ON FUNCTION p8.get_sync_statistics(UUID, TIMESTAMP) IS 
'Provides aggregated statistics for synced files and resources.
Parameters:
- user_id: Filter by specific user ID (optional)
- since_date: Filter files synced since this date (optional)';