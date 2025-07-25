-- Function: p8.get_relationships
-- Description:
--   Retrieves relationships from the graph database, optionally filtered by source and target.
--   Returns active relationships by default (terminated_at IS NULL).
--
-- Parameters:
--   source_label     TEXT   - Source node label to filter by (optional)
--   source_name      TEXT   - Source node name to filter by (optional)
--   rel_type         TEXT   - Relationship type to filter by (optional)
--   target_label     TEXT   - Target node label to filter by (optional)
--   target_name      TEXT   - Target node name to filter by (optional)
--   source_user_id   TEXT   - Source node user_id to filter by (optional)
--   target_user_id   TEXT   - Target node user_id to filter by (optional)
--   include_inactive BOOLEAN- Whether to include terminated relationships (default FALSE)
--
-- Returns:
--   TABLE of relationship information
--   
-- Usage:
--   SELECT * FROM p8.get_relationships('User', 'alice@example.com');
--   SELECT * FROM p8.get_relationships(rel_type := 'likes');
--   SELECT * FROM p8.get_relationships('User', NULL, NULL, 'Topic');

DROP FUNCTION IF EXISTS p8.get_relationships;
CREATE OR REPLACE FUNCTION p8.get_relationships(
    source_label     TEXT    DEFAULT NULL,
    source_name      TEXT    DEFAULT NULL,
    rel_type         TEXT    DEFAULT NULL,
    target_label     TEXT    DEFAULT NULL,
    target_name      TEXT    DEFAULT NULL,
    source_user_id   TEXT    DEFAULT NULL,
    target_user_id   TEXT    DEFAULT NULL,
    include_inactive BOOLEAN DEFAULT FALSE
)
RETURNS TABLE(
    src_label    TEXT,
    src_name     TEXT,
    src_user_id  TEXT,
    relationship TEXT,
    tgt_label    TEXT,
    tgt_name     TEXT,
    tgt_user_id  TEXT,
    created_at   TIMESTAMP,
    terminated_at TIMESTAMP,
    properties   JSONB
)
LANGUAGE plpgsql
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    cypher_query TEXT;
    match_clause TEXT := 'MATCH (a)';
    where_clauses TEXT[] := '{}';
    relation_clause TEXT := '-[r]->';
    where_clause TEXT := '';
BEGIN
    -- Load AGE extension
    -- AGE extension is preloaded at session level
    SET search_path = ag_catalog, "$user", public;
    
    -- Check if graph exists
    IF NOT EXISTS (SELECT 1 FROM ag_graph WHERE name = 'percolate') THEN
        RETURN;
    END IF;
    
    -- Build source node match conditions
    IF source_label IS NOT NULL THEN
        match_clause := format('MATCH (a:%s)', source_label);
        
        IF source_name IS NOT NULL THEN
            where_clauses := array_append(where_clauses, format('a.name = ''%s''', source_name));
        END IF;
        
        IF source_user_id IS NOT NULL THEN
            where_clauses := array_append(where_clauses, format('a.user_id = ''%s''', source_user_id));
        ELSE
            where_clauses := array_append(where_clauses, 'a.user_id IS NULL');
        END IF;
    ELSE
        match_clause := 'MATCH (a)';
    END IF;
    
    -- Build relationship match
    IF rel_type IS NOT NULL THEN
        relation_clause := format('-[r:%s]->', rel_type);
    ELSE
        relation_clause := '-[r]->';
    END IF;
    
    -- Build target node match conditions
    IF target_label IS NOT NULL THEN
        match_clause := format('%s%s(b:%s)', match_clause, relation_clause, target_label);
        
        IF target_name IS NOT NULL THEN
            where_clauses := array_append(where_clauses, format('b.name = ''%s''', target_name));
        END IF;
        
        IF target_user_id IS NOT NULL THEN
            where_clauses := array_append(where_clauses, format('b.user_id = ''%s''', target_user_id));
        ELSE
            where_clauses := array_append(where_clauses, 'b.user_id IS NULL');
        END IF;
    ELSE
        match_clause := format('%s%s(b)', match_clause, relation_clause);
    END IF;
    
    -- Filter active relationships by default
    IF NOT include_inactive THEN
        where_clauses := array_append(where_clauses, 'r.terminated_at IS NULL');
    END IF;
    
    -- Combine WHERE clauses if any exist
    IF array_length(where_clauses, 1) > 1 THEN
        -- Remove the first empty element
        where_clauses := where_clauses[2:array_length(where_clauses, 1)];
        where_clause := ' WHERE ' || array_to_string(where_clauses, ' AND ');
    END IF;
    
    -- Build the complete Cypher query
    cypher_query := format('%s%s
                          RETURN 
                             a.label AS src_label, 
                             a.name AS src_name,
                             a.user_id AS src_user_id,
                             r.label AS relationship,
                             b.label AS tgt_label,
                             b.name AS tgt_name,
                             b.user_id AS tgt_user_id,
                             r.created_at,
                             r.terminated_at,
                             r',
                         match_clause, where_clause);
    
    -- Execute and return results
    RETURN QUERY 
    SELECT 
        (v).src_label::TEXT,
        (v).src_name::TEXT,
        (v).src_user_id::TEXT,
        (v).relationship::TEXT,
        (v).tgt_label::TEXT,
        (v).tgt_name::TEXT,
        (v).tgt_user_id::TEXT,
        ((v).created_at)::TIMESTAMP,
        ((v).terminated_at)::TIMESTAMP,
        (to_jsonb((v).r) - 'created_at' - 'terminated_at' - 'id' - 'label' - 'start_id' - 'end_id')::JSONB AS properties
    FROM cypher('percolate', cypher_query) AS (v agtype);
END;
$BODY$;