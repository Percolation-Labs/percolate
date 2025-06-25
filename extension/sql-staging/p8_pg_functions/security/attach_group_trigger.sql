-- PostgreSQL Group-Based Access Trigger Function for Percolate
-- This file contains functions for attaching triggers that set groupid based on column values

-- Drop existing functions if they exist
DROP FUNCTION IF EXISTS p8.set_groupid_from_column() CASCADE;
DROP FUNCTION IF EXISTS p8.attach_group_trigger(TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS p8.apply_group_rule(TEXT, TEXT, TEXT, TEXT);

-- Trigger function that sets groupid based on a column value with prefix
CREATE OR REPLACE FUNCTION p8.set_groupid_from_column()
RETURNS TRIGGER AS $$
DECLARE
    column_value TEXT;
    prefix TEXT;
    source_column TEXT;
    new_groupid TEXT;
BEGIN
    -- Get the prefix and source column from trigger arguments
    prefix := TG_ARGV[0];
    source_column := TG_ARGV[1];
    
    -- Handle INSERT and UPDATE operations
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        -- Get the column value dynamically
        EXECUTE format('SELECT ($1).%I::TEXT', source_column) 
        INTO column_value 
        USING NEW;
        
        -- Only set groupid if the source column has a value
        IF column_value IS NOT NULL AND column_value != '' THEN
            new_groupid := prefix || ':' || column_value;
            
            -- Set the groupid on the NEW record
            NEW.groupid := new_groupid;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to attach the group trigger to a table
CREATE OR REPLACE FUNCTION p8.attach_group_trigger(
    p_table_identifier TEXT,      -- namespace.table_name format
    p_column_name TEXT,           -- column to use for group value
    p_prefix TEXT                 -- prefix for the group (e.g., 'role', 'dept', etc.)
)
RETURNS VOID AS $$
DECLARE
    v_schema_name TEXT;
    v_table_name TEXT;
    v_trigger_name TEXT;
    v_full_table_name TEXT;
    v_column_exists BOOLEAN;
BEGIN
    -- Parse the table identifier into schema and table name
    IF position('.' IN p_table_identifier) > 0 THEN
        v_schema_name := split_part(p_table_identifier, '.', 1);
        v_table_name := split_part(p_table_identifier, '.', 2);
    ELSE
        -- Default to p8 schema if not specified
        v_schema_name := 'p8';
        v_table_name := p_table_identifier;
    END IF;
    
    v_full_table_name := v_schema_name || '.' || v_table_name;
    v_trigger_name := v_table_name || '_' || p_column_name || '_group_trigger';
    
    -- Validate that the table exists
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables t
        WHERE t.table_schema = v_schema_name 
        AND t.table_name = v_table_name
    ) THEN
        RAISE EXCEPTION 'Table %.% does not exist', v_schema_name, v_table_name;
    END IF;
    
    -- Validate that the specified column exists
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns c
        WHERE c.table_schema = v_schema_name 
        AND c.table_name = v_table_name
        AND c.column_name = p_column_name
    ) THEN
        RAISE EXCEPTION 'Column % does not exist in table %.%', p_column_name, v_schema_name, v_table_name;
    END IF;
    
    -- Ensure groupid column exists
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns c
        WHERE c.table_schema = v_schema_name 
        AND c.table_name = v_table_name
        AND c.column_name = 'groupid'
    ) THEN
        EXECUTE format('ALTER TABLE %I.%I ADD COLUMN groupid TEXT', v_schema_name, v_table_name);
        RAISE NOTICE 'Added groupid column to %.%', v_schema_name, v_table_name;
    END IF;
    
    -- Drop existing trigger if it exists
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I.%I', v_trigger_name, v_schema_name, v_table_name);
    
    -- Create the trigger
    EXECUTE format('
        CREATE TRIGGER %I
        BEFORE INSERT OR UPDATE ON %I.%I
        FOR EACH ROW
        EXECUTE FUNCTION p8.set_groupid_from_column(%L, %L)
    ', v_trigger_name, v_schema_name, v_table_name, p_prefix, p_column_name);
    
    RAISE NOTICE 'Group trigger % attached to % using column % with prefix %', 
                 v_trigger_name, v_full_table_name, p_column_name, p_prefix;
    
    -- Update existing rows to set groupid based on current column values
    EXECUTE format('
        UPDATE %I.%I 
        SET groupid = %L || '':'' || %I::TEXT 
        WHERE %I IS NOT NULL 
        AND %I::TEXT != ''''
        AND (groupid IS NULL OR groupid != %L || '':'' || %I::TEXT)
    ', v_schema_name, v_table_name, p_prefix, p_column_name, 
       p_column_name, p_column_name, p_prefix, p_column_name);
    
    RAISE NOTICE 'Updated existing rows in % with groupid values', v_full_table_name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to apply group rule to existing table values
CREATE OR REPLACE FUNCTION p8.apply_group_rule(
    p_table_identifier TEXT,      -- namespace.table_name format
    p_column_name TEXT,           -- column to use for group value
    p_prefix TEXT,                -- prefix for the group
    p_where_clause TEXT DEFAULT NULL  -- optional WHERE clause to filter rows
)
RETURNS INTEGER AS $$
DECLARE
    v_schema_name TEXT;
    v_table_name TEXT;
    v_rows_updated INTEGER;
    v_sql TEXT;
BEGIN
    -- Parse the table identifier into schema and table name
    IF position('.' IN p_table_identifier) > 0 THEN
        v_schema_name := split_part(p_table_identifier, '.', 1);
        v_table_name := split_part(p_table_identifier, '.', 2);
    ELSE
        -- Default to p8 schema if not specified
        v_schema_name := 'p8';
        v_table_name := p_table_identifier;
    END IF;
    
    -- Validate that the table exists
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables t
        WHERE t.table_schema = v_schema_name 
        AND t.table_name = v_table_name
    ) THEN
        RAISE EXCEPTION 'Table %.% does not exist', v_schema_name, v_table_name;
    END IF;
    
    -- Validate that the specified column exists
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns c
        WHERE c.table_schema = v_schema_name 
        AND c.table_name = v_table_name
        AND c.column_name = p_column_name
    ) THEN
        RAISE EXCEPTION 'Column % does not exist in table %.%', p_column_name, v_schema_name, v_table_name;
    END IF;
    
    -- Ensure groupid column exists
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns c
        WHERE c.table_schema = v_schema_name 
        AND c.table_name = v_table_name
        AND c.column_name = 'groupid'
    ) THEN
        RAISE EXCEPTION 'Column groupid does not exist in table %.%. Run attach_group_trigger first.', v_schema_name, v_table_name;
    END IF;
    
    -- Build the UPDATE SQL
    v_sql := format('
        UPDATE %I.%I 
        SET groupid = %L || '':'' || %I::TEXT 
        WHERE %I IS NOT NULL 
        AND %I::TEXT != ''''',
        v_schema_name, v_table_name, p_prefix, p_column_name, 
        p_column_name, p_column_name
    );
    
    -- Add optional WHERE clause if provided
    IF p_where_clause IS NOT NULL THEN
        v_sql := v_sql || ' AND (' || p_where_clause || ')';
    END IF;
    
    -- Execute the update and get the number of affected rows
    EXECUTE v_sql;
    GET DIAGNOSTICS v_rows_updated = ROW_COUNT;
    
    RAISE NOTICE 'Updated % rows in %.% with groupid values', v_rows_updated, v_schema_name, v_table_name;
    
    RETURN v_rows_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Documentation
COMMENT ON FUNCTION p8.set_groupid_from_column() IS 
'Trigger function that automatically sets the groupid field based on a column value with a prefix.
This function is designed to work with batch updates and maintains role-based access control.

The trigger receives two arguments:
1. prefix: The prefix to prepend to the column value (e.g., "role", "dept")
2. source_column: The name of the column to use as the group value

The resulting groupid format is: PREFIX:column_value';

COMMENT ON FUNCTION p8.attach_group_trigger(TEXT, TEXT, TEXT) IS
'Attaches a trigger to a table that automatically sets groupid based on a column value.
This enables role-level access control where rows can be read by users in specific groups.

Arguments:
- table_identifier: The table in namespace.table_name format (defaults to p8 schema if not specified)
- column_name: The column whose value will be used for the group
- prefix: The prefix to prepend to the group (e.g., "role", "dept", "team")

The trigger will:
1. Work on both INSERT and UPDATE operations
2. Handle batch updates efficiently
3. Set groupid to PREFIX:column_value format
4. Only set groupid if the source column has a non-null, non-empty value

Example usage:
SELECT p8.attach_group_trigger(''hr.employees'', ''department'', ''dept'');
-- This will set groupid to ''dept:sales'' for employees in the sales department

SELECT p8.attach_group_trigger(''users'', ''role'', ''role'');
-- This will set groupid to ''role:admin'' for users with admin role';

COMMENT ON FUNCTION p8.apply_group_rule(TEXT, TEXT, TEXT, TEXT) IS
'Applies the group rule to existing rows in a table by updating their groupid values.
This function is useful for retroactively applying group-based access control.

Arguments:
- table_identifier: The table in namespace.table_name format (defaults to p8 schema if not specified)
- column_name: The column whose value will be used for the group
- prefix: The prefix to prepend to the group (e.g., "role", "dept", "team")
- where_clause: Optional WHERE clause to filter which rows to update (default: NULL - update all rows)

Returns:
- The number of rows updated

Example usage:
-- Update all rows
SELECT p8.apply_group_rule(''hr.employees'', ''department'', ''dept'');

-- Update only active employees
SELECT p8.apply_group_rule(''hr.employees'', ''department'', ''dept'', ''status = ''''active'''''');

-- Update users created before trigger was attached
SELECT p8.apply_group_rule(''users'', ''role'', ''role'', ''created_at < ''''2024-01-01'''''');';