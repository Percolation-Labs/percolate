-- Drop existing functions to ensure idempotency
DROP FUNCTION IF EXISTS p8.get_resource_metrics;
DROP FUNCTION IF EXISTS p8.file_upload_search;

-- Resource metrics function with optional semantic search
CREATE OR REPLACE FUNCTION p8.get_resource_metrics(
    p_user_id TEXT DEFAULT NULL,
    p_query_text TEXT DEFAULT NULL,
    p_limit INT DEFAULT 20
) RETURNS TABLE (
    uri TEXT,
    resource_name TEXT,
    chunk_count BIGINT,
    total_chunk_size BIGINT,
    avg_chunk_size NUMERIC,
    max_date TIMESTAMP WITH TIME ZONE,
    categories TEXT[],
    semantic_score FLOAT,
    user_id TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    query_embedding VECTOR;
BEGIN
    -- If query_text is provided, perform semantic search on resources using embeddings
    IF p_query_text IS NOT NULL THEN
        -- Calculate embedding once and store it
        query_embedding := p8.get_embedding_for_text(p_query_text);
        
        -- Use CTE for semantic search results
        RETURN QUERY
        WITH semantic_results AS (
            SELECT
                r.uri,
                r.name,
                r.category,
                r.userid,
                -- Use the pre-calculated embedding
                1 - (MIN(e.embedding_vector <=> query_embedding)) AS score
            FROM p8."Resources" r
            JOIN p8_embeddings."p8_Resources_embeddings" e ON e.source_record_id = r.id
            WHERE 
                (p_user_id IS NULL OR r.userid::TEXT = p_user_id)
            GROUP BY r.uri, r.name, r.category, r.userid
        )
        SELECT
            sr.uri,
            MAX(sr.name)::TEXT as resource_name,
            COUNT(r.id) as chunk_count,
            SUM(LENGTH(r.content)) as total_chunk_size,
            AVG(LENGTH(r.content))::NUMERIC as avg_chunk_size,
            MAX(r.resource_timestamp)::timestamp with time zone as max_date,
            ARRAY_AGG(DISTINCT sr.category) as categories,
            MAX(sr.score)::FLOAT as semantic_score,
            sr.userid::TEXT as user_id
        FROM semantic_results sr
        JOIN p8."Resources" r ON r.uri = sr.uri AND r.userid = sr.userid
        GROUP BY sr.uri, sr.userid
        ORDER BY semantic_score DESC, chunk_count DESC
        LIMIT p_limit;
        
    ELSE
        -- Standard metrics query without semantic search
        RETURN QUERY
        SELECT
            r.uri,
            MAX(r.name)::TEXT as resource_name,
            COUNT(r.id) as chunk_count,
            SUM(LENGTH(r.content)) as total_chunk_size,
            AVG(LENGTH(r.content))::NUMERIC as avg_chunk_size,
            MAX(r.resource_timestamp)::timestamp with time zone as max_date,
            ARRAY_AGG(DISTINCT r.category) as categories,
            NULL::FLOAT as semantic_score,
            r.userid::TEXT as user_id
        FROM p8."Resources" r
        WHERE 
            p_user_id IS NULL OR r.userid::TEXT = p_user_id
        GROUP BY r.uri, r.userid
        ORDER BY max_date DESC, chunk_count DESC
        LIMIT p_limit;
    END IF;
END;
$$;

-- File upload search function with optional semantic search
CREATE OR REPLACE FUNCTION p8.file_upload_search(
    p_user_id TEXT DEFAULT NULL,
    p_query_text TEXT DEFAULT NULL,
    p_tags TEXT[] DEFAULT NULL,
    p_limit INT DEFAULT 20
) RETURNS TABLE (
    upload_id TEXT,
    filename TEXT,
    content_type TEXT,
    total_size BIGINT,
    uploaded_size BIGINT,
    status TEXT,
    created_at TIMESTAMP WITH TIME ZONE,
    updated_at TIMESTAMP WITH TIME ZONE,
    s3_uri TEXT,
    tags TEXT[],
    resource_id TEXT,
    -- Resource metrics when available
    resource_uri TEXT,
    resource_name TEXT,
    chunk_count BIGINT,
    resource_size BIGINT,
    indexed_at TIMESTAMP WITH TIME ZONE,
    semantic_score FLOAT
)
LANGUAGE plpgsql
AS $$
DECLARE
    query_embedding VECTOR;
BEGIN
    -- If query_text is provided, prioritize semantic search on resources
    IF p_query_text IS NOT NULL THEN
        -- Calculate embedding once and store it
        query_embedding := p8.get_embedding_for_text(p_query_text);
        
        -- Use CTE for semantic search results
        RETURN QUERY
        WITH semantic_matches AS (
            SELECT
                r.uri,
                MAX(r.name) as name,
                COUNT(DISTINCT r.id) as chunk_count,
                SUM(LENGTH(r.content)) as resource_size,
                MAX(r.resource_timestamp) as indexed_at,
                1 - (MIN(e.embedding_vector <=> query_embedding)) AS score
            FROM p8."Resources" r
            JOIN p8_embeddings."p8_Resources_embeddings" e ON e.source_record_id = r.id
            WHERE 
                (p_user_id IS NULL OR r.userid::TEXT = p_user_id)
            GROUP BY r.uri
            HAVING (1 - (MIN(e.embedding_vector <=> query_embedding))) > 0.0
        )
        SELECT
            t.id::TEXT as upload_id,
            t.filename,
            t.content_type,
            t.total_size::BIGINT,
            t.uploaded_size::BIGINT,
            t.status,
            t.created_at::timestamp with time zone,
            t.updated_at::timestamp with time zone,
            t.s3_uri,
            t.tags,
            t.resource_id::TEXT,
            -- Resource info from semantic search
            sm.uri as resource_uri,
            sm.name::TEXT as resource_name,
            sm.chunk_count,
            sm.resource_size,
            sm.indexed_at::timestamp with time zone,
            sm.score::FLOAT as semantic_score
        FROM public."TusFileUpload" t
        INNER JOIN semantic_matches sm ON sm.uri = t.s3_uri
        WHERE
            (p_user_id IS NULL OR t.user_id::TEXT = p_user_id)
            AND (p_tags IS NULL OR t.tags && p_tags)  -- Array overlap check for tags
        ORDER BY sm.score DESC, t.updated_at DESC
        LIMIT p_limit;
        
    ELSE
        -- Standard search without semantic component
        -- Start with uploads and optionally join resources
        RETURN QUERY
        SELECT
            t.id::TEXT as upload_id,
            t.filename,
            t.content_type,
            t.total_size::BIGINT,
            t.uploaded_size::BIGINT,
            t.status,
            t.created_at::timestamp with time zone,
            t.updated_at::timestamp with time zone,
            t.s3_uri,
            t.tags,
            t.resource_id::TEXT,
            -- Resource metrics if available
            r_agg.uri as resource_uri,
            r_agg.name::TEXT as resource_name,
            r_agg.chunk_count,
            r_agg.resource_size,
            r_agg.indexed_at::timestamp with time zone,
            NULL::FLOAT as semantic_score
        FROM public."TusFileUpload" t
        LEFT JOIN LATERAL (
            SELECT
                r.uri,
                MAX(r.name) as name,
                COUNT(*) as chunk_count,
                SUM(LENGTH(r.content)) as resource_size,
                MAX(r.resource_timestamp)::timestamp with time zone as indexed_at
            FROM p8."Resources" r
            WHERE r.uri = t.s3_uri
            GROUP BY r.uri
        ) r_agg ON true
        WHERE
            (p_user_id IS NULL OR t.user_id::TEXT = p_user_id)
            AND (p_tags IS NULL OR t.tags && p_tags)  -- Array overlap check for tags
        ORDER BY t.updated_at DESC
        LIMIT p_limit;
    END IF;
END;
$$;

-- Suggested indexes for better performance (commented out)
-- CREATE INDEX IF NOT EXISTS idx_resources_uri ON p8."Resources"(uri);
-- CREATE INDEX IF NOT EXISTS idx_resources_userid ON p8."Resources"(userid);
-- CREATE INDEX IF NOT EXISTS idx_resources_timestamp ON p8."Resources"(resource_timestamp DESC);
-- CREATE INDEX IF NOT EXISTS idx_tus_file_upload_user_id ON public."TusFileUpload"(user_id);
-- CREATE INDEX IF NOT EXISTS idx_tus_file_upload_tags ON public."TusFileUpload" USING gin(tags);
-- CREATE INDEX IF NOT EXISTS idx_tus_file_upload_status ON public."TusFileUpload"(status);
-- CREATE INDEX IF NOT EXISTS idx_tus_file_upload_updated_at ON public."TusFileUpload"(updated_at DESC);
-- CREATE INDEX IF NOT EXISTS idx_tus_file_upload_s3_uri ON public."TusFileUpload"(s3_uri);