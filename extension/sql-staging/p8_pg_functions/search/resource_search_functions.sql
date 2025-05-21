-- Enable pg_trgm extension for fuzzy text matching
-- Note: This extension may already exist, hence IF NOT EXISTS
CREATE EXTENSION IF NOT EXISTS pg_trgm;

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
        
        -- Use CTE for both semantic search results and filename matches
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
        ),
        filename_matches AS (
            SELECT DISTINCT
                r.uri,
                r.name,
                r.category,
                r.userid,
                -- Use fuzzy matching for filenames with normalization
                -- Normalize more aggressively to compete with semantic scores
                CASE 
                    WHEN GREATEST(
                        similarity(LOWER(r.name), LOWER(p_query_text)),
                        similarity(LOWER(r.uri), LOWER(p_query_text))
                    ) > 0.3 
                    THEN 0.7 + GREATEST(
                        similarity(LOWER(r.name), LOWER(p_query_text)),
                        similarity(LOWER(r.uri), LOWER(p_query_text))
                    ) * 0.3
                    ELSE 0
                END AS filename_score
            FROM p8."Resources" r
            WHERE 
                (p_user_id IS NULL OR r.userid::TEXT = p_user_id)
                AND (
                    LOWER(r.name) LIKE '%' || LOWER(p_query_text) || '%'
                    OR LOWER(r.uri) LIKE '%' || LOWER(p_query_text) || '%'
                    OR similarity(LOWER(r.name), LOWER(p_query_text)) > 0.3
                    OR similarity(LOWER(r.uri), LOWER(p_query_text)) > 0.3
                )
        ),
        combined_results AS (
            -- Union semantic and filename results, taking the best score
            SELECT
                COALESCE(sr.uri, fm.uri) as uri,
                COALESCE(sr.name, fm.name) as name,
                COALESCE(sr.category, fm.category) as category,
                COALESCE(sr.userid, fm.userid) as userid,
                GREATEST(
                    COALESCE(sr.score, 0),
                    COALESCE(fm.filename_score, 0)
                ) as best_score
            FROM semantic_results sr
            FULL OUTER JOIN filename_matches fm 
                ON sr.uri = fm.uri AND sr.userid = fm.userid
        )
        SELECT
            cr.uri,
            MAX(cr.name)::TEXT as resource_name,
            COUNT(r.id) as chunk_count,
            SUM(LENGTH(r.content)) as total_chunk_size,
            AVG(LENGTH(r.content))::NUMERIC as avg_chunk_size,
            MAX(r.resource_timestamp)::timestamp with time zone as max_date,
            ARRAY_AGG(DISTINCT cr.category) as categories,
            MAX(cr.best_score)::FLOAT as semantic_score,
            cr.userid::TEXT as user_id
        FROM combined_results cr
        JOIN p8."Resources" r ON r.uri = cr.uri AND r.userid = cr.userid
        GROUP BY cr.uri, cr.userid
        ORDER BY semantic_score DESC, max_date DESC
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
        
        -- Use CTE for semantic search results and filename matching
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
        ),
        filename_matches AS (
            -- Match filenames directly on TusFileUpload table
            SELECT DISTINCT
                t.id,
                t.filename,
                t.content_type,
                t.total_size,
                t.uploaded_size,
                t.status,
                t.created_at,
                t.updated_at,
                t.s3_uri,
                t.tags,
                t.resource_id,
                t.user_id,
                -- Fuzzy match score for filenames with normalization
                -- Normalize more aggressively to compete with semantic scores
                CASE 
                    WHEN similarity(LOWER(t.filename), LOWER(p_query_text)) > 0.3
                    THEN 0.7 + similarity(LOWER(t.filename), LOWER(p_query_text)) * 0.3
                    ELSE 0
                END AS filename_score
            FROM public."TusFileUpload" t
            WHERE 
                (p_user_id IS NULL OR t.user_id::TEXT = p_user_id)
                AND (p_tags IS NULL OR t.tags && p_tags)
                AND (
                    LOWER(t.filename) LIKE '%' || LOWER(p_query_text) || '%'
                    OR similarity(LOWER(t.filename), LOWER(p_query_text)) > 0.3
                )
        ),
        combined_results AS (
            -- Combine semantic and filename matches
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
                sm.uri as resource_uri,
                sm.name::TEXT as resource_name,
                sm.chunk_count,
                sm.resource_size,
                sm.indexed_at::timestamp with time zone,
                COALESCE(sm.score, 0)::FLOAT as semantic_score,
                0 as filename_match_score,
                1 as match_type -- 1 for semantic
            FROM public."TusFileUpload" t
            INNER JOIN semantic_matches sm ON sm.uri = t.s3_uri
            WHERE
                (p_user_id IS NULL OR t.user_id::TEXT = p_user_id)
                AND (p_tags IS NULL OR t.tags && p_tags)
            
            UNION ALL
            
            SELECT
                fm.id::TEXT as upload_id,
                fm.filename,
                fm.content_type,
                fm.total_size::BIGINT,
                fm.uploaded_size::BIGINT,
                fm.status,
                fm.created_at::timestamp with time zone,
                fm.updated_at::timestamp with time zone,
                fm.s3_uri,
                fm.tags,
                fm.resource_id::TEXT,
                r.uri as resource_uri,
                r.name::TEXT as resource_name,
                r.chunk_count,
                r.resource_size,
                r.indexed_at::timestamp with time zone,
                0::FLOAT as semantic_score,
                fm.filename_score as filename_match_score,
                2 as match_type -- 2 for filename
            FROM filename_matches fm
            LEFT JOIN LATERAL (
                SELECT
                    r.uri,
                    MAX(r.name) as name,
                    COUNT(*) as chunk_count,
                    SUM(LENGTH(r.content)) as resource_size,
                    MAX(r.resource_timestamp)::timestamp with time zone as indexed_at
                FROM p8."Resources" r
                WHERE r.uri = fm.s3_uri
                GROUP BY r.uri
            ) r ON true
        )
        SELECT * FROM (
            SELECT DISTINCT ON (cr.upload_id)
                cr.upload_id,
                cr.filename,
                cr.content_type,
                cr.total_size,
                cr.uploaded_size,
                cr.status,
                cr.created_at,
                cr.updated_at,
                cr.s3_uri,
                cr.tags,
                cr.resource_id,
                cr.resource_uri,
                cr.resource_name,
                cr.chunk_count,
                cr.resource_size,
                cr.indexed_at,
                -- Take the maximum score between semantic and filename matching
                GREATEST(cr.semantic_score, cr.filename_match_score) as semantic_score
            FROM combined_results cr
            ORDER BY cr.upload_id, GREATEST(cr.semantic_score, cr.filename_match_score) DESC, cr.match_type
        ) deduplicated
        ORDER BY semantic_score DESC, updated_at DESC
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