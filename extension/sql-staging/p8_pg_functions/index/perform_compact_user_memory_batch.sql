DROP FUNCTION IF EXISTS p8.perform_compact_user_memory_batch;
CREATE OR REPLACE FUNCTION perform_compact_user_memory_batch(threshold INTEGER DEFAULT 7)
RETURNS TABLE (
  user_id_out text,
  rel_type_out text,
  rel_count_out integer
) AS
$$
DECLARE
  batch RECORD; 
  fromatted_cypher_query TEXT;
BEGIN
	/*

  This function which could be generalized to other node types specifically compacts relationships between User and Concept nodes.
  Its assumed that the users node has a user id which is important for qualifying user memories by named entities

  A threshold defaults to 7 which means that as users have greater than 7 direct links we insert a Hub Node between them. 
  If we need to later add more direct links they will always be merged onto the same hub node for that user and that relationship type
  For example the relationships 'likes' or 'has-skills' will be linked to a hub for that relationship type

  Today we do not compact hubs but another process could do that in future e.g. like-good-italian or something very specific.
  The true value of this for now is simply knowing that the relationships exist and can be expanded. Recall that this expansion as far as actually entity lookups should be small data

	select * from perform_compact_user_memory_batch(5)
	*/
  -- Step 1: Get batches of relationship groups

   formatted_cypher_query := format($cq$
	    MATCH (a:User)-[r]->(b:Concept)
	    WITH a, TYPE(r) AS relType, collect(r) AS rels, collect(b) AS targets
	    WITH a, a.user_id AS user_id, relType AS rel_type, rels, targets, size(rels) AS rel_count
	    WHERE rel_count > %s
	    RETURN user_id, rel_type, rels, targets, rel_count
	    ORDER BY rel_count DESC
	    LIMIT 100
	  $cq$, threshold);
	  
  FOR batch IN
    SELECT 
	  result->'rels' as rels, 
	  (result->>'rel_count')::INTEGER as rel_count, 
	  result->>'user_id' as user_id,
	  result->>'rel_type' as rel_type  
	 FROM cypher_query(formatted_cypher_query, 
	 'user_id text, rel_type text, rels agtype, targets agtype, rel_count integer'
    )
  LOOP
 
    -- Step 2: For each batch, recreate the relationships from Hub to Concept, and link User to Hub with the same type
    PERFORM cypher_query(
      '
        MATCH (a:User {user_id: ''' || batch.user_id || '''})-[r:' || batch.rel_type || ']->(b:Concept)
        WITH a, b, r, properties(r) AS props
        MERGE (c:Concept {is_hub:true,  name: ''' ||   'has_'|| batch.rel_type || ''', user_id: ''' || batch.user_id || '''})
        CREATE (c)-[newRel:' || batch.rel_type || ']->(b)
        SET newRel = props
        MERGE (a)-[newRel2:' || batch.rel_type || ']->(c)
        SET newRel2 = props
        DELETE r
      '
    );

    RAISE NOTICE 'Processed batch for user % with relType %:  .', batch.user_id, batch.rel_type ;

    user_id_out := batch.user_id;
    rel_type_out := batch.rel_type;
    rel_count_out := batch.rel_count;
    RETURN NEXT;
  END LOOP;

  RETURN;
END;
$$ LANGUAGE plpgsql;
