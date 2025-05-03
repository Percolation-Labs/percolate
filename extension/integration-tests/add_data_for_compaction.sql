-- Clear all users (optional if you want to start fresh)
SELECT * FROM cypher_query(
  'MATCH (u:User)
   DETACH DELETE u'
);
SELECT * FROM cypher_query(
  'MATCH (u:Concept)
   DETACH DELETE u'
);

-- Create a User node for Tom (idempotent)
SELECT * FROM cypher_query(
  '
  MERGE (u:User {name: ''Tom'', user_id: ''tom_123''})
  RETURN u
  ',
  'u agtype'
);

-- Create Concept nodes for things Tom likes (idempotent)
SELECT * FROM cypher_query(
  '
  MERGE (c1:Concept {name: ''Pizza''})
  MERGE (c2:Concept {name: ''Coffee''})
  MERGE (c3:Concept {name: ''Movies''})
  MERGE (c4:Concept {name: ''Reading''})
  MERGE (c5:Concept {name: ''Swimming''})
  RETURN c1, c2, c3, c4, c5
  ',
  'c1 agtype, c2 agtype, c3 agtype, c4 agtype, c5 agtype'
);

-- Create "likes" relationships from Tom to the concepts (idempotent)
SELECT * FROM cypher_query(
  '
  MATCH (u:User {name: ''Tom''}),
        (c1:Concept {name: ''Pizza''}),
        (c2:Concept {name: ''Coffee''}),
        (c3:Concept {name: ''Movies''}),
        (c4:Concept {name: ''Reading''}),
        (c5:Concept {name: ''Swimming''})
  MERGE (u)-[r1:likes]->(c1) SET r1.rating = 5
  MERGE (u)-[r2:likes]->(c2) SET r2.rating = 4
  MERGE (u)-[r3:likes]->(c3) SET r3.rating = 5
  MERGE (u)-[r4:likes]->(c4) SET r4.rating = 3
  MERGE (u)-[r5:likes]->(c5) SET r5.rating = 4
  RETURN u
  ',
  'u agtype'
);

-- Create Concept nodes for things Tom is allergic to (idempotent)
SELECT * FROM cypher_query(
  '
  MERGE (c6:Concept {name: ''Peanuts''})
  MERGE (c7:Concept {name: ''Shellfish''})
  MERGE (c8:Concept {name: ''Pollen''})
  MERGE (c9:Concept {name: ''Dust''})
  MERGE (c10:Concept {name: ''Cat Fur''})
  RETURN c6, c7, c8, c9, c10
  ',
  'c6 agtype, c7 agtype, c8 agtype, c9 agtype, c10 agtype'  
);

-- Create "has_allergy" relationships from Tom to allergy concepts (idempotent)
SELECT * FROM cypher_query(
  '
  MATCH (u:User {name: ''Tom''}),
        (c6:Concept {name: ''Peanuts''}),
        (c7:Concept {name: ''Shellfish''}),
        (c8:Concept {name: ''Pollen''}),
        (c9:Concept {name: ''Dust''}),
        (c10:Concept {name: ''Cat Fur''})
  MERGE (u)-[r6:has_allergy]->(c6) SET r6.severity = ''severe''
  MERGE (u)-[r7:has_allergy]->(c7) SET r7.severity = ''moderate''
  MERGE (u)-[r8:has_allergy]->(c8) SET r8.severity = ''mild''
  MERGE (u)-[r9:has_allergy]->(c9) SET r9.severity = ''moderate''
  MERGE (u)-[r10:has_allergy]->(c10) SET r10.severity = ''severe''
  RETURN u
  ',
  'u agtype'
);

-- Verify the data
SELECT * FROM cypher_query(
  '
  MATCH  (u:User {name: ''Tom''})-[r]->(c:Concept)
  RETURN u.name, TYPE(r) as relationship_type, c.name as concept, r
  ',
  'name agtype, relationship_type agtype, concept agtype, r agtype'
);

SELECT * FROM cypher_query(
  '
  MATCH  (a:Concept)-[r]->(c:Concept)
  RETURN TYPE(r) as relationship_type, c.name as concept, r
  ',
  'relationship_type agtype, concept agtype, r agtype'
);

SELECT * FROM cypher_query(
  '
  MATCH p = (u:User {name: ''Tom''})-[r*1..2]->(c:Concept)
  RETURN u.name,  c.name as concept, relationships(p) as relationships
  ',
  'name agtype,  concept agtype, relationships agtype'
);
 
-- -----
SELECT * FROM cypher_query(
  '
  MATCH p = (u:User {name: ''Tom''})-[r*1..1]->(c:Concept)
  RETURN u.name,  c.name as concept, relationships(p) as relationships
  ',
  'name agtype,  concept agtype, relationships agtype'
);
 