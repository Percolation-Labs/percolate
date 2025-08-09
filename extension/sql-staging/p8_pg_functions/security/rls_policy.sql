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