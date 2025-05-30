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