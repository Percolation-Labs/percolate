
WITH generated_id AS (
    SELECT p8.json_to_uuid('{}'::JSONB) AS session_id
)
INSERT INTO p8."Session" (id, query, agent)
SELECT session_id, 'Percolate Initialization Run at updated_at date', 'percolate'
FROM generated_id
ON CONFLICT (id)  
DO UPDATE SET
    query = EXCLUDED.query;  


WITH db_key AS (
    SELECT p8.json_to_uuid(json_build_object('ts', CURRENT_TIMESTAMP::TEXT)::JSONB) AS api_key
),
settings AS(
        SELECT api_key, p8.json_to_uuid('{"key": "P8_API_KEY"}'::JSONB) AS setting_id from db_key
)
INSERT INTO p8."Settings" (id, key, value)
SELECT setting_id, 'P8_API_KEY', api_key
FROM settings 
ON CONFLICT (id)  
DO UPDATE SET
    value = EXCLUDED.value;  

--register the api with the key in session - we use the api for admin tasks on the DB

INSERT INTO p8."ApiProxy" (id, name, proxy_uri, token)
SELECT 
    p8.json_to_uuid(jsonb_build_object('proxy_uri', 'http://percolate-api:5008')::JSONB) AS session_id,
    'percolate',
    'http://percolate-api:5008', --K8s and Docker will likely both use these sorts of hosts TBD
    value AS token
FROM p8."Settings"
WHERE key = 'P8_API_KEY'
ON CONFLICT (id)  
DO UPDATE SET
    token = EXCLUDED.token;
----------

-- Configure PostgreSQL to preload AGE extension for proper functionality
-- This matches the CloudNative configuration: session_preload_libraries: "age"
ALTER SYSTEM SET session_preload_libraries = 'age';
SELECT pg_reload_conf();

-- we dont want to rely too heavily on this but certainly for testing we should set this
-- this allows language models to be called and are given a time to generate
-- if generation is too long we should be switching to the client streaming
INSERT INTO p8."Settings" (id, key, value)
SELECT  p8.json_to_uuid('{"key": "CURLOPT_TIMEOUT"}'::JSONB), 'CURLOPT_TIMEOUT', '5000'
ON CONFLICT (id)  
DO UPDATE SET
    value = EXCLUDED.value;  

---
--- the general percolate agent preamble - inserted on top of all agents unless disabled

INSERT INTO p8."Settings" (id, key, value)
SELECT  p8.json_to_uuid('{"key": "P8_SYS_PROMPT"}'::JSONB) , 'P8_SYS_PROMPT',
'You are a Percolate AI Agent for data rich use cases. You can use tools and query day.' ||
'You should generally use the standard functions you have to lookup entities or search data related to you' ||
'sometimes the question will not be related to the data you have and you can ask for help to get other functions' ||
'you should use judgment to know if you are likely to have the answer i.e. if some one asks for Functions and you are not a Functions agent you should not search with yourself as the entity' ||
'but you also should not guess the entity name to use unless you have identified available entities' ||
'if you are generating large content output, you can sometimes announce it first using a function' ||
'in some cases you may be able to use real world knowledge to answer simple question as a ping-test but generally you should try to find the answers in the data'
ON CONFLICT (id)  
DO UPDATE SET
    value = EXCLUDED.value,  
	key =  EXCLUDED.key; 


CREATE OR REPLACE FUNCTION grant_full_access_all_schemas(p_user text)
RETURNS void AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN 
      SELECT nspname 
      FROM pg_namespace
      WHERE nspname NOT LIKE 'pg_%'
        AND nspname <> 'information_schema'
    LOOP
        RAISE NOTICE 'Granting privileges on schema: %', r.nspname;

        -- Grant usage on the schema
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', r.nspname, p_user);

        -- Grant all privileges on all existing tables in the schema
        EXECUTE format('GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA %I TO %I', r.nspname, p_user);

        -- Grant all privileges on all existing sequences in the schema
        EXECUTE format('GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA %I TO %I', r.nspname, p_user);

        -- Grant execute privileges on all existing functions in the schema
        EXECUTE format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO %I', r.nspname, p_user);

        -- Set default privileges for future tables in the schema
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL ON TABLES TO %I', r.nspname, p_user);

        -- Set default privileges for future sequences in the schema
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL ON SEQUENCES TO %I', r.nspname, p_user);

        -- Set default privileges for future functions in the schema
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT EXECUTE ON FUNCTIONS TO %I', r.nspname, p_user);
    END LOOP;
END;
$$ LANGUAGE plpgsql;


--SELECT grant_full_access_all_schemas('app');
