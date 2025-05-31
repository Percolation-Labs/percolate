-- Function to set user context for row-level security
DROP FUNCTION IF EXISTS p8.set_user_context;
CREATE OR REPLACE FUNCTION p8.set_user_context(
    p_user_id UUID, 
    p_role_level INTEGER = NULL
)
RETURNS VOID AS $$
DECLARE
    v_role_level INTEGER;
    v_user_record RECORD;
    v_groups TEXT[];
BEGIN
    -- If role_level not provided, try to load it from the User table
    IF p_role_level IS NULL THEN
        -- Get role_level, required_access_level, and groups from the User table
        SELECT u.role_level, u.required_access_level, u.groups
        INTO v_user_record
        FROM p8."User" u
        WHERE u.id = p_user_id;
        
        -- Use role_level if available, otherwise use required_access_level
        -- If neither is found, default to public access (100)
        IF v_user_record.role_level IS NOT NULL THEN
            v_role_level := v_user_record.role_level;
        ELSIF v_user_record.required_access_level IS NOT NULL THEN
            -- Use the required_access_level as a fallback
            -- This makes sense because God users have required_access_level=0
            -- Admin users have required_access_level=1, etc.
            v_role_level := v_user_record.required_access_level;
        ELSE
            -- Default to public access if nothing is found
            v_role_level := 100;
        END IF;
        
        -- Get user groups if available
        v_groups := v_user_record.groups;
    ELSE
        -- Use the explicitly provided role level
        v_role_level := p_role_level;
        
        -- Still need to get groups from User table
        SELECT u.groups
        INTO v_groups
        FROM p8."User" u
        WHERE u.id = p_user_id;
    END IF;
    
    -- Set the session variables
    PERFORM set_config('percolate.user_id', p_user_id::TEXT, false);
    PERFORM set_config('percolate.role_level', v_role_level::TEXT, false);
    
    -- Set user groups if available
    IF v_groups IS NOT NULL AND array_length(v_groups, 1) > 0 THEN
        -- For LIKE pattern matching in the policy, we need commas as separators
        PERFORM set_config('percolate.user_groups', ',' || array_to_string(v_groups, ',') || ',', false);
    ELSE
        -- Set empty string if no groups
        PERFORM set_config('percolate.user_groups', '', false);
    END IF;
    
    -- Return the role level as a message for debugging
    RAISE NOTICE 'Set user context: user_id=%, role_level=%, groups=%', 
                 p_user_id, v_role_level, v_groups;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Documentation
COMMENT ON FUNCTION p8.set_user_context(UUID, INTEGER) IS 
'Sets PostgreSQL session variables for row-level security:
- percolate.user_id: UUID of the current user
- percolate.role_level: Access level of the user (0=GOD, 1=ADMIN, 5=INTERNAL, 10=PARTNER, 100=PUBLIC)
- percolate.user_groups: Comma-separated list of groups the user belongs to

Arguments:
- p_user_id: The user ID to set in the session
- p_role_level: Optional role level to override the user''s default level

Examples:
SELECT p8.set_user_context(''4114f279-f345-511b-b375-1953089e078f'');
SELECT p8.set_user_context(''4114f279-f345-511b-b375-1953089e078f'', 1);
';