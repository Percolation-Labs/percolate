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

-- we want to do this but its done in trigger
-- select * from p8.insert_entity_nodes('p8.Agent');
-- select * from p8.insert_entity_nodes('p8.Function');
