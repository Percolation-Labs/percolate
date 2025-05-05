-- Function: p8.add_relationships_to_node
-- Description:
--   Batch processing of relationships (edges) in the graph. This function expects a JSONB
--   array of edge objects, each with the following fields:
--     source_label    TEXT         -- source node label (e.g. 'User', 'Topic')
--     source_name     TEXT         -- source node name/identifier
--     rel_type        TEXT         -- the relationship type (e.g. 'likes', 'knows')
--     target_name     TEXT         -- target node name/identifier
--     activate        BOOLEAN      -- whether to activate (true) or deactivate (false) the relationship
--     source_user_id  TEXT         -- optional user_id for source node scoping (null for global)
--     target_label    TEXT         -- optional target node label (defaults to 'Concept')
--     target_user_id  TEXT         -- optional user_id for target node scoping (null for global)
--     rel_props       JSONB        -- optional relationship properties as JSONB
--
-- Returns:
--   INTEGER: The number of relationships processed.
-- Usage:
--   SELECT p8.add_relationships_to_node('[
--     {
--       "source_label": "User",
--       "source_name": "sirsh@email.com",
--       "rel_type": "likes",
--       "target_name": "Coffee",
--       "activate": true,
--       "source_user_id": null,
--       "target_label": "Concept",
--       "target_user_id": null,
--       "rel_props": {"confidence": "0.95"}
--     },
--     {
--       "source_label": "User",
--       "source_name": "sirsh@email.com",
--       "rel_type": "dislikes",
--       "target_name": "Tea",
--       "activate": true
--     }
--   ]'::jsonb);

DROP FUNCTION IF EXISTS p8.add_relationships_to_node;
CREATE OR REPLACE FUNCTION p8.add_relationships_to_node(edges JSONB)
RETURNS INTEGER
LANGUAGE plpgsql
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    edge JSONB;
    count INTEGER := 0;
    
    -- Edge fields
    source_label TEXT;
    source_name TEXT;
    rel_type TEXT;
    target_name TEXT;
    activate BOOLEAN;
    source_user_id TEXT;
    target_label TEXT;
    target_user_id TEXT;
    rel_props JSONB;
BEGIN
    -- Process each edge in the input JSON array
    FOR edge IN SELECT * FROM jsonb_array_elements(edges)
    LOOP
        -- Extract required fields
        source_label := edge->>'source_label';
        source_name := edge->>'source_name';
        rel_type := edge->>'rel_type';
        target_name := edge->>'target_name';
        
        -- Extract optional fields with defaults
        activate := COALESCE((edge->>'activate')::boolean, TRUE);
        source_user_id := edge->>'source_user_id';
        target_label := COALESCE(edge->>'target_label', 'Concept');
        target_user_id := edge->>'target_user_id';
        rel_props := COALESCE(edge->'rel_props', '{}'::jsonb);
        
        -- Validate required fields
        IF source_label IS NULL OR source_name IS NULL OR rel_type IS NULL OR target_name IS NULL THEN
            RAISE NOTICE 'Skipping invalid edge: missing required fields.';
            CONTINUE;
        END IF;
        
        -- Call the single relationship function
        PERFORM p8.add_relationship_to_node(
            source_label,
            source_name,
            rel_type,
            target_name,
            activate,
            source_user_id,
            target_label,
            target_user_id,
            rel_props
        );
        
        count := count + 1;
    END LOOP;
    
    RETURN count;
END;
$BODY$;