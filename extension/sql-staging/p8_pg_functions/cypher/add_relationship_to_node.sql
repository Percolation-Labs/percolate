-- Function: p8.add_relationship_to_node
-- Description:
--   Idempotently MERGE two graph nodes (scoped by optional user_id) and a relationship between them.
--   Nodes default to label 'Concept' if not specified. The relationship is MERGEd only once,
--   with a created_at timestamp and extra properties from a JSONB map.
--   
--   When activate=TRUE (default), relationship is created or reactivated.
--   When activate=FALSE, relationship is marked as terminated with current timestamp.
--
-- Usage example:
--   -- Insert/merge a relationship
--   SELECT p8.add_relationship_to_node(
--     'User', 'sirsh@email.com',  -- source_label, source_name
--     'interested_in',            -- rel_type
--     'GraphDB',                  -- target_name
--     TRUE,                       -- activate (default TRUE)
--     NULL,                       -- source_user_id (nullable for global)
--     'Topic',                    -- target_label (default 'Concept')
--     NULL,                       -- target_user_id
--     '{"confidence":"0.87"}'::jsonb  -- rel_props
--   );
--
--   -- Deactivate the relationship (set terminated_at)
--   SELECT p8.add_relationship_to_node(
--     'User', 'sirsh@email.com',  -- source_label, source_name
--     'interested_in',            -- rel_type
--     'GraphDB',                  -- target_name
--     FALSE                       -- activate=FALSE to deactivate relationship
--   );
--
--   -- Retrieve the relationship to verify (round trip)
--   SELECT a AS source_node, r AS relationship, b AS target_node
--   FROM cypher('percolate', $$
--     MATCH (a:User {name: 'sirsh@email.com', user_id: null})
--           -[r:interested_in]->
--           (b:Topic {name: 'GraphDB', user_id: null})
--     RETURN a, r, b
--   $$) AS (a agtype, r agtype, b agtype);
DROP FUNCTION IF EXISTS p8.add_relationship_to_node;
CREATE OR REPLACE FUNCTION p8.add_relationship_to_node(
    source_label      text,
    source_name       text,
    rel_type          text,
    target_name       text,
    activate          boolean    DEFAULT true,
    source_user_id    text       DEFAULT NULL,
    target_label      text       DEFAULT 'Concept',
    target_user_id    text       DEFAULT NULL,
    rel_props         jsonb      DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    cypher_query    text;
    sql             text;
    src_user_clause text;
    tgt_user_clause text;
    rel_set_clause  text;
    kv              record;
    created_at_val  text;
BEGIN
    -- Load AGE extension and ensure search_path
    LOAD 'age';
    SET search_path = ag_catalog, "$user", public;
    
    -- Check if graph exists and create it if it doesn't
    IF NOT EXISTS (SELECT 1 FROM ag_graph WHERE name = 'percolate') THEN
        PERFORM create_graph('percolate');
    END IF;

    -- Build user_id clause for source node
    IF source_user_id IS NULL OR trim(source_user_id) = '' THEN
        src_user_clause := 'user_id: null';
    ELSE
        src_user_clause := format('user_id: %L', source_user_id);
    END IF;

    -- Build user_id clause for target node
    IF target_user_id IS NULL OR trim(target_user_id) = '' THEN
        tgt_user_clause := 'user_id: null';
    ELSE
        tgt_user_clause := format('user_id: %L', target_user_id);
    END IF;

    -- Compute timestamp and (de)activate relationship
    created_at_val := now()::timestamp::text;
    IF activate THEN
        -- Activation: upsert nodes and relationship, set created_at if new, clear terminated_at, apply extra props
        rel_set_clause := format('SET r.created_at = COALESCE(r.created_at, %L), r.terminated_at = null', created_at_val);
        FOR kv IN SELECT * FROM jsonb_each_text(rel_props) LOOP
            rel_set_clause := rel_set_clause || format(', r.%I = %L', kv.key, kv.value);
        END LOOP;
    ELSE
        -- Deactivation: mark relationship as terminated by setting terminated_at timestamp
        rel_set_clause := format('SET r.terminated_at = %L', created_at_val);
    END IF;

    -- Construct the Cypher MERGE query for the full pattern (nodes + relationship)
    cypher_query := format(
        'MERGE (a:%s {name: %L, %s})-[r:%s]->(b:%s {name: %L, %s}) %s',
        source_label, source_name, src_user_clause,
        rel_type,
        target_label, target_name, tgt_user_clause,
        rel_set_clause
    );

    -- Wrap into SQL call, following our standard formatting (with spaces around $$)
    sql := format(
        '
SELECT * FROM cypher(''percolate'', $$ %s $$) AS (v agtype);
',
        cypher_query
    );

    -- Execute the statement
    EXECUTE sql;
END;
$BODY$;