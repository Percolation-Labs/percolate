-- Function: p8.add_relationship_to_node
-- Description:
--   Idempotently MERGE two graph nodes (scoped by optional user_id) and a relationship between them.
--   Nodes default to label 'Concept' if not specified. The relationship is MERGEd only once,
--   with a created_at timestamp and extra properties from a JSONB map.
--   
--   When activate=TRUE (default), relationship is created or reactivated.
--   When activate=FALSE, relationship is marked as terminated with current timestamp.
--
/*
Usage example:

 SELECT p8.add_relationship_to_node('User', 'sirsh@email.com',  'interested_in',   'GraphDB');
 SELECT p8.add_relationship_to_node('User', 'sirsh@email.com',  'interested_in',   'Percolated');
 SELECT p8.add_relationship_to_node('User', 'sirsh@email.com',  'interested_in',   'Math');

 SELECT p8.add_relationship_to_node('User', 'sirsh@gmail.com',  'interested_in',   'GraphDB', True, '123');
 SELECT p8.add_relationship_to_node('User', 'sirsh@gmail.com',  'interested_in',   'Percolated', True, '123');
 
 --rel props
  SELECT p8.add_relationship_to_node('User', 'sirsh@gmail.com',  'interested_in',   'Percolated', True, '123', NULL, NULL, '{
  "source": "user_input",
  "weight": "0.75",
  "notes": "Added via API",
  "confidence": "high"
}'::jsonb);
 

  */

  
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
RETURNS jsonb
LANGUAGE plpgsql
AS $BODY$
DECLARE
    f_query          text;
    sql              text;
    src_user_clause  text;
    tgt_user_clause  text;
    prop_set_clause  text := '';
    kv               record;
    ts               text := now()::timestamp::text;
    result_data      jsonb;
BEGIN
    -- 1) Load AGE extension and set search_path
    LOAD 'age';
    SET search_path = ag_catalog, "$user", public;

	target_label:= COALESCE(target_label,'Concept');
    -- 3) Build user_id property fragments for source and target
    src_user_clause := CASE
        WHEN source_user_id IS NULL OR trim(source_user_id) = ''
            THEN ''
        ELSE format(', user_id: %L', source_user_id)
    END;
    tgt_user_clause := CASE
        WHEN target_user_id IS NULL OR trim(target_user_id) = ''
            THEN 'user_id: no_id'
        ELSE format('user_id: %L', target_user_id)
    END;

    -- 4) Turn any extra JSONB props into `, r.key = 'value'` fragments
    FOR kv IN SELECT * FROM jsonb_each_text(rel_props) LOOP
        prop_set_clause := prop_set_clause
            || format(', r.%I = %L', kv.key, kv.value);
    END LOOP;

    -- 5) Modified Cypher query to return the relationship and nodes
    f_query := format(
        'MERGE (a:%s {name: %L %s})
         MERGE (b:%s {name: %L})
		 WITH a, b
		 MERGE (a)-[r:%s]->(b)
         SET
           r.created_at    = coalesce(r.created_at, %L),
           r.terminated_at = CASE WHEN %s THEN null ELSE %L END 
           %s
         RETURN a AS source_node, r AS relationship, b AS target_node',
        source_label, source_name, src_user_clause,
        target_label, target_name,
        rel_type,
        ts,
        activate::text, ts,
        prop_set_clause
    );

raise NOTICE '%',f_query;
	
    -- 6) Execute Cypher query and fetch the result
    SELECT row_to_json(t)::jsonb INTO result_data
    FROM (
        SELECT * FROM cypher_query(f_query,
		'a agtype, r agtype, b agtype'
		) 

    ) t;
    
    RETURN result_data;
END;
$BODY$;