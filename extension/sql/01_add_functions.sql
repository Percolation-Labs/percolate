-- Percolate PostgreSQL Functions
-- Generated from sql-staging on 2025-08-09 19:59:10
-- DO NOT EDIT - This file is auto-generated

-- ====================================================================
-- ROOT LEVEL FUNCTIONS
-- ====================================================================

-- Function from: percolate.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS percolate_with_tools;
DROP FUNCTION IF EXISTS percolate;

CREATE OR REPLACE FUNCTION public.percolate(
    text TEXT,
    model VARCHAR(100) DEFAULT 'gpt-4.1-mini',
    tool_names_in TEXT[] DEFAULT NULL,
    system_prompt TEXT DEFAULT 'Respond to the users query using tools and functions as required',
    token_override TEXT DEFAULT NULL,
    temperature FLOAT DEFAULT 0.01
)
RETURNS TABLE(
    message_response text,
    tool_calls jsonb,
    tool_call_result jsonb,
    session_id_out uuid,
    status text
)  AS $$
BEGIN
    RETURN QUERY 
    SELECT * FROM percolate_with_agent(text,'p8.PercolateAgent');
END;
$$ LANGUAGE plpgsql;

-- Wrapper function `percolate_with_tools`
CREATE OR REPLACE FUNCTION public.percolate_with_tools(
    question TEXT,
    tool_names_in TEXT[],
    model_key VARCHAR(100) DEFAULT 'gpt-4.1-mini',
    system_prompt TEXT DEFAULT 'Respond to the users query using tools and functions as required',
    token_override TEXT DEFAULT NULL,
    temperature FLOAT DEFAULT 0.01
)
RETURNS TABLE(
    message_response text,
    tool_calls jsonb,
    tool_call_result jsonb,
    session_id_out uuid,
    status text
)  AS $$
BEGIN
    RETURN QUERY 
    SELECT * FROM percolate_with_agent(text,'p8.PercolateAgent');
END;
$$ LANGUAGE plpgsql;

-- Wrapper function `percolate_with_agent`


DROP FUNCTION IF EXISTS public.percolate_with_agent;
CREATE OR REPLACE FUNCTION public.percolate_with_agent(
    question text,
    agent text DEFAULT 'p8.PercolateAgent',
    model_key character varying DEFAULT 'gpt-4.1-mini'::character varying,
    tool_names_in text[] DEFAULT NULL::text[],
    system_prompt text DEFAULT 'Respond to the users query using tools and functions as required'::text,
    token_override text DEFAULT NULL::text,
    user_id uuid DEFAULT NULL::uuid,
    temperature double precision DEFAULT 0.01
)
RETURNS TABLE(
    message_response text,
    tool_calls jsonb,
    tool_call_result jsonb,
    session_id_out uuid,
    status text
) 
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
ROWS 1000
AS $BODY$
DECLARE
    tool_names_array TEXT[];
    endpoint_uri TEXT;
    api_token TEXT;
    selected_model TEXT;
    selected_scheme TEXT;
    function_names TEXT[];
    message_payload JSON;
    created_session_id uuid;
    	recovered_system_prompt TEXT;
BEGIN

    /*
    This wraps the inner function for ask (currently this is the canonical one for testing and we generalize for schemes)
    It takes in an agent and a question which defines the LLM request from the data.
    -- If you have followed the python guide, this agent will exist or try another agent.
    -- Example usage:
    -- select * from percolate_with_agent('list some pets that str sold', 'MyFirstAgent');
    -- First turn retrieves data from tools and provides a session id which you can resume.
    -- To test with other schemes:
    -- select * from percolate_with_agent('list some pets that str sold', 'MyFirstAgent', NONE, NONE, 'gemini-1.5-flash'); 
    -- select * from percolate_with_agent('list some pets that str sold', 'MyFirstAgent', NONE, NONE, 'claude-3-5-sonnet-20241022');

    select * from percolate_with_agent('how does percolate manage to work with google, openai and anthropic schemes seamlessly in the database - give sql examples', 'p8.PercolateAgent', 

	-- select * from p8.get_canonical_messages('8d4357de-eb78-8df5-2182-ef4d85969bc5', 'test', 'test');
	-- select * from p8.get_google_messages('8d4357de-eb78-8df5-2182-ef4d85969bc5', 'test', 'test');
	-- select * from p8.get_canonical_messages('8d4357de-eb78-8df5-2182-ef4d85969bc5', 'test', 'test');
    */

   
    -- Create session and store session ID
    SELECT create_session FROM p8.create_session(user_id, question, agent)
    INTO created_session_id;

    -- Ensure session creation was successful
    IF created_session_id IS NULL THEN
        RAISE EXCEPTION 'Failed to create session';
    END IF;

    -- Retrieve API details
    SELECT completions_uri, COALESCE(token, token_override), model, scheme
    INTO endpoint_uri, api_token, selected_model, selected_scheme
    FROM p8."LanguageModelApi"
    WHERE "name" = COALESCE(model_key, 'gpt-4.1-mini')
    LIMIT 1;

    -- Ensure API details were found
    IF api_token IS NULL OR selected_model IS NULL OR selected_scheme IS NULL THEN
        RAISE EXCEPTION 'Missing required API details for request. Model request is %s, scheme=%s',selected_model, selected_scheme;
    END IF;

    -- Default public schema for agent if not provided
    SELECT CASE 
        WHEN agent NOT LIKE '%.%' THEN 'public.' || agent 
        ELSE agent 
    END INTO agent;

    -- Fetch tools for the agent by calling the new function (we could add extra tool_names_in)
    SELECT p8.get_agent_tool_names(agent, selected_scheme, TRUE) INTO function_names;
             
    -- Ensure tools were fetched successfully
    IF function_names IS NULL THEN
        RAISE EXCEPTION 'No tools found for agent % in scheme %', agent, selected_scheme;
    END IF;

    -- Recover system prompt using agent name
    SELECT coalesce(p8.generate_markdown_prompt(agent), system_prompt) INTO recovered_system_prompt;
    
    -- Get the messages for the correct scheme
    IF selected_scheme = 'anthropic' THEN
        -- Select into message payload from p8.get_anthropic_messages
        SELECT * INTO message_payload FROM p8.get_anthropic_messages(created_session_id, question, recovered_system_prompt);
    ELSIF selected_scheme = 'google' THEN
        -- Select into message payload from p8.get_google_messages
        SELECT * INTO message_payload FROM p8.get_google_messages(created_session_id, question, recovered_system_prompt);
    ELSE
        -- Select into message payload from p8.get_canonical_messages
        SELECT * INTO message_payload FROM p8.get_canonical_messages(created_session_id, question, recovered_system_prompt);
    END IF;

    -- Ensure message payload was successfully fetched
    IF message_payload IS NULL THEN
        RAISE EXCEPTION 'Failed to retrieve message payload for session %', created_session_id;
    END IF;

    --RAISE NOTICE 'Ask request with tools % for agent % using language model %', function_names, agent, model_key;

    -- Return the results using p8.ask function
    RETURN QUERY 
    SELECT * FROM p8.ask(
        message_payload::json, 
        created_session_id, 
        function_names, 
        model_key, 
        token_override, 
        user_id
    );
END;
$BODY$;


-- Function from: plan.sql
------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.plan(
    question text,
    model_key character varying DEFAULT 'gpt-4o-mini'::character varying,
    token_override text DEFAULT NULL::text,
    user_id uuid DEFAULT NULL::uuid
)
RETURNS TABLE(
    message_response text,
    tool_calls jsonb,
    tool_call_result jsonb,
    session_id_out uuid,
    status text
) 
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
ROWS 1000
AS $BODY$
DECLARE
    endpoint_uri TEXT;
    api_token TEXT;
    selected_model TEXT;
    selected_scheme TEXT;
    functions JSON;
    message_payload JSON;
    created_session_id uuid;
    recovered_system_prompt TEXT;
    additional_message JSON;
BEGIN

    IF question IS NULL THEN
        RAISE EXCEPTION 'No question provided to the plan function - check parameters names are propagated';
    END IF;

    -- Create session and store session ID
    SELECT create_session FROM p8.create_session(user_id, question, 'p8.PlanModel')
    INTO created_session_id;

    -- Ensure session creation was successful
    IF created_session_id IS NULL THEN
        RAISE EXCEPTION 'Failed to create session';
    END IF;

    -- Retrieve API details
    SELECT completions_uri, COALESCE(token, token_override), model, scheme
    INTO endpoint_uri, api_token, selected_model, selected_scheme
    FROM p8."LanguageModelApi"
    WHERE "name" = COALESCE(model_key, 'gpt-4o-mini')
    LIMIT 1;

    -- Ensure API details were found
    IF api_token IS NULL OR selected_model IS NULL OR selected_scheme IS NULL THEN
        RAISE EXCEPTION 'Missing required API details for request. Model request is %s, scheme=%s', selected_model, selected_scheme;
    END IF;

    -- Recover system prompt
    SELECT coalesce(p8.generate_markdown_prompt('p8.PlanModel'), 'Respond to the users query using tools and functions as required')
    INTO recovered_system_prompt;

    -- Get the initial message payload
    SELECT * INTO message_payload FROM p8.get_canonical_messages(created_session_id, question, recovered_system_prompt);

    -- Ensure message payload was successfully fetched
    IF message_payload IS NULL THEN
        RAISE EXCEPTION 'Failed to retrieve message payload for session %', created_session_id;
    END IF;

    -- Retrieve functions and format as an additional user message
	SELECT json_build_object(
	    'role', 'user',
	    'content', json_agg(json_build_object('name', f.name, 'desc', f.description))::TEXT
	)
	INTO additional_message
	FROM p8."Function" f;


    -- Append the additional message correctly (handling array case)
    IF additional_message IS NOT NULL THEN
        message_payload = (message_payload::JSONB || jsonb_build_array(additional_message))::JSON;
    END IF;

    RAISE NOTICE 'Ask request for agent % using language model - % - messages %', 'p8.PlanModel', model_key, message_payload;

    -- Call p8.ask with tools set to NULL (can be updated later)
    RETURN QUERY 
    SELECT * FROM p8.ask(
        message_payload::json, 
        created_session_id, 
        NULL,  -- Tools can be fetched, but we pass NULL for now
        model_key, 
        token_override, 
        user_id
    );
END;
$BODY$;


-- ====================================================================
-- CYPHER FUNCTIONS
-- ====================================================================

-- Function from: cypher/add_relationship_to_node.sql
------------------------------------------------------------
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
    -- AGE extension is preloaded at session level
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


-- Function from: cypher/add_relationships_to_node.sql
------------------------------------------------------------
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


-- Function from: cypher/cypher_query.sql
------------------------------------------------------------
drop function if exists public.cypher_query;
CREATE OR REPLACE FUNCTION public.cypher_query(
    cypher_query TEXT,
    return_columns TEXT DEFAULT 'result agtype', -- may just take names if they are all agtypes
    graph_name TEXT DEFAULT 'percolate'   
)
RETURNS TABLE(result JSONB)  -- Adapt dynamically based on return_columns
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    sql_query TEXT;
BEGIN
	/*
	run a cypher query against the graph
	you need to name your select columns for multiple results
		 
 	select * from public.cypher_query('MATCH (v) RETURN v');
	*/

    SET search_path = ag_catalog, "$user", public;

    -- Use the dynamic graph_name in the query
    sql_query := 'WITH cypher_result AS (
                    SELECT * FROM cypher(''' || graph_name || ''', $$' || cypher_query || '$$) 
                    AS (' || return_columns || ')
                  )
                  SELECT to_jsonb(cypher_result) FROM cypher_result;';

    RETURN QUERY EXECUTE sql_query;
END;
$BODY$;


-- Function from: cypher/get_connected_entities.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.get_connected_entities;
CREATE OR REPLACE FUNCTION p8.get_connected_entities(category_name TEXT)
RETURNS TABLE (category_hub TEXT, target_entity TEXT) AS $BODY$
DECLARE
    cypher_query text;
BEGIN
	/*

	get connected entities is for sourcing nodes connected to some theme via category nodes
	For now it can be directed connected or connected by one intermediate category hub
    This could be used to create concept summaries back into the X category but summarising connected entities 
	
	--use a target node 
	SELECT * FROM p8.get_connected_entities('Physical Endurance');
	*/
	SET search_path = ag_catalog, "$user", public;
	
 	cypher_query := format(
        'WITH gdata AS (
            SELECT * FROM cypher(''percolate'', $$
                MATCH (c:Category {name: %L})-[*1]-(m:Category)-[*1]-(n:public__Chapter)
                RETURN m AS middle_node, n AS target_node
            $$) AS (hub agtype, target_node agtype)
            UNION
            SELECT * FROM cypher(''percolate'', $$
                MATCH (c:Category {name: %L})-[*1..2]-(n:public__Chapter)
                RETURN null::agtype AS middle_node, n AS target_node
            $$) AS (hub agtype, target_node agtype)
        )
        SELECT 
            (hub::json)->''properties''->>''name'' AS category_hub,
            (target_node::json)->''properties''->>''name'' AS target_entity
        FROM gdata',
        category_name, category_name
    );
    
    RETURN QUERY EXECUTE cypher_query;
END;
$BODY$ LANGUAGE plpgsql;


-- Function from: cypher/get_paths.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.get_paths;

CREATE OR REPLACE FUNCTION p8.get_paths(
	names text[],
	max_length integer DEFAULT 3,
	max_paths integer DEFAULT 10
	)
    RETURNS TABLE(path_length integer, origin_node text, target_node text, target_node_id bigint, path_node_labels text[]) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    cypher_query text;
    sql text;
BEGIN

	/*

    This is used as the basis of getting nodes related by paths as this can be used by graphwalkers

	Example usage:
	select * from p8.get_paths(ARRAY['page47_moby'])
	*/
    -- Format the Cypher query string with the input names

		SET search_path = ag_catalog, "$user", public;


    cypher_query := format(
        'MATCH p = (a:public__Chapter)-[:ref*1..%s]-(b:public__Chapter)
         WHERE a.name IN [%s]
         RETURN 
		 		length(p) AS path_length, 
                a.name AS origin_node, 
                b.name AS target_node, 
				id(b) as target_node_id,
                nodes(p) AS path_nodes',
				max_length,
            array_to_string(array(
            SELECT quote_literal(name)
            FROM unnest(names) AS name
        ), ', ')  -- Comma-separated quoted strings
    );

    -- Format the SQL statement for Cypher execution
    sql := format(
        '
		 WITH data as(
		 SELECT
		 path_length,
		 origin_node::TEXT,
		 target_node::TEXT,
		 target_node_id,
		 path_nodes::JSON
		   FROM cypher(''percolate'', $$ %s $$) AS (path_length int, origin_node agtype, target_node agtype, target_node_id BIGINT, path_nodes agtype)
		)
		-- Use the helper function get_node_property_names to extract the "name" field from the path_nodes JSON
		select 
            path_length,
            origin_node,
            target_node,
			target_node_id,
            p8.get_node_property_names(path_nodes) AS path_node_labels
		from data limit %L;
		',
        cypher_query, max_paths
    );

    -- Execute the dynamic SQL and return the result
    RETURN QUERY EXECUTE sql;
END;
$BODY$;


-- Function from: cypher/get_relationships.sql
------------------------------------------------------------
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


-- ====================================================================
-- ENTITIES FUNCTIONS
-- ====================================================================

-- Function from: entities/cypher_entity_match.sql
------------------------------------------------------------
CREATE OR REPLACE FUNCTION p8.cypher_entity_match(
	keys text[])
    RETURNS TABLE(entity_type text, node_keys text[]) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    sql TEXT;
	keys_string TEXT;
BEGIN
	SET search_path = ag_catalog, "$user", public; 
	
	SELECT string_agg(format('''%s''', k), ', ') INTO keys_string
	FROM unnest(keys) AS k;

    -- Dynamically create the Cypher query string
    sql := format($c$
	 ------

	   WITH nodes AS (
		SELECT * FROM cypher('percolate', $$ 
			MATCH (v)
			WHERE v.uid IN [%s]
			RETURN v, v.key
		    $$) AS (v agtype, key agtype)
	    ),
	    records AS (
	        SELECT 
	            key::text, 
	            (v::json)->>'label' AS entity_type
	        FROM nodes
	    ),
	    grouped_records AS (
	        SELECT 
	            CASE 
	                WHEN strpos(entity_type, '__') > 0 THEN replace(entity_type, '__', '.')
	                ELSE entity_type
	            END AS entity_type,
	            array_agg(key) AS keys
	        FROM records
	        GROUP BY entity_type
	    )
		select * from grouped_records
	 ------
	 $c$, keys_string -- this goes into the s in the cypher
    );

    -- Execute the dynamic query
    RETURN QUERY EXECUTE sql;
END;
$BODY$;


-- Function from: entities/generate_markdown_prompt.sql
------------------------------------------------------------
-- FUNCTION: public.generate_markdown_prompt(text, integer)

-- DROP FUNCTION IF EXISTS public.generate_markdown_prompt(text, integer);

CREATE OR REPLACE FUNCTION p8.generate_markdown_prompt(
	table_entity_name text,
	max_enum_entries integer DEFAULT 200)
    RETURNS text
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    markdown_prompt TEXT;
    field_info RECORD;
    field_descriptions TEXT := '';
    enum_values TEXT := '';
	column_unique_values JSONB;
    p8_system_prompt TEXT := '';
BEGIN
/*
select * from p8.generate_markdown_prompt('p8.Agent')
*/
    SELECT CASE 
        WHEN table_entity_name NOT LIKE '%.%' THEN 'public.' || table_entity_name 
        ELSE table_entity_name 
    END INTO table_entity_name;

    SELECT value 
    into p8_system_prompt from p8."Settings" where key = 'P8_SYS_PROMPT' limit 1;


    -- Add entity name and description to the markdown
    SELECT COALESCE(p8_system_prompt,'') || E'\n\n' || 
           '## Agent Name: ' || b.name || E'\n\n' || 
           '### Description: ' || E'\n\n' || COALESCE(b.description, 'No description provided.') || E'\n\n'
    INTO markdown_prompt
    FROM p8."Agent" b
    WHERE b.name = table_entity_name;

    -- Add field descriptions in a table format
    FOR field_info IN
        SELECT a.name AS field_name, 
               a.field_type, 
               COALESCE(a.description, '') AS field_description
        FROM p8."ModelField" a
        WHERE a.entity_name = table_entity_name
    LOOP
        field_descriptions := field_descriptions || 
            '| ' || field_info.field_name || ' | ' || field_info.field_type || 
            ' | ' || field_info.field_description || ' |' || E'\n';
    END LOOP;

    IF field_descriptions <> '' THEN
        markdown_prompt := markdown_prompt || 
            '### Field Descriptions' || E'\n\n' ||
            '| Field Name | Field Type | Description |' || E'\n' ||
            '|------------|------------|-------------|' || E'\n' ||
            field_descriptions || E'\n';
    END IF;

    -- Check for enums and add them if they are below the max_enum_entries threshold
    -- create some sort of enums view from metadata

	select get_unique_enum_values into column_unique_values from p8.get_unique_enum_values(table_entity_name);
	-- create an example repository for the table
	
    -- Add space for examples and functions
    markdown_prompt := markdown_prompt || 
        '### Examples' || E'\n\n' ||
        'in future we will add examples that match the question via vector search' || E'\n\n'  ||
		'### The unique distinct same values for some columns ' || E'\n\n' ||
		column_unique_values || E'\n';

		

    RETURN markdown_prompt;
END;
$BODY$;


-- Function from: entities/get_agent_tool_names.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.get_agent_tool_names;
CREATE OR REPLACE FUNCTION p8.get_agent_tool_names(
    recovered_agent TEXT,
    selected_scheme TEXT DEFAULT  'openai',
    add_percolate_tools BOOLEAN DEFAULT TRUE
)
RETURNS TEXT[] AS $$
DECLARE
    tool_names_array TEXT[];
    functions JSONB;
BEGIN

/*
select * from p8.get_agent_tool_names('p8.Agent', NULL, FALSE)
select * from p8.get_agent_tool_names('p8.Agent', NULL, TRUE)
select * from p8.get_agent_tool_names('p8.Agent', 'google')

*/
    -- Get tool names from Agent functions
    SELECT ARRAY(
        SELECT jsonb_object_keys(a.functions::JSONB)
        FROM p8."Agent" a
        WHERE a.name = recovered_agent AND a.functions IS NOT NULL
    ) INTO tool_names_array;

     -- Add percolate tools if the parameter is true
    IF add_percolate_tools THEN
        -- Augment the tool_names_array with the percolate tools
        -- These are the standard percolate tools that are added unless the entity deactivates them
        tool_names_array := tool_names_array || ARRAY[
            'help', 
            'get_entities', 
            'search', 
            'announce_generate_large_output',
            'activate_functions_by_name'
        ];
    END IF;
    
    RETURN tool_names_array;
END;
$$ LANGUAGE plpgsql;


-- Function from: entities/get_agent_tools.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.get_agent_tools;
CREATE OR REPLACE FUNCTION p8.get_agent_tools(
    recovered_agent TEXT,
    selected_scheme TEXT DEFAULT  'openai',
    add_percolate_tools BOOLEAN DEFAULT TRUE
)
RETURNS JSONB AS $$
DECLARE
    tool_names_array TEXT[];
    functions JSONB;
BEGIN

/*
select * from p8.get_agent_tools('p8.Agent', NULL, FALSE)
select * from p8.get_agent_tools('p8.Agent', NULL, TRUE)
select * from p8.get_agent_tools('p8.Agent', 'google')

*/

    SELECT p8.get_agent_tool_names(recovered_agent,selected_scheme,add_percolate_tools) into tool_names_array;

    
    -- Fetch tool data if tool names exist
    IF tool_names_array IS NOT NULL THEN
        SELECT p8.get_tools_by_name(tool_names_array, COALESCE(selected_scheme,'openai'))
        INTO functions;
    ELSE
        functions := '[]'::JSONB;
    END IF;

    -- Return the final tools data
    RETURN functions;
END;
$$ LANGUAGE plpgsql;


-- Function from: entities/get_entities.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.get_entities;
CREATE OR REPLACE FUNCTION p8.get_entities(
    keys text[],
    userid text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    result JSONB := '{}'::JSONB;
BEGIN
	/*
	import p8 get_graph_nodes_by_key

	example: selects any entity by its business key by going to the graph for the index and then joining the table
	this example happens to have a table name which is an entity also in the agents table.
	
		-- Example without user filter (returns all matching entities)
		-- select * from p8.get_entities(ARRAY['p8.Agent']);
		-- Example with user filter (returns only public or user-specific entities)
		-- select * from p8.get_entities(ARRAY['p8.Agent'], 'user123');
	*/

    SET search_path = ag_catalog, "$user", public;
	
    -- Load nodes based on keys, returning the associated entity type and key
    WITH nodes AS (
        SELECT id, entity_type FROM p8.get_graph_nodes_by_key(keys)
    ),
    grouped_records AS (
        SELECT 
            CASE 
                WHEN strpos(entity_type, '__') > 0 THEN replace(entity_type, '__', '.')
                ELSE entity_type
            END AS entity_type,
            array_agg(id) FILTER (WHERE id IS NOT NULL AND id != '') AS keys
        FROM nodes
        WHERE id IS NOT NULL AND entity_type IS NOT NULL AND id != ''
        GROUP BY entity_type
        HAVING array_length(array_agg(id) FILTER (WHERE id IS NOT NULL AND id != ''), 1) > 0
    )
    -- Combine grouped records with their table data using a JOIN and aggregate the result
    -- Use COALESCE to handle empty results
    SELECT COALESCE(
        jsonb_object_agg(
            entity_type, 
            p8.get_records_by_keys(entity_type, grouped_records.keys)
        ), 
        '{}'::jsonb
    )
    INTO result
    FROM grouped_records;

    -- Return the final JSON object
    RETURN result;
END;
$BODY$;


-- Function from: entities/get_entity_ids_by_description.sql
------------------------------------------------------------
CREATE OR REPLACE FUNCTION p8.get_entity_ids_by_description(
    description_text text,
    entity_name text,  -- The entity/table name to search
    limit_results integer DEFAULT 5
)
RETURNS TABLE(id uuid) 
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
ROWS 1000
AS $BODY$
DECLARE
    embedded_question VECTOR; -- Variable to store the computed embedding
    sql_query text;  -- Variable to store dynamic SQL query
	schema_name text;
	table_name_only text;
BEGIN
	/*
	you can use this function to get the ids of the entity and then join those in
	sql query to select e.g
    
	select a.* from p8.get_entity_ids_by_description('something about langauge models', 'p8.Agent', 1) idx
	 join p8."Agent" a on a.id = idx.id
	*/

    -- Compute the embedding once and store it in the variable
    SELECT embedding 
    INTO embedded_question
    FROM p8.get_embedding_for_text(description_text);

	schema_name := split_part(entity_name, '.', 1);
    table_name_only := split_part(entity_name, '.', 2);
	
    -- Construct the dynamic SQL query
    sql_query := format('
        WITH records AS (
            SELECT b.id, 
                   min(a.embedding_vector <-> $1) AS vdistance
            FROM p8_embeddings.%I a
            JOIN %s."%s" b ON b.id = a.source_record_id
            WHERE a.embedding_vector <-> $1 <= 0.75
            GROUP BY b.id
        )
        SELECT a.id
        FROM records a
        ORDER BY vdistance ASC
        LIMIT $2;
    ', REPLACE(entity_name, '.', '_') || '_embeddings', 
	   schema_name, table_name_only,
	   schema_name, table_name_only );

    -- Execute the dynamic SQL and return the result
    RETURN QUERY EXECUTE sql_query USING embedded_question, limit_results;
END;
$BODY$;


-- Function from: entities/get_graph_node_by_key.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.get_graph_nodes_by_key;
CREATE OR REPLACE FUNCTION p8.get_graph_nodes_by_key(
    keys text[],
    userid text DEFAULT NULL
)
RETURNS TABLE(id text, entity_type text) -- Returning both id and entity_type
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    sql_query text;
BEGIN
    -- Set search path to include ag_catalog for AGE functions
    SET search_path = ag_catalog, "$user", public;
    
    -- Construct the dynamic SQL with quoted keys and square brackets
    -- Build the dynamic SQL for retrieving graph nodes, optionally filtering by user_id
    -- Start building the Cypher match, filtering by business key
    sql_query := 'WITH nodes AS (
                    SELECT * 
                    FROM cypher(''percolate'', $$ 
                        MATCH (v)
                        WHERE v.key IN ['
                 || array_to_string(ARRAY(SELECT '"' || replace(replace(k, '\', '\\'), '"', '\"') || '"' FROM unnest(keys) AS k), ', ')
                 || '] 
                        RETURN v, v.uid 
                    $$) AS (v agtype, key agtype)
                  ), 
                  records AS (
                    SELECT 
                        key::text, 
                        (v::json)->>''label'' AS entity_type
                    FROM nodes
                  )
                  SELECT key, entity_type
                  FROM records';
    
    -- Execute the dynamic SQL and return the result
    RETURN QUERY EXECUTE sql_query;
END;
$BODY$;


-- Function from: entities/get_graph_nodes_by_id.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.get_graph_nodes_by_id;
CREATE OR REPLACE FUNCTION p8.get_graph_nodes_by_id(
    keys bigint[]
)
RETURNS TABLE(id text, entity_type text) 
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    sql_query text;
    keys_str text;
BEGIN
    /*

    we can use an alt function to get by the business key but this function queries by the AGE BIG INT id
    This can be useful for low level functions that resolves arbitrary entities of different types and we can resolve the json of the actual entity using another function e.g. as done in get_entities

    Example usage:
    SELECT * FROM p8.get_graph_nodes_by_id(ARRAY[844424930131969]);
    */

    -- Convert the array to a Cypher-friendly list format
    keys_str := array_to_string(keys, ', '); -- Converts [id1, id2] → "id1, id2"

    -- Construct the Cypher query dynamically
    sql_query := format(
        'WITH nodes AS (
            SELECT * 
            FROM cypher(''percolate'', $$ 
                MATCH (v)
                WHERE id(v) IN [%s]
                RETURN v 
            $$) AS (v agtype)
        ), 
        records AS (
            SELECT 
                (v::json)->>''id'' AS id,  -- Extracting the node ID
                (v::json)->>''label'' AS entity_type -- Extracting the label
            FROM nodes
        )
        SELECT id, entity_type FROM records',
        keys_str
    );

    -- Execute the dynamic SQL and return the result
    RETURN QUERY EXECUTE sql_query;
END;
$BODY$;


-- Function from: entities/get_grouped_records.sql
------------------------------------------------------------
CREATE OR REPLACE FUNCTION p8.get_grouped_records(
	keys text[])
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    result JSONB := '{}'::JSONB;
BEGIN
    WITH nodes AS (
        SELECT * FROM cypher('percolate', $$
            MATCH (v)
            WHERE v.uid IN %L
            RETURN v, v.key
        $$, keys) AS (v agtype, key agtype)
    ),
    records AS (
        SELECT 
            key::text, 
            (v::json)->>'label' AS entity_type
        FROM nodes
    ),
    grouped_records AS (
        SELECT 
            CASE 
                WHEN strpos(entity_type, '__') > 0 THEN replace(entity_type, '__', '.')
                ELSE entity_type
            END AS entity_type,
            array_agg(key) AS keys
        FROM records
        GROUP BY entity_type
    )
    SELECT jsonb_agg(jsonb_build_object('entity_type', entity_type, 'keys', keys))
    INTO result
    FROM grouped_records;

    RETURN result;
END;
$BODY$;


-- Function from: entities/get_records_by_keys.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.get_records_by_keys;
CREATE OR REPLACE FUNCTION p8.get_records_by_keys(
    table_name TEXT,
    key_list TEXT[],
    key_column TEXT DEFAULT 'id'::TEXT,
    include_entity_metadata BOOLEAN DEFAULT TRUE
)
RETURNS JSONB
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    result JSONB;            -- The JSON result to be returned
    metadata JSONB;          -- The metadata JSON result
    query TEXT;              -- Dynamic query to execute
    schema_name VARCHAR;
    pure_table_name VARCHAR;
    safe_key_list TEXT[];    -- Safely processed key list
BEGIN
    -- Ensure clean search path to avoid session variable interference
    SET LOCAL search_path = p8, public;
    
    schema_name := lower(split_part(table_name, '.', 1));
    pure_table_name := split_part(table_name, '.', 2);

    -- Debug: Log what we received
    RAISE NOTICE 'get_records_by_keys: table=%, input_keys=%, input_type=%', table_name, key_list, pg_typeof(key_list);

    -- Check if key_list is empty, null, or contains only empty strings
    IF key_list IS NULL OR array_length(key_list, 1) IS NULL OR array_length(key_list, 1) = 0 THEN
        result := '[]'::jsonb;
    ELSE
        -- Filter out empty strings and null values from key_list
        safe_key_list := array_remove(array_remove(key_list, ''), NULL);
        
        -- Check again after filtering
        IF safe_key_list IS NULL OR array_length(safe_key_list, 1) IS NULL OR array_length(safe_key_list, 1) = 0 THEN
            result := '[]'::jsonb;
        ELSE
            -- Debug: Log what we're about to query
            RAISE NOTICE 'get_records_by_keys: filtered_keys=%, array_length=%', safe_key_list, array_length(safe_key_list, 1);
            
            -- Use a safer approach: build the query with explicit array handling
            query := format('SELECT jsonb_agg(to_jsonb(t)) FROM %I."%s" t WHERE t.%I::TEXT = ANY($1::TEXT[])', schema_name, pure_table_name, key_column);
            
            -- Execute the dynamic query with the safe key list
            EXECUTE query USING safe_key_list INTO result;
        END IF;
    END IF;
    
    -- Fetch metadata if include_entity_metadata is TRUE
    IF include_entity_metadata THEN
        -- Initialize metadata to NULL first
        metadata := NULL;
        
        -- Try to fetch metadata from Agent table
        BEGIN
            SELECT jsonb_build_object(
                'description', COALESCE(a.description, ''),
                'functions', a.functions
            )
            INTO metadata
            FROM p8."Agent" a
            WHERE a.name = table_name;
        EXCEPTION 
            WHEN OTHERS THEN
                -- If any error occurs (including JSON casting errors), set metadata to NULL
                metadata := NULL;
        END;
    ELSE
        metadata := NULL;
    END IF;
    
    -- Return JSONB object containing both data and metadata
    RETURN jsonb_build_object('data', result,
								'metadata', metadata, 
								'instruction', 'you can request to activate new functions by name to use them as tools');
END;
$BODY$;


-- Function from: entities/get_unique_enum_values.sql
------------------------------------------------------------
CREATE OR REPLACE FUNCTION p8.get_unique_enum_values(
	table_name text,
	max_limit integer DEFAULT 250)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    schema_name TEXT;
    table_name_only TEXT;
    col RECORD;
    unique_values JSONB = '{}'::JSONB;
	column_unique_values JSONB;
    sql_query TEXT;
BEGIN
    -- Split the fully qualified table name into schema and table name
    schema_name := split_part(table_name, '.', 1);
    table_name_only := split_part(table_name, '.', 2);

    FOR col IN
        SELECT   attname  
		FROM   pg_stats
		WHERE   schemaname = schema_name     AND tablename = table_name_only and n_distinct between 1 and max_limit  

	    LOOP
	        -- Prepare dynamic SQL to count distinct values in each column
	        sql_query := format(
	            'SELECT jsonb_agg(%I) FROM (SELECT DISTINCT %I FROM %I."%s" ) AS subquery',
	            col.attname, col.attname, schema_name, table_name_only
	        );
			--RAISE NOTICE '%', sql_query;
	        -- Execute the dynamic query and store the result in the JSON object
	        EXECUTE sql_query INTO column_unique_values;

	        -- Add the unique values for the column to the JSON object
	        -- The key is the column name, the value is the array of unique values
	        unique_values := unique_values || jsonb_build_object(col.attname, column_unique_values);
	    END LOOP;

    -- Return the JSON object with unique values for each column
    RETURN unique_values;
END;
$BODY$;


-- Function from: entities/query_entity.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.query_entity;
CREATE OR REPLACE FUNCTION p8.query_entity(
    question TEXT,
    table_name TEXT,
    user_id UUID DEFAULT NULL,
    semantic_only BOOLEAN DEFAULT FALSE,
    vector_search_function TEXT DEFAULT 'vector_search_entity',
    min_confidence NUMERIC DEFAULT 0.7
)
RETURNS TABLE(
    query_text TEXT,
    confidence NUMERIC,
    relational_result JSONB,
    vector_result JSONB,
    error_message TEXT
) 
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
ROWS 1000
AS $BODY$
DECLARE
    query_to_execute TEXT;
    query_confidence NUMERIC;
    schema_name TEXT;
    table_without_schema TEXT;
    full_table_name TEXT;
    sql_query_result JSONB;
    sql_error TEXT;
    vector_search_result JSONB;
    embedding_for_text VECTOR;
    ack_http_timeout BOOLEAN;
BEGIN

    /*
    first crude look at merging multiple together
    we will spend time on this later with a proper fast parallel index

    select * from p8.nl2sql('current place of residence', 'p8.UserFact' )
    select * from p8.query_entity('what is my favourite color', 'p8.UserFact', 'e9c56a28-1d09-5253-af36-4b9d812f6bfa')
    select * from p8.query_entity('what is my favourite color', 'p8.UserFact', '10e0a97d-a064-553a-9043-3c1f0a6e6725')

    select * from p8.query_entity('what sql queries do we have for generating uuids from json', 'p8.PercolateAgent')
    */

    -- Extract schema and table name
    schema_name := split_part(table_name, '.', 1);
    table_without_schema := split_part(table_name, '.', 2);
    full_table_name := FORMAT('%I."%I"', schema_name, table_without_schema);

    select http_set_curlopt('CURLOPT_TIMEOUT','8000') into ack_http_timeout;
    RAISE NOTICE 'THE HTTP TIMEOUT IS HARDCODED TO 8000ms';  

    -- Initialize error and result variables
    sql_error := NULL;
    sql_query_result := NULL;
    vector_search_result := NULL;

    IF NOT semantic_only THEN
        -- Call the nl2sql function to get the SQL query and confidence
        SELECT "query", nq.confidence INTO query_to_execute, query_confidence  
        FROM p8.nl2sql(question, table_name) nq;

        -- Replace 'YOUR_TABLE' in the query with the actual table name
        query_to_execute := REPLACE(query_to_execute, 'YOUR_TABLE', full_table_name);

        -- Execute the SQL query if confidence is high enough
        IF query_confidence >= min_confidence THEN
            BEGIN
                query_to_execute := rtrim(query_to_execute, ';');
                EXECUTE FORMAT('SELECT jsonb_agg(row_to_json(t)) FROM (%s) t', query_to_execute)
                INTO sql_query_result;
            EXCEPTION
                WHEN OTHERS THEN
                    sql_error := SQLERRM; -- Capture the error message
                    sql_query_result := NULL;
            END;
        END IF;
    ELSE
        -- Skip SQL query generation and execution
        query_to_execute := NULL;
        query_confidence := 0;
        sql_query_result := '[]'::jsonb;
    END IF;

    -- Get the embedding for the question
    SELECT p8.get_embedding_for_text(question) INTO embedding_for_text;

    -- Use the selected vector search function to perform the vector search
    -- update this to filter by user id if its provided
    BEGIN
        IF user_id IS NOT NULL THEN
            EXECUTE FORMAT(
                'SELECT jsonb_agg(row_to_json(result)) 
                 FROM (
                     SELECT b.*, a.vdistance 
                     FROM p8.%I(%L, %L) a
                     JOIN %I.%I b ON b.id = a.id  
                     WHERE (b.userid IS NULL OR b.userid = %L)
                     ORDER BY a.vdistance
                 ) result',
                vector_search_function, question, table_name,
                schema_name, table_without_schema, user_id
            ) INTO vector_search_result;
        ELSE
            EXECUTE FORMAT(
                'SELECT jsonb_agg(row_to_json(result)) 
                 FROM (
                     SELECT b.*, a.vdistance 
                     FROM p8.%I(%L, %L) a
                     JOIN %I.%I b ON b.id = a.id  
                     ORDER BY a.vdistance
                 ) result',
                vector_search_function, question, table_name,
                schema_name, table_without_schema
            ) INTO vector_search_result;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            sql_error := COALESCE(sql_error, '') || '; Vector search error: ' || SQLERRM;
            vector_search_result := NULL;
    END;

    -- Return results as separate columns
    RETURN QUERY 
    SELECT 
        query_to_execute AS query_text,
        query_confidence AS confidence,
        sql_query_result AS relational_result,
        vector_search_result AS vector_result,
        sql_error AS error_message;
END;
$BODY$;


-- Function from: entities/register_entities.sql
------------------------------------------------------------
-- FUNCTION: p8.register_entities(text, boolean, text)

-- DROP FUNCTION IF EXISTS p8.register_entities(text, boolean, text);

CREATE OR REPLACE FUNCTION p8.register_entities(
	qualified_table_name text,
	plan boolean DEFAULT false,
	graph_name text DEFAULT 'percolate'::text)
    RETURNS TABLE(load_and_cypher_script text, view_script text) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    schema_name TEXT;
    table_name TEXT;
    graph_node TEXT;
    view_name TEXT;
    -- dynamically determined business key field for graph nodes
    key_col TEXT;
BEGIN
    -- Split schema and table name
    schema_name := split_part(qualified_table_name, '.', 1);
    table_name := split_part(qualified_table_name, '.', 2);
    graph_node := format('%s__%s', schema_name, table_name);
    view_name := format('vw_%s_%s', schema_name, table_name);
    -- Determine the business key field for this entity (default to 'name')
    SELECT COALESCE(
        (SELECT mf.name
         FROM p8."ModelField" mf
         WHERE mf.entity_name = qualified_table_name AND mf.is_key = true
         LIMIT 1),
        'name'
    )
    INTO key_col;

    -- Create the LOAD and Cypher script
    load_and_cypher_script := format(
        $CY$
        SET search_path = ag_catalog, "$user", public;
        SELECT * 
        FROM cypher('%s', $$
            CREATE (:%s{key:'ref', uid: 'ref'})
        $$) as (v agtype);
        $CY$,
        graph_name, graph_node
    );

    -- Create the VIEW script, using dynamic key_col
    -- the key col default to name or key by convention but could be anything
    -- in principle if we change the key column it could invalidate the index 
    -- forcing us to rebuild for a new key in extreme cases
    view_script := format(
        $$
        CREATE OR REPLACE VIEW p8."%s" AS (
            WITH G AS (
                SELECT id AS gid,
                       (properties::json->>'uid')::VARCHAR AS node_uid,
                       (properties::json->>'key')::VARCHAR AS node_key
                FROM %s."%s" g
            )

            SELECT t.%s AS key,
                   t.id::VARCHAR(50) AS uid,
                   t.updated_at,
                   t.created_at,
                   t.userid,
                   G.*
            FROM %s."%s" t
            LEFT JOIN G ON t.id::character varying(50)::text = G.node_uid::character varying(50)::text
        );
        $$,
        view_name,
        graph_name,
        graph_node,
        key_col,
        schema_name,
        table_name
    );

	IF NOT plan THEN
        EXECUTE load_and_cypher_script;
        EXECUTE view_script;
    END IF;

    RETURN QUERY SELECT load_and_cypher_script, view_script;
END;
$BODY$;

ALTER FUNCTION p8.register_entities(text, boolean, text)
    OWNER TO postgres;


-- Function from: entities/vector_search_entity.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.vector_search_entity;

CREATE OR REPLACE FUNCTION p8.vector_search_entity(
    question TEXT,
    entity_name TEXT,
    distance_threshold NUMERIC DEFAULT 0.75,
    limit_results INTEGER DEFAULT 3 --TODO think about this, this is very low
)
RETURNS TABLE(id uuid, vdistance double precision) 
LANGUAGE 'plpgsql'
AS $BODY$
DECLARE
    embedding_for_text TEXT;
    schema_name TEXT;
    table_name TEXT;
    vector_search_query TEXT;
BEGIN
    /*
	This is a generic model search that resturns ids which can be joined with the original table
	we dont do it ine one because we want to dedup and take min distance on multiple embeddings 
	
	select  * from p8.vector_search_entity('what sql queries do we have for generating uuids from json', 'p8.PercolateAgent')
	*/
    -- Format the entity name to include the schema if not already present
    SELECT CASE 
        WHEN entity_name NOT LIKE '%.%' THEN 'public.' || entity_name 
        ELSE entity_name 
    END INTO entity_name;

    -- Compute the embedding for the question
    embedding_for_text := p8.get_embedding_for_text(question);

    -- Extract schema and table name from the entity name (assuming format schema.table)
    schema_name := split_part(entity_name, '.', 1);
    table_name := split_part(entity_name, '.', 2);

    -- Construct the dynamic query using a CTE to order by vdistance and limit results
    vector_search_query := FORMAT(
        'WITH vector_search_results AS (
            SELECT b.id, MIN(a.embedding_vector <-> %L) AS vdistance
            FROM p8_embeddings."%s_%s_embeddings" a
            JOIN %s.%I b ON b.id = a.source_record_id
            WHERE a.embedding_vector <-> %L <= %L
            GROUP BY b.id
        )
        SELECT id, vdistance
        FROM vector_search_results
        ORDER BY vdistance
        LIMIT %s',
        embedding_for_text, schema_name, table_name, schema_name, table_name, embedding_for_text, distance_threshold, limit_results
    );

    -- Execute the query and return the results
    RETURN QUERY EXECUTE vector_search_query;
END;
$BODY$;


-- ====================================================================
-- INDEX FUNCTIONS
-- ====================================================================

-- Function from: index/add_nodes_AND_insert_entity_nodes.sql
------------------------------------------------------------
/*
this file contains two queries that go together. 
1] The first contains the main logic to add a graph node using a view over entities of type X
2] the second just iterates to flush batches
*/

DROP FUNCTION IF EXISTS   p8.add_nodes;
CREATE OR REPLACE FUNCTION p8.add_nodes(
	table_name text)
    RETURNS integer
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    cypher_query TEXT;
    row RECORD;
    sql TEXT;
    schema_name TEXT;
    pure_table_name TEXT;
    view_name TEXT;
    view_exists BOOLEAN;
    nodes_created_count INTEGER := 0;  
BEGIN

    /*
    Adding nodes uses a contractual view over age nodes
    we keep track of any Percolate entity in the graph with a graph id, label (key) and user id if given
    */
    --AGE extension is preloaded at session level
    SET search_path = ag_catalog, "$user", public; 

    schema_name := lower(split_part(table_name, '.', 1));
    pure_table_name := split_part(table_name, '.', 2);
    view_name := format('p8."vw_%s_%s"', schema_name, pure_table_name);
    
    -- Check if the view exists before attempting to query it
    EXECUTE format('
        SELECT EXISTS (
            SELECT FROM information_schema.views 
            WHERE table_schema = ''p8'' 
            AND table_name = ''vw_%s_%s''
        )', schema_name, pure_table_name) 
    INTO view_exists;
    
    -- If view doesn't exist, log a message and return 0
    IF NOT view_exists THEN
        RAISE NOTICE 'View % does not exist - skipping node creation', view_name;
        RETURN 0;
    END IF;

    cypher_query := 'CREATE ';

    -- Loop through each row in the table  
    FOR row IN
        EXECUTE format('SELECT uid, key, userid FROM %s WHERE gid IS NULL LIMIT 1660', view_name)
    LOOP
        -- Append Cypher node creation for each row (include user_id only when present)
        IF row.userid IS NULL THEN
            cypher_query := cypher_query || format(
                '(:%s__%s {uid: "%s", key: "%s"}), ',
                schema_name, pure_table_name, row.uid, row.key
            );
        ELSE
            cypher_query := cypher_query || format(
                '(:%s__%s {uid: "%s", key: "%s", user_id: "%s"}), ',
                schema_name, pure_table_name, row.uid, row.key, row.userid
            );
        END IF;

        nodes_created_count := nodes_created_count + 1;
    END LOOP;

    --run the batch
    IF nodes_created_count > 0 THEN
        cypher_query := left(cypher_query, length(cypher_query) - 2);

        sql := format(
            'SELECT * FROM cypher(''percolate'', $$ %s $$) AS (v agtype);',
            cypher_query
        );

        EXECUTE sql;

        RETURN nodes_created_count;
    ELSE
        -- No rows to process
        RAISE NOTICE 'Nothing to do in add_nodes for this batch - all good';
        RETURN 0;
    END IF;
END;
$BODY$;


/*
------------------------------------------------
Below is the query for managing batches of inserts
------------------------------------------------
*/

DROP FUNCTION IF EXISTS   p8.insert_entity_nodes;

CREATE OR REPLACE FUNCTION p8.insert_entity_nodes(
	entity_table text)
    RETURNS TABLE(entity_name text, total_records_affected integer) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    records_affected INTEGER := 0;
    total_records_affected INTEGER := 0;
BEGIN
	/*imports p8.add_nodes*/
    -- Loop until no more records are affected
    LOOP
        -- Call p8_add_nodes and get the number of records affected
        SELECT add_nodes INTO records_affected FROM p8.add_nodes(entity_table);

        -- If no records are affected, exit the loop
        IF records_affected = 0 THEN
            EXIT;
        END IF;

        -- Add the current records affected to the total
        total_records_affected := total_records_affected + records_affected;
    END LOOP;

    -- Return the entity name and total records affected
    RETURN QUERY SELECT entity_table AS entity_name, total_records_affected;
END;
$BODY$;


-- Function from: index/add_weighted_edges.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.add_weighted_edges;

CREATE OR REPLACE FUNCTION p8.add_weighted_edges(
    node_data jsonb,  -- JSON array containing multiple nodes with their respective edges
    table_name text DEFAULT NULL,
    edge_name text DEFAULT 'semref'
)
RETURNS void
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    node_name text;
    edge jsonb;
    neighbor_name text;
    edge_weight float;
    cypher_query text;
    sql text;
    schema_name text;
    pure_table_name text;
    formatted_node_name text;
BEGIN
    /*
    Adds weighted edges for nodes provided in the `node_data` JSON array.
    This is used to build KKN edges. Note that semantic search finds a neighborhood anyway
    but this can be used if we want to probe sparsely and then fill in the detail.
    A worker processes can add KNN or balltree neighborhoods.
    
    The input `node_data` should contain a JSON array where each item represents a node with a "name" and an "edges" array.
    Each node's "edges" array should be a list of objects, each containing a "name" for the neighbor node and a "weight" for the edge.

    Example input format:
    SELECT p8.add_weighted_edges(
    '[
        {
            "name": "page127_moby",
            "edges": [
                {"name": "page126_moby", "weight": 0.5},
                {"name": "page128_moby", "weight": 0.8}
            ]
        }
    ]'::jsonb,
    'public.Chapter'
    );

    This function will loop through each node in the array and for each node, loop through its "edges" array
    to add a relationship between the node and the neighboring nodes.

	--retrieve related nodes
	SELECT * FROM cypher('percolate', $$ 
	MATCH (a{name:'page127_moby'})-[r:semref]->(b)
	RETURN a.name AS node1, b.name AS node2, r.weight AS edge_weight
	$$) AS (node1 text, node2 text, edge_weight float);

    */

    -- AGE extension is preloaded at session level
    SET search_path = ag_catalog, "$user", public;

    -- Loop through each node in the "node_data" JSON array
    FOR node_data IN SELECT * FROM jsonb_array_elements(node_data)
    LOOP
        -- Extract the node name from the current node JSON object
        node_name := node_data->>'name';

        -- If table_name is provided, split it into schema and table format
        IF table_name IS NOT NULL THEN
            schema_name := lower(split_part(table_name, '.', 1));
            pure_table_name := split_part(table_name, '.', 2);
            formatted_node_name := schema_name || '__' || pure_table_name;
        ELSE
            formatted_node_name := node_name; -- Default to node_name if no table_name is provided
        END IF;

        -- Loop through each neighbor in the "edges" array of the current node
        FOR edge IN SELECT * FROM jsonb_array_elements(node_data->'edges')
        LOOP
            -- Extract the neighbor's name and weight
            neighbor_name := edge->>'name';
            edge_weight := (edge->>'weight')::float;

            -- Construct the Cypher query to add the weighted edge
            cypher_query := format(
                'MERGE (a:%s {name: ''%s''})
                 MERGE (b:%s {name: ''%s''})
                 MERGE (a)-[r:%I {weight: %s}]->(b)',
                formatted_node_name, node_name, formatted_node_name, neighbor_name, edge_name, edge_weight
            );
	
            -- Format SQL statement for Cypher execution
            sql := format(
                'SELECT * FROM cypher(''percolate'', $$ %s $$) AS (v agtype);',
                cypher_query
            );

            BEGIN
                -- Execute the Cypher query to create the edge
                EXECUTE sql;
            EXCEPTION
                WHEN OTHERS THEN
                    -- Handle errors if any
                    RAISE NOTICE 'Error while adding edge between % and %: %', node_name, neighbor_name, SQLERRM;
            END;
        END LOOP;
    END LOOP;
END;
$BODY$;


-- Function from: index/build_graph_index.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.build_graph_index;
CREATE OR REPLACE FUNCTION p8.build_graph_index(
    entity_name TEXT,
    graph_path_column TEXT DEFAULT 'graph_paths'
)
RETURNS TABLE (graph_element TEXT) AS $$
DECLARE
    paths_json jsonb;
    table_name TEXT;
    schema_name TEXT;
    quoted_table TEXT;
BEGIN
    /*
        Example usage:
        SELECT * FROM p8.build_graph_index('public.Chapter', 'concept_graph_paths');

				select * from p8.get_connected_nodes('public.Chapter', 'page3_moby', 'public.Chapter')

		
    */

    SET search_path = ag_catalog, "$user", public;


    schema_name := lower(split_part(entity_name, '.', 1));
    table_name := split_part(entity_name, '.', 2);
    
    -- Quote the schema and table name properly
    quoted_table := format('%s.%I', schema_name, table_name);
    
    -- Construct the JSON array of paths in the format name/path/tail
    EXECUTE format(
        'SELECT jsonb_agg(name || ''/'' || path) 
         FROM (SELECT name, unnest(%I) AS path FROM %s 
               WHERE name IS NOT NULL AND %I IS NOT NULL) sub',
        graph_path_column, quoted_table, graph_path_column
    )
    INTO paths_json;

	 -- Execute the graph creation function with the generated paths
    EXECUTE format(
        'SELECT p8.create_graph_from_paths(%L::jsonb);', paths_json
    );
	
    -- Return the list of elements extracted from the JSON array
    RETURN QUERY 
    SELECT jsonb_array_elements_text(paths_json);
END;
$$ LANGUAGE plpgsql;


-- Function from: index/create_graph_from_paths.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.create_graph_from_paths;

CREATE OR REPLACE FUNCTION p8.create_graph_from_paths(
	paths_json jsonb,
	path_source_node_type text DEFAULT 'public.Chapter'::text,
	graph_path_relation text DEFAULT 'ref'::text,
	graph_category_node text DEFAULT 'Category'::text)
    RETURNS TABLE (path TEXT, status TEXT, error_message TEXT)
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    path text;
    path_elements text[];
    task_name text;
    category1_name text;
    category2_name text;
    cypher_query text;
    schema_name TEXT;
    pure_table_name TEXT;
    graph_path_node TEXT;
    sql text;
    results jsonb := '[]'::jsonb;  -- Initialize an empty JSON array to store results
BEGIN
    /*

    You can create a typed path along typed nodes from any source node
    The source node should follow the node conventions for table names and they key should be the first part of the path
    
    Example usage:
    SELECT p8.create_graph_from_paths('["page62_moby/B/C", "page47_moby/B/C", "TX/B/D"]'::jsonb);
    SELECT p8.create_graph_from_paths('["page62_moby/B/C"]'::jsonb);
    
    If these have been added, you can connect page 47 to page 62 via node Category:C
    
    Sample Cypher Queries:
    SELECT * FROM cypher('percolate', $$ MATCH path = (a:P8_Task {name: 'TX'})-[:ref]->(b:Category)-[:ref]->(c:Category) RETURN path $$) AS (path agtype);
    SELECT * FROM cypher('percolate', $$ MATCH path = (start:public__Chapter {name: 'page62_moby'})-[:ref*1..3]-(ch:public__Chapter) RETURN ch, length(path) AS path_length $$) AS (ch agtype, path_length int);
    
    */
    
    -- Load AGE extension and set search path
    -- AGE extension is preloaded at session level
    SET search_path = ag_catalog, "$user", public;

    -- Extract the schema and table names for the source node
    schema_name := lower(split_part(path_source_node_type, '.', 1));
    pure_table_name := split_part(path_source_node_type, '.', 2);
    graph_path_node := schema_name || '__' || pure_table_name;

    -- Iterate over each path in the JSON array and process
    FOR path IN SELECT jsonb_array_elements_text(paths_json)
    LOOP
        -- Split the path into its components
        path_elements := string_to_array(path, '/');
        
        -- Ensure path has exactly three elements (Task -> Category1 -> Category2)
        IF array_length(path_elements, 1) = 3 THEN
            task_name := path_elements[1];
            category1_name := path_elements[2];
            category2_name := path_elements[3];

            -- Construct the Cypher query with dynamic parameters
            cypher_query := format(
                'MERGE (a:%s {name: ''%s''})
                 MERGE (b:%s {name: ''%s''})
                 MERGE (c:%s {name: ''%s''})
                 MERGE (a)-[:%I]->(b)
                 MERGE (b)-[:%I]->(c)',
                graph_path_node, REPLACE(task_name, '''', ''), graph_category_node, category1_name, graph_category_node, category2_name,
                graph_path_relation, graph_path_relation
            );

            -- Format the SQL statement for Cypher execution
            sql := format(
                'SELECT * FROM cypher(''percolate'', $$ %s $$) AS (v agtype);',
                cypher_query
            );

            BEGIN
                -- Execute the Cypher query
                EXECUTE sql;

                -- Accumulate success result in the JSON array
                results := results || jsonb_build_object('path', path, 'status', 'success', 'error_message', NULL);
            EXCEPTION
                WHEN OTHERS THEN
                    -- Accumulate failure result with error message in the JSON array
                    results := results || jsonb_build_object('path', path, 'status', 'failure', 'error_message', SQLERRM);
            END;
        ELSE
            -- If path format is invalid (not exactly 3 elements), accumulate failure result
            results := results || jsonb_build_object('path', path, 'status', 'failure', 'error_message', 'Invalid path format');
        END IF;
    END LOOP;

    -- Return all results at once as a single table
    RETURN QUERY 
    SELECT * FROM jsonb_to_recordset(results) AS (path TEXT, status TEXT, error_message TEXT);

END;
$BODY$;


-- Function from: index/fetch_embeddings.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.fetch_embeddings;

CREATE OR REPLACE FUNCTION p8.fetch_embeddings(
    param_array_data jsonb,
    param_token text DEFAULT NULL,
    param_model text DEFAULT 'default')
    RETURNS TABLE(embedding vector) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000
AS $BODY$
DECLARE
    resolved_model text;
    resolved_token text;
    response jsonb;
    status_code int;
    request_url text;
    use_ollama BOOLEAN;
BEGIN
/*
-- Example calls 
   1 OLLAMA case for a dockerized ollama:
	-- for small hardware making the request directly is slow so we can set a timeout
   select http_set_curlopt('CURLOPT_TIMEOUT','20000') into ack_http_timeout;
   SELECT * FROM p8.fetch_embeddings(
    '["Hello world", "How are you?"]'::jsonb,
    NULL,
    'bge-m3'
);

SELECT * FROM p8.fetch_embeddings(
    '["Hello world", "How are you?"]'::jsonb,
    NULL,
    'text-embedding-ada-002'
);
*/
    -- Set the model to 'text-embedding-ada-002' if it's 'default'
    resolved_model := CASE 
        WHEN param_model = 'default' THEN 'text-embedding-ada-002'
        ELSE param_model
    END;

    -- Check if the model should use Ollama
    use_ollama := resolved_model IN ('bge-m3');

    IF use_ollama THEN
        request_url := 'http://ollama:11434/api/embed';
        resolved_token := ''; -- No API token required for Ollama
    ELSE
        -- If the token is not set, fetch it
        IF param_token IS NULL THEN
            SELECT token INTO resolved_token
            FROM p8."LanguageModelApi"
            WHERE "name" = 'gpt-4o-mini';
        ELSE
            resolved_token := param_token;
        END IF;

        request_url := 'https://api.openai.com/v1/embeddings';
    END IF;

    BEGIN
        -- Execute HTTP request
        SELECT content::jsonb INTO response
        FROM http( (
            'POST', 
            request_url, 
            ARRAY[http_header('Authorization', 'Bearer ' || resolved_token)],
            'application/json',
            jsonb_build_object(
                'input', param_array_data,
                'model', resolved_model,
                'encoding_format', 'float'
            )
        )::http_request);
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'HTTP request failed: %', SQLERRM;
    END;

    IF response IS NULL THEN
        RAISE EXCEPTION 'API response is null, request might have failed';
    END IF;

    status_code := response->>'status';

    IF status_code >= 400 THEN
        RAISE EXCEPTION 'API request failed with status: %, response: %', status_code, response;
    END IF;

    -- Return embeddings if no errors
	IF use_ollama THEN
		RETURN QUERY
		--not sure in general yet what the interfaces are but at least embeddings is plural for ollama
	    SELECT VECTOR(item::TEXT) AS embedding
	    FROM jsonb_array_elements(response->'embeddings') AS item;
	ELSE
	    RETURN QUERY
	    SELECT VECTOR((item->'embedding')::TEXT) AS embedding
	    FROM jsonb_array_elements(response->'data') AS item;
	END IF;
END;
$BODY$;


-- Function from: index/fetch_openai_embeddings.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.fetch_openai_embeddings;

CREATE OR REPLACE FUNCTION p8.fetch_openai_embeddings(
    param_array_data jsonb,
	param_token text DEFAULT NULL,
    param_model text DEFAULT 'default')
    RETURNS TABLE(embedding vector) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    resolved_model text;
    resolved_token text;
BEGIN
    -- Set the model to 'text-embedding-ada-002' if it's 'default'
    resolved_model := CASE 
        WHEN param_model = 'default' THEN 'text-embedding-ada-002'
        ELSE param_model
    END;

    -- If the token is not set, fetch it - we dont have to use the model below to select just any model that uses the same key
    IF param_token IS NULL THEN
        SELECT token
        INTO resolved_token
        FROM p8."LanguageModelApi"
        WHERE "name" = 'gpt-4o-mini';
    ELSE
        resolved_token := param_token;
    END IF;

    -- Execute HTTP request to fetch embeddings and return the parsed embeddings as pgvector
    RETURN QUERY
    SELECT VECTOR((item->'embedding')::TEXT) AS embedding
    FROM (
        SELECT jsonb_array_elements(content::JSONB->'data') AS item
        FROM http((
            'POST', 
            'https://api.openai.com/v1/embeddings', 
            ARRAY[http_header('Authorization', 'Bearer ' || resolved_token)],
            'application/json',
            jsonb_build_object(
                'input', param_array_data,
                'model', resolved_model,
                'encoding_format', 'float'
            )
        )::http_request)
    ) subquery;
END;
$BODY$;


-- Function from: index/generate_and_fetch_embeddings.sql
------------------------------------------------------------
-- FUNCTION: p8.generate_and_fetch_embeddings(text, text, text, text, integer)

-- DROP FUNCTION IF EXISTS p8.generate_and_fetch_embeddings(text, text, text, text, integer);

CREATE OR REPLACE FUNCTION p8.generate_and_fetch_embeddings(
	param_table text,
	param_column text,
	param_embedding_model text DEFAULT 'default'::text,
	param_token text DEFAULT NULL::text,
	param_limit_fetch integer DEFAULT 200)
    RETURNS TABLE(id uuid, source_id uuid, embedding_id text, column_name text, embedding vector) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    resolved_model text;
BEGIN
	/*
	imports
	p8.generate_requests_for_embeddings

	example

	select * from p8.generate_and_fetch_embeddings('p8.Resources', 'content')
	*/

    -- Set the model to 'text-embedding-ada-002' if it's 'default'
    resolved_model := CASE 
        WHEN param_embedding_model = 'default' THEN 'text-embedding-ada-002'
        ELSE param_embedding_model 
    END;

    -- If the token is not set, fetch it
    IF param_token IS NULL THEN
        SELECT token
        INTO param_token 
        FROM p8."LanguageModelApi"
        WHERE "name" = 'gpt-4o-mini';
    END IF;

    -- Execute the main query
    RETURN QUERY EXECUTE format(
        $sql$
		--first request anything that needs embeddings
		WITH request AS (
			SELECT *  FROM p8.generate_requests_for_embeddings(%L,%L,%L) LIMIT %L
		),
		payload AS (
			--the payload is an array of cells with a description ->JSONB
			SELECT jsonb_agg(description) AS aggregated_data
			--SELECT jsonb_build_array(description) AS aggregated_data
			FROM request
		),
		--we then pass these to some openai model for now - could be a more generalized model for embeddings
        embedding_result AS (
            SELECT 
                embedding,
                ROW_NUMBER() OVER () AS idx
            FROM p8.fetch_embeddings(
				(SELECT aggregated_data FROM payload),
                %L,            
                %L
            )
        )
		--by joining the ids we match the original table index to the result from open ai 
		-- we are assuming all descriptinos have some text or fails
        SELECT 
            request.bid AS id,
            request.source_id,
            request.embedding_id,
            request.column_name,
            embedding_result.embedding
        FROM embedding_result
        JOIN request ON request.idx = embedding_result.idx
        $sql$,
        param_table,
        param_column,
        resolved_model,
        param_limit_fetch,
        param_token,
        resolved_model
    );
END;
$BODY$;

ALTER FUNCTION p8.generate_and_fetch_embeddings(text, text, text, text, integer)
    OWNER TO postgres;


-- Function from: index/generate_requests_for_embeddings.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.generate_requests_for_embeddings;

CREATE OR REPLACE FUNCTION p8.generate_requests_for_embeddings(
	param_table text,
	param_description_col text,
	param_embedding_model text,
	max_length integer DEFAULT 10000)
    RETURNS TABLE(eid uuid, source_id uuid, description text, bid uuid, column_name text, embedding_id text, idx bigint) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    sanitized_table TEXT;
    PSCHEMA TEXT;
    PTABLE TEXT;
BEGIN
/*
if there are records in the table for this embedding e.g. the table like p8.Agents has unfilled records 
WE are filtering out cases where there is a null or blank description column

		select * from p8.generate_requests_for_embeddings('p8.Resources', 'content', 'text-embedding-ada-002')
		select * from p8.generate_requests_for_embeddings('p8.Agent', 'description', 'text-embedding-ada-002')
				select * from p8.generate_requests_for_embeddings('design.bodies', 'generated_garment_description', 'text-embedding-ada-002')
				select * from p8.generate_requests_for_embeddings('p8.PercolateAgent', 'content', 'text-embedding-ada-002')

*/
    -- Sanitize the table name
    sanitized_table := REPLACE(PARAM_TABLE, '.', '_');
    PSCHEMA := split_part(PARAM_TABLE, '.', 1);
    PTABLE := split_part(PARAM_TABLE, '.', 2);

    -- Return query dynamically constructs the required output
    RETURN QUERY EXECUTE format(
        $sql$
        SELECT 
            b.id AS eid, 
            a.id AS source_id, 
            LEFT(COALESCE(a.%I, 'no desc'), %s)::TEXT AS description, -- Truncate description to max_length - NOTE its important that we chunk upstream!!!! but this stops a blow up downstream           
            p8.json_to_uuid(json_build_object(
                'embedding_id', %L,
                'column_name', %L,
                'source_record_id', a.id
            )::jsonb) AS id,
            %L AS column_name,
            %L AS embedding_id,
            ROW_NUMBER() OVER () AS idx
        FROM %I.%I a
        LEFT JOIN p8_embeddings."%s_embeddings" b 
            ON b.source_record_id = a.id 
            AND b.column_name = %L
        WHERE b.id IS NULL
		and %I IS NOT NULL
		and %I <> ''
 
        $sql$,
        PARAM_DESCRIPTION_COL,         -- %I for the description column
        max_length,                    -- %s for max string length truncation
        PARAM_EMBEDDING_MODEL,         -- %L for the embedding model
        PARAM_DESCRIPTION_COL,         -- %L for the column name
        PARAM_DESCRIPTION_COL,         -- %L for the column name again
        PARAM_EMBEDDING_MODEL,         -- %L for the embedding model
        PSCHEMA,                       -- %I for schema name
        PTABLE,                        -- %I for table name
        sanitized_table,               -- %I for sanitized embedding table
        PARAM_DESCRIPTION_COL,          -- %L for the column name in the join condition
		PARAM_DESCRIPTION_COL,
		PARAM_DESCRIPTION_COL
    );
END;
$BODY$;


-- Function from: index/get_connected_nodes.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.get_connected_nodes;
CREATE OR REPLACE FUNCTION p8.get_connected_nodes(
    node_type TEXT,
    source_node_name TEXT,
	target_type TEXT DEFAULT NULL,
    max_length INT DEFAULT 3
) RETURNS TABLE(node_id TEXT, node_label TEXT, node_name TEXT, path_length INT)
AS $BODY$
DECLARE
    cypher_query TEXT;
    sql TEXT;
	schema_name TEXT;
    pure_table_name TEXT;
BEGIN

	/*
		select * from p8.get_connected_nodes('public.Chapter', 'page62_moby')

		select * from p8.get_connected_nodes('public.Chapter', 'page62_moby', 'public.Chapter')

	*/
	
	SET search_path = ag_catalog, "$user", public;

	schema_name := lower(split_part(node_type, '.', 1));
    pure_table_name := split_part(node_type, '.', 2);
	--formatted as we do for graph nodes 
	node_type := schema_name || '__' || pure_table_name;

	if target_type IS NOT NULL THEN
		schema_name := lower(split_part(target_type, '.', 1));
	    pure_table_name := split_part(target_type, '.', 2);
		--formatted as we do for graph nodes 
		target_type := schema_name || '__' || pure_table_name;

	END IF;
    -- Construct Cypher query dynamically
    cypher_query := format(
        'MATCH path = (start:%s {name: ''%s''})-[:ref*1..%s]-(ch%s%s)
         RETURN ch, length(path) AS path_length',
        node_type, source_node_name, max_length,
        CASE WHEN target_type IS NULL THEN '' ELSE ':' END, 
        COALESCE(target_type, '')
    );

    -- Debug output
    RAISE NOTICE '%', cypher_query;

    -- Format SQL statement
    sql := format(
        'SELECT 
            (ch::json)->>''id'' AS node_id, 
            (ch::json)->>''label'' AS node_label, 
            ((ch::json)->''properties''->>''name'') AS node_name,
            path_length 
        FROM cypher(''percolate'', $$ %s $$) AS (ch agtype, path_length int);',
        cypher_query
    );

    -- Execute the SQL and return the result
    RETURN QUERY EXECUTE sql;
END;
$BODY$ LANGUAGE plpgsql;


-- Function from: index/get_embedding_for_text.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.get_embedding_for_text;

CREATE OR REPLACE FUNCTION p8.get_embedding_for_text(
	description_text text,
	embedding_model text DEFAULT 'text-embedding-ada-002'::text)
RETURNS TABLE(embedding vector) 
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
ROWS 1000

AS $BODY$
DECLARE
    api_token TEXT;
    embedding_response JSONB;
    request_url TEXT;
    use_ollama BOOLEAN;
BEGIN
    /*
        for now we have a crude way of assuming ollama for open source models
        if running locally it would look like this but the url we use is the dockerized service so localhost becomes ollama
        curl http://localhost:11434/api/embed -d '{
            "model": "bge-m3",
            "input": "Hello World"
            }'
    */

    -- Step 1: Check if the model is in the list of hardcoded Ollama models
    use_ollama := embedding_model IN ('bge-m3');

    IF use_ollama THEN
        request_url := 'http://ollama:11434/api/embed';
        api_token := ''; -- No API token required for Ollama
    ELSE
        -- Retrieve API token for OpenAI models
        SELECT "token"
        INTO api_token
        FROM p8."LanguageModelApi"
        WHERE "name" = 'gpt-4o-mini'; -- embedding_model hint

        IF api_token IS NULL THEN
            RAISE EXCEPTION 'Token not found for the provided model or OpenAI default: %', api_token;
        END IF;

        request_url := 'https://api.openai.com/v1/embeddings';
    END IF;

    -- Step 2: Make the HTTP request
    SELECT content::JSONB
    INTO embedding_response
    FROM public.http(
        (
            'POST',
            request_url,
            ARRAY[
                public.http_header('Authorization', 'Bearer ' || api_token)
            ],
            'application/json',
            jsonb_build_object(
                'input', ARRAY[description_text],  -- Single description in this case
                'model', embedding_model,
                'encoding_format', 'float'
            )
        )::public.http_request
    );

    -- Step 3: Extract the embedding and convert it to a PG vector
    RETURN QUERY
    SELECT
        VECTOR((embedding_response->'data'->0->'embedding')::text) AS embedding;

END;
$BODY$;


-- Function from: index/insert_entity_embeddings.sql
------------------------------------------------------------
-- FUNCTION: p8.insert_entity_embeddings(text, text)

-- DROP FUNCTION IF EXISTS p8.insert_entity_embeddings(text, text);

CREATE OR REPLACE FUNCTION p8.insert_entity_embeddings(
	param_entity_name text,
	param_token text DEFAULT NULL::text)
    RETURNS TABLE(field_id uuid, entity_name_out text, records_affected integer) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    field_record RECORD;
    rows_affected INTEGER;
    total_records INTEGER;
BEGIN

	/*
	import 
	p8.insert_generated_embeddings
	*/

    --we just need a token so any OpenAI model or whatever the embedding is
    IF param_token IS NULL THEN
        SELECT token into param_token
            FROM p8."LanguageModelApi"
            WHERE "name" = 'gpt-4o-mini'
            LIMIT 1;
    END IF;
 
    -- Loop through the fields in the table for the specified entity
    FOR field_record IN 
        SELECT id, name, field_type, embedding_provider
        FROM p8."ModelField"
        WHERE entity_name = param_entity_name
		 and embedding_provider is not null
    LOOP
        -- Initialize the total records affected for this field
        total_records := 0;

        -- Continue calling the insert_generated_embeddings function until no records are affected
        LOOP
            rows_affected := p8.insert_generated_embeddings(
                param_entity_name, 
                field_record.name, 
                field_record.embedding_provider, 
                param_token
            );

            -- Add to the total records count
            total_records := total_records + rows_affected;

            -- Exit the loop if no rows were affected
            IF rows_affected = 0 THEN
                EXIT;
            END IF;
        END LOOP;

        -- Return the metadata for this field
        RETURN QUERY SELECT 
            field_record.id,
			param_entity_name,
            total_records;
    END LOOP;
END;
$BODY$;

ALTER FUNCTION p8.insert_entity_embeddings(text, text)
    OWNER TO postgres;


-- Function from: index/insert_generated_embeddings.sql
------------------------------------------------------------
-- FUNCTION: p8.insert_generated_embeddings(text, text, text, text)

-- DROP FUNCTION IF EXISTS p8.insert_generated_embeddings(text, text, text, text);

CREATE OR REPLACE FUNCTION p8.insert_generated_embeddings(
    param_table text,
    param_column text,
    param_embedding_model text DEFAULT 'default',
    param_token text DEFAULT NULL)
    RETURNS integer
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    schema_name TEXT;
    table_name TEXT;
    sanitized_table TEXT;
    affected_rows INTEGER;
    table_exists BOOLEAN DEFAULT TRUE;
    resolved_model TEXT;
    resolved_token TEXT;
BEGIN
/*
imports p8.generate_and_fetch_embeddings
example
select * from p8.insert_generated_embeddings('p8.Agent', 'description')
returns non 0 if it needed to insert somethign
caller e.g. p8.insert_entity_embeddings('p8.Agent') can flush all required embeddings


select * from p8.insert_generated_embeddings('p8.Chapter', 'content')

*/
    -- Resolve the model name, defaulting to 'text-embedding-ada-002' if 'default' is provided
    resolved_model := CASE 
        WHEN param_embedding_model = 'default' THEN 'text-embedding-ada-002'
        ELSE param_embedding_model
    END;

    -- Resolve the token, fetching it if NULL
    IF param_token IS NULL THEN
        SELECT token
        INTO resolved_token
        FROM p8."LanguageModelApi"
        WHERE "name" = 'gpt-4o-mini';
    ELSE
        resolved_token := param_token;
    END IF;

    -- Sanitize the table name
    sanitized_table := REPLACE(param_table, '.', '_');

    -- Check if the target embedding table exists
    SELECT EXISTS (
        SELECT *
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'p8_embeddings' AND c.relname = sanitized_table || '_embeddings'
    )
    INTO table_exists;

    -- Construct and execute the insertion if the table exists
    IF table_exists THEN
        EXECUTE format(
            $sql$
            INSERT INTO p8_embeddings."%s_embeddings" (id, source_record_id, embedding_name, column_name, embedding_vector)
            SELECT * 
            FROM p8.generate_and_fetch_embeddings(
                %L,
                %L,
                %L,
                %L
            )
            $sql$,
            sanitized_table,    -- Target embedding table
            param_table,        -- Passed to the function
            param_column,       -- Column to embed
            resolved_model,     -- Resolved embedding model
            resolved_token      -- Resolved API token
        );

        -- Get the number of affected rows
        GET DIAGNOSTICS affected_rows = ROW_COUNT;
        RETURN affected_rows;
    END IF;

    RETURN 0;
END;
$BODY$;

ALTER FUNCTION p8.insert_generated_embeddings(text, text, text, text)
    OWNER TO postgres;


-- Function from: index/perform_compact_user_memory_batch.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.perform_compact_user_memory_batch;
CREATE OR REPLACE FUNCTION p8.perform_compact_user_memory_batch(
	threshold integer DEFAULT 7)
RETURNS integer
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
  batch RECORD;
  formatted_cypher_query TEXT;
  affected_count INTEGER := 0;
BEGIN
  /*
  This function compacts User→Concept relationships when they exceed a threshold.
  It inserts a Hub node between them for each user and relationship type.

  This function which could be generalized to other node types specifically compacts relationships between User and Concept nodes.
  It's assumed that the users node has a user_id which is important for qualifying user memories by named entities.

  A threshold defaults to 7 which means that as users have greater than 7 direct links we insert a Hub Node between them. 
  If we need to later add more direct links they will always be merged onto the same hub node for that user and that relationship type.
  For example the relationships 'likes' or 'has-skills' will be linked to a hub for that relationship type.

  Today we do not compact hubs but another process could do that in future e.g. like-good-italian or something very specific.
  The true value of this for now is simply knowing that the relationships exist and can be expanded. Recall that this expansion as far as actual entity lookups should be small data.

  Example:
    SELECT * FROM p8.perform_compact_user_memory_batch(5);
	*/


  -- Step 1: Get batches of relationship groups
  formatted_cypher_query := format('
    MATCH (a:User)-[r]->(b:Concept)
    WITH a, TYPE(r) AS relType, collect(r) AS rels, collect(b) AS targets
    WITH a, a.user_id AS user_id, relType AS rel_type, rels, targets, size(rels) AS rel_count
    WHERE rel_count > %s
    RETURN user_id, rel_type, rels, targets, rel_count
    ORDER BY rel_count DESC
    LIMIT 100', threshold);

  FOR batch IN
    SELECT 
      result->'rels' AS rels,
      (result->>'rel_count')::INTEGER AS rel_count,
      --user ids are required but we dont want to blow up the query
      COALESCE(result->>'user_id', '') AS user_id,
      result->>'rel_type' AS rel_type  
    FROM cypher_query(
      formatted_cypher_query,
      'user_id text, rel_type text, rels agtype, targets agtype, rel_count integer'
    )
  LOOP
    -- Step 2: Rewire relationships into hub pattern
    select * from cypher_query(
      '
        MATCH (a:User {user_id: ''' || batch.user_id || '''})-[r:' || batch.rel_type || ']->(b:Concept)
        WITH a, b, r, properties(r) AS props
        MERGE (c:Concept {is_hub:true, name: ''' || 'has_' || batch.rel_type || ''', user_id: ''' || batch.user_id || '''})
        CREATE (c)-[newRel:' || batch.rel_type || ']->(b)
        SET newRel = props
        MERGE (a)-[newRel2:' || batch.rel_type || ']->(c)
        SET newRel2 = props
        DELETE r
      ');

    RAISE NOTICE 'Processed batch for user % with relType %', batch.user_id, batch.rel_type;

    -- Increment affected count
    affected_count := affected_count + 1;
  END LOOP;

  RETURN affected_count;
END;
$BODY$;

ALTER FUNCTION p8.perform_compact_user_memory_batch(integer)
    OWNER TO postgres;


-- ====================================================================
-- REQUESTS FUNCTIONS
-- ====================================================================

-- Function from: requests/ask.sql
------------------------------------------------------------
-- FUNCTION: p8.ask(json, uuid, json, text, text, uuid)

DROP FUNCTION IF EXISTS p8.ask;

CREATE OR REPLACE FUNCTION p8.ask(
	message_payload json,
	session_id uuid DEFAULT NULL::uuid,
	functions_names TEXT[] DEFAULT NULL::TEXT[],
	model_name text DEFAULT 'gpt-4o-mini'::text,
	token_override text DEFAULT NULL::text,
	user_id uuid DEFAULT NULL::uuid)
    RETURNS TABLE(message_response text, tool_calls jsonb, tool_call_result jsonb, session_id_out uuid, status text) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    -- Declare variables
    endpoint_uri TEXT;
    api_token TEXT;
    selected_model TEXT;
    selected_scheme TEXT;
    api_response JSON;
    result_set TEXT;
    api_error TEXT;
    tool_calls JSONB;
    tool_call JSONB;
    tool_results JSONB := '[]'; --aggregates
    tool_result JSONB;
    tool_error TEXT;
    status_audit TEXT;
    finish_reason TEXT;
    tokens_in INTEGER;
    tokens_out INTEGER;
    response_id UUID;
	ack_http_timeout BOOLEAN;
    functions_in JSON;
BEGIN
	/*
	take in a message payload etc and call the correct request for each scheme
	each scheme maps to canonical which we store
	note, when calling these schemes again we read back messages in their format
	we also want to audit everything in this function

	select * from percolate_with_agent('list some pets that str sold', 'MyFirstAgent');
	*/

    -- Fetch endpoint and API token from LanguageModelApi
    SELECT completions_uri, coalesce(token, token_override), model, scheme
    INTO endpoint_uri, api_token, selected_model, selected_scheme
    FROM p8."LanguageModelApi"
    WHERE "name" = model_name 
    LIMIT 1;

    -- Ensure both the URI and token are available
    IF endpoint_uri IS NULL OR api_token IS NULL THEN
        RAISE EXCEPTION 'Missing API endpoint or token for model: %', selected_model;
    END IF;

    -- If session does not exist, create a new session UUID (using JSON uuid creation)
    IF session_id IS NULL THEN
        SELECT p8.json_to_uuid(json_build_object('date', current_date::text, 'user_id', coalesce(user_id,''))::JSONB)
        INTO session_id;
    END IF;

    -- Generate a new response UUID using session_id and content ID
    SELECT p8.json_to_uuid(json_build_object('sid', session_id, 'ts',CURRENT_TIMESTAMP::TEXT)::JSONB)
    INTO response_id;

    --get the functions requested for the agent and including merging in from the session
    functions_in = p8.get_session_functions(session_id, functions_names, selected_scheme);

    RAISE NOTICE 'scheme %: we have functions % ', selected_scheme, functions_names;
    -- Make the API request based on scheme
    --we return RETURNS TABLE(message_response text, tool_calls jsonb, tool_call_result jsonb, session_id_out uuid, status TEXT)
    --RETURNS TABLE(content TEXT,tool_calls_out JSON,tokens_in INTEGER,tokens_out INTEGER,finish_reason TEXT,api_error JSONB) AS

    --TODO we will read this from a setting in future
    select http_set_curlopt('CURLOPT_TIMEOUT','5000') into ack_http_timeout;
    RAISE NOTICE 'THE HTTP TIMEOUT IS HARDCODED TO 5000ms';
   
    IF selected_scheme = 'google' THEN
        SELECT * FROM p8.request_google(message_payload,  functions_in, selected_model, endpoint_uri, api_token)
        INTO result_set, tool_calls, tokens_in, tokens_out, finish_reason, api_error;
    ELSIF selected_scheme = 'anthropic' THEN
        SELECT * FROM p8.request_anthropic(message_payload, functions_in, selected_model, endpoint_uri, api_token)
        INTO result_set, tool_calls, tokens_in, tokens_out, finish_reason, api_error;
    ELSE
        -- Default case for other schemes
        SELECT * FROM p8.request_openai(message_payload, functions_in, selected_model, endpoint_uri, api_token)
        INTO result_set, tool_calls, tokens_in, tokens_out, finish_reason, api_error;
    END IF;


    --TODO: i think i need to check how the response is cast from json
    -- Handle finish reason and status
    status_audit := 'TOOL_CALL_RESPONSE';
    IF finish_reason ilike '%stop%' or finish_reason ilike '%end_turn%' THEN 
        status_audit := 'COMPLETED';
    END IF;


    
	--RAISE NOTICE 'LLM Gave finish reason and tool calls %, % - we set status %', finish_reason, tool_calls, status_audit;
	
    -- Iterate through each tool call
    FOR tool_call IN SELECT * FROM JSONB_ARRAY_ELEMENTS(tool_calls)
    LOOP
        BEGIN
            RAISE NOTICE 'calling %', tool_call;
            -- Attempt to call the function - the response id is added for context
            tool_result := json_build_object('id', tool_call->>'id', 'data', p8.eval_function_call(tool_call,response_id)); -- This will be saved in tool_eval_data
            tool_error := NULL; -- No error
            -- Aggregate tool_result into tool_results array
            tool_results := tool_results || tool_result;
        EXCEPTION WHEN OTHERS THEN
            -- Capture the error if the function call fails
            tool_result := NULL;
            tool_error := SQLSTATE || ': ' || SQLERRM;
            RAISE NOTICE 'tool_error %', tool_error;
        END;

        -- Set status based on tool result or error
        IF tool_error IS NOT NULL THEN
            status_audit := 'TOOL_ERROR';
            result_set := tool_error;
        ELSE
            -- Set status to ERROR if tool_eval failed
        END IF;
    END LOOP;

--	RAISE notice 'generated response id % from % and %', response_id,session_id,api_response->>'id';

    IF api_error IS NOT NULL THEN
        result_set := api_error;
        status_audit := 'ERROR';
    END IF;

    -- Insert into p8.AIResponse table
    INSERT INTO p8."AIResponse" 
        (id, model_name, content, tokens_in, tokens_out, session_id, role, status, tool_calls, tool_eval_data,function_stack)
    VALUES 
        (response_id, selected_model, COALESCE(result_set, ''), COALESCE(tokens_in, 0), COALESCE(tokens_out, 0), 
        session_id, 'assistant', status_audit, tool_calls, tool_results,functions_names)
    ON CONFLICT (id) DO UPDATE SET
        model_name    = EXCLUDED.model_name, 
        content       = EXCLUDED.content,
        tokens_in     = EXCLUDED.tokens_in,
        tokens_out    = EXCLUDED.tokens_out,
        session_id    = EXCLUDED.session_id,
        role          = EXCLUDED.role,
        status        = EXCLUDED.status,
        tool_calls    = EXCLUDED.tool_calls,
        tool_eval_data = EXCLUDED.tool_eval_data,
		 function_stack = ARRAY(SELECT DISTINCT unnest(p8."AIResponse".function_stack || EXCLUDED.function_stack));


    -- Return results
    RETURN QUERY
    SELECT result_set::TEXT, tool_calls::JSONB, tool_results::JSONB, session_id, status_audit;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'ASK API call failed: % % response id %', SQLERRM, result_set, api_response->'id';
END;
$BODY$;


-- Function from: requests/deprecate_ask_with_prompt_and_tools.sql
------------------------------------------------------------
CREATE OR REPLACE FUNCTION p8.ask_with_prompt_and_tools(
	question text,
	tool_names_in text[] DEFAULT NULL::text[],
	system_prompt text DEFAULT 'Respond to the users query using tools and functions as required'::text,
	model_key character varying DEFAULT 'gpt-4o-mini'::character varying,
	token_override text DEFAULT NULL::text,
	temperature double precision DEFAULT 0.01)
    RETURNS TABLE(message_response text, tool_calls jsonb, tool_call_result jsonb) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    api_response JSON; -- Variable to store the API response
    endpoint_uri TEXT; -- URL of the API endpoint
    api_token TEXT; -- API token for authorization
    selected_model TEXT; -- Match model from key - sometimes they are the same
    selected_scheme TEXT; -- Scheme (e.g., openai, google, anthropic)
    tool_calls JSONB; -- Extracted tool calls
    processed_tool_calls JSONB := '[]'::JSONB; -- Initialize as an empty JSON array
    tool_call JSONB; -- Individual tool call
    tool_result JSONB;
    tool_error TEXT;
	result_set TEXT DEFAULT NULL;
BEGIN
	/*
    imports
	p8.get_tools_by_description
	p8.get_tools_by_name
	p8.google_to_open_ai_response
	p8.anthropic_to_open_ai_response
	p8.eval_function_call
	*/
    -- Fetch the model-specific API endpoint, token, and scheme
    SELECT completions_uri, coalesce(token,token_override), model, scheme
    INTO endpoint_uri, api_token, selected_model, selected_scheme
    FROM p8."LanguageModelApi"
    WHERE "name" = model_key
    LIMIT 1;

    -- Ensure both the URI and token are available
    IF endpoint_uri IS NULL OR api_token IS NULL THEN
        RAISE EXCEPTION 'Missing API endpoint or token for model: %', selected_model;
    END IF;

    -- Try searching for tools if not specified
    IF tool_names_in IS NULL OR array_length(tool_names_in, 1) = 0 THEN
        -- Auto-determine tools from the question
        SELECT ARRAY_AGG(name)
        INTO tool_names_in
        FROM p8.get_tools_by_description(question, 5); -- Adjust the limit as needed
    END IF;

    -- Prepare the tools and payload based on the scheme
    IF selected_scheme = 'openai' THEN
        -- OpenAI-specific payload
        SELECT content
        INTO api_response
        FROM public.http(
            (
                'POST',
                endpoint_uri,
                ARRAY[public.http_header('Authorization', 'Bearer ' || api_token)],
                'application/json',
                json_build_object(
                    'model', selected_model,
                    'messages', json_build_array(
                        json_build_object('role', 'system', 'content', system_prompt),
                        json_build_object('role', 'user', 'content', question)
                    ),
                    'tools', (SELECT p8.get_tools_by_name(tool_names_in, selected_scheme)), -- Fetch tools by names with scheme
                    'temperature', temperature
                )
            )::public.http_request
        );

		raise notice '%', api_response;
		 -- Extract tool calls from the response
	    tool_calls := (api_response->'choices'->0->'message'->>'tool_calls')::JSON;
		result_set := (api_response->'choices'->0->'message'->>'content')::TEXT;
		
    ELSIF selected_scheme = 'google' THEN
        -- Google-specific payload
        SELECT content
        INTO api_response
        FROM public.http(
            (
                'POST',
                endpoint_uri || '?key=' || api_token,
				NULL,
				 'application/json',
                json_build_object(
                    'contents', json_build_array(
                        json_build_object('role', 'user', 'parts', json_build_object('text', question))
                    ),
                    'tool_config', json_build_object(
                        'function_calling_config', json_build_object('mode', 'ANY')
                    ),
                    'tools', (SELECT p8.get_tools_by_name(tool_names_in, selected_scheme)) -- Fetch tools by names with scheme
                )
            )::public.http_request
        );

		 SELECT msg, tool_calls_out as tc
		    INTO result_set, tool_calls
		    FROM p8.google_to_open_ai_response(api_response::JSONB);

			raise notice '%', api_response;
    ELSIF selected_scheme = 'anthropic' THEN
        -- Anthropic-specific payload
		 
        SELECT content
        INTO api_response
        FROM public.http(
            (
                'POST',
                endpoint_uri,
                ARRAY[
                    public.http_header('x-api-key', api_token),
                    public.http_header('anthropic-version', '2023-06-01')
                ],
                'application/json',
                json_build_object(
                    'model', selected_model,
                    'max_tokens', 1024,
                    'messages', json_build_array(
                        json_build_object('role', 'user', 'content', question)
                    ),
                    'tools', (SELECT p8.get_tools_by_name(tool_names_in, selected_scheme)) -- Fetch tools by names with scheme
                )
            )::public.http_request
        );

		raise notice '%', api_response;

		---------
		 -- Extract content and tool use for the 'anthropic' scheme
		 SELECT msg, tool_calls_out as tc
		    INTO result_set, tool_calls
		    FROM p8.anthropic_to_open_ai_response(api_response::JSONB);

		----------

    ELSE
        RAISE EXCEPTION 'Unsupported scheme: %', selected_scheme;
    END IF;
 
	
    -- Iterate through each tool call
    FOR tool_call IN SELECT * FROM JSONB_ARRAY_ELEMENTS(tool_calls)
    LOOP
        BEGIN
            -- Attempt to call the function
            tool_result := p8.eval_function_call(tool_call);
            tool_error := NULL; -- No error
        EXCEPTION WHEN OTHERS THEN
            -- Capture the error if the function call fails
            tool_result := NULL;
            tool_error := SQLSTATE || ': ' || SQLERRM;
        END;

        -- Add the result or error to processed_tool_calls
        processed_tool_calls := processed_tool_calls || JSONB_BUILD_OBJECT(
            'tool_call', tool_call,
            'result', tool_result,
            'error', tool_error
        );
    END LOOP;

    -- Return the API response and processed tool calls
    RETURN QUERY
    SELECT coalesce(result_set,'')::TEXT,
           tool_calls,
           processed_tool_calls;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'API call failed: % %', SQLERRM, result_set;
END;
$BODY$;

ALTER FUNCTION p8.ask_with_prompt_and_tools(text, text[], text, character varying, text, double precision)
    OWNER TO postgres;


-- Function from: requests/get_anthropic_messages.sql
------------------------------------------------------------
CREATE OR REPLACE FUNCTION p8.get_anthropic_messages(
    session_id_in uuid,
    question text DEFAULT NULL::text,
    agent_or_system_prompt text DEFAULT NULL::text)
    RETURNS TABLE(messages json, last_role text, last_updated_at timestamp without time zone) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000
AS $BODY$
DECLARE
    recovered_session_id UUID;
    user_id UUID;
    recovered_agent TEXT;
    recovered_question TEXT;
    generated_system_prompt TEXT;
BEGIN
    -- 1. Get session details from p8."Session"
    SELECT s.id, s.userid, s.agent, s.query 
    INTO recovered_session_id, user_id, recovered_agent, recovered_question
    FROM p8."Session" s
    WHERE s.id = session_id_in;

    -- Check if session exists
    IF recovered_session_id IS NULL THEN
        RETURN QUERY 
        SELECT NULL::JSON, NULL::TEXT, NULL::TIMESTAMP;
        RETURN;
    END IF;

    -- 2. Generate system prompt based on the recovered agent
    SELECT p8.generate_markdown_prompt(recovered_agent) 
    INTO generated_system_prompt;

    -- If no generated system prompt, fall back to using the agent directly
    IF generated_system_prompt IS NULL THEN
        generated_system_prompt := recovered_agent;
    END IF;

    RETURN QUERY
    WITH session_data AS (
        -- Fetch session data for the specified session_id
        SELECT content, role, tool_calls, tool_eval_data, created_at
        FROM p8."AIResponse" a
        WHERE a.session_id = session_id_in
    ),
    max_session_data AS (
        -- Get the last role and most recent timestamp
        SELECT role AS last_role, created_at AS last_updated_at
        FROM session_data
        ORDER BY created_at DESC
        LIMIT 1
    ),
    extracted_messages AS (
        -- Extract all messages, interleaving tool calls and user/assistant content while preserving the data structure
        SELECT NULL::TIMESTAMP as created_at, 'system' AS role, 
               json_build_array(
                   jsonb_build_object('type', 'text', 'text', COALESCE(agent_or_system_prompt, generated_system_prompt))
               ) AS content,
               0 AS rank
        UNION ALL
        SELECT NULL::TIMESTAMP as created_at, 'user' AS role, 
               json_build_array(
                   jsonb_build_object('type', 'text', 'text', COALESCE(question, recovered_question))
               ) AS content,
               1 AS rank
        UNION ALL
        SELECT created_at, 'assistant' AS role,
               jsonb_build_array(
                   jsonb_build_object(
                       'name', el->'function'->>'name',
                       'id', el->>'id',
                       'input', (el->'function'->>'arguments')::JSON,
                       'type', 'tool_use'
                   )
               )::JSON AS content,
               2 AS rank
        FROM session_data, 
             LATERAL jsonb_array_elements(tool_calls::JSONB) el
        WHERE tool_calls IS NOT NULL
        UNION ALL
        SELECT created_at, 'user' AS role,
               jsonb_build_array(
                   jsonb_build_object(
                       'type', 'tool_result',
                       'tool_use_id', el->>'id',
                       'content', el->>'data'
                   )
               )::JSON AS content,
               2 AS rank
        FROM session_data, 
             LATERAL jsonb_array_elements(tool_eval_data::JSONB) el
        WHERE tool_eval_data IS NOT NULL
    ),
    ordered_messages AS (
        -- Order the extracted messages by rank (to maintain the interleaving order) and created_at timestamp
        SELECT role, content
        FROM extracted_messages
        ORDER BY rank, created_at ASC
    ),
    jsonrow AS (
        -- Convert ordered messages into JSON
        SELECT json_agg(row_to_json(ordered_messages)) AS messages
        FROM ordered_messages
    )
    -- Return the ordered JSON messages along with metadata
    SELECT jsonrow.messages, max_session_data.last_role, max_session_data.last_updated_at
    FROM jsonrow 
    LEFT JOIN max_session_data ON true; -- Ensures at least one row is returned
END;
$BODY$;

ALTER FUNCTION p8.get_anthropic_messages(uuid, text, text)
    OWNER TO postgres;


-- Function from: requests/get_canonical_messages.sql
------------------------------------------------------------
CREATE OR REPLACE FUNCTION p8.get_canonical_messages(
    session_id_in UUID,  
    question TEXT DEFAULT NULL,  
    override_system_prompt TEXT DEFAULT NULL  
) 
RETURNS TABLE(messages JSON, last_role TEXT, last_updated_at TIMESTAMP WITHOUT TIME ZONE) 
LANGUAGE plpgsql
COST 100
VOLATILE 
PARALLEL UNSAFE
ROWS 1000 
AS $BODY$
DECLARE
    recovered_session_id TEXT;
    user_id TEXT;
    recovered_agent TEXT;
    recovered_question TEXT;
    generated_system_prompt TEXT;
BEGIN

    -- 1. Get session details from p8."Session"
    SELECT s.id, s.userid, s.agent, s.query 
    INTO recovered_session_id, user_id, recovered_agent, recovered_question
    FROM p8."Session" s
    WHERE s.id = session_id_in;

    -- Check if session exists
    IF recovered_session_id IS NULL THEN
        RETURN QUERY 
        SELECT NULL::JSON, NULL::TEXT, NULL::TIMESTAMP;
        RETURN;
    END IF;

    -- 2. Generate system prompt based on the recovered agent
    SELECT p8.generate_markdown_prompt(recovered_agent) 
    INTO generated_system_prompt;

    -- If no generated system prompt, fall back to using the agent directly
    IF generated_system_prompt IS NULL THEN
        generated_system_prompt := recovered_agent;
    END IF;

    -- 3. Construct the response messages
    RETURN QUERY
    WITH session_data AS (
        -- Fetch session data for the specified session_id
        SELECT content, role, tool_calls, tool_eval_data, created_at
        FROM p8."AIResponse" a
        WHERE a.session_id = session_id_in
    ),
    max_session_data AS (
        -- Get the last role and most recent timestamp
        SELECT role AS last_role, created_at AS last_updated_at
        FROM session_data
        ORDER BY created_at DESC
        LIMIT 1
    ),
    extracted_messages AS (
        -- Extract all messages in a structured way while keeping order
        SELECT NULL::TIMESTAMP as created_at, 'system' AS role, 
               COALESCE(override_system_prompt, generated_system_prompt) AS content, 
               NULL::TEXT AS tool_call_id,
			   NULL::JSON as tool_calls,
			   0 as rank
        UNION ALL
        SELECT NULL::TIMESTAMP as created_at, 'user' AS role, 
               COALESCE(question, recovered_question) AS content, 
               NULL::TEXT AS tool_call_id,
			    NULL::JSON as tool_calls,
			   1 as rank
        UNION ALL
        SELECT created_at, 'assistant' AS role, 
               'Calling ' || (el->>'function')::TEXT AS content,
               el->>'id' AS tool_call_id,
			   tool_calls,
			   2 as rank
        FROM session_data, 
             LATERAL jsonb_array_elements(tool_calls::JSONB) el
        WHERE tool_calls IS NOT NULL
         UNION ALL
        -- Extract tool responses
        SELECT created_at, 'tool' AS role,
               'Responded ' || (el->>'data')::TEXT AS content,
               el->>'id' AS tool_call_id,
			   NULL::JSON as tool_calls,
			   2 as rank
        FROM session_data, 
             LATERAL jsonb_array_elements(tool_eval_data::JSONB) el
        WHERE tool_eval_data IS NOT NULL
    ),
    ordered_messages AS (
        -- Order all extracted messages by created_at
        SELECT role, content, tool_calls, tool_call_id
        FROM extracted_messages
        ORDER BY rank, created_at ASC
    ),
    jsonrow AS (
        -- Convert ordered messages into JSON
        SELECT json_agg(row_to_json(ordered_messages)) AS messages
        FROM ordered_messages
    )
    -- Return JSON messages with metadata
    SELECT * 
    FROM jsonrow 
    LEFT JOIN max_session_data ON true;

END;
$BODY$;


-- Function from: requests/get_google_messages.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.get_google_messages;
CREATE OR REPLACE FUNCTION p8.get_google_messages(
    session_id_in UUID,
    question TEXT DEFAULT NULL,
    agent_or_system_prompt TEXT DEFAULT NULL
)
RETURNS TABLE(messages JSON, last_role TEXT, last_updated_at TIMESTAMP WITHOUT TIME ZONE) 
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
ROWS 1000
AS $BODY$
DECLARE
    recovered_session_id UUID;
    user_id UUID;
    recovered_agent TEXT;
    recovered_question TEXT;
    generated_system_prompt TEXT;
BEGIN
    /*
    https://cloud.google.com/vertex-ai/generative-ai/docs/multimodal/function-calling

    select messages from p8.get_google_messages('619857d3-434f-fa51-7c88-6518204974c9');

    call parts should be 

    {
        "functionCall": {
            "name": "get_current_weather",
            "args": {
                "location": "San Francisco"
            }
        }
    }
    
    response parts should be

    {
        "functionResponse": {
            "name": "get_current_weather",
            "response": {
                "temperature": 30.5,
                "unit": "C"
            }
        }
    }
    */

    -- 1. Get session details from p8."Session"
    SELECT s.id, s.userid, s.agent, s.query 
    INTO recovered_session_id, user_id, recovered_agent, recovered_question
    FROM p8."Session" s
    WHERE s.id = session_id_in;

    -- Check if session exists
    IF recovered_session_id IS NULL THEN
        -- Return null values for the session-related fields if session does not exist
        RETURN QUERY 
        SELECT NULL::JSON, NULL::TEXT, NULL::TIMESTAMP;
        RETURN;
    END IF;

    -- 2. Generate system prompt based on the recovered agent
    SELECT p8.generate_markdown_prompt(recovered_agent) 
    INTO generated_system_prompt;

    -- If no generated system prompt, fall back to using the agent directly
    IF generated_system_prompt IS NULL THEN
        generated_system_prompt := recovered_agent;
    END IF;

    -- 3. Construct the response messages
    RETURN QUERY
    WITH session_data AS (
        -- Fetch session data for the specified session_id
        SELECT content, role, tool_calls, tool_eval_data, created_at
        FROM p8."AIResponse" a
        WHERE a.session_id = session_id_in
    ),
    max_session_data AS (
        -- Get the last role and most recent timestamp
        SELECT role AS last_role, created_at AS last_updated_at
        FROM session_data
        ORDER BY created_at DESC
        LIMIT 1
    ),
    message_data AS (
        -- Combine system, user, and session data
        SELECT 'system' AS role, json_build_array(json_build_object('text',
            COALESCE(agent_or_system_prompt, generated_system_prompt)
        )) AS parts
        UNION ALL
        SELECT 'user' AS role, json_build_array(json_build_object('text',
            COALESCE(question, recovered_question)
        )) AS parts
        UNION ALL
        -- Generate one row for assistant tool call summary
        SELECT 'model' AS role,
            json_build_array(
                json_build_object(
                    'functionCall', json_build_object(
                        'name', el->'function'->>'name',
                        'args', (el->'function'->>'arguments')::json
                    )
                )
            ) AS parts
        FROM session_data, 
             LATERAL jsonb_array_elements(tool_calls::JSONB) el
        UNION ALL
        -- Generate multiple rows from tool_eval_data JSON array with a tool call id on each
        SELECT 'user' AS role,
            json_build_array(
                json_build_object(
                    'functionResponse',
                    json_build_object(
                        'name', el->>'id',
                        'response', json_build_object(
                            'name', el->>'id',
                            -- experiment with json or text
                            'content', (el->'data')::TEXT
                        )
                    )
                )
            ) AS parts
        FROM session_data, 
             LATERAL jsonb_array_elements(tool_eval_data::JSONB) el
    ),
    jsonrow AS (
        SELECT json_agg(row_to_json(message_data)) AS messages
        FROM message_data
    )
    SELECT * 
    FROM jsonrow 
    LEFT JOIN max_session_data ON true;  -- Ensure a row is returned even if no session data is found

END;
$BODY$;

ALTER FUNCTION p8.get_google_messages(UUID, text, text)
OWNER TO postgres;


-- Function from: requests/insert_web_results.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.insert_web_search_results;

CREATE OR REPLACE FUNCTION p8.insert_web_search_results(
    query TEXT,
    session_id UUID DEFAULT p8.json_to_uuid(jsonb_build_object('proxy_uri', 'http://percolate-api:5008')::JSONB),
    api_endpoint TEXT DEFAULT 'https://api.tavily.com/search',
    search_limit INT DEFAULT 5
) RETURNS VOID AS $$
DECLARE
    result RECORD;
    resource_id UUID;
    task_resource_id UUID;
BEGIN
    -- Example usage:
    -- SELECT p8.insert_web_search_results('latest tech news');
    
    -- Loop through search results
    FOR result IN 
        SELECT * FROM p8.run_web_search(query, search_limit, TRUE)
    LOOP
        -- Generate deterministic resource ID
        SELECT p8.json_to_uuid(jsonb_build_object('uri', result.url)::JSONB) INTO resource_id;
        
        -- Upsert into Resources table
        INSERT INTO p8."Resources" (id, name, category, content, summary, ordinal, uri, metadata, graph_paths)
        VALUES (
            resource_id,
            result.title,
            'web', -- Default category
            result.content,
            result.summary,
            0,
            result.url,
            jsonb_build_object('score', result.score, 'images', result.images),
            NULL
        )
        ON CONFLICT (id) DO UPDATE SET
            name = EXCLUDED.name,
            content = EXCLUDED.content,
            summary = EXCLUDED.summary,
            metadata = EXCLUDED.metadata;
        
        -- Generate deterministic TaskResource ID
        SELECT p8.json_to_uuid(jsonb_build_object('session_id', session_id, 'resource_id', resource_id)::JSONB) INTO task_resource_id;
        
        -- Insert into TaskResource table (ignore conflicts)
        INSERT INTO p8."TaskResource" (id, resource_id, session_id)
        VALUES (task_resource_id, resource_id, session_id)
        ON CONFLICT DO NOTHING;
    END LOOP;
END;
$$ LANGUAGE plpgsql;


-- Function from: requests/nl2sql.sql
------------------------------------------------------------
-- FUNCTION: p8.nl2sql(text, character varying, character varying, character varying, double precision)

DROP FUNCTION IF EXISTS p8.nl2sql;

CREATE OR REPLACE FUNCTION p8.nl2sql(
	question text,
	agent_name character varying,
	model_in character varying DEFAULT 'gpt-4.1-mini'::character varying,
	api_token character varying DEFAULT NULL::character varying,
	temperature double precision DEFAULT 0.0)
    RETURNS TABLE(response jsonb, query text, confidence numeric) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    table_schema_prompt TEXT;
    api_response JSON;
    ack_http_timeout BOOLEAN;
BEGIN
	/*
	imports
	p8.generate_markdown_prompt
	*/

    --default public schema
	SELECT 
        CASE 
            WHEN agent_name NOT LIKE '%.%' THEN 'public.' || agent_name 
            ELSE agent_name 
        END 
    INTO agent_name;

    -- Generate the schema prompt for the table
    SELECT generate_markdown_prompt INTO table_schema_prompt FROM p8.generate_markdown_prompt(agent_name);

	IF table_schema_prompt IS NULL THEN
        --RAISE EXCEPTION 'Agent with name "%" not found.', agent_name;
        --we default to this for robustness TODO: think about how this could cause confusion
        table_schema_prompt:= 'p8.PercolateAgent';
    END IF;
	
    IF api_token IS NULL THEN    
        SELECT token into api_token
            FROM p8."LanguageModelApi"
            WHERE "name" = model_in
            LIMIT 1;
    END IF;

    select http_set_curlopt('CURLOPT_TIMEOUT','8000') into ack_http_timeout;
    RAISE NOTICE 'THE HTTP TIMEOUT IS HARDCODED TO 8000ms';

    -- API call to OpenAI with the necessary headers and payload
    WITH T AS(
        SELECT 'system' AS "role", 
		   'you will generate a PostgreSQL query for the provided table metadata that can '
		|| ' query that table (but replace table with YOUR_TABLE) to answer the users question and respond in json format'
		|| 'responding with the query and a strictly numeric confidence as a number from 0 to 1 - escape characters so that the json can be loaded in postgres.' 
		AS "content" 
        UNION
        SELECT 'system' AS "role", table_schema_prompt AS "content" 
        UNION
        SELECT 'user' AS "role", question AS "content"
    )
    SELECT content FROM http(
        ('POST', 
         'https://api.openai.com/v1/chat/completions', 
         ARRAY[http_header('Authorization', 'Bearer ' || api_token)],
         'application/json',
         json_build_object(
             'model', model_in,
             'response_format', json_build_object('type', 'json_object'),
             'messages', (SELECT JSON_AGG(t) FROM T AS t),
             'temperature', temperature
         )
        )::http_request
    ) INTO api_response;

	RAISE NOTICE 'Table Schema Prompt: %', api_response;

    -- Parse the response content into JSON and extract query and confidence values
    RETURN QUERY
    SELECT 
        -- Parse the JSON response string to JSONB and extract the content
        (api_response->'choices'->0->'message'->>'content')::JSONB AS response,  -- Content as JSONB
        ((api_response->'choices'->0->'message'->>'content')::JSONB->>'query')::TEXT AS query,  -- Extract query
        CASE
            WHEN ((api_response->'choices'->0->'message'->>'content')::JSONB->>'confidence') ~ '^[0-9]*\.?[0-9]+$'
            THEN ((api_response->'choices'->0->'message'->>'content')::JSONB->>'confidence')::NUMERIC
            ELSE 0.5
        END AS confidence;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'API call failed: %', SQLERRM;
END;
$BODY$;

ALTER FUNCTION p8.nl2sql(text, character varying, character varying, character varying, double precision)
    OWNER TO postgres;


-- Function from: requests/request_by_scheme.sql
------------------------------------------------------------
--select * from p8."LanguageModelApi"



DROP function if exists p8.request_openai;
CREATE OR REPLACE FUNCTION p8.request_openai(
    message_payload JSON,
    functions_in JSON DEFAULT NULL,
    model_name TEXT DEFAULT 'gpt-4o-mini',
    endpoint_uri TEXT DEFAULT 'https://api.openai.com/v1/chat/completions',
    api_token TEXT DEFAULT NULL
)
RETURNS TABLE(
    message_content TEXT, 
    tool_calls_out JSONB, 
    tokens_in INTEGER, 
    tokens_out INTEGER, 
    finish_reason TEXT, 
    api_error TEXT
) AS
$$
DECLARE
    api_response JSONB;
    result_set TEXT;
    tool_calls JSONB;
    selected_model TEXT;
    api_error JSONB;
    tokens_in INTEGER;
    tokens_out INTEGER;
    finish_reason TEXT;
BEGIN
    -- If api_token is NULL, retrieve values from the LanguageModelApi table
    IF api_token IS NULL THEN
        SELECT completions_uri, 
               COALESCE(token, api_token), 
               model
        INTO endpoint_uri, api_token, selected_model
        FROM p8."LanguageModelApi"
        WHERE scheme = 'openai'
        LIMIT 1;
    END IF;

    -- Ensure model_name defaults to the selected model if not provided
    IF model_name IS NULL THEN
        model_name := selected_model;
    END IF;

    -- Make the HTTP request and retrieve the response
    SELECT content
        INTO api_response
        FROM public.http(
		  (
            'POST',
            endpoint_uri,
            ARRAY[public.http_header('Authorization', 'Bearer ' || api_token)],
            'application/json',
            json_build_object(
                'model', model_name,
                'messages', message_payload,
                'tools', CASE 
                        WHEN functions_in IS NULL OR functions_in::TEXT = '[]' THEN NULL
                        ELSE functions_in 
                     END-- functions have been mapped for the scheme
            )::jsonb
		   )::http_request
        );

    -- Log the API response for debugging
    --RAISE NOTICE 'API Response: % from functions %', api_response, functions_in;

    -- Extract tool calls from the response
    tool_calls := (api_response->'choices'->0->'message'->>'tool_calls')::JSONB;
    result_set := (api_response->'choices'->0->'message'->>'content')::TEXT;
    api_error := (api_response->>'error')::TEXT;

    -- Handle token usage
    tokens_in := (api_response->'usage'->>'prompt_tokens')::INTEGER;
    tokens_out := (api_response->'usage'->>'completion_tokens')::INTEGER;
    finish_reason := (api_response->'choices'->0->>'finish_reason')::TEXT;
	
    --RAISE NOTICE 'WE HAVE % %', result_set, finish_reason;

    -- Return the results
    RETURN QUERY
    SELECT result_set::TEXT, tool_calls::JSONB, tokens_in::INTEGER, tokens_out::INTEGER, finish_reason::TEXT, api_error::TEXT;

END;
$$ LANGUAGE plpgsql;

-------------
DROP function if exists p8.request_anthropic;
CREATE OR REPLACE FUNCTION p8.request_anthropic(
    message_payload JSON,
    functions_in JSON DEFAULT NULL,
    model_name TEXT DEFAULT 'claude-3-5-sonnet-20241022',
    endpoint_uri TEXT DEFAULT 'https://api.anthropic.com/v1/messages',
	api_token TEXT DEFAULT NULL
)
RETURNS TABLE(
    message_content TEXT, 
    tool_calls_out JSONB, 
    tokens_in INTEGER, 
    tokens_out INTEGER, 
    finish_reason TEXT, 
    api_error TEXT
) AS
$$
DECLARE
    api_response JSONB;
    result_set JSONB;
    selected_model TEXT;
    selected_scheme TEXT;
    system_messages TEXT;
BEGIN
    -- If api_token is NULL, retrieve values from the LanguageModelApi table
    IF api_token IS NULL THEN
        SELECT completions_uri, 
               COALESCE(token, api_token), 
               model, 
               scheme
        INTO endpoint_uri, api_token, selected_model, selected_scheme
        FROM p8."LanguageModelApi"
        WHERE scheme = 'anthropic'
        LIMIT 1;
    END IF;

    -- Ensure model_name defaults to the selected model if not provided
    IF model_name IS NULL THEN
        model_name := selected_model;
    END IF;

    -- Extract and concatenate all system messages into system_messages variable
    SELECT string_agg(message->>'content', ' ') 
    INTO system_messages
    FROM jsonb_array_elements(message_payload::JSONB) AS msg(message)
    WHERE msg.message->>'role' = 'system';

    -- Filter out system messages from message_payload
    message_payload := (
        SELECT jsonb_agg(msg.message) 
        FROM jsonb_array_elements(message_payload::JSONB) AS msg(message)
        WHERE msg.message->>'role' != 'system'
    );

    -- Make the HTTP request and retrieve the response
    SELECT content
        INTO api_response
        FROM public.http(
		   (
            'POST',
            endpoint_uri,
             ARRAY[
                    public.http_header('x-api-key', api_token),
                    public.http_header('anthropic-version', '2023-06-01')
                ],
            'application/json',
            json_build_object(
                'messages', message_payload,
                'system', system_messages,  
                'max_tokens', 8192, --TODO set this per model
                'tools', COALESCE(functions_in, '[]'::JSON),
                'model', model_name
            )::jsonb
		   )::http_request
        );

    -- Log the API response for debugging
    RAISE NOTICE 'API Response: %', api_response;

    -- Return the processed result in canonical form
    RETURN QUERY 
    SELECT * from p8.anthropic_to_open_ai_response(api_response);

END;
$$ LANGUAGE plpgsql;

--------------------------------------------------------
drop function if exists p8.request_google;
-- FUNCTION: p8.request_google(json, json, text, text, text)

-- DROP FUNCTION IF EXISTS p8.request_google(json, json, text, text, text);

CREATE OR REPLACE FUNCTION p8.request_google(
	message_payload json,
	functions_in json DEFAULT NULL::json,
	model_name text DEFAULT 'gemini-1.5-flash'::text,
	endpoint_uri text DEFAULT 'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent'::text,
	api_token text DEFAULT NULL::text)
    RETURNS TABLE(message_content text, tool_calls_out jsonb, tokens_in integer, tokens_out integer, finish_reason text, api_error text) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    api_response JSONB;
    system_messages TEXT;
    result_set JSONB;
    selected_model TEXT;
    selected_scheme TEXT;
BEGIN
    -- If api_token is NULL, retrieve values from the LanguageModelApi table
    IF api_token IS NULL THEN
        SELECT completions_uri, 
               COALESCE(token, api_token), 
               model, 
               scheme
        INTO endpoint_uri, api_token, selected_model, selected_scheme
        FROM p8."LanguageModelApi"
        WHERE scheme = 'google'
        LIMIT 1;
    END IF;

    -- Ensure model_name defaults to the selected model if not provided
    IF model_name IS NULL THEN
        model_name := selected_model;
    END IF;

    -- Extract and concatenate all system messages into system_messages variable
    SELECT string_agg(message->>'content', ' ') 
    INTO system_messages
    FROM jsonb_array_elements(message_payload::JSONB) AS msg(message)
    WHERE msg.message->>'role' = 'system';

    -- Filter out system messages from message_payload
    message_payload := (
        SELECT jsonb_agg(msg.message) 
        FROM jsonb_array_elements(message_payload::JSONB) AS msg(message)
        WHERE msg.message->>'role' != 'system'
    );

    -- Make the HTTP request and retrieve the response

	
    SELECT content
        INTO api_response
        FROM public.http(
		  (
            'POST',
            endpoint_uri || '?key=' || api_token,
            NULL,
            'application/json',
            json_build_object(
                'contents', message_payload,
                'system_instruction',  system_messages,  -- Add concatenated system text
                -- 'tool_config', json_build_object(
                --     'function_calling_config', json_build_object(
                --         'mode', 
                --         CASE 
                --             WHEN functions_in IS NOT NULL THEN 'ANY' 
                --             ELSE 'NONE' 
                --         END
                --     )
                -- ),
                'tools', functions_in,
                'model', model_name
            )::jsonb
		   )::http_request
        );

    -- Log the API response for debugging
    RAISE NOTICE 'API Response: %', api_response;

    -- Return the processed result in canonical form
    RETURN QUERY 
    SELECT * from p8.google_to_open_ai_response(api_response);

END;
$BODY$;

ALTER FUNCTION p8.request_google(json, json, text, text, text)
    OWNER TO postgres;


-- Function from: requests/response_mappings.sql
------------------------------------------------------------
/*we map all function call args to string for canonical*/

-- FUNCTION: p8.anthropic_to_open_ai_response(jsonb)

DROP FUNCTION IF EXISTS p8.anthropic_to_open_ai_response ;

CREATE OR REPLACE FUNCTION p8.anthropic_to_open_ai_response(
	api_response jsonb)
    RETURNS TABLE(msg text, tool_calls_out jsonb, tokens_in integer, tokens_out integer, finish_reason text, api_error text) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
BEGIN
    /*
    Example anthropic response message usage:
    select * from p8.anthropic_to_open_ai_response('{
  "id": "msg_015kdLpARvtbRqDSmJKiamSB",
  "type": "message",
  "role": "assistant",
  "model": "claude-3-5-sonnet-20241022",
  "content": [
    {"type": "text", "text": "Ill help you check the weather in Paris for tomorrow. Let me use the get_weather function with tomorrows date."},
    {"type": "tool_use", "id": "toolu_01GV5rqVypHCQ6Yhrfsz8qhQ", "name": "get_weather", "input": {"city": "Paris", "date": "2024-01-16"}}
  ],
  "stop_reason": "tool_use",
  "stop_sequence": null,
  "usage": {
    "input_tokens": 431,
    "cache_creation_input_tokens": 0,
    "cache_read_input_tokens": 0,
    "output_tokens": 101
  }
}'::JSONB)
    */

	 IF api_response ? 'error' THEN
        RETURN QUERY 
        SELECT api_response->>'error', NULL::JSONB, NULL::INTEGER, NULL::INTEGER, NULL, api_response->>'error';
        RETURN;
    END IF;
	
    RETURN QUERY
    WITH r AS (
        SELECT jsonb_array_elements(api_response->'content') AS el
    ),
    msg AS (
        SELECT el->>'text' AS msg
        FROM r
        WHERE el->>'type' = 'text'
    ),
    tool_calls AS (
        SELECT json_build_array(
                    json_build_object(
                        'id', el->>'id',
                        'type', 'function',
                        'function', json_build_object(
                            'name', el->>'name',
                            'arguments', (el->>'input')::TEXT
                        )
                    )
                ) AS tool_calls
        FROM r
        WHERE el->>'type' = 'tool_use'
    ),
    tokens AS (
        SELECT 
            (api_response->'usage'->>'input_tokens')::INTEGER AS tokens_in,
            (api_response->'usage'->>'output_tokens')::INTEGER AS tokens_out
    ),
    finish AS (
        SELECT 
            api_response->>'stop_reason' AS finish_reason
    ),
    error AS (
        SELECT api_response->>'error' AS api_error
    )
    SELECT
        msg.msg::TEXT, --in case null
        tool_calls.tool_calls::JSONB,
        tokens.tokens_in,
        tokens.tokens_out,
        lower(finish.finish_reason),
        error.api_error
    FROM msg
    FULL OUTER JOIN tool_calls ON TRUE
    CROSS JOIN tokens
    CROSS JOIN finish
    CROSS JOIN error;
END;
$BODY$;

ALTER FUNCTION p8.anthropic_to_open_ai_response(jsonb)
    OWNER TO postgres;
-----

-- FUNCTION: p8.google_to_open_ai_response(jsonb)

-- DROP FUNCTION IF EXISTS p8.google_to_open_ai_response(jsonb);

CREATE OR REPLACE FUNCTION p8.google_to_open_ai_response(
	api_response jsonb)
    RETURNS TABLE(msg text, tool_calls_out jsonb, tokens_in integer, tokens_out integer, finish_reason text, api_error TEXT) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    function_call jsonb; -- Variable to hold the function call JSON
BEGIN
    /*
    Example Google response message usage:
    select * from p8.google_to_open_ai_response('{
        "candidates": [
            {
                "content": {
                    "parts": [
                        {
                            "functionCall": {
                                "name": "get_weather",
                                "args": {"date": "2024-07-27", "city": "Paris"}
                            }
                        }
                    ],
                    "role": "model"
                },
                "finishReason": "STOP",
                "avgLogprobs": -0.004642472602427006
            }
        ],
        "usageMetadata": {
            "promptTokenCount": 83,
            "candidatesTokenCount": 16,
            "totalTokenCount": 99
        },
        "modelVersion": "gemini-1.5-flash"
    }'::JSONB)
    */

    -- Capture the function call from the JSON
    function_call := api_response->'candidates'->0->'content'->'parts'->0->'functionCall';

    -- Extract token usage and finish reason
    tokens_in := (api_response->'usageMetadata'->>'promptTokenCount')::INTEGER;
    tokens_out := (api_response->'usageMetadata'->>'candidatesTokenCount')::INTEGER;
    finish_reason := lower((api_response->'candidates'->0->>'finishReason')::TEXT);

    -- Capture any API errors
    api_error := api_response->>'error';

    -- Return the message and mapped tool calls
    RETURN QUERY
    SELECT
        (api_response->'candidates'->0->'content'->'parts'->0->>'text')::TEXT AS msg,
        CASE
            WHEN function_call IS NOT NULL THEN
                json_build_array(
                    json_build_object(
                        'id', function_call->>'name', -- Use the name as the ID
                        'type', 'function',
                        'function', json_build_object(
                            'name', function_call->>'name',
                            'arguments', (function_call->'args')::TEXT
                        )
                    )
                )::JSONB
            ELSE NULL
        END AS tool_calls_out,
        tokens_in,
        tokens_out,
        finish_reason,
        api_error;
END;
$BODY$;

ALTER FUNCTION p8.google_to_open_ai_response(jsonb)
    OWNER TO postgres;


-- Function from: requests/resume_session.sql
------------------------------------------------------------
-- FUNCTION: p8.resume_session(uuid, text)

-- DROP FUNCTION IF EXISTS p8.resume_session(uuid, text);

CREATE OR REPLACE FUNCTION p8.resume_session(
	session_id uuid,
	token_override text DEFAULT NULL::text)
    RETURNS TABLE(message_response text, tool_calls jsonb, tool_call_result jsonb, session_id_out uuid, status text) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    recovered_session_id uuid;
    user_id uuid;
    recovered_agent text;
    recovered_question text;
    selected_scheme text;
    model_key text;
    last_session_status text;
    functions text[];
    message_payload json;
    tool_eval_data_recovered jsonb;
BEGIN

	/*
	to test this generate a session and then select the id into the resume

	select * from percolate_with_agent('what pets are sold', 'MyFirstAgent');
	
	select * from p8.resume_session('075b3126-326c-d62d-db5d-506764babf09') --openai
	select * from p8.resume_session('6cf58a04-1650-9aae-8097-60f449274a70') --anthropic
	select * from p8.resume_session('619857d3-434f-fa51-7c88-6518204974c9') --google
	
 
	  -- select messages from p8.get_canonical_messages('583060b2-70c6-478c-a483-2292870a980a');
	  -- select messages from p8.get_anthropic_messages('6cf58a04-1650-9aae-8097-60f449274a70');
	  -- select messages from p8.get_google_messages('619857d3-434f-fa51-7c88-6518204974c9');
	  -- select * from p8."AIResponse" where session_id = '583060b2-70c6-478c-a483-2292870a980a'

	    --try this and resume from canonical 
	select * from percolate_with_agent('list some pets that str sold', 'MyFirstAgent', NULL, NULL, 'gemini-1.5-flash'); 
    select * from percolate_with_agent('list some pets that str sold', 'MyFirstAgent', NULL, NULL, 'claude-3-5-sonnet-20241022');
 
	*/
	
    -- 1. Get session details from p8.Session
    SELECT s.id, s.userid, s.agent, s.query INTO 
        recovered_session_id, user_id, recovered_agent, recovered_question
    FROM p8."Session" s
    WHERE s.id = session_id;

    -- Check if session exists
    IF recovered_session_id IS NULL THEN
        RETURN QUERY 
            SELECT 'No matching session'::text, NULL::jsonb, NULL::jsonb, session_id, NULL::text;
        RETURN;
    END IF;

    -- 2. Get the model key and last session status from p8.AIResponse
    SELECT r.model_name, r.status, a.scheme INTO 
        model_key, last_session_status, selected_scheme
    FROM p8."AIResponse" r
    JOIN p8."LanguageModelApi" a ON r.model_name = a.model
    WHERE r.session_id = recovered_session_id
    ORDER BY r.created_at DESC
    LIMIT 1;

    -- 3. Get the messages for the correct scheme
    IF selected_scheme = 'anthropic' THEN
        -- Select into message payload from p8.get_anthropic_messages
        SELECT messages INTO message_payload FROM p8.get_anthropic_messages(recovered_session_id);
    ELSIF selected_scheme = 'google' THEN
        -- Select into message payload from p8.get_google_messages
        SELECT messages INTO message_payload FROM p8.get_google_messages(recovered_session_id);
    ELSE
        -- Select into message payload from p8.get_canonical_messages
        SELECT messages INTO message_payload FROM p8.get_canonical_messages(recovered_session_id);
    END IF;

	--	RAISE NOTICE 'For session % and scheme %, we have Messages %', recovered_session_id, selected_scheme, message_payload;

    -- In case message_payload is NULL, log and return a generic response
    IF message_payload IS NULL THEN
        RETURN QUERY 
            SELECT 'No message payload found'::text, NULL::jsonb, NULL::jsonb, session_id, last_session_status;
        RETURN;
    END IF;

	 -- Default public schema for agent if not provided
    SELECT CASE 
        WHEN recovered_agent NOT LIKE '%.%' THEN 'public.' || recovered_agent 
        ELSE recovered_agent 
    END INTO recovered_agent;
	
    -- 4. Handle tool evaluation data recovery (using get_agent_tools function)
    BEGIN
        -- Call the get_agent_tools function to fetch tools for the agent
        SELECT p8.get_agent_tool_names(recovered_agent, selected_scheme, TRUE) INTO functions;
        
        -- If functions is NULL, log error and return
        IF functions IS NULL THEN
            RETURN QUERY 
                SELECT format('Error: Failed to retrieve agent tools for agent "%s" with scheme "%s"', recovered_agent, selected_scheme)::text,
				  NULL::jsonb, NULL::jsonb, session_id, last_session_status;
            RETURN;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        -- Error handling in case get_agent_tools fails
        RETURN QUERY 
            SELECT 'Error: ' || SQLERRM, NULL::jsonb, NULL::jsonb, session_id, last_session_status;
        RETURN;
    END;

	
    -- 5. Return the results using p8.ask function
    RETURN QUERY 
    SELECT * 
    FROM p8.ask(
        message_payload::json, 
        recovered_session_id, 
        functions, 
        model_key, 
        token_override, 
        user_id
    );
END;
$BODY$;

ALTER FUNCTION p8.resume_session(uuid, text)
    OWNER TO postgres;


-- Function from: requests/run.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS run;
CREATE OR REPLACE FUNCTION run(
    question text,                          --ask a hard question 
    limit_iterations int DEFAULT 3,         -- the number of turns allowed 
    model text DEFAULT 'gpt-4o-mini',       -- the model to use - gpt models are faster for this sort of thing usually
    agent text DEFAULT 'p8.PercolateAgent'  -- you can use any agent, by default the Percolation agent is a general purpose agent that will ask for help if needed
) RETURNS TABLE (
    message_response text,
    tool_calls jsonb,
    tool_call_result jsonb,
    session_id_out uuid,
    status text
) AS $$
DECLARE
    session_id_captured uuid;
    current_row record;  -- To capture the row from resume_session
    iterations int := 1; -- default to 
BEGIN
    /*
    this function is just for test/poc
    just because we can do this does not mean we should as it presents long running queries
    this would be implemented in practice with a bounder against the API.
    The client would then consume from an API that ways for the result
    Nonetheless, for testing purposes its good to test that the session does resolve as we resume to a limit

    Here is an example if you have registered the tool example for swagger/pets

    select * from run('please activate function get_pet_findByStatus and find two pets that are sold')

    this requires multiple turns - first it realizes it needs the function so activates, then it runs the function (keep in mind we eval tool calls in each turn)
    then it finally generates the answer
    */

    -- First, call percolate_with_agent function
    SELECT p.session_id_out INTO session_id_captured
    FROM percolate_with_agent(question, agent, model) p;
    
    -- Get the function_stack (just an example)
    SELECT function_stack INTO message_response
    FROM p8."AIResponse" r
    WHERE r.session_id = session_id_captured;

    -- Loop to iterate until limit_iterations or status = 'COMPLETED'
    LOOP
		RAISE NOTICE '***resuming session, iteration %***', iterations+1;
        -- Call resume_session to resume the session and get the row
        SELECT * INTO current_row
        FROM p8.resume_session(session_id_captured);
        
        -- Check if the status is 'COMPLETED' or iteration limit reached
        IF current_row.status = 'COMPLETED' OR iterations >= (limit_iterations-1) THEN
            EXIT;
        END IF;
        
        iterations := iterations + 1;
    END LOOP;
    
    -- Return the final row from resume_session
    RETURN QUERY
    SELECT current_row.message_response,
           current_row.tool_calls,
           current_row.tool_call_result,
           current_row.session_id_out,
           current_row.status;
END;
$$ LANGUAGE plpgsql;


-- Function from: requests/run_web_search.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.run_web_search;

CREATE OR REPLACE FUNCTION p8.run_web_search(
    query TEXT,
    max_results INT DEFAULT 5,
    fetch_content BOOLEAN DEFAULT FALSE, -- Whether to fetch full page content
    include_images BOOLEAN DEFAULT FALSE,
    api_endpoint TEXT DEFAULT 'https://api.tavily.com/search',
    topic TEXT DEFAULT 'general', -- news|finance and other things
    optional_token TEXT DEFAULT NULL -- Allow token to be optionally passed in
) RETURNS TABLE (
    title TEXT,
    url TEXT,
    summary TEXT,
    content TEXT,
    score FLOAT,
    images TEXT[]
) AS $$
DECLARE
    api_token TEXT;
    call_uri TEXT := api_endpoint;
    api_response TEXT;
    response_json JSONB;
    result JSONB;
BEGIN
    /* We should generalize this for working with Brave or Tavily but for now just the latter.
       The token needs to be set to match the search endpoint for the provider.
       We can normally insert these search results into ingested resources based on context - we can read the search results in full if needed.


	   select * from p8.run_web_search('philosophy of mind')

	   	select * from p8.run_web_search('philosophy of mind','https://api.tavily.com/search', 'general', 3, TRUE,TRUE)

		select * from http_get('https://en.wikipedia.org/wiki/Philosophy_of_mind')
    */

	
    -- Determine API token: Use optional_token if provided, otherwise fetch from ApiProxy
    IF optional_token IS NOT NULL THEN
        api_token := optional_token;
    ELSE
        SELECT token INTO api_token 
        FROM p8."ApiProxy" 
        WHERE proxy_uri = api_endpoint 
        LIMIT 1;
    END IF;


    -- Raise exception if no token is available
    IF api_token IS NULL THEN
        RAISE EXCEPTION 'API token not found for %', api_endpoint;
    END IF;

    -- Construct request payload
    response_json := jsonb_build_object(
        'query', query,
        'topic', topic,
        'max_results', max_results,
        'include_images', include_images
    );

    -- Make the HTTP POST request
    SELECT a.content INTO api_response
    FROM http(
        (
            'POST', 
            call_uri, 
            ARRAY[
                http_header('Authorization', 'Bearer ' || api_token)--,
                --http_header('Content-Type', 'application/json')
            ], 
            'application/json', 
            response_json
        )::http_request
    ) as a;

    -- Convert the response to JSONB
    response_json := api_response::JSONB;

    -- Validate response format
    IF NOT response_json ? 'results' THEN
        RAISE EXCEPTION 'Unexpected API response format: %', response_json;
    END IF;

    -- Loop through each result and return as table rows
    FOR result IN 
        SELECT * FROM jsonb_array_elements(response_json->'results')
    LOOP
        title := result->>'title';
        url := result->>'url';
        summary := result->>'content'; -- Renamed from content to summary
        score := (result->>'score')::FLOAT;
        
        -- Extract images array, defaulting to an empty array if not present
        images := COALESCE(
            ARRAY(
                SELECT jsonb_array_elements_text(result->'images')
            )::TEXT[],
            ARRAY[]::TEXT[]
        );

		--RAISE NOTICE '%', url;
		
        -- Fetch full page content if flag is set
         -- Fetch full page content with error handling
        IF fetch_content THEN
            BEGIN
                SELECT a.content INTO content FROM http_get(url) a;
            EXCEPTION WHEN OTHERS THEN
                content := NULL;
                RAISE NOTICE 'Failed to fetch content for URL: %', url;
            END;
        ELSE
            content := NULL;
        END IF;

        RETURN NEXT;
    END LOOP;
END;
$$ LANGUAGE plpgsql;


-- ====================================================================
-- SEARCH FUNCTIONS
-- ====================================================================

-- Function from: search/deep_search.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.deep_search;

CREATE OR REPLACE FUNCTION p8.deep_search(
    query_text TEXT,
    table_entity_name TEXT,
    content_column TEXT DEFAULT 'content'
)
RETURNS TABLE (
    id UUID,
    vector_distance DOUBLE PRECISION,
    entity_name TEXT,
    content TEXT,
    related_paths JSONB
)
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    schema_name TEXT;
    table_name TEXT;
    dynamic_query TEXT;
BEGIN

	/*
	select * rom p8.deep_search('tell me about harpoons', 'public.Chapter')	
	*/

    -- Load necessary extensions and set search path
    -- AGE extension is preloaded at session level
    SET search_path = ag_catalog, "$user", public;

    schema_name := split_part(table_entity_name, '.', 1);
    table_name := split_part(table_entity_name, '.', 2);

    -- Perform vector search and gather the entity IDs, distances, and content
    RETURN QUERY EXECUTE format(
        'WITH vector_results AS (
            SELECT v.id, v.vdistance, c.name AS entity_name, c.%I AS content
            FROM %I.%I c
            JOIN p8.vector_search_entity($1, $2) v
            ON c.id = v.id
        ),
        path_data AS (
            SELECT 
                origin_node AS entity_name,
                jsonb_agg(
                    jsonb_build_object(
                        ''path_node_labels'', path_node_labels
                    )
                ) AS related_paths
            FROM vector_results
            CROSS JOIN LATERAL p8.get_paths(ARRAY[vector_results.entity_name], 3)
            GROUP BY origin_node
        )
        SELECT vr.id, vr.vdistance, vr.entity_name, vr.content, COALESCE(pd.related_paths, ''[]''::jsonb)
        FROM vector_results vr
        LEFT JOIN path_data pd ON vr.entity_name = pd.entity_name;',
        content_column, schema_name, table_name
    ) USING query_text, table_entity_name;
END;
$BODY$;


-- Function from: search/fuzzy_match_node_key.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.fuzzy_match_node_key;

CREATE OR REPLACE FUNCTION p8.fuzzy_match_node_key(
    match_text TEXT,
    similarity_threshold REAL DEFAULT 0.4
)
RETURNS TABLE (
    id TEXT,
    key TEXT,
    similarity_score REAL
)
LANGUAGE SQL
AS $$

	/*
	CREATE EXTENSION IF NOT EXISTS pg_trgm;

	select * from p8.fuzzy_match_node_key('100012')
	*/
    SELECT 
        id,
        json_data->>'key' AS key,
        similarity(json_data->>'key', match_text) AS similarity_score
    FROM (
        SELECT id, properties::json AS json_data
        FROM percolate._ag_label_vertex
    ) AS sub
    WHERE similarity(json_data->>'key', match_text) > similarity_threshold
    ORDER BY similarity_score DESC;
$$;


-- Function from: search/get_fuzzy_entities.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.get_fuzzy_entities;

CREATE OR REPLACE FUNCTION p8.get_fuzzy_entities(
    search_terms TEXT[],
    similarity_threshold REAL DEFAULT 0.5,
    userid TEXT DEFAULT NULL,
    max_matches_per_term INT DEFAULT 5
)
RETURNS JSONB
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    unique_keys TEXT[];
    result JSONB;
BEGIN
    /*
    Optimized function to fuzzy match multiple search terms and return entities that match
    
    1. Function performs fuzzy matching on multiple search terms and returns the expected entities.
    2. Default threshold of 0.5 is appropriate because:
        - At 0.5, it matches exact terms and very close variations
        - For "Agent" search, it matches both "agent" and "p8.Agent" (scores 1.0 and 0.67)
        - For "Resource" search, it matches "resource_id" (0.75) and "p8.Resources" (0.57)
        - It filters out weak matches like "resource_timestamp" (0.47)
    3. Threshold behavior:
        - 0.3-0.4: Too permissive, includes weak matches like "resource_timestamp"
        - 0.5: Good balance (current default)
        - 0.6: More restrictive, drops "p8.Resources"
        - 0.7: Very restrictive, only matches "agent" and "resource_id"
    4. Performance characteristics:
        - Uses single optimized query with CROSS JOIN
        - Limits matches per term (default 5)
        - Deduplicates results before passing to get_entities
        - Properly handles case-insensitive matching

    Parameters:
    - search_terms: Array of strings to search for
    - similarity_threshold: Minimum similarity score (0.0-1.0) to consider a match (default: 0.5)
    - userid: Optional user ID for filtering results (deprecated, will be removed)
    - max_matches_per_term: Maximum number of matches to return per search term (default: 5)
    
    Example usage:
    -- Search for multiple terms (uses default threshold 0.5)
    SELECT p8.get_fuzzy_entities(ARRAY['customer', 'order', 'product']);
    
    -- Search with custom threshold
    SELECT p8.get_fuzzy_entities(ARRAY['customer', 'order'], 0.6);
    
    -- Search with user filter (deprecated, will be removed)
    SELECT p8.get_fuzzy_entities(ARRAY['customer', 'order'], 0.6, 'user123');
    
    -- Search with all parameters
    SELECT p8.get_fuzzy_entities(ARRAY['customer', 'order'], 0.7, 'user123', 10);
    
    Returns:
    {
        "search_metadata": {
            "search_terms": ["customer", "order"],
            "similarity_threshold": 0.5,
            "max_matches_per_term": 5,
            "matched_keys_count": 4,
            "matched_keys": ["Customer", "CustomerOrder", "Order", "OrderItem"]
        },
        "entities": {
            "Customer": {...},
            "Order": {...},
            ...
        }
    }
    */
    
    -- Ensure pg_trgm extension is available
    --CREATE EXTENSION IF NOT EXISTS pg_trgm;
    
    -- Get all fuzzy matches in a single optimized query
    WITH all_matches AS (
        SELECT DISTINCT
            json_data->>'key' AS key,
            search_term,
            similarity(json_data->>'key', search_term) AS similarity_score,
            ROW_NUMBER() OVER (PARTITION BY search_term ORDER BY similarity(json_data->>'key', search_term) DESC) as rank
        FROM (
            SELECT id, properties::json AS json_data
            FROM percolate._ag_label_vertex
        ) vertices
        CROSS JOIN unnest(search_terms) AS search_term
        WHERE similarity(json_data->>'key', search_term) > similarity_threshold
    ),
    ranked_matches AS (
        SELECT key
        FROM all_matches
        WHERE rank <= max_matches_per_term
    )
    SELECT ARRAY_AGG(DISTINCT key)
    INTO unique_keys
    FROM ranked_matches;
    
    -- If we have matched keys, get the entities
    IF unique_keys IS NOT NULL AND array_length(unique_keys, 1) > 0 THEN
        -- Call get_entities with the matched keys
        result := p8.get_entities(unique_keys, userid);
    ELSE
        -- Return empty result if no matches found
        result := '{}'::JSONB;
    END IF;
    
    -- Add metadata about the search
    result := jsonb_build_object(
        'search_metadata', jsonb_build_object(
            'search_terms', search_terms,
            'similarity_threshold', similarity_threshold,
            'max_matches_per_term', max_matches_per_term,
            'matched_keys_count', COALESCE(array_length(unique_keys, 1), 0),
            'matched_keys', unique_keys
        ),
        'entities', result
    );
    
    RETURN result;
END;
$BODY$;

-- Grant execute permission to public
GRANT EXECUTE ON FUNCTION p8.get_fuzzy_entities(TEXT[], REAL, TEXT, INT) TO public;

-- Add comment for documentation
COMMENT ON FUNCTION p8.get_fuzzy_entities IS 'Optimized fuzzy match for multiple search terms. Returns entities that match any of the provided search terms with a similarity score above the threshold. Uses a single query for efficiency.';

-- Create an index to improve fuzzy matching performance if it doesn't exist
-- Note: This should be run once on the actual database, not in the function
-- CREATE INDEX IF NOT EXISTS idx_vertex_key_trgm ON percolate._ag_label_vertex USING gin ((properties::json->>'key') gin_trgm_ops);


-- Function from: search/merge_search_results.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.merge_search_results;

CREATE OR REPLACE FUNCTION p8.merge_search_results(
    sql_results JSONB,
    vector_results JSONB,
    graph_results JSONB,
    sql_weight NUMERIC DEFAULT 0.4,
    vector_weight NUMERIC DEFAULT 0.4,
    graph_weight NUMERIC DEFAULT 0.2,
    max_results INTEGER DEFAULT 10
)
RETURNS TABLE(
    id UUID,
    score NUMERIC,
    content JSONB,
    source TEXT,
    rank INTEGER
) 
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL SAFE
ROWS 1000
AS $BODY$
DECLARE
    combined_results JSONB;
    sql_count INTEGER;
    vector_count INTEGER;
    graph_count INTEGER;
BEGIN
    /*
    Merges search results from different sources (SQL, vector, graph) with weighted scoring
    
    Example usage:
    SELECT * FROM p8.merge_search_results(
        query_result.relational_result, 
        query_result.vector_result, 
        query_result.graph_result
    ) FROM p8.query_entity_fast('what is my favorite color', 'p8.UserFact') AS query_result;
    */
    
    -- Initialize counters
    sql_count := CASE WHEN sql_results IS NOT NULL THEN jsonb_array_length(sql_results) ELSE 0 END;
    vector_count := CASE WHEN vector_results IS NOT NULL THEN jsonb_array_length(vector_results) ELSE 0 END;
    graph_count := CASE WHEN graph_results IS NOT NULL THEN jsonb_array_length(graph_results) ELSE 0 END;
    
    -- Create a CTE for SQL results
    RETURN QUERY WITH
    sql_data AS (
        SELECT 
            (r->>'id')::UUID AS id,
            sql_weight AS base_score,
            r AS content,
            'sql' AS source,
            idx AS original_rank
        FROM jsonb_array_elements(COALESCE(sql_results, '[]'::JSONB)) WITH ORDINALITY AS a(r, idx)
        WHERE idx <= max_results
    ),
    
    -- Create a CTE for vector results
    vector_data AS (
        SELECT 
            (r->>'id')::UUID AS id,
            vector_weight * (1 - COALESCE((r->>'vdistance')::NUMERIC, 0.5)) AS base_score,
            r AS content,
            'vector' AS source,
            idx AS original_rank
        FROM jsonb_array_elements(COALESCE(vector_results, '[]'::JSONB)) WITH ORDINALITY AS a(r, idx)
        WHERE idx <= max_results
    ),
    
    -- Create a CTE for graph results - assuming graph results have target node IDs
    graph_data AS (
        SELECT 
            (r->>'target_node_id')::UUID AS id,
            graph_weight * (1 - (r->>'path_length')::NUMERIC / 10) AS base_score,
            r AS content,
            'graph' AS source,
            idx AS original_rank
        FROM jsonb_array_elements(COALESCE(graph_results, '[]'::JSONB)) WITH ORDINALITY AS a(r, idx)
        WHERE idx <= max_results
    ),
    
    -- Union all results
    all_results AS (
        SELECT * FROM sql_data
        UNION ALL
        SELECT * FROM vector_data
        UNION ALL
        SELECT * FROM graph_data
    ),
    
    -- Group by ID to combine scores from different sources
    grouped_results AS (
        SELECT 
            id,
            SUM(base_score) AS total_score,
            jsonb_agg(jsonb_build_object('content', content, 'source', source, 'rank', original_rank)) AS all_content,
            STRING_AGG(source, ',') AS sources
        FROM all_results
        GROUP BY id
    )
    
    -- Final output with ranking
    SELECT 
        id,
        total_score AS score,
        all_content AS content,
        sources AS source,
        RANK() OVER (ORDER BY total_score DESC) AS rank
    FROM grouped_results
    ORDER BY score DESC
    LIMIT max_results;
END;
$BODY$;

COMMENT ON FUNCTION p8.merge_search_results IS 
'Merges and scores results from SQL, vector, and graph searches to provide a unified ranking.';


-- Function from: search/parallel_search.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.parallel_search;

CREATE OR REPLACE FUNCTION p8.parallel_search(
    query TEXT,
    entity_types TEXT[] DEFAULT NULL,
    user_id UUID DEFAULT NULL,
    max_results INTEGER DEFAULT 10,
    include_graph BOOLEAN DEFAULT TRUE,
    include_execution_stats BOOLEAN DEFAULT FALSE
)
RETURNS TABLE(
    entity_type TEXT,
    id UUID,
    score NUMERIC,
    content JSONB,
    rank INTEGER,
    execution_stats JSONB
) 
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL SAFE
ROWS 1000
AS $BODY$
DECLARE
    entity_type TEXT;
    default_entities TEXT[];
    result_data JSONB := '[]'::JSONB;
    execution_stats_data JSONB := '{}'::JSONB;
BEGIN
    /*
    A high-level parallel search across multiple entity types with unified ranking.
    Executes SQL queries, vector searches, and graph traversals in parallel.
    
    Example usage:
    -- Search across all default entities:
    SELECT * FROM p8.parallel_search('customer retention strategies');
    
    -- Search specific entities:
    SELECT * FROM p8.parallel_search('favorite color', ARRAY['p8.UserFact'], 'e9c56a28-1d09-5253-af36-4b9d812f6bfa');
    
    -- Search with execution statistics:
    SELECT * FROM p8.parallel_search('database performance', NULL, NULL, 10, true, true);
    */
    
    -- If no entity types provided, use default set of searchable entities
    IF entity_types IS NULL THEN
        SELECT ARRAY_AGG(entity_name) INTO default_entities
        FROM p8."ModelField"
        WHERE embedding_provider IS NOT NULL
        GROUP BY entity_name
        LIMIT 10; -- Limit to top 10 entity types for performance
        
        entity_types := default_entities;
    END IF;
    
    -- Process each entity type in parallel
    FOR entity_type IN SELECT unnest(entity_types) LOOP
        -- Use a separate background worker for each entity type
        PERFORM pg_background_send('
            SELECT pg_notify(
                ''parallel_search_result'', 
                json_build_object(
                    ''entity_type'', $1,
                    ''results'', (
                        SELECT json_build_object(
                            ''query_results'', q.*,
                            ''merged_results'', (
                                SELECT json_agg(m.*)
                                FROM p8.merge_search_results(
                                    q.relational_result,
                                    q.vector_result,
                                    CASE WHEN $2 THEN q.graph_result ELSE NULL END,
                                    0.4, 0.4, 0.2, $3
                                ) m
                            )
                        )
                        FROM p8.query_entity_fast($4, $1, $5) q
                    )
                )::text
            )', 
            ARRAY[entity_type, include_graph, max_results, query, user_id]
        );
    END LOOP;
    
    -- Collect results from all background workers
    DECLARE
        notification_payload JSONB;
        all_results JSONB := '[]'::JSONB;
        wait_count INTEGER := 0;
        max_wait INTEGER := 300; -- Maximum wait iterations (30 seconds at 100ms intervals)
        entity_count INTEGER := array_length(entity_types, 1);
        processed_count INTEGER := 0;
    BEGIN
        -- Listen for notifications from background workers
        LISTEN parallel_search_result;
        
        -- Wait for results or timeout
        WHILE processed_count < entity_count AND wait_count < max_wait LOOP
            -- Check for notifications
            FOR notification_payload IN
                SELECT payload::jsonb
                FROM pg_notification_queue_usage 
                WHERE channel = 'parallel_search_result'
            LOOP
                -- Process notification
                processed_count := processed_count + 1;
                
                -- Extract entity type and results
                DECLARE
                    current_entity TEXT := notification_payload->>'entity_type';
                    entity_results JSONB := notification_payload->'results'->'merged_results';
                    query_execution_stats JSONB := jsonb_build_object(
                        current_entity, 
                        notification_payload->'results'->'query_results'->'execution_time_ms'
                    );
                BEGIN
                    -- Add entity type to each result
                    SELECT jsonb_agg(
                        jsonb_set(r, '{entity_type}', to_jsonb(current_entity))
                    )
                    FROM jsonb_array_elements(entity_results) r
                    INTO entity_results;
                    
                    -- Add to overall results
                    all_results := all_results || COALESCE(entity_results, '[]'::JSONB);
                    
                    -- Add execution stats if requested
                    IF include_execution_stats THEN
                        execution_stats_data := execution_stats_data || query_execution_stats;
                    END IF;
                END;
            END LOOP;
            
            -- If not all entities processed, wait a bit
            IF processed_count < entity_count THEN
                PERFORM pg_sleep(0.1);
                wait_count := wait_count + 1;
            END IF;
        END LOOP;
        
        -- Stop listening
        UNLISTEN parallel_search_result;
        
        -- Re-rank all results across entity types
        SELECT jsonb_agg(r ORDER BY (r->>'score')::NUMERIC DESC)
        FROM jsonb_array_elements(all_results) r
        INTO result_data;
    END;
    
    -- Return final results
    RETURN QUERY 
    SELECT 
        (r->>'entity_type')::TEXT AS entity_type,
        (r->>'id')::UUID AS id,
        (r->>'score')::NUMERIC AS score,
        (r->>'content')::JSONB AS content,
        ROW_NUMBER() OVER (ORDER BY (r->>'score')::NUMERIC DESC) AS rank,
        CASE WHEN include_execution_stats THEN execution_stats_data ELSE NULL END AS execution_stats
    FROM jsonb_array_elements(COALESCE(result_data, '[]'::JSONB)) r
    ORDER BY score DESC
    LIMIT max_results;
END;
$BODY$;

COMMENT ON FUNCTION p8.parallel_search IS 
'High-level search function that executes parallel searches across multiple entity types, 
combining SQL, vector, and graph search approaches for comprehensive results.';


-- Function from: search/query_entity_fast.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.query_entity_fast;

CREATE OR REPLACE FUNCTION p8.query_entity_fast(
    question TEXT,
    table_name TEXT,
    user_id TEXT DEFAULT NULL,
    graph_max_depth INTEGER DEFAULT 2,
    min_confidence NUMERIC DEFAULT 0.7,
    limit_results INTEGER DEFAULT 5,
    use_sql_index BOOLEAN DEFAULT FALSE
)
RETURNS TABLE(
    query_text TEXT,
    confidence NUMERIC,
    relational_result JSONB,
    vector_result JSONB,
    graph_result JSONB,
    hybrid_score NUMERIC,
    execution_time_ms JSONB,
    error_message TEXT
) 
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL SAFE
ROWS 1000
AS $BODY$
DECLARE
    schema_name TEXT;
    table_without_schema TEXT;
    full_table_name TEXT;
    sql_query TEXT;
    sql_confidence NUMERIC;
    sql_start_time TIMESTAMPTZ;
    sql_end_time TIMESTAMPTZ;
    vector_start_time TIMESTAMPTZ;
    vector_end_time TIMESTAMPTZ;
    graph_start_time TIMESTAMPTZ;
    graph_end_time TIMESTAMPTZ;
    sql_query_result JSONB;
    vector_search_result JSONB;
    graph_result_data JSONB;
    error_messages TEXT[];
    timing_data JSONB;
    hybrid_score NUMERIC;
BEGIN
    /*
    Parallel query execution for entity search combining:
    1. SQL query generation and execution (if use_sql_index is TRUE)
    2. Vector similarity search
    3. Graph traversal for related entities
    
    The use_sql_index parameter controls whether to use SQL-based searching.
    It is FALSE by default because SQL searches with ILIKE patterns are not efficient 
    for content tables with rich text, as they require sequential scans unless special 
    GIN indexes are set up. Vector search is generally more effective for semantic matching.
    
    Example usage:
    SELECT * FROM p8.query_entity_fast('what is my favorite color', 'p8.UserFact', 'e9c56a28-1d09-5253-af36-4b9d812f6bfa');
    SELECT * FROM p8.query_entity_fast('documents about database performance', 'p8.Document');
    SELECT * FROM p8.query_entity_fast('research on AI', 'p8.Resources', NULL, 2, 0.7, 5, FALSE); -- Disable SQL index
    SELECT * FROM p8.query_entity_fast('research on AI', 'p8.Resources', NULL, 2, 0.7, 5, TRUE);  -- Enable SQL index
    */

    -- Extract schema and table name
    schema_name := split_part(table_name, '.', 1);
    table_without_schema := split_part(table_name, '.', 2);
    full_table_name := FORMAT('%I."%I"', schema_name, table_without_schema);
    
    -- Initialize results
    sql_query_result := NULL;
    vector_search_result := NULL;
    graph_result_data := NULL;
    error_messages := ARRAY[]::TEXT[];

    -- BLOCK 1: Generate SQL query using nl2sql if use_sql_index is enabled
    sql_start_time := clock_timestamp();
    
    IF use_sql_index THEN
        -- Execute nl2sql synchronously only if SQL index is enabled
        BEGIN
            SELECT nl."query", nl.confidence INTO sql_query, sql_confidence
            FROM p8.nl2sql(question, table_name) AS nl;
        EXCEPTION WHEN OTHERS THEN
            error_messages := array_append(error_messages, 'NL2SQL error: ' || SQLERRM);
            sql_query := NULL;
            sql_confidence := 0;
        END;
    ELSE
        -- Skip SQL query generation if SQL index is disabled
        sql_query := NULL;
        sql_confidence := 0;
        error_messages := array_append(error_messages, 'SQL indexing disabled by use_sql_index parameter');
    END IF;
    
    -- PARALLEL BLOCK 2: Perform vector search
    vector_start_time := clock_timestamp();
    
    BEGIN
        -- Try a simplified vector search approach - see if p8.vector_search_entity exists
        BEGIN
            -- Just check if the function exists and the table exists
            EXECUTE FORMAT('
                SELECT COUNT(*) 
                FROM pg_proc p 
                JOIN pg_namespace n ON p.pronamespace = n.oid
                WHERE n.nspname = ''p8'' AND p.proname = ''vector_search_entity''');
                
            -- If no exception, we can try to run the function
            IF user_id IS NOT NULL THEN
                BEGIN
                    -- Execute vector search with user_id filter
                    EXECUTE FORMAT('
                        SELECT jsonb_agg(row_to_json(result)) 
                        FROM (
                            SELECT b.*, a.vdistance 
                            FROM p8.vector_search_entity($1, $2, 0.75, $3) a
                            JOIN %I.%I b ON b.id = a.id
                            WHERE b.userid = $4::TEXT
                            ORDER BY a.vdistance
                        ) result', schema_name, table_without_schema)
                        INTO vector_search_result
                        USING question, table_name, limit_results, user_id;
                        
                    -- Handle null result
                    IF vector_search_result IS NULL THEN
                        vector_search_result := '[]'::jsonb;
                    END IF;
                EXCEPTION WHEN OTHERS THEN
                    error_messages := array_append(error_messages, 'Vector search user filter error: ' || SQLERRM);
                    vector_search_result := '[]'::jsonb;
                END;
            ELSE
                BEGIN
                    -- Execute vector search without user_id filter
                    EXECUTE FORMAT('
                        SELECT jsonb_agg(row_to_json(result)) 
                        FROM (
                            SELECT b.*, a.vdistance 
                            FROM p8.vector_search_entity($1, $2, 0.75, $3) a
                            JOIN %I.%I b ON b.id = a.id
                            ORDER BY a.vdistance
                        ) result', schema_name, table_without_schema)
                        INTO vector_search_result
                        USING question, table_name, limit_results;
                        
                    -- Handle null result
                    IF vector_search_result IS NULL THEN
                        vector_search_result := '[]'::jsonb;
                    END IF;
                EXCEPTION WHEN OTHERS THEN
                    error_messages := array_append(error_messages, 'Vector search error: ' || SQLERRM);
                    vector_search_result := '[]'::jsonb;
                END;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            error_messages := array_append(error_messages, 'Vector search function not available: ' || SQLERRM);
            vector_search_result := '[]'::jsonb;
        END;
    EXCEPTION WHEN OTHERS THEN
        error_messages := array_append(error_messages, 'Vector search outer error: ' || SQLERRM);
        vector_search_result := '[]'::jsonb;
    END;
    
    vector_end_time := clock_timestamp();
    
    -- PARALLEL BLOCK 3: Perform graph traversal
    graph_start_time := clock_timestamp();
    
    BEGIN
        -- Simplified graph traversal that won't error out
        -- In a production environment, we would implement full graph traversal
        graph_result_data := '[]'::jsonb;
    EXCEPTION WHEN OTHERS THEN
        error_messages := array_append(error_messages, 'Graph traversal error: ' || SQLERRM);
        graph_result_data := '[]'::jsonb;
    END;
    
    graph_end_time := clock_timestamp();
    
    -- Execute SQL query based on nl2sql results (only if use_sql_index is TRUE)
    BEGIN
        -- Initialize empty result
        sql_query_result := '[]'::jsonb;
        
        -- Only proceed if SQL querying is enabled and we have a query
        IF use_sql_index AND sql_query IS NOT NULL THEN
            -- Clean up quotes in table names
            sql_query := REPLACE(sql_query, 'YOUR_TABLE', full_table_name);
            -- Fix possible double quoting issue
            sql_query := REPLACE(sql_query, '""', '"');
            
            -- Execute SQL query if confidence is high enough
            IF sql_confidence >= min_confidence THEN
                BEGIN
                    sql_query := rtrim(sql_query, ';');
                    
                    -- Try to execute the query directly, handle possible issues
                    BEGIN
                        EXECUTE FORMAT('SELECT jsonb_agg(row_to_json(t)) FROM (%s) t', sql_query)
                        INTO sql_query_result;
                        
                        -- Handle null result
                        IF sql_query_result IS NULL THEN
                            sql_query_result := '[]'::jsonb;
                        END IF;
                    EXCEPTION WHEN OTHERS THEN
                        error_messages := array_append(error_messages, 'SQL execution error: ' || SQLERRM);
                        sql_query_result := '[]'::jsonb;
                    END;
                EXCEPTION WHEN OTHERS THEN
                    error_messages := array_append(error_messages, 'SQL execution error: ' || SQLERRM);
                END;
            ELSE
                error_messages := array_append(error_messages, 'SQL confidence too low: ' || sql_confidence::TEXT);
            END IF;
        ELSIF NOT use_sql_index THEN
            -- Skip execution, set empty array
            sql_query_result := '[]'::jsonb;
        ELSE
            error_messages := array_append(error_messages, 'No valid SQL query available');
        END IF;
    END;
    
    sql_end_time := clock_timestamp();
    
    -- Combine results with hybrid scoring
    DECLARE
        hybrid_score_value NUMERIC := 0;
        sql_results_count INTEGER := 0;
        sql_weight NUMERIC;
        vector_weight NUMERIC;
        graph_weight NUMERIC;
    BEGIN
        -- Determine weights based on whether SQL is used
        IF use_sql_index THEN
            -- Standard weights when all search types are enabled
            sql_weight := 0.4;
            vector_weight := 0.4;
            graph_weight := 0.2;
        ELSE
            -- Adjusted weights when SQL is disabled - increase vector weight
            sql_weight := 0.0;
            vector_weight := 0.8;
            graph_weight := 0.2;
        END IF;
        
        -- Calculate hybrid score based on available results
        IF use_sql_index AND sql_query_result IS NOT NULL THEN
            sql_results_count := jsonb_array_length(sql_query_result);
            IF sql_results_count > 0 AND sql_confidence >= min_confidence THEN
                -- Weight by both confidence and number of results
                hybrid_score_value := hybrid_score_value + (sql_confidence * sql_weight);
                
                -- Add a small bonus for each result found (up to 5 max)
                hybrid_score_value := hybrid_score_value + 
                    LEAST(sql_results_count, 5) * 0.02;
            END IF;
        END IF;
        
        IF vector_search_result IS NOT NULL AND jsonb_array_length(vector_search_result) > 0 THEN
            -- Use best vector match score (1 - distance) as component
            hybrid_score_value := hybrid_score_value + 
                (1 - (vector_search_result->0->>'vdistance')::NUMERIC) * vector_weight;
                
            -- Add a small bonus for each result found (up to 5 max)
            hybrid_score_value := hybrid_score_value + 
                LEAST(jsonb_array_length(vector_search_result), 5) * 0.02;
        END IF;
        
        IF graph_result_data IS NOT NULL AND jsonb_array_length(graph_result_data) > 0 THEN
            -- Give score boost based on graph connectivity
            hybrid_score_value := hybrid_score_value + graph_weight;
        END IF;
        
        -- Set variable for return query (scale to 0-1 range)
        hybrid_score := LEAST(hybrid_score_value, 1.0);
    END;
    
    -- Prepare timing information
    timing_data := jsonb_build_object(
        'sql_query_ms', EXTRACT(EPOCH FROM (sql_end_time - sql_start_time)) * 1000,
        'vector_search_ms', EXTRACT(EPOCH FROM (vector_end_time - vector_start_time)) * 1000,
        'graph_traversal_ms', EXTRACT(EPOCH FROM (graph_end_time - graph_start_time)) * 1000,
        'total_ms', EXTRACT(EPOCH FROM (clock_timestamp() - sql_start_time)) * 1000
    );
    
    -- Return all results
    RETURN QUERY 
    SELECT 
        sql_query AS query_text,
        sql_confidence AS confidence,
        sql_query_result AS relational_result,
        vector_search_result AS vector_result,
        graph_result_data AS graph_result,
        hybrid_score AS hybrid_score,
        timing_data AS execution_time_ms,
        array_to_string(error_messages, '; ') AS error_message;
END;
$BODY$;

COMMENT ON FUNCTION p8.query_entity_fast IS 
'Parallel entity query function that optionally executes SQL queries, vector search, and graph traversal 
for faster results and hybrid scoring. By default, SQL indexing is disabled (use_sql_index=FALSE) 
because ILIKE-based SQL queries on rich text fields are inefficient without proper GIN indexes.';


-- Function from: search/resource_search_functions.sql
------------------------------------------------------------
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


-- ====================================================================
-- SECURITY FUNCTIONS
-- ====================================================================

-- Function from: security/create_app_user.sql
------------------------------------------------------------
-- Function to create application user with full data access but not database superuser privileges
-- This ensures the user can access all data but cannot bypass row-level security policies

DROP FUNCTION IF EXISTS p8.create_app_user;
CREATE OR REPLACE FUNCTION p8.create_app_user(username TEXT, password TEXT)
RETURNS TEXT AS $$
DECLARE
    schema_rec RECORD;
    conn_string TEXT;
    role_exists BOOLEAN;
BEGIN
    -- Check if the role exists
    SELECT EXISTS (SELECT FROM pg_roles WHERE rolname = username) INTO role_exists;
    
    -- Create the role if it doesn't exist, otherwise update the password
    IF NOT role_exists THEN
        EXECUTE format('CREATE ROLE %I WITH LOGIN PASSWORD %L', username, password);
    ELSE
        EXECUTE format('ALTER ROLE %I WITH PASSWORD %L', username, password);
    END IF;
    
    -- Ensure the role does not have superuser or BYPASSRLS privileges
    EXECUTE format('
    ALTER ROLE %I NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
    ', username);
    
    -- We'll skip explicit age extension grants for now
    
    -- Grant privileges to each non-system schema
    FOR schema_rec IN (
        SELECT nspname FROM pg_namespace 
        WHERE nspname NOT LIKE 'pg_%' 
        AND nspname != 'information_schema'
    ) LOOP
        -- Grant schema usage and create privileges
        EXECUTE format('GRANT USAGE, CREATE ON SCHEMA %I TO %I;', 
                      schema_rec.nspname, username);
        
        -- Grant all privileges on all tables in the schema
        EXECUTE format('
        GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO %I;
        ', schema_rec.nspname, username);
        
        -- Grant usage on all sequences
        EXECUTE format('
        GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %I TO %I;
        ', schema_rec.nspname, username);
        
        -- Set default privileges for future tables and sequences
        EXECUTE format('
        ALTER DEFAULT PRIVILEGES IN SCHEMA %I
        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I;
        ', schema_rec.nspname, username);
        
        EXECUTE format('
        ALTER DEFAULT PRIVILEGES IN SCHEMA %I
        GRANT USAGE, SELECT ON SEQUENCES TO %I;
        ', schema_rec.nspname, username);
        
        -- Grant execute on functions
        EXECUTE format('
        GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO %I;
        ', schema_rec.nspname, username);
        
        EXECUTE format('
        ALTER DEFAULT PRIVILEGES IN SCHEMA %I
        GRANT EXECUTE ON FUNCTIONS TO %I;
        ', schema_rec.nspname, username);
    END LOOP;
    
    -- Generate connection string based on current connection
    -- This assumes current_database() returns the database name
    conn_string := format('postgresql://%I:%s@%s:%s/%s', 
                         username, 
                         password,
                         (SELECT setting FROM pg_settings WHERE name = 'listen_addresses'),
                         (SELECT setting FROM pg_settings WHERE name = 'port'),
                         current_database());
    
    RETURN conn_string;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Documentation
COMMENT ON FUNCTION p8.create_app_user(TEXT, TEXT) IS 
'Creates a PostgreSQL user with full data access privileges, schema creation rights, but no superuser status.
This ensures row-level security policies will be enforced while allowing table creation.

Arguments:
- username: The username for the new application user
- password: The password for the new user

Returns:
- Connection string for the new user

Example:
SELECT p8.create_app_user(''percolate_app'', ''strong_password'');';


-- Function from: security/rls_policy.sql
------------------------------------------------------------
-- PostgreSQL Row-Level Security Policy Function for Percolate
-- This file contains the core function for attaching RLS policies to tables

DROP FUNCTION IF EXISTS p8.attach_rls_policy;
-- Function to attach row-level security policy to a table with configurable access level
CREATE OR REPLACE FUNCTION p8.attach_rls_policy(
    p_schema_name TEXT, 
    p_table_name TEXT, 
    p_default_access_level INTEGER DEFAULT 5  -- Default to INTERNAL (5)
)
RETURNS VOID AS $$
DECLARE
    full_table_name TEXT;
    policy_name TEXT;
    policy_exists BOOLEAN;
    has_userid_column BOOLEAN;
BEGIN
    -- Construct the full table name
    full_table_name := p_schema_name || '.' || p_table_name;
    policy_name := p_table_name || '_access_policy';
    
    -- Check if the table exists
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables t
        WHERE t.table_schema = p_schema_name 
        AND t.table_name = p_table_name
    ) THEN
        RAISE EXCEPTION 'Table %.% does not exist', p_schema_name, p_table_name;
    END IF;
    
    -- Check if the required columns exist, add them if they don't
    BEGIN
        -- Check for userid column
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns c
            WHERE c.table_schema = p_schema_name 
              AND c.table_name = p_table_name
              AND c.column_name = 'userid'
        ) THEN
            EXECUTE format('ALTER TABLE %I.%I ADD COLUMN userid UUID', p_schema_name, p_table_name);
            RAISE NOTICE 'Added userid column to %.%', p_schema_name, p_table_name;
        END IF;
        
        -- Check for groupid column
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns c
            WHERE c.table_schema = p_schema_name 
              AND c.table_name = p_table_name
              AND c.column_name = 'groupid'
        ) THEN
            EXECUTE format('ALTER TABLE %I.%I ADD COLUMN groupid TEXT', p_schema_name, p_table_name);
            RAISE NOTICE 'Added groupid column to %.%', p_schema_name, p_table_name;
        END IF;
        
        -- Check for required_access_level column
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns c
            WHERE c.table_schema = p_schema_name 
              AND c.table_name = p_table_name
              AND c.column_name = 'required_access_level'
        ) THEN
            EXECUTE format('ALTER TABLE %I.%I ADD COLUMN required_access_level INTEGER DEFAULT %s', 
                           p_schema_name, p_table_name, p_default_access_level);
            RAISE NOTICE 'Added required_access_level column to %.% with default %', 
                         p_schema_name, p_table_name, p_default_access_level;
        ELSE
            -- Check if the current default value matches the specified default
            DECLARE
                current_default TEXT;
            BEGIN
                SELECT column_default INTO current_default
                FROM information_schema.columns 
                WHERE table_schema = p_schema_name 
                  AND table_name = p_table_name
                  AND column_name = 'required_access_level';
                
                -- If the default value doesn't match, update it
                IF current_default IS NULL OR current_default != p_default_access_level::TEXT THEN
                    EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN required_access_level SET DEFAULT %s', 
                                   p_schema_name, p_table_name, p_default_access_level);
                    RAISE NOTICE 'Updated default value of required_access_level to % in %.%', 
                                 p_default_access_level, p_schema_name, p_table_name;
                END IF;
            END;
            
            -- Update existing records to the specified access level if they don't match
            EXECUTE format('UPDATE %I.%I SET required_access_level = %s WHERE required_access_level != %s OR required_access_level IS NULL', 
                          p_schema_name, p_table_name, p_default_access_level, p_default_access_level);
            RAISE NOTICE 'Updated required_access_level to % for existing records in %.%', 
                          p_default_access_level, p_schema_name, p_table_name;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Error adding security columns to %.%: %', p_schema_name, p_table_name, SQLERRM;
    END;
    
    -- Enable row-level security on the table
    EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', p_schema_name, p_table_name);
    
    -- Check if the policy already exists
    SELECT EXISTS (
        SELECT 1 FROM pg_policies p
        WHERE p.schemaname = p_schema_name
          AND p.tablename = p_table_name
          AND p.policyname = policy_name
    ) INTO policy_exists;
    
    -- If the policy exists, drop it before recreating
    IF policy_exists THEN
        BEGIN
            EXECUTE format('DROP POLICY %I ON %I.%I', policy_name, p_schema_name, p_table_name);
            RAISE NOTICE 'Dropped existing policy % on table %', policy_name, full_table_name;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Could not drop policy % on table %: %', policy_name, full_table_name, SQLERRM;
        END;
    END IF;
    
    -- Create the RLS policy with modified conditions
    EXECUTE format('
        CREATE POLICY %I ON %I.%I
        USING (
            -- PRIMARY CONDITION: Role level check
            current_setting(''percolate.role_level'')::INTEGER <= required_access_level
            
            OR
            
            -- SECONDARY CONDITIONS: Elevate user access through ownership or group membership
            (
                -- 1. User owns the record
                (current_setting(''percolate.user_id'')::UUID = userid AND userid IS NOT NULL)
                
                -- 2. User is member of the record''s group (with safer handling)
                OR (
                    groupid IS NOT NULL AND 
                    current_setting(''percolate.user_groups'', ''true'') IS NOT NULL AND
                    current_setting(''percolate.user_groups'', ''true'') != '''' AND
                    current_setting(''percolate.user_groups'', ''true'') ~ ''^,.*,$'' AND
                    position('','' || groupid::TEXT || '','' IN current_setting(''percolate.user_groups'', ''true'')) > 0
                )
            )
        )', 
        policy_name, p_schema_name, p_table_name
    );
    
    -- Force RLS even for table owner
    EXECUTE format('ALTER TABLE %I.%I FORCE ROW LEVEL SECURITY', p_schema_name, p_table_name);
    
    RAISE NOTICE 'Row-level security policy attached to % with default access level %', 
                 full_table_name, p_default_access_level;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


DROP FUNCTION IF EXISTS p8.secure_all_tables;
-- Function to secure all tables in a schema with configurable access levels
CREATE OR REPLACE FUNCTION p8.secure_all_tables(
    p_schema_name TEXT DEFAULT 'p8',
    p_default_access_level INTEGER DEFAULT 5
)
RETURNS VOID AS $$
DECLARE
    r RECORD;
BEGIN
    -- Add security columns to all tables in the schema
    FOR r IN (
        SELECT table_name 
        FROM information_schema.tables 
        WHERE table_schema = p_schema_name 
        AND table_type = 'BASE TABLE'
    ) LOOP
        BEGIN
            -- Apply RLS policy to the table with the specified default access level
            PERFORM p8.attach_rls_policy(p_schema_name, r.table_name, p_default_access_level);
            RAISE NOTICE 'Secured table: %.%', p_schema_name, r.table_name;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Error securing table %.%: %', p_schema_name, r.table_name, SQLERRM;
        END;
    END LOOP;
    
    RAISE NOTICE 'All tables in % schema have been secured with row-level security (default access level: %)', 
                 p_schema_name, p_default_access_level;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Documentation
COMMENT ON FUNCTION p8.attach_rls_policy(TEXT, TEXT, INTEGER) IS 
'Attaches a row-level security policy to a table with configurable access level.
The policy enforces:
1. Role-based access (user''s role level must be sufficient)
   - This is the primary access control mechanism
   - OR
2. User-specific access privileges:
   - User owns the record (userid matches)
   - User is a member of the record''s group
   
With this policy, user access can be elevated through ownership or group membership,
but records without owners (userid IS NULL) are only visible to users with appropriate role level.

Arguments:
- schema_name: The schema containing the table
- table_name: The name of the table to secure
- default_access_level: Default access level for the table (default 5 = INTERNAL)
  (0=GOD, 1=ADMIN, 5=INTERNAL, 10=PARTNER, 100=PUBLIC)

Example:
SELECT p8.attach_rls_policy(''p8'', ''User'', 1);  -- Require ADMIN access by default';

COMMENT ON FUNCTION p8.secure_all_tables(TEXT, INTEGER) IS
'Secures all tables in a schema with row-level security policies.
Adds required security columns if they don''t exist and attaches policies.

Arguments:
- schema_name: The schema to secure (default ''p8'')
- default_access_level: Default access level for tables (default 5 = INTERNAL)
  (0=GOD, 1=ADMIN, 5=INTERNAL, 10=PARTNER, 100=PUBLIC)

Example:
SELECT p8.secure_all_tables();  -- Secure all tables in p8 schema with INTERNAL access
SELECT p8.secure_all_tables(''app'', 10);  -- Secure all tables in app schema with PARTNER access';


-- Function from: security/set_user_context.sql
------------------------------------------------------------
-- Function to set user context for row-level security
DROP FUNCTION IF EXISTS p8.set_user_context;
CREATE OR REPLACE FUNCTION p8.set_user_context(
    p_user_id UUID, 
    p_role_level INTEGER = NULL
)
RETURNS TABLE(user_id UUID, role_level INTEGER, groups TEXT[]) AS $$
DECLARE
    v_role_level INTEGER;
    v_user_record RECORD;
    v_groups TEXT[];
BEGIN
    -- If role_level not provided, try to load it from the User table
    IF p_role_level IS NULL THEN
        -- Get role_level, required_access_level, and groups from the User table
        SELECT u.role_level, u.required_access_level, u.groups
        INTO v_user_record
        FROM p8."User" u
        WHERE u.id = p_user_id;
        
        -- Use role_level if available, otherwise use required_access_level
        -- If neither is found, default to public access (100)
        IF v_user_record.role_level IS NOT NULL THEN
            v_role_level := v_user_record.role_level;
        ELSIF v_user_record.required_access_level IS NOT NULL THEN
            -- Use the required_access_level as a fallback
            -- This makes sense because God users have required_access_level=0
            -- Admin users have required_access_level=1, etc.
            v_role_level := v_user_record.required_access_level;
        ELSE
            -- Default to public access if nothing is found
            v_role_level := 100;
        END IF;
        
        -- Get user groups if available
        v_groups := v_user_record.groups;
    ELSE
        -- Use the explicitly provided role level
        v_role_level := p_role_level;
        
        -- Still need to get groups from User table
        SELECT u.groups
        INTO v_groups
        FROM p8."User" u
        WHERE u.id = p_user_id;
    END IF;
    
    -- Set the session variables
    PERFORM set_config('percolate.user_id', p_user_id::TEXT, false);
    PERFORM set_config('percolate.role_level', v_role_level::TEXT, false);
    
    -- TEMPORARILY COMMENTED OUT TO TEST BUG
    -- Set user groups if available - use proper array format to prevent confusion with SQL parameters
    -- IF v_groups IS NOT NULL AND array_length(v_groups, 1) > 0 THEN
    --     -- Store as JSON array to avoid confusion with SQL array literals
    --     PERFORM set_config('percolate.user_groups_json', array_to_json(v_groups)::TEXT, false);
    --     -- Also keep comma format for backward compatibility with existing policies
    --     PERFORM set_config('percolate.user_groups', ',' || array_to_string(v_groups, ',') || ',', false);
    -- ELSE
    --     -- Set empty values
    --     PERFORM set_config('percolate.user_groups_json', '[]', false);
    --     PERFORM set_config('percolate.user_groups', '', false);
    -- END IF;
    
    -- Set empty user groups to test if this fixes the contamination bug
    PERFORM set_config('percolate.user_groups', '', false);
    
    -- Return the role level as a message for debugging
    RAISE NOTICE 'Set user context: user_id=%, role_level=%, groups=%', 
                 p_user_id, v_role_level, v_groups;
    
    -- Return the user context information
    RETURN QUERY SELECT p_user_id, v_role_level, v_groups;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Documentation
COMMENT ON FUNCTION p8.set_user_context(UUID, INTEGER) IS 
'Sets PostgreSQL session variables for row-level security and returns user context:
- percolate.user_id: UUID of the current user
- percolate.role_level: Access level of the user (0=GOD, 1=ADMIN, 5=INTERNAL, 10=PARTNER, 100=PUBLIC)
- percolate.user_groups: Comma-separated list of groups the user belongs to

Arguments:
- p_user_id: The user ID to set in the session
- p_role_level: Optional role level to override the user''s default level

Returns:
- user_id: The user ID that was set
- role_level: The role level that was set
- groups: Array of groups the user belongs to

Examples:
SELECT * FROM p8.set_user_context(''4114f279-f345-511b-b375-1953089e078f'');
SELECT * FROM p8.set_user_context(''4114f279-f345-511b-b375-1953089e078f'', 1);
';


-- ====================================================================
-- TOOLS FUNCTIONS
-- ====================================================================

-- Function from: tools/activate_functions_by_name.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.activate_functions_by_name;
CREATE OR REPLACE FUNCTION p8.activate_functions_by_name(
    names TEXT[], 
    response_id UUID
) RETURNS TEXT[] AS $$
DECLARE
    updated_functions TEXT[];
BEGIN
    /*
    Merges the list of activated functions in the dialogue and returns the updated function stack.

    Example usage:
	SELECT * FROM p8.activate_functions_by_name(ARRAY[ 'Test', 'Other'], '42e80e20-6b9e-02f4-8af7-76d4f1ef049f'::UUID);
    SELECT * FROM p8.activate_functions_by_name(ARRAY[ 'New'], '42e80e20-6b9e-02f4-8af7-76d4f1ef049f'::UUID);
    */

    INSERT INTO p8."AIResponse" (id, model_name, content, role, function_stack)
    VALUES (
        response_id, 
        'percolate', 
        '', 
        '', 
        names
    )
    ON CONFLICT (id) DO UPDATE 
    SET 
        model_name = EXCLUDED.model_name,
        content = EXCLUDED.content,
        role = EXCLUDED.role,
        function_stack = ARRAY(SELECT DISTINCT unnest(p8."AIResponse".function_stack || EXCLUDED.function_stack))
    RETURNING function_stack INTO updated_functions;

    RETURN updated_functions;
END;
$$ LANGUAGE plpgsql;


-- Function from: tools/eval_function_call.sql
------------------------------------------------------------
/*
TODO: need to resolve the percolate or other API token 
*/

CREATE OR REPLACE FUNCTION p8.eval_function_call(
	function_call jsonb,
    response_id UUID DEFAULT NULL )
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    -- Variables to hold extracted data
    function_name TEXT;
    args JSONB;
    metadata RECORD;
    uri_root TEXT;
    call_uri TEXT;
    params JSONB;
    kwarg TEXT;
    matches TEXT[];
    final_args JSONB;
    api_response JSONB;
    api_token TEXT;
	query_arg TEXT[];
    native_result JSONB;
	--
	v_state   TEXT;
    v_msg     TEXT;
    v_detail  TEXT;
    v_hint    TEXT;
    v_context TEXT;
BEGIN

	/*
	--if you added the pet store example functions
	 select * from p8.eval_function_call('{"function": {"name": "get_pet_findByStatus", "arguments": "{\"status\":[\"sold\"]}"}}'::JSONB)
	 
	*/

    -- This is a variant of fn_construct_api_call but higher level - 
	-- we can refactor this into multilple modules but for now we will check for native calls inline
    IF function_call IS NULL OR NOT function_call ? 'function' THEN
        RAISE EXCEPTION 'Invalid input: function_call must contain a "function" key';
    END IF;

    function_name := function_call->'function'->>'name';
    IF function_name IS NULL THEN
        RAISE EXCEPTION 'Invalid input: "function" must have a "name"';
    END IF;

    args := (function_call->'function'->>'arguments')::JSON;
    IF args IS NULL THEN
        args := '{}';
    END IF;

	--AGE extension is preloaded at session level
	SET search_path = ag_catalog, "$user", public;
	
    -- Lookup endpoint metadata
    SELECT endpoint, proxy_uri, verb
    INTO metadata
    FROM p8."Function"
    WHERE "name" = function_name;

	IF metadata.proxy_uri = 'native' THEN
		RAISE notice 'native query with args % % and response id %',  function_name, args,response_id;
        SELECT * FROM p8.eval_native_function(function_name,args::JSONB,response_id)
        INTO native_result;
        RETURN native_result;
	ELSE
	    -- If no matching endpoint is found, raise an exception
	    IF NOT FOUND THEN
	        RAISE EXCEPTION 'No metadata found for function %', function_name;
	    END IF;
	
	    -- Construct the URI root and call URI
	    uri_root :=  metadata.proxy_uri;
	    call_uri := uri_root || metadata.endpoint;
	    final_args := args;
	
	    -- Ensure API token is available
	    
		api_token := (SELECT token FROM p8."ApiProxy" a where a.proxy_uri=metadata.proxy_uri LIMIT 1); 
		
	
	    -- Make the HTTP call
		RAISE NOTICE 'Invoke % with %', call_uri, final_args;
		BEGIN
		    IF UPPER(metadata.verb) = 'GET' THEN
		        -- For GET requests, append query parameters to the URL
		        call_uri := call_uri || '?' || p8.encode_url_query(final_args);
				RAISE NOTICE 'encoded %', call_uri;
		        SELECT content
		        INTO api_response
		        FROM http(
		            (
		                'GET', 
		                call_uri, 
		                ARRAY[http_header('Authorization', 'Bearer ' || api_token)], -- Add Bearer token
		                'application/json', 
		                NULL -- No body for GET requests
		            )::http_request
		        );
		    ELSE
		        -- For POST requests, include the body
		        SELECT content
		        INTO api_response
		        FROM http(
		            (
		                UPPER(metadata.verb), 
		                call_uri, 
		                ARRAY[http_header('Authorization', 'Bearer ' || api_token)], -- Add Bearer token
		                'application/json', 
		                final_args -- Pass the body for POST or other verbs
		            )::http_request
		        );
		    END IF;
		EXCEPTION WHEN OTHERS THEN
		    RAISE EXCEPTION 'HTTP request failed: %', SQLERRM;
		END;

		RAISE NOTICE 'tool response api %', api_response;
	
	    -- Return the API response
	    RETURN api_response;
	END IF;

EXCEPTION WHEN OTHERS THEN 
    GET STACKED DIAGNOSTICS
        v_state   = RETURNED_SQLSTATE,
        v_msg     = MESSAGE_TEXT,
        v_detail  = PG_EXCEPTION_DETAIL,
        v_hint    = PG_EXCEPTION_HINT,
        v_context = PG_EXCEPTION_CONTEXT;

    RAISE EXCEPTION E'Got exception:
        state  : %
        message: %
        detail : %
        hint   : %
        context: %', 
        v_state, v_msg, v_detail, v_hint, v_context;
END;
$BODY$;


-- Function from: tools/eval_native_function.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.eval_native_function;
CREATE OR REPLACE FUNCTION p8.eval_native_function(
	function_name text,
	args jsonb,
    response_id UUID DEFAULT NULL
    )
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
	declare KEYS text[];
    result JSONB;
BEGIN
    /*
    working on a way to eval native functions with kwargs and hard coding for now

    this would be used for example if we did this
    select * from percolate_with_agent('get the description of the entity called p8.PercolateAgent', 'p8.PercolateAgent' ) 

    examples are

    SELECT p8.eval_native_function(
    'get_entities', 
    '{"keys": ["p8.Agent", "p8.PercolateAgent"]}'::JSONB
    );

    SELECT p8.eval_native_function(
    'activate_functions_by_name', 
    '{"estimated_length": 20000}'::JSONB
    );

    SELECT p8.eval_native_function(
    'search', 
    '{"question": "i need an agent about agents", "entity_table_name":"p8.Agent"}'::JSONB
    );  
	--basically does select * from p8.query_entity('i need an agent about agents', 'p8.Agent')

     SELECT p8.eval_native_function(
        'activate_functions_by_name', 
        '{"function_names": ["p8.Agent", "p8.PercolateAgent"]}'::JSONB,
        '42e80e20-6b9e-02f4-8af7-76d4f1ef049f'::UUID
        );  
        
  
    */
    CASE function_name
        WHEN 'activate_functions_by_name' THEN
            keys := ARRAY(SELECT jsonb_array_elements_text(args->'function_names')::TEXT);
           
			-- Call activate_functions_by_name and convert the TEXT[] into a JSON array
            SELECT jsonb_agg(value) 
            INTO result
            FROM unnest(p8.activate_functions_by_name(keys, response_id)) AS value;

        -- NB the args here need to match how we define the native function interface in python or wherever
        -- If function_name is 'get_entities', call p8.get_entities with the given argument
        WHEN 'get_entities' THEN
            -- Extract the keys array from JSONB and cast it to a PostgreSQL TEXT array
            keys := ARRAY(SELECT jsonb_array_elements_text(args->'keys')::TEXT);
        
            SELECT p8.get_entities(keys) INTO result;

        -- If function_name is 'search', call p8.query_entity with the given arguments
        WHEN 'search' THEN
            SELECT jsonb_agg(row) 
			INTO result
			FROM (
			    SELECT p8.query_entity(args->>'question', args->>'entity_table_name')
			) AS row;

        -- If function_name is 'help', call p8.plan with the given argument
        WHEN 'help' THEN
            SELECT jsonb_agg(row) 
			INTO result
			FROM (
			     SELECT public.plan(COALESCE(args->>'questions',args->>'question'))
			) AS row;

        -- If function_name is 'activate_functions_by_name', return a message and estimated_length
        WHEN 'announce_generate_large_output' THEN
            RETURN jsonb_build_object(
                'message', 'acknowledged',
                'estimated_length', args->>'estimated_length'
            );

        -- Default case for an unknown function_name
        ELSE
            RAISE EXCEPTION 'Function name "%" is unknown for args: %', function_name, args;
    END CASE;

    -- Return the result of the function called
    RETURN result;
END;
$BODY$;


-- Function from: tools/get_session_functions.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.get_session_functions;
CREATE OR REPLACE FUNCTION p8.get_session_functions(
	session_id_in uuid,
	functions_names text[],
	selected_scheme text DEFAULT 'openai'::text)
    RETURNS jsonb
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    existing_functions TEXT[];
    merged_functions TEXT[];
    result JSONB;
BEGIN
    /*
    Retrieves the function stack from p8.AIResponse, merges it with additional function names,
    and returns the corresponding tool information.
    
    Example Usage:
    
    SELECT p8.get_session_functions(
        '42e80e20-6b9e-02f4-8af7-76d4f1ef049f'::UUID, 
        ARRAY['get_entities'], 
        'openai'
    );
    */

    -- Fetch the existing function stack from the last session message but we need to think about this
    SELECT COALESCE(function_stack, ARRAY[]::TEXT[])
    INTO existing_functions
    FROM p8."AIResponse"
    WHERE session_id = session_id_in
	order by created_at DESC
	LIMIT 1 ;

    -- Merge existing functions with new ones, removing duplicates
    merged_functions := ARRAY(
        SELECT DISTINCT unnest(existing_functions || functions_names)
    );

	RAISE NOTICE 'Session functions for response % are % after merging existing % ', session_id_in, merged_functions, existing_functions;
	
    -- Get tool information for the merged function names
    SELECT p8.get_tools_by_name(merged_functions, selected_scheme) INTO result;

    RETURN result;
END;
$BODY$;


-- Function from: tools/get_tools_by_description.sql
------------------------------------------------------------
CREATE OR REPLACE FUNCTION p8.get_tools_by_description(
    description_text text,
    limit_results integer DEFAULT 5)
RETURNS TABLE(name character varying, spec json, distance double precision) 
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
ROWS 1000
AS $BODY$
DECLARE
    embedded_question VECTOR; -- Variable to store the computed embedding
BEGIN
    -- Compute the embedding once and store it in the variable
    SELECT embedding
    INTO embedded_question
    FROM p8.get_embedding_for_text(description_text);

    -- Check if embedding calculation returned NULL
    IF embedded_question IS NULL THEN
        RAISE EXCEPTION 'Embedding calculation failed for input: %', description_text;
    END IF;

    -- Perform the query only if embedding is valid
    RETURN QUERY
    WITH records AS (
        SELECT 
            b.name,
            MIN(a.embedding_vector <-> embedded_question) AS vdistance
        FROM p8_embeddings."p8_Function_embeddings" a
        JOIN p8."Function" b ON b.id = a.source_record_id
        WHERE a.embedding_vector <-> embedded_question <= 0.75
        GROUP BY b.name
    )
    SELECT 
        CAST(r.name AS character varying) AS name,
        f.function_spec,
        r.vdistance
    FROM records r
    JOIN p8."Function" f ON r.name = f.name
    ORDER BY r.vdistance ASC
    LIMIT limit_results;

    -- Optional: Return an empty result set if no matches are found
    RETURN;
END;
$BODY$;

ALTER FUNCTION p8.get_tools_by_description(text, integer)
OWNER TO postgres;


-- Function from: tools/get_tools_by_name.sql
------------------------------------------------------------
CREATE OR REPLACE FUNCTION p8.get_tools_by_name(
    names text[],
    scheme text DEFAULT 'openai'::text
)
RETURNS jsonb
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    record_count INT;
BEGIN
    -- Check the count of records matching the names
    SELECT COUNT(*) INTO record_count
    FROM p8."Function"
    WHERE name = ANY(names);

    -- If no records match, return an empty JSON array
    IF record_count = 0 THEN
        RETURN '[]'::JSONB;
    END IF;

    -- Handle the scheme and return the appropriate JSON structure
    IF scheme = 'google' THEN
        RETURN (
            SELECT JSON_BUILD_ARRAY(
                JSON_BUILD_OBJECT('function_declarations', JSON_AGG(function_spec::JSON))
            )
            FROM p8."Function"
            WHERE name = ANY(names)
        );
    ELSIF scheme = 'anthropic' THEN
        RETURN (
            SELECT JSON_AGG(
                JSON_BUILD_OBJECT(
                    'name', name,
                    'description', function_spec->>'description',
                    'input_schema', (function_spec->>'parameters')::JSON
                )
            )
            FROM p8."Function"
            WHERE name = ANY(names)
        );
    ELSE
        -- Default to openai
        RETURN (
            SELECT JSON_AGG(
                JSON_BUILD_OBJECT(
                    'type', 'function',
                    'function', function_spec::JSON
                )
            )
            FROM p8."Function"
            WHERE name = ANY(names)
        );
    END IF;
END;
$BODY$;


-- ====================================================================
-- USERS FUNCTIONS
-- ====================================================================

-- Function from: users/get_user_concept_links.sql
------------------------------------------------------------
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


-- Function from: users/update_user_model.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.update_user_model;
CREATE OR REPLACE FUNCTION p8.update_user_model(
  user_uuid UUID,
  last_ai_response_in TEXT
)
RETURNS void AS $$
DECLARE
  latest_thread_id TEXT;
  latest_thread_timestamp TIMESTAMP;
  questions TEXT[];
BEGIN
   /*
 a routine to update the user model including kick of async complex tasks
 thread ids can be from any system but we prefer uuids. 
 For this reason we do a case insensitive string match on the ids
 
 select * from p8.update_user_model('10e0a97d-a064-553a-9043-3c1f0a6e6725'::uuid, 'Hello, how can I help?')
 select * from p8."User" where id = '10e0a97d-a064-553a-9043-3c1f0a6e6725'

  SELECT thread_id
  INTO latest_thread_id
  FROM p8."Session"
  WHERE userid = user_uuid
  ORDER BY created_at DESC
  LIMIT 1;

  SELECT ARRAY_AGG(query ORDER BY created_at)
      FROM p8."Session"
      WHERE lower(thread_id) = lower('325aa22e-f6e0-47ba-aa0d-eaafb5e99466')
	  
 */
  SELECT thread_id, updated_at
  INTO latest_thread_id, latest_thread_timestamp
  FROM p8."Session"
  WHERE userid = user_uuid
  ORDER BY created_at DESC
  LIMIT 1;

  IF latest_thread_id IS NOT NULL THEN
    -- Get list of queries in the thread
    SELECT ARRAY_AGG(query ORDER BY created_at)
    INTO questions
    FROM p8."Session"
    WHERE lower(thread_id) = lower(latest_thread_id::TEXT);

    -- Overwrite recent_threads with a new array of one object
    UPDATE p8."User"
    SET recent_threads = jsonb_build_array(jsonb_build_object(
          'thread_timestamp', latest_thread_timestamp,
          'thread_id', latest_thread_id,
          'questions', questions
        )),
        last_ai_response = last_ai_response_in
    WHERE id = user_uuid;
  END IF;
END;
$$ LANGUAGE plpgsql;


-- ====================================================================
-- UTILS FUNCTIONS
-- ====================================================================

-- Function from: utils/create_and_update_session.sql
------------------------------------------------------------
CREATE OR REPLACE FUNCTION p8.update_session(
    id UUID,
    user_id UUID,
    query TEXT
)
RETURNS VOID AS $$
BEGIN
    INSERT INTO p8."Session" (id, userid, query)
    VALUES (id, userid, query)
    ON CONFLICT (id) 
    DO UPDATE SET query = EXCLUDED.query;
END;
$$ LANGUAGE plpgsql;


 
CREATE OR REPLACE FUNCTION p8.create_session(
    user_id UUID,
    query TEXT,
    agent TEXT DEFAULT NULL,
	parent_session_id UUID DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    session_id UUID;
BEGIN
    -- Generate session ID from user_id and current timestamp
    session_id := p8.json_to_uuid(
        json_build_object('timestamp', current_timestamp::text, 'user_id', user_id)::JSONB
    );

    -- Upsert into p8.Session
    INSERT INTO p8."Session" (id, userid, query, parent_session_id, agent)
    VALUES (session_id, user_id, query, parent_session_id, agent)
    ON CONFLICT (id) DO UPDATE
    SET userid = EXCLUDED.userid,
        query = EXCLUDED.query,
        parent_session_id = EXCLUDED.parent_session_id,
        agent = EXCLUDED.agent;

    RETURN session_id;
END;
$$ LANGUAGE plpgsql;


-- Function from: utils/encode_url_query.sql
------------------------------------------------------------
-- FUNCTION: p8.encode_url_query(jsonb)

-- DROP FUNCTION IF EXISTS p8.encode_url_query(jsonb);

CREATE OR REPLACE FUNCTION p8.encode_url_query(
	json_input jsonb)
    RETURNS text
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    key TEXT;
    value JSONB;
    query_parts TEXT[] := ARRAY[]::TEXT[];
    formatted_value TEXT;
BEGIN
/*
for example  select p8.encode_url_query('{"status": ["sold", "available"]}') -> status=sold,available

select p8.encode_url_query('{"body_code": "KT-2011", "body_version": 1}')
*/
    -- Iterate through each key-value pair in the JSONB object
    FOR key, value IN SELECT * FROM jsonb_each(json_input)
    LOOP
        -- Check if the value is an array
        IF jsonb_typeof(value) = 'array' THEN
            -- Convert the array to a comma-separated string
            formatted_value := array_to_string(ARRAY(
                SELECT jsonb_array_elements_text(value)
            ), ',');
        ELSE
            -- Convert other types to text
            formatted_value := trim(both '"' from value::TEXT);
        END IF;

        -- Append the key-value pair to the query parts
        query_parts := query_parts || (key || '=' || formatted_value);
    END LOOP;

    -- Combine the query parts into a single string separated by '&'
    RETURN array_to_string(query_parts, '&');
END;
$BODY$;

ALTER FUNCTION p8.encode_url_query(jsonb)
    OWNER TO postgres;


-- Function from: utils/get_node_property_names.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS get_node_property_names;
CREATE OR REPLACE FUNCTION p8.get_node_property_names(path_nodes json)
RETURNS text[] AS $$
DECLARE
    result text[];
BEGIN
	/*
	
	SELECT p8.get_node_property_names(
    '[{"id": 3659174697238668, "label": "public__Chapter", "properties": {"name": "page47_moby"}}, 
      {"id": 4222124650660157, "label": "Category", "properties": {"name": "Chance"}}, 
      {"id": 4222124650660039, "label": "Category", "properties": {"name": "Philosophy"}}, 
      {"id": 3659174697238783, "label": "public__Chapter", "properties": {"name": "page114_moby"}}]'
	);
	*/
    -- Extract the 'name' properties from the JSON array and store them in the result array
    SELECT array_agg((node->'properties'->>'name')::text)
    INTO result
    FROM json_array_elements(path_nodes) AS node;

    -- Return the result array of names
    RETURN result;
END;
$$ LANGUAGE plpgsql;


-- Function from: utils/ping_api.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.ping_api();

CREATE OR REPLACE FUNCTION p8.ping_api()
RETURNS INTEGER AS
$$
DECLARE
    api_token_in TEXT;
    proxy_uri_in TEXT;
    http_result RECORD;
BEGIN
    -- Fetch API details from the p8."ApiProxy" table
    SELECT token, proxy_uri 
    INTO api_token_in, proxy_uri_in
    FROM p8."ApiProxy"
    WHERE name = 'percolate'
    LIMIT 1;

    -- If no API details are found, exit early
    IF api_token_in IS NULL OR proxy_uri_in IS NULL THEN
        RAISE NOTICE 'API details not found, skipping ping';
        RETURN NULL;
    END IF;

    BEGIN
        -- Make the GET request to /auth/ping
        SELECT *
        INTO http_result
        FROM public.http(
            ( 'GET', 
              proxy_uri_in || '/auth/ping',
              ARRAY[http_header('Authorization', 'Bearer ' || api_token_in)],
              NULL,
              NULL
            )::http_request
        );
    EXCEPTION 
        WHEN OTHERS THEN
            RAISE NOTICE 'Error executing ping request: %', SQLERRM;
            RETURN NULL;
    END;

    -- Log and return the status code
    RAISE NOTICE 'Pinged %/auth/ping - Status: %, Response: %', proxy_uri_in, http_result.status, http_result.content;
    RETURN http_result.status;
END;
$$ LANGUAGE plpgsql;


-- Function from: utils/ping_service.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.ping_service(text);

CREATE OR REPLACE FUNCTION p8.ping_service(service_name text DEFAULT 'percolate-api')
RETURNS jsonb AS
$$
DECLARE
    service_url TEXT;
    http_result RECORD;
    result jsonb;
    start_time timestamp;
    end_time timestamp;
    response_time_ms numeric;
BEGIN
    start_time := clock_timestamp();
    
    -- Set service URL based on service name
    CASE service_name
        WHEN 'percolate-api' THEN
            service_url := 'http://percolate-api:5008/health';
        WHEN 'percolate-api-external' THEN
            service_url := 'http://localhost:5008/health';
        WHEN 'ollama' THEN
            service_url := 'http://ollama-service:11434/';
        WHEN 'minio' THEN
            service_url := 'http://minio:9000/minio/health/live';
        ELSE
            -- Custom URL provided
            service_url := service_name;
    END CASE;

    BEGIN
        -- Make the GET request with a 5-second timeout
        SELECT *
        INTO http_result
        FROM public.http(
            ( 'GET', 
              service_url,
              ARRAY[]::http_header[],
              NULL,
              '5000'::text -- 5 second timeout
            )::http_request
        );
        
        end_time := clock_timestamp();
        response_time_ms := EXTRACT(epoch FROM (end_time - start_time)) * 1000;
        
        result := jsonb_build_object(
            'service', service_name,
            'url', service_url,
            'status', 'up',
            'http_status', http_result.status,
            'response_time_ms', response_time_ms,
            'response_body', http_result.content,
            'timestamp', start_time
        );
        
        RAISE NOTICE 'Service % is UP - Status: % (%.2f ms)', service_name, http_result.status, response_time_ms;
        
    EXCEPTION 
        WHEN OTHERS THEN
            end_time := clock_timestamp();
            response_time_ms := EXTRACT(epoch FROM (end_time - start_time)) * 1000;
            
            result := jsonb_build_object(
                'service', service_name,
                'url', service_url,
                'status', 'down',
                'error', SQLERRM,
                'response_time_ms', response_time_ms,
                'timestamp', start_time
            );
            
            RAISE NOTICE 'Service % is DOWN - Error: % (%.2f ms)', service_name, SQLERRM, response_time_ms;
    END;

    RETURN result;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION p8.ping_service(text) IS 'Ping a service to check if it is accessible. Returns JSON with status, response time, and details. Use percolate-api, ollama, minio, or provide custom URL.';

-- Create a convenience function to ping all core services
DROP FUNCTION IF EXISTS p8.ping_all_services();

CREATE OR REPLACE FUNCTION p8.ping_all_services()
RETURNS jsonb AS
$$
DECLARE
    results jsonb := '[]'::jsonb;
    service_result jsonb;
BEGIN
    -- Ping each core service
    FOR service_result IN 
        SELECT p8.ping_service(service) as result
        FROM unnest(ARRAY['percolate-api', 'ollama', 'minio']) as service
    LOOP
        results := results || service_result.result;
    END LOOP;
    
    RETURN jsonb_build_object(
        'timestamp', clock_timestamp(),
        'services', results,
        'summary', jsonb_build_object(
            'total', jsonb_array_length(results),
            'up', (SELECT count(*) FROM jsonb_array_elements(results) WHERE value->>'status' = 'up'),
            'down', (SELECT count(*) FROM jsonb_array_elements(results) WHERE value->>'status' = 'down')
        )
    );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION p8.ping_all_services() IS 'Ping all core Percolate services (API, Ollama, MinIO) and return status summary.';


-- Function from: utils/ping_service_auth.sql
------------------------------------------------------------
DROP FUNCTION IF EXISTS p8.ping_service(text, boolean);

CREATE OR REPLACE FUNCTION p8.ping_service(
    service_name text DEFAULT 'percolate-api',
    test_auth boolean DEFAULT FALSE
)
RETURNS jsonb AS
$$
DECLARE
    service_url TEXT;
    http_result RECORD;
    result jsonb;
    start_time timestamp;
    end_time timestamp;
    response_time_ms numeric;
    auth_headers http_header[];
    api_token TEXT;
BEGIN
    start_time := clock_timestamp();
    
    -- Set service URL based on service name and auth requirement
    CASE service_name
        WHEN 'percolate-api' THEN
            IF test_auth THEN
                service_url := 'http://percolate-api:5008/admin/index/';  -- Protected endpoint
            ELSE
                service_url := 'http://percolate-api:5008/health';       -- Health endpoint
            END IF;
        WHEN 'percolate-api-external' THEN
            IF test_auth THEN
                service_url := 'http://localhost:5008/admin/index/';
            ELSE
                service_url := 'http://localhost:5008/health';
            END IF;
        WHEN 'ollama' THEN
            service_url := 'http://ollama-service:11434/';
            test_auth := FALSE; -- Ollama doesn't need auth
        WHEN 'minio' THEN
            service_url := 'http://minio:9000/minio/health/live';
            test_auth := FALSE; -- MinIO health doesn't need auth
        ELSE
            -- Custom URL provided
            service_url := service_name;
    END CASE;

    -- If testing auth, get the API token from database
    IF test_auth THEN
        SELECT token INTO api_token
        FROM p8."ApiProxy"
        WHERE name = 'percolate'
        LIMIT 1;
        
        IF api_token IS NULL THEN
            RETURN jsonb_build_object(
                'service', service_name,
                'url', service_url,
                'status', 'error',
                'error', 'No API token found in ApiProxy table',
                'test_auth', test_auth,
                'timestamp', start_time
            );
        END IF;
        
        -- Set authorization header
        auth_headers := ARRAY[
            http_header('Authorization', 'Bearer ' || api_token),
            http_header('Content-Type', 'application/json')
        ];
    ELSE
        auth_headers := ARRAY[]::http_header[];
    END IF;

    BEGIN
        -- Make the request with appropriate headers
        IF test_auth AND service_name LIKE '%percolate-api%' THEN
            -- POST request with JSON body for auth test
            SELECT *
            INTO http_result
            FROM public.http(
                ROW(
                    'POST',
                    service_url,
                    auth_headers,
                    'application/json',
                    '{"model_name": "test", "entity_full_name": "test.ping"}'
                )::http_request
            );
        ELSE
            -- GET request for health check
            SELECT *
            INTO http_result
            FROM public.http(
                ROW(
                    'GET',
                    service_url,
                    auth_headers,
                    NULL,
                    NULL
                )::http_request
            );
        END IF;
        
        end_time := clock_timestamp();
        response_time_ms := EXTRACT(epoch FROM (end_time - start_time)) * 1000;
        
        -- Check if auth test succeeded (200) or failed (401/403)
        IF test_auth THEN
            IF http_result.status = 200 THEN
                result := jsonb_build_object(
                    'service', service_name,
                    'url', service_url,
                    'status', 'up',
                    'auth_status', 'authorized',
                    'http_status', http_result.status,
                    'response_time_ms', response_time_ms,
                    'test_auth', test_auth,
                    'timestamp', start_time
                );
                RAISE NOTICE 'Service % auth test PASSED - Token accepted (%.2f ms)', service_name, response_time_ms;
            ELSIF http_result.status IN (401, 403) THEN
                result := jsonb_build_object(
                    'service', service_name,
                    'url', service_url,
                    'status', 'up',  -- Service is up but auth failed
                    'auth_status', 'unauthorized',
                    'http_status', http_result.status,
                    'response_time_ms', response_time_ms,
                    'test_auth', test_auth,
                    'timestamp', start_time
                );
                RAISE NOTICE 'Service % auth test FAILED - Token rejected (%.2f ms)', service_name, response_time_ms;
            ELSE
                result := jsonb_build_object(
                    'service', service_name,
                    'url', service_url,
                    'status', 'up',
                    'auth_status', 'unknown',
                    'http_status', http_result.status,
                    'response_time_ms', response_time_ms,
                    'response_body', http_result.content,
                    'test_auth', test_auth,
                    'timestamp', start_time
                );
            END IF;
        ELSE
            -- Regular health check
            result := jsonb_build_object(
                'service', service_name,
                'url', service_url,
                'status', 'up',
                'http_status', http_result.status,
                'response_time_ms', response_time_ms,
                'response_body', http_result.content,
                'test_auth', test_auth,
                'timestamp', start_time
            );
        END IF;
        
        RAISE NOTICE 'Service % is UP - Status: % (%.2f ms)', service_name, http_result.status, response_time_ms;
        
    EXCEPTION 
        WHEN OTHERS THEN
            end_time := clock_timestamp();
            response_time_ms := EXTRACT(epoch FROM (end_time - start_time)) * 1000;
            
            result := jsonb_build_object(
                'service', service_name,
                'url', service_url,
                'status', 'down',
                'error', SQLERRM,
                'response_time_ms', response_time_ms,
                'test_auth', test_auth,
                'timestamp', start_time
            );
            
            RAISE NOTICE 'Service % is DOWN - Error: % (%.2f ms)', service_name, SQLERRM, response_time_ms;
    END;

    RETURN result;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION p8.ping_service(text, boolean) IS 'Ping a service to check if it is accessible. Second parameter (test_auth) when TRUE tests authentication with database token. Returns JSON with status, auth results, response time, and details.';

-- Backward compatibility: keep the old signature
DROP FUNCTION IF EXISTS p8.ping_service(text);

CREATE OR REPLACE FUNCTION p8.ping_service(service_name text DEFAULT 'percolate-api')
RETURNS jsonb AS
$$
BEGIN
    RETURN p8.ping_service(service_name, FALSE);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION p8.ping_service(text) IS 'Ping a service to check if it is accessible (without auth test). Use ping_service(service, TRUE) to test authentication.';

