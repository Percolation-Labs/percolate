"""
Example script demonstrating the use of the get_user_context method in PostgresService.

This script creates a PostgresService instance with different user contexts and
shows how to inspect the session variables to debug Row-Level Security issues.
"""

import uuid
from percolate.services.PostgresService import PostgresService
from percolate.utils.env import POSTGRES_CONNECTION_STRING

def main():
    print("PostgresService User Context Debugging Example")
    print("=" * 50)
    
    # Create a test user ID
    test_user_id = uuid.uuid4()
    
    # Example 1: PostgresService with user ID only
    print("\nExample 1: PostgresService with user ID only")
    pg1 = PostgresService(
        user_id=test_user_id,
        role_level=None  # Will be loaded from database if available
    )
    
    # Get and display user context
    context1 = pg1.get_user_context()
    print_context(context1)
    
    # Example 2: PostgresService with user ID and explicit role level
    print("\nExample 2: PostgresService with user ID and explicit role level")
    pg2 = PostgresService(
        user_id=test_user_id,
        role_level=5  # INTERNAL access level
    )
    
    # Get and display user context
    context2 = pg2.get_user_context()
    print_context(context2)
    
    # Example 3: PostgresService with user ID, role level, and groups
    print("\nExample 3: PostgresService with user ID, role level, and groups")
    pg3 = PostgresService(
        user_id=test_user_id,
        role_level=5,  # INTERNAL access level
        user_groups=["group1", "group2"]
    )
    
    # Get and display user context
    context3 = pg3.get_user_context()
    print_context(context3)
    
    # Example 4: PostgresService with empty groups
    print("\nExample 4: PostgresService with empty groups")
    pg4 = PostgresService(
        user_id=test_user_id,
        role_level=5,  # INTERNAL access level
        user_groups=[]  # Empty groups
    )
    
    # Get and display user context
    context4 = pg4.get_user_context()
    print_context(context4)
    
    print("\nDone! Use pg.get_user_context() to debug Row-Level Security issues.")

def print_context(context):
    """Helper function to print context in a readable format"""
    print(f"Source: {context['source']}")
    print(f"User ID: {context['user_id']}")
    print(f"Role Level: {context['role_level']}")
    
    if 'user_groups_raw' in context:
        print(f"User Groups (raw): '{context['user_groups_raw']}'")
    
    groups = context['user_groups']
    if groups and len(groups) > 0:
        print(f"User Groups: {groups}")
    else:
        print("User Groups: []")
    
    if 'error' in context:
        print(f"Error: {context['error']}")
    
    print("-" * 40)

if __name__ == "__main__":
    main()