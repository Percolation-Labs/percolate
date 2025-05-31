import pytest
import uuid
from percolate.services.PostgresService import PostgresService
from percolate.utils.env import TESTDB_CONNECTION_STRING

@pytest.mark.slow
def test_get_user_context():
    """Test the get_user_context method to verify it returns correct session information"""
    
    # Generate a unique test user ID
    test_user_id = uuid.uuid4()
    test_groups = ["group1", "group2"]
    test_role_level = 5
    
    # Create a PostgresService instance with user context
    pg = PostgresService(
        connection_string=TESTDB_CONNECTION_STRING,
        user_id=test_user_id,
        user_groups=test_groups,
        role_level=test_role_level
    )
    
    # Close any existing connection to test without connection
    if pg.conn:
        pg.conn.close()
        pg.conn = None
    
    # Get user context before connection
    context_before = pg.get_user_context()
    
    # Verify context matches what we set
    assert context_before["user_id"] == str(test_user_id), "User ID should match"
    assert context_before["role_level"] == test_role_level, "Role level should match"
    assert context_before["user_groups"] == test_groups, "User groups should match"
    assert "local" in context_before["source"], "Source should indicate local values"
    
    # Force connection
    pg._connect()
    
    # Get user context after connection
    context_after = pg.get_user_context()
    
    # Verify context is from database session
    assert context_after["source"] == "database session", "Source should be database session"
    assert context_after["user_id"] == str(test_user_id), "User ID should match"
    assert context_after["role_level"] == test_role_level, "Role level should match"
    
    # Verify groups are parsed correctly from session
    assert set(context_after["user_groups"]) == set(test_groups), f"User groups should match: {context_after['user_groups']} vs {test_groups}"
    assert context_after["user_groups_raw"].startswith(",") and context_after["user_groups_raw"].endswith(","), "Raw groups should have leading/trailing commas"
    
    # Test with empty groups
    pg_empty = PostgresService(
        connection_string=TESTDB_CONNECTION_STRING,
        user_id=test_user_id,
        user_groups=[],  # Empty groups
        role_level=test_role_level
    )
    
    pg_empty._connect()
    empty_context = pg_empty.get_user_context()
    
    # Verify empty groups are handled correctly
    assert empty_context["user_groups"] == [], "Empty groups should be an empty list"
    assert empty_context["user_groups_raw"] == "", "Raw empty groups should be an empty string"
    
    # Clean up
    if pg.conn:
        pg.conn.close()
    if pg_empty.conn:
        pg_empty.conn.close()