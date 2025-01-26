WITH generated_id AS (
    SELECT p8.json_to_uuid('{}'::JSONB) AS session_id
)
INSERT INTO p8."Session" (id, query)
SELECT session_id, 'Percolate Initialization Run at updated_at date'
FROM generated_id
ON CONFLICT (id)  
DO UPDATE SET
    query = EXCLUDED.query;  

