---------create app user-----------------
-- Create app user if it doesn't exist
DO $$ 
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app') THEN
        CREATE USER app;
    END IF;
END $$;

-- Grant privileges to app user
GRANT ALL PRIVILEGES ON DATABASE app TO app;
GRANT ALL PRIVILEGES ON SCHEMA public TO app;

---------extensions----------------------
CREATE EXTENSION IF NOT EXISTS HTTP;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS age;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

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


-- Create the trigger function to register inserts e.g. to build indexes
CREATE OR REPLACE FUNCTION notify_entity_updates()
RETURNS TRIGGER AS
$$
DECLARE
    api_token_in TEXT;
    proxy_uri_in TEXT;
    full_name TEXT;
    response JSON;
BEGIN
    -- Construct the full name of the table
    full_name := TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME;

    -- Fetch API details from the p8."ApiProxy" table - this will be running on local host in docker contexts
    SELECT token, proxy_uri 
    INTO api_token_in, proxy_uri_in
    FROM p8."ApiProxy"
    WHERE name = 'percolate'
    LIMIT 1;

    -- If no API details are found, do nothing
    IF api_token_in IS NULL OR proxy_uri_in IS NULL THEN
        RAISE NOTICE 'API details not found, skipping request';
        RETURN NEW;
    END IF;

    BEGIN
        -- Make the POST request
        SELECT content INTO response
        FROM public.http(
            ( 'POST', 
            proxy_uri_in || '/admin/index/',
            ARRAY[http_header('Authorization', 'Bearer ' || api_token_in)],
            'application/json',
            json_build_object('entity_full_name', full_name)::jsonb
            )::http_request
        );
     EXCEPTION 
        WHEN OTHERS THEN
            --todo log errors in the session
            RAISE NOTICE 'Error executing HTTP request: %', SQLERRM;
            response := NULL;
    END;
    -- Log the response
    RAISE NOTICE 'applying for % index at % - %',  full_name, proxy_uri_in || '/admin/index/', response;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

---
CREATE OR REPLACE FUNCTION attach_notify_trigger_to_table(schema_name TEXT, table_name TEXT) RETURNS VOID AS
$$
DECLARE
    trigger_name TEXT;
BEGIN
    -- Construct a unique trigger name
    trigger_name := 'notify_entity_updates' || table_name;

    -- Drop the trigger if it exists
    EXECUTE format(
        'DROP TRIGGER IF EXISTS %I ON %I.%I;',
        trigger_name, schema_name, table_name
    );
    
    -- Execute dynamic SQL to create the trigger
    EXECUTE format(
        'CREATE TRIGGER %I
        AFTER UPDATE ON %I.%I
        FOR EACH STATEMENT
        EXECUTE FUNCTION notify_entity_updates();',
        trigger_name, schema_name, table_name
    );

    RAISE NOTICE 'Trigger % created on %.%', trigger_name, schema_name, table_name;
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

 

ALTER DATABASE app SET percolate.user_id = '00000000-0000-0000-0000-000000000000';
ALTER DATABASE app SET percolate.role_level = 1;
ALTER DATABASE app SET percolate.user_groups = '{}';

------Grant AGE extension permissions to app user---------
-- Grant access to AGE catalog schema and functions
GRANT USAGE ON SCHEMA ag_catalog TO app;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA ag_catalog TO app;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA ag_catalog TO app;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA ag_catalog TO app;

-- Grant access to percolate graph schema
GRANT USAGE ON SCHEMA percolate TO app;
GRANT ALL PRIVILEGES ON SCHEMA percolate TO app;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA percolate TO app;
---------------------------------------------------------