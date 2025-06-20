# PostgreSQL Row-Level Security in Percolate

This document explains the row-level security (RLS) implementation in Percolate's PostgreSQL database. The security model uses a combination of user ID, group membership, and role-based access control to protect data at the row level.

## Overview

Percolate implements a comprehensive row-level security model with three key components:

1. **Role-based access levels** - Numeric values that define security clearance (lower = higher privilege)
2. **User ownership** - Direct ownership of records by a specific user
3. **Group ownership** - Ownership of records by a group, with users belonging to multiple groups

## System User for Operations Without User Context

In some scenarios, operations need to be performed without an explicit user context (background jobs, system operations, etc.). For these cases, Percolate uses a system user:

- The system user has a consistent UUID generated from the string "system-user"
- By default, the system user has admin privileges (access_level = 1)
- The system user ID can be overridden by setting the `P8_SYSTEM_USER_ID` environment variable
- PostgresService automatically uses the system user when no user_id is provided

## Access Level Definitions

Role-based access is defined using numeric levels, where lower numbers indicate higher privileges:

| Level | Role     | Description                           |
|-------|----------|---------------------------------------|
| 0     | God      | Unrestricted access to all data       |
| 1     | Admin    | Administrative access                 |
| 5     | Internal | Internal/employee access              |
| 10    | Partner  | External partner access               |
| 100   | Public   | Public access (most restricted)       |

Additional levels can be defined between these values for more granular access control.

## Database Schema Modifications

Each table in the database will include additional columns to support the RLS model:

```sql
-- Added to all Percolate tables
userid UUID,                   -- User who owns this record (NULL means no specific owner)
groupid UUID,                  -- Group that owns this record (NULL means no specific group)
required_access_level INTEGER,  -- Minimum role level required (default 100 = public)
```

## SQL Policy Implementation

### 1. Creating Row-Level Security Policies

The following SQL creates the RLS policy for a table:

```sql
-- Enable row-level security on a table
ALTER TABLE schema_name.table_name ENABLE ROW LEVEL SECURITY;

-- Force RLS even for table owner
ALTER TABLE schema_name.table_name FORCE ROW LEVEL SECURITY;

-- Create the RLS policy
CREATE POLICY table_name_access_policy ON schema_name.table_name
USING (
  -- PRIMARY CONDITION: Role level check must pass
  current_setting('percolate.role_level')::INTEGER <= required_access_level
  
  AND
  
  -- SECONDARY CONDITIONS: At least one must be true
  (
    -- 1. User owns the record
    current_setting('percolate.user_id')::UUID = user_id 
    -- 2. Record has no specific owner (user_id is NULL)
    OR user_id IS NULL
    -- 3. User is member of the record's group
    OR current_setting('percolate.user_groups', 'true')::TEXT[] @> ARRAY[groupid::TEXT]
    -- 4. The userid column matches (backward compatibility)
    OR (userid IS NOT NULL AND current_setting('percolate.user_id')::UUID = userid)
  )
);
```

This policy ensures that:
1. The user's role level must be sufficient (lower or equal to required_access_level)
2. AND at least one of the ownership conditions must be met:
   - The user owns the record
   - The record has no specific owner
   - The user is a member of the record's group
   - The userid column matches (for backward compatibility)


### 3. Setting User Context

When a user connects, the PostgreSQL session variables must be set to establish their security context:

```sql
-- Set the user context when a connection is established
SET percolate.user_id = '123e4567-e89b-12d3-a456-426614174000';
SET percolate.user_groups = ARRAY['22222222-e89b-12d3-a456-426614174000', '33333333-e89b-12d3-a456-426614174000'];
SET percolate.role_level = 5;  -- Internal access level
```

## Model Configuration

Percolate's Pydantic model configuration will be enhanced to include access level definitions:

```python
class PercolateBaseModel(BaseModel):
    """Base model with security attributes"""
    user_id: Optional[UUID] = None
    groupid: Optional[UUID] = None
    required_access_level: int = 100  # Default to public access
    
    model_config = {
        # Existing config...
        "access_level": 100,  # Default access level for this model type
    }

class ExecutiveDocument(PercolateBaseModel):
    """Example of a restricted document model"""
    title: str
    content: str
    
    model_config = {
        # Existing config...
        "access_level": 1,  # Admin access required
    }
```

## Required Changes to PostgreSQL Service

The PostgresService class handles row-level security through:

1. Session context management
2. Automatic application of user context
3. Enhanced repository creation

### Code Sample: PostgresService Modifications

```python
class PostgresService:
    def __init__(
        self,
        model: BaseModel = None,
        connection_string=None,
        on_connect_error: str = None,
        user_id: Optional[str] = None,
        user_groups: Optional[List[str]] = None,
        role_level: Optional[int] = None,
    ):
        # Existing initialization...
        
        # Store user context
        self.user_id = user_id if user_id is not None else SYSTEM_USER_ID
        self.user_groups = user_groups or []
        
        # Set initial role_level (may be updated during user context loading)
        if role_level is not None:
            self.role_level = role_level
        elif self.user_id == SYSTEM_USER_ID:
            self.role_level = SYSTEM_USER_ROLE_LEVEL
        else:
            # For non-system users, we'll load from the database
            self.role_level = 100  # Default to public until we load from database
        
        # Apply user context when connection is established
        if self.conn:
            self._apply_user_context()
    
    def _apply_user_context(self):
        """Apply user context to the PostgreSQL session"""
        if not self.conn:
            return
        
        # Check if we need to fetch user context from the database
        if self._need_user_context:
            # Load user details from database
            # ...
        
        # Apply context to database session
        cursor = self.conn.cursor()
        try:
            # Apply user_id
            if self.user_id:
                cursor.execute("SET percolate.user_id = %s", (str(self.user_id),))
            
            # Apply user_groups
            if self.user_groups:
                groups_array = "{" + ",".join([str(g) for g in self.user_groups]) + "}"
                cursor.execute("SET percolate.user_groups = %s", (groups_array,))
            
            # Apply role_level
            if self.role_level is not None:
                cursor.execute("SET percolate.role_level = %s", (self.role_level,))
            
            self.conn.commit()
        finally:
            cursor.close()
```

## Idempotent RLS Function Behavior

The `p8.attach_rls_policy` function is designed to be fully idempotent, which means it can be safely run multiple times on the same table without causing issues. When executed, the function:

1. Adds security columns (userid, groupid, required_access_level) if they don't already exist
2. Updates the required_access_level for all existing records to match the specified default level
3. Drops any existing RLS policy on the table before creating a new one
4. Applies the appropriate RLS policy with the specified access level

This idempotent behavior makes it safe to use in database migrations, repeated deployments, or when reconfiguring security settings. You can change the access level of a table at any time by simply calling the function again with a different level parameter.

Example usage:
```sql
-- Initial application of RLS with INTERNAL access (level 5)
SELECT p8.attach_rls_policy('p8', 'Document', 5);

-- Later, changing to ADMIN access (level 1)
SELECT p8.attach_rls_policy('p8', 'Document', 1);
```

## Important Notes for Database Users

For row-level security to function properly, the database connection must use a non-superuser PostgreSQL role. Superuser roles and roles with the BYPASSRLS attribute will bypass all RLS policies, even with FORCE ROW LEVEL SECURITY enabled.

To create an application user that respects RLS:

```sql
-- Create application user
CREATE ROLE percolate_app WITH LOGIN PASSWORD 'secure_password';

-- Ensure no superuser or bypass RLS privileges
ALTER ROLE percolate_app NOSUPERUSER NOBYPASSRLS;

-- Grant necessary privileges
GRANT USAGE ON SCHEMA p8 TO percolate_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA p8 TO percolate_app;
```

Alternatively, you can use the `p8.create_app_user` function which handles all these steps for you:

```sql
-- Create application user with proper RLS settings
SELECT p8.create_app_user('percolate_app', 'secure_password');
```

## Testing Row-Level Security

To verify that row-level security is working properly, you can use the following test approach:

1. Connect to the database using a non-superuser role
2. Set session variables for different user contexts
3. Run the same query and verify different results based on user context

Example test:

```python
# Test as admin user
admin_pg = PostgresService(
    connection_string="postgresql://percolate_app:secure_password@localhost:5438/app",
    user_id="admin-uuid",
    role_level=1  # Admin
)
admin_results = admin_pg.execute('SELECT COUNT(*) FROM p8."User"')

# Test as internal user
internal_pg = PostgresService(
    connection_string="postgresql://percolate_app:secure_password@localhost:5438/app",
    user_id="employee-uuid",
    role_level=5  # Internal
)
internal_results = internal_pg.execute('SELECT COUNT(*) FROM p8."User"')

# Admin should see more records than internal user
assert admin_results[0]['count'] > internal_results[0]['count']
```

## Conclusion

This row-level security implementation provides a flexible and powerful way to control data access in Percolate. By combining user ownership, group membership, and role-based access levels, we can create a secure multi-tenant environment that protects sensitive data while allowing appropriate access.

The security model is:
- **Comprehensive**: Covers individual, group, and role-based access
- **Flexible**: Can be adjusted for different security requirements
- **Efficient**: Implemented at the database level for consistent enforcement
- **Transparent**: Automatically applied without application code changes

This approach ensures that data access is properly controlled regardless of how the database is accessed, providing a strong security foundation for the Percolate platform.