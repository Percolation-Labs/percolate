-- FUNCTION: p8.nl2sql(text, character varying, character varying, character varying, double precision)

-- DROP FUNCTION IF EXISTS p8.nl2sql(text, character varying, character varying, character varying, double precision);

CREATE OR REPLACE FUNCTION p8.nl2sql(
	question text,
	agent_name character varying,
	model_in character varying DEFAULT 'gpt-4o-2024-08-06'::character varying,
	api_token character varying DEFAULT NULL::character varying,
	temperature double precision DEFAULT 0.01)
    RETURNS TABLE(response jsonb, query text, confidence numeric) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    table_schema_prompt TEXT;
    api_response JSON;
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

    -- API call to OpenAI with the necessary headers and payload
    WITH T AS(
        SELECT 'system' AS "role", 
		   'you will generate a PostgreSQL query for the provided table metadata that can '
		|| ' query that table (but replace table with YOUR_TABLE) to answer the users question and respond in json format'
		|| 'responding with the query and confidence - escape characters so that the json can be loaded in postgres.' 
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
        ((api_response->'choices'->0->'message'->>'content')::JSONB->>'confidence')::NUMERIC AS confidence;  -- Extract confidence

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'API call failed: %', SQLERRM;
END;
$BODY$;

ALTER FUNCTION p8.nl2sql(text, character varying, character varying, character varying, double precision)
    OWNER TO postgres;
