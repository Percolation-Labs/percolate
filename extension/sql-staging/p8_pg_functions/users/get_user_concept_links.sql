DROP FUNCTION IF EXISTS p8.get_user_concept_links;
CREATE OR REPLACE FUNCTION p8.get_user_concept_links(
  user_name TEXT,
   rel_type TEXT DEFAULT NULL,
  select_hub BOOLEAN DEFAULT FALSE,
  depth INT DEFAULT 2
)
RETURNS TABLE (
  results JSONB
) AS
$$
DECLARE
  formatted_cypher_query TEXT;
  rel_pattern TEXT;
  where_clause TEXT;
BEGIN

  /*
  	select concept nodes linked to users. 
  	- By default we include all concept nodes that are terminal and exclude hubs which are structural
  	- you can explicitly pass the flag NULL to show all which is really just a testing device
  	- you can pass flag True to just show hubs
    - rel_type allows filtering by relationship type

	select * from p8.get_user_concept_links('Tom', 'has_allergy' )
  */

  -- Construct relationship pattern based on rel_type
  rel_pattern := CASE 
    WHEN rel_type IS NULL THEN '[*1..' || depth || ']'  -- any relationship type
    ELSE '[:' || rel_type || '*1..' || depth || ']'     -- specific relationship type
  END;

  -- Construct WHERE clause
  where_clause := CASE 
    WHEN select_hub IS NULL THEN ''
    WHEN select_hub THEN 'WHERE c.is_hub = true'
    ELSE 'WHERE COALESCE(c.is_hub, false) = false'
  END;

  -- Format the complete Cypher query
  formatted_cypher_query := format($cq$
    MATCH path = (u:User {name: '%s'})-%s->(c:Concept)
    %s
    RETURN u AS u, c AS concept, path
  $cq$,
    user_name,
    rel_pattern,
    where_clause
  );

  RETURN QUERY
  SELECT * FROM cypher_query(
    formatted_cypher_query,
    'u agtype, concept agtype, path agtype'
  );

END;
$$ LANGUAGE plpgsql;
