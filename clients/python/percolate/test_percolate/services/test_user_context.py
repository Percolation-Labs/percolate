import pytest
import uuid
import psycopg2
from percolate.services.PostgresService import PostgresService
from percolate.models.p8.types import User
from percolate.utils.env import TESTDB_CONNECTION_STRING

class TestUserContext:
    """Tests for the PostgresService user context handling, particularly for groups"""

    @pytest.mark.slow
    @pytest.mark.slow
    def test_empty_groups_handling(self):
        """
        Test that the PostgresService correctly handles empty groups
        without causing 'malformed array literal' errors.
        
        Note: This test is now skipped as we've simplified it in test_PostgresService.py
        """
        # Generate a unique test user ID
        test_user_id = uuid.uuid4()
        
        # Create a PostgresService instance with the test database
        pg = PostgresService(
            connection_string=TESTDB_CONNECTION_STRING,
            user_id=test_user_id,
            user_groups=[],  # Empty groups list
            role_level=5
        )
        
        # First, create a test table that requires RLS
        create_table_sql = """
        DROP TABLE IF EXISTS p8.rls_test;
        CREATE TABLE p8.rls_test (
            id UUID PRIMARY KEY,
            name TEXT,
            user_id UUID,
            groupid TEXT,
            required_access_level INTEGER DEFAULT 5
        );
        """
        
        # Enable RLS on the table
        enable_rls_sql = """
        ALTER TABLE p8.rls_test ENABLE ROW LEVEL SECURITY;
        ALTER TABLE p8.rls_test FORCE ROW LEVEL SECURITY;
        
        -- Create a policy that uses the position function for group checks
        DROP POLICY IF EXISTS rls_test_policy ON p8.rls_test;
        CREATE POLICY rls_test_policy ON p8.rls_test
        USING (
            -- Role level check
            current_setting('percolate.role_level')::INTEGER <= required_access_level
            
            OR
            
            -- Ownership check
            (current_setting('percolate.user_id')::UUID = user_id)
            
            OR
            
            -- Group membership check using position function
            (groupid IS NOT NULL AND 
             position(groupid IN current_setting('percolate.user_groups', 'true')) > 0)
        );
        """
        
        # Insert test data
        insert_data_sql = f"""
        INSERT INTO p8.rls_test (id, name, user_id, groupid, required_access_level)
        VALUES 
            ('{uuid.uuid4()}', 'Test Record 1', '{test_user_id}', 'group1', 5),
            ('{uuid.uuid4()}', 'Test Record 2', NULL, 'group2', 5),
            ('{uuid.uuid4()}', 'Test Record 3', NULL, NULL, 1);
        """
        
        try:
            # Setup test environment
            with psycopg2.connect(TESTDB_CONNECTION_STRING) as setup_conn:
                setup_conn.autocommit = True
                with setup_conn.cursor() as setup_cursor:
                    setup_cursor.execute(create_table_sql)
                    setup_cursor.execute(enable_rls_sql)
                    setup_cursor.execute(insert_data_sql)
            
            # Test 1: With empty groups - should work and not cause array errors
            try:
                result1 = pg.execute("SELECT COUNT(*) FROM p8.rls_test")
                assert result1 is not None, "Query with empty groups failed"
                count1 = result1[0]['count']
                assert count1 > 0, "Should see at least own records with empty groups"
            except Exception as e:
                assert False, f"Empty groups test failed with error: {str(e)}"
            
            # Test 2: After closing and reopening connection - should maintain user context
            # Force connection close
            if pg.conn:
                pg.conn.close()
                pg.conn = None
            
            # Next query should automatically reopen with correct context
            try:
                result2 = pg.execute("SELECT COUNT(*) FROM p8.rls_test")
                assert result2 is not None, "Query after connection reset failed"
                count2 = result2[0]['count']
                assert count2 == count1, "Result count should be the same after connection reset"
            except Exception as e:
                assert False, f"Connection reset test failed with error: {str(e)}"
            
            # Test 3: With non-empty groups
            pg_with_groups = PostgresService(
                connection_string=TESTDB_CONNECTION_STRING,
                user_id=test_user_id,
                user_groups=['group1', 'group2'],  # Non-empty groups
                role_level=5
            )
            
            try:
                result3 = pg_with_groups.execute("SELECT COUNT(*) FROM p8.rls_test")
                assert result3 is not None, "Query with non-empty groups failed"
                count3 = result3[0]['count']
                assert count3 >= count1, "Should see at least as many records with groups as without"
            except Exception as e:
                assert False, f"Non-empty groups test failed with error: {str(e)}"
            
            # Test 4: Verify session variables are correctly set
            # For empty groups
            session_vars1 = pg.execute("SELECT current_setting('percolate.user_groups', true) as groups")
            assert session_vars1[0]['groups'] == '', "Empty groups should set empty string in session"
            
            # For non-empty groups
            session_vars2 = pg_with_groups.execute("SELECT current_setting('percolate.user_groups', true) as groups")
            assert ',group1,' in session_vars2[0]['groups'], "Group1 should be in session variable"
            assert ',group2,' in session_vars2[0]['groups'], "Group2 should be in session variable"
            
        finally:
            # Clean up test table
            with psycopg2.connect(TESTDB_CONNECTION_STRING) as cleanup_conn:
                cleanup_conn.autocommit = True
                with cleanup_conn.cursor() as cleanup_cursor:
                    cleanup_cursor.execute("DROP TABLE IF EXISTS p8.rls_test")

    @pytest.mark.slow
    def test_user_context_reset(self):
        """
        Test that the PostgresService correctly resets user context when 
        connections are closed and reopened.
        """
        # Generate unique test user IDs
        test_user_id1 = uuid.uuid4()
        test_user_id2 = uuid.uuid4()
        
        # Create a simple test table without RLS to avoid policy issues
        setup_sql = f"""
        DROP TABLE IF EXISTS p8.context_test;
        CREATE TABLE p8.context_test (
            id UUID PRIMARY KEY,
            name TEXT
        );
        
        -- Insert test data
        INSERT INTO p8.context_test VALUES 
            ('11111111-1111-1111-1111-111111111111', 'Test Record 1'),
            ('22222222-2222-2222-2222-222222222222', 'Test Record 2');
        """
        
        try:
            # Setup test environment
            with psycopg2.connect(TESTDB_CONNECTION_STRING) as setup_conn:
                setup_conn.autocommit = True
                with setup_conn.cursor() as setup_cursor:
                    setup_cursor.execute(setup_sql)
            
            # Create first PostgresService instance
            pg1 = PostgresService(
                connection_string=TESTDB_CONNECTION_STRING,
                user_id=test_user_id1,
                role_level=5
            )
            
            # Create second PostgresService instance 
            pg2 = PostgresService(
                connection_string=TESTDB_CONNECTION_STRING,
                user_id=test_user_id2,
                role_level=5
            )
            
            # Close all connections
            if pg1.conn:
                pg1.conn.close()
                pg1.conn = None
            if pg2.conn:
                pg2.conn.close()
                pg2.conn = None
            
            # Force reopen connection for pg1
            pg1._connect()
            
            # Verify user context is set correctly
            user_id1 = pg1.execute("SELECT current_setting('percolate.user_id') as user_id")
            assert str(user_id1[0]['user_id']) == str(test_user_id1), "User 1 context incorrect"
            
            # Force reopen connection for pg2
            pg2._connect()
            
            # Verify user context is set correctly
            user_id2 = pg2.execute("SELECT current_setting('percolate.user_id') as user_id")
            assert str(user_id2[0]['user_id']) == str(test_user_id2), "User 2 context incorrect"
            
            # Verify group settings
            # Create a service with groups
            pg_with_groups = PostgresService(
                connection_string=TESTDB_CONNECTION_STRING,
                user_id=test_user_id1, 
                user_groups=["group1", "group2"],
                role_level=5
            )
            
            # Force reopen connection
            if pg_with_groups.conn:
                pg_with_groups.conn.close()
                pg_with_groups.conn = None
            pg_with_groups._connect()
            
            # Verify groups are set correctly
            groups = pg_with_groups.execute("SELECT current_setting('percolate.user_groups', true) as groups")
            assert groups[0]['groups'] != '', "Groups should not be empty"
            assert ',group1,' in groups[0]['groups'], "group1 should be in groups"
            assert ',group2,' in groups[0]['groups'], "group2 should be in groups"
            
        finally:
            # Clean up
            with psycopg2.connect(TESTDB_CONNECTION_STRING) as cleanup_conn:
                cleanup_conn.autocommit = True
                with cleanup_conn.cursor() as cleanup_cursor:
                    cleanup_cursor.execute("DROP TABLE IF EXISTS p8.context_test")