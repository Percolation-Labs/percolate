
import pytest
import percolate as p8
from pydantic import BaseModel,Field
from percolate.models import DefaultEmbeddingField
from percolate.services.PostgresService import PostgresService
from percolate.utils.env import TESTDB_CONNECTION_STRING
import uuid
import psycopg2

class MyFirstAgent(BaseModel):
    """You are an agent that provides the information you are asked and a second random fact"""
    #if it has no model config or python module it would save to the public database schema
    model_config = {'namespace':'public'}
    name: str = Field(description="Task name")
    #the default embedding field is just settings json_schema_extra.embedding_provider, so you can do that yourself
    description:str = DefaultEmbeddingField(description="Task description")
    
    @classmethod
    def get_model_functions(cls):
        """i return a list of functions by key stored in the database"""
        return {
            'get_pet_findByStatus': "a function i use to look up pets based on their status"
        }

@pytest.mark.skip("Skipping Postgres registration test: no live database in CI environment")
@pytest.mark.slow
def test_register_model():
    """this test is used to test the creation of the test model"""
    repo = p8.repository(MyFirstAgent)
    _ = repo.register()
    
    """check if the model is registered
    1. The table must exist
    2. test that embedding was created when it should have been TODO:
    3. the graph view for watermark was created when it should have been
    """
    
    assert repo.check_entity_exists(), "The entity was not created at registration"

#@pytest.mark.skip("Skipping empty groups test: requires live database")
@pytest.mark.slow
def test_empty_groups_handling():
    """Test that empty groups are handled correctly in PostgresService"""
    # Create PostgresService with empty groups
    pg = PostgresService(
        connection_string=TESTDB_CONNECTION_STRING,
        user_id=uuid.uuid4(),
        user_groups=[],  # Empty groups list
        role_level=5
    )
    
    # Create a test table with RLS
    create_sql = """
    DROP TABLE IF EXISTS p8.empty_groups_test;
    CREATE TABLE p8.empty_groups_test (
        id UUID PRIMARY KEY,
        name TEXT,
        user_id UUID,
        groupid TEXT,
        required_access_level INTEGER DEFAULT 5
    );
    
    -- Enable RLS
    ALTER TABLE p8.empty_groups_test ENABLE ROW LEVEL SECURITY;
    ALTER TABLE p8.empty_groups_test FORCE ROW LEVEL SECURITY;
    
    -- Create policy that uses position() for group checks
    CREATE POLICY empty_groups_test_policy ON p8.empty_groups_test
    USING (
        current_setting('percolate.role_level')::INTEGER <= required_access_level
        OR
        (
            -- Position check for groups that should handle empty strings
            groupid IS NOT NULL AND 
            position(groupid IN current_setting('percolate.user_groups', 'true')) > 0
        )
    );
    
    -- Insert test data
    INSERT INTO p8.empty_groups_test VALUES 
        ('11111111-1111-1111-1111-111111111111', 'Test 1', NULL, 'group1', 5);
    """
    
    cleanup_sql = "DROP TABLE IF EXISTS p8.empty_groups_test;"
    
    try:
        # Setup the test table
        with psycopg2.connect(TESTDB_CONNECTION_STRING) as setup_conn:
            setup_conn.autocommit = True
            with setup_conn.cursor() as cursor:
                cursor.execute(create_sql)
        
        # Test 1: Query should work with empty groups
        try:
            result = pg.execute("SELECT COUNT(*) FROM p8.empty_groups_test")
            # If we get here without error, the test passes
            assert True, "Query executed successfully with empty groups"
            
            # Verify user_groups is set correctly
            user_groups = pg.execute("SELECT current_setting('percolate.user_groups', true) as groups")
            assert user_groups[0]['groups'] == '', "Empty groups should be set as empty string"
            
        except Exception as e:
            assert False, f"Query with empty groups failed: {str(e)}"
            
        # Test 2: Force connection close and reopen
        if pg.conn:
            pg.conn.close()
            pg.conn = None
            
        # Query should still work after connection reset
        try:
            result = pg.execute("SELECT COUNT(*) FROM p8.empty_groups_test")
            assert True, "Query executed successfully after connection reset"
            
            # Verify user_groups is still set correctly
            user_groups = pg.execute("SELECT current_setting('percolate.user_groups', true) as groups")
            assert user_groups[0]['groups'] == '', "Empty groups should still be set after connection reset"
            
        except Exception as e:
            assert False, f"Query after connection reset failed: {str(e)}"
    
    finally:
        # Clean up
        with psycopg2.connect(TESTDB_CONNECTION_STRING) as cleanup_conn:
            cleanup_conn.autocommit = True
            with cleanup_conn.cursor() as cursor:
                cursor.execute(cleanup_sql)
    