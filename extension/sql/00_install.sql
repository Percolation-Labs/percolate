---------extensions----------------------
CREATE EXTENSION IF NOT EXISTS HTTP;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS age;

-----------------------------------------
-----------------------------------------


------Add any triggers-------------------
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
-----------------------------------------
-----------------------------------------


------Add percolate p8 schema------------
CREATE SCHEMA IF NOT EXISTS p8;
CREATE SCHEMA IF NOT EXISTS p8_embeddings;

--MAYBE
--ALTER DATABASE app SET search_path = ag_catalog, "$user", public;


--utils
CREATE OR REPLACE FUNCTION p8.json_to_uuid(
	json_data jsonb)
    RETURNS uuid
    LANGUAGE 'plpgsql'
    COST 100
    IMMUTABLE PARALLEL UNSAFE
AS $BODY$
DECLARE
    json_string TEXT;
    hash TEXT;
    uuid_result UUID;
BEGIN
    -- Serialize the JSON object in a deterministic way - this needs to match how python or other langs would do it
    json_string := jsonb(json_data)::text;
    hash := md5(json_string);
    uuid_result := (
        SUBSTRING(hash FROM 1 FOR 8) || '-' ||
        SUBSTRING(hash FROM 9 FOR 4) || '-' ||
        SUBSTRING(hash FROM 13 FOR 4) || '-' ||
        SUBSTRING(hash FROM 17 FOR 4) || '-' ||
        SUBSTRING(hash FROM 21 FOR 12)
    )::uuid;

    RETURN uuid_result;
END;
$BODY$;


------Add the p8 graph and schema--------
LOAD  'age';
SET search_path = ag_catalog, "$user", public;
DO $$ 
BEGIN
 IF NOT EXISTS (
        SELECT 1 FROM pg_namespace WHERE nspname = 'percolate'
    ) THEN
        PERFORM create_graph('percolate');
    END IF;
END $$;
-----------------------------------------
-----------------------------------------
