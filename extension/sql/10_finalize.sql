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



select * from p8.insert_entity_nodes('p8.Agent');
select * from p8.insert_entity_nodes('p8.Function');
