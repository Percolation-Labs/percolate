# Knowledge Graph System Architecture

The living knowledge graph system represents a powerful way to organize and evolve information structures based on natural language content, automatically discovering meaningful patterns and relationships while maintaining the rich context of the original narratives. 

The users "identity" is stored in semantic texts er users and various narrative sequences exist as threads. 

Behind this there is a graph structure which provides concise relationships and links to entities that can be looked up

- New content is added as nodes in the vector database
- Relation extraction service processes node content
- Extracted relationships are added as edges in the graph
- Graph analysis service periodically evaluates the graph structure
- When thresholds are exceeded, structure nodes are created and the graph is rewired
- Query engine provides access to the evolving knowledge structure
- Text content in percolate can have markdown hyper links to entity nodes e.g. entity-link/id, Friendly Name - the agent can query these entities in the graph


As an example, a user interact with the system stating facts and asking questions. A few seed relations are used e.g. `knows`, `likes` `likes-not` `has-allergy` `has-goal` `has-skill` `working-on`. The system can learn what relationships are interesting to each user and store them in add relations. 

A Process reads a users interactions and calls two processes to process graph structure and build narrative structures which are temporal summaries that link events and provide links to resources. 

You can find all SQL queries under `extension/sql-staging/p8_pg_functions` in this repo. The `cypher` queries can be used for many low level cypher wrappers and some other folders like `index` can be used for building and processing graphs. `search` can be used to add high level query helpers.
You can learn more about AGE graph extension [here](https://age.apache.org/age-manual/master/index.html)  .

## 1. Data Model
### 1.1 Nodes

Content Nodes: Store text content with metadata

Properties: id, name, content, created_at, metadata
Indexed by vector embeddings for similarity retrieval
Retrieved via get_entities() function

- User nodes have ids and names and email addresses.

### 1.2 Edges

Relationship Edges: Connect nodes with typed relationships

Properties: source_id, target_id, label, created_at, terminated_at, metadata
Temporal awareness through created_at and terminated_at timestamps
Core operations:

add_edge(source_id, target_id, label, metadata)
terminate_edge(edge_id, termination_reason)

### 1.3 Structure Nodes

Aggregation Nodes: Represent groupings of similar relationships

Created dynamically when threshold conditions are met
Example: When Person A has > P likes edges to people, create a "likes-people" structure node

## 2.2 Temporal Awareness

Support for querying graph state at specific points in time
Filter edges based on created_at and terminated_at values
Enable historical analysis and time-based diffing


## 5. Opportunities and Risks
### 5.1 Opportunities

- Emergent Knowledge Structures: The system can discover patterns and relationships not explicitly defined
- Adaptive Organization: Knowledge structure evolves based on content rather than fixed schemas
- Temporal Intelligence: Tracking changes in relationships over time enables trend analysis
- Contextual Understanding: Mixing narrative content with structured relationships preserves context
- Dynamic Categorization: Automatic grouping creates meaningful abstractions as data grows
- Recommendation Power: Graph structure can reveal non-obvious connections between entities
- Scalable Knowledge Base: Structure nodes prevent graph explosion as content grows

### 5.2 Risks

- Extraction Quality: Relation extraction accuracy directly impacts graph quality
- Over-aggregation: Excessive grouping may obscure important individual relationships
- Temporal Complexity: Managing the temporal dimension adds significant complexity
- Context Loss: Structure nodes may lose contextual nuance from original relationships
- Threshold Sensitivity: Grouping thresholds require careful tuning to be effective
- Graph Fragmentation: Isolated subgraphs may form without proper connectivity
- Performance Concerns: Deep traversals and complex rewiring operations may be computationally expensive
- Cold Start Problem: The system requires sufficient data for meaningful structure to emerge

## Desired
- Confidence Scores: Add confidence values to extracted relationships
- Contradictory Information: Handle conflicting relationships
- User Feedback Loop: Allow users to correct or validate relationships
- Multi-modal Content: Expand to include images, audio, and video

## Example

From the text content "Alice is a software engineer who loves coffee and Italian food. She's currently working on Project X using Python and Machine Learning. She plans to attend the Data Science Conference 2025. Alice knows Bob but they don't work on the same projects. Bob likes pizza and pasta but is allergic to coffee."
Extracted relationships might include:

(Alice) -[likes]-> (Coffee)
(Alice) -[likes]-> (Italian Food)
(Alice) -[working-on]-> (Project X)
(Alice) -[uses]-> (Python)
(Alice) -[uses]-> (Machine Learning)
(Alice) -[has-goal]-> (Data Science Conference 2025)
(Alice) -[knows]-> (Bob)
(Bob) -[likes]-> (Pizza)
(Bob) -[likes]-> (Pasta)
(Bob) -[has-allergy]-> (Coffee)
  
## Implementation

Below is an overview of how we implement graph operations using PostgreSQL AGE and Cypher in our SQL extensions. All functions live under `extension/sql-staging/p8_pg_functions/index`.

### 1. Loading the AGE extension
- Every function that issues Cypher must first load the AGE extension and set the search path:
  ```sql
  LOAD 'age';
  SET search_path = ag_catalog, "$user", public;
  ```

### 2. Node naming and ID conventions
- Each node is uniquely identified by the tuple (label, name, user_id).
  - **user_id**: owner user id (nullable). If NULL or blank, the node is global; otherwise it's scoped to a user.
- Table-qualified names (e.g. `schema.table`) map to graph labels using `schema__table`.
- Each node carries at minimum:
  - **uid** (or `id`): the internal PK from the base table or view
  - **name** (or `key`): the human-friendly identifier
  - **user_id**: the id of the owning user (nullable)
  - *(future)* role/access metadata
- Structure nodes (Memory Hubs):
  - Labeled using the pattern `UserMemoryHub__<relation_type>` (e.g. `UserMemoryHub__likes`).
  - Properties:
    - **relation_type**: the name of the relation aggregated
    - **user_id**: the owner (non-null)
  - These nodes represent per-user aggregations of a relation and must always be scoped to a user.

### 3. Adding nodes via SQL
- Function: `p8.add_nodes(table_name text)`
- Backed by a view `p8.vw_<schema>_<table>` that yields rows with `uid` and `key`.  
- Builds a single Cypher `CREATE` statement that MERGEs all new nodes in batch.
- Returns the number of nodes created.
- See `add_nodes_AND_insert_entity_nodes.sql`.

### 4. Inserting entities repeatedly
- Function: `p8.insert_entity_nodes(entity_table text)`
- Calls `p8.add_nodes` in a loop until no new rows remain.
- Useful for bulk-loading all entities of a given type.

### 5. Adding weighted edges
- Function: `p8.add_weighted_edges(node_data jsonb, table_name text DEFAULT NULL, edge_name text DEFAULT 'semref')`  
- Expects a JSONB array of objects `{ name: <node>, edges: [ { name: <neighbor>, weight: <float> }, … ] }`.  
- For each element:
  1. Determine the graph label (from `table_name` or default to `name`).  
  2. Construct a Cypher MERGE for both end nodes and the relationship with `{ weight }`.  
  3. Wrap the Cypher in a dynamic SQL string and `EXECUTE` it safely via `format()` with `%I` for identifiers and proper quoting for values.
- See `add_weighted_edges.sql`.

### 6. Other utility functions
- `create_graph_from_paths.sql` – build subgraphs from paths queries
- `build_graph_index.sql` – generate graph reachability or neighborhood indexes
- All use the same pattern: load AGE, build a Cypher query string, then execute via `SELECT * FROM cypher('percolate', $$…$$)`.

#### Example: embedding Cypher in PL/pgSQL
In our functions (e.g. `get_paths.sql`), we build a single multi-line string with explicit `\n` line breaks and then wrap it in a `cypher` call, spacing the `$$` delimiters for readability:
```sql
-- Build the Cypher MERGE query
cypher_query := format(
    'MERGE (a:%I {name: %L, %s})\n'
    || 'MERGE (b:%I {name: %L, %s})\n'
    || 'MERGE (a)-[r:%I]->(b)\n'
    || '%s',
    source_label, source_name, src_user_clause,
    target_label, target_name, tgt_user_clause,
    rel_type,
    rel_set_clause
);

-- Wrap into SQL for AGE
sql := format(
    '\nSELECT * FROM cypher(''percolate'', $$ %s $$) AS (v agtype);\n',
    cypher_query
);
-- Then EXECUTE sql;
```

### 7. Testing via `psql`
Use the application database on port `15432`, retrieving the password from the `P8_TEST_BEARER_TOKEN` env var:
```bash
export PGPASSWORD="$P8_TEST_BEARER_TOKEN"
psql -h localhost -p 15432 -U postgres -d app
```
Inside `psql`, you can exercise the functions, for example:
```sql
SELECT * FROM p8.insert_entity_nodes('p8.my_entities');
SELECT p8.add_weighted_edges(
  '[{"name":"nodeA","edges":[{"name":"nodeB","weight":0.75}]}]'::jsonb,
  'p8.my_entities',
  'related_to'
);
```

After threshold-based rewiring, we might see:

(Bob) -[likes-food]-> (Structure: Italian Foods) -[contains]-> (Pizza)
(Structure: Italian Foods) -[contains]-> (Pasta)

## Example relations

- `is-learning`
- `recommends`
- `has-value`
- `fears`
- `takes-medication-for` 
- `plans-to-attend` 
- `advocates-for`
- `opposes`
- `teaches`
- `aspires-to`
- `reports-to`


## Example queries

 1.   Exercise activation:

               SELECT p8.add_relationship_to_node(
                 'User','Alice','likes','Coffee');
2. Verify:

               LOAD 'age';
               SET search_path=ag_catalog,"$user",public;
               SELECT a,r,b
               FROM cypher('percolate',$$
                 MATCH (a:User{name:'Alice',user_id:null})-[r:likes]->(b:Concept{name:'Coffee',user_id:null})
                 RETURN a,r,b
               $$) AS (a agtype,r agtype,b agtype);
 3. Deactivate:

               SELECT p8.add_relationship_to_node(
                 'User','Alice','likes','Coffee',
                 FALSE 
               );
 4. Confirm the edge’s `terminated_at` was set: we return it but dont filter it here and the caller can check as its useful historical context to surface

               SELECT r
               FROM cypher('percolate',$$
                 MATCH ()-[r:likes]->()
                 RETURN r
               $$) AS (r agtype);


## Use the AGE Graph Viewer

You can fetch the code for the AGE graph viewer and run it locally with

```bash
#you may or may not this this first line
export NODE_OPTIONS=--openssl-legacy-provider
npm run start
```

Run a query such as below depending on the state of your graph

```sql
SELECT * FROM cypher('percolate', $$
  MATCH p = (u:User)-[r*1..2]->(c:Concept)
  RETURN u.name,  c.name as concept, relationships(p) as relationships
$$) as (v agtype);
```
