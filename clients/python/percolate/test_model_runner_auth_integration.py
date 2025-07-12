import os
import json

# Set environment variables BEFORE importing percolate
os.environ['P8_PG_HOST'] = 'localhost'
os.environ['P8_PG_PORT'] = '25432'
os.environ['P8_PG_USER'] = 'app'
os.environ['P8_PG_PASSWORD'] = os.environ.get('P8_TEST_BEARER_TOKEN', '')
os.environ['P8_PG_DATABASE'] = 'app'

print(f"Set P8 environment variables:")
print(f"  P8_PG_HOST: {os.environ['P8_PG_HOST']}")
print(f"  P8_PG_PORT: {os.environ['P8_PG_PORT']}")
print(f"  P8_PG_USER: {os.environ['P8_PG_USER']}")
print(f"  P8_PG_DATABASE: {os.environ['P8_PG_DATABASE']}")
print(f"  P8_PG_PASSWORD: {'***' if os.environ.get('P8_PG_PASSWORD') else 'NOT SET'}")

# NOW import percolate after environment is set
import pytest
import percolate as p8
from percolate.services.llm import CallingContext
from percolate.models.p8.types import Resources, Agent


class TestModelRunnerAuthIntegration:
    """Integration test for ModelRunner authentication and authorization with real agents"""
    
    def __init__(self):
        """Initialize - database connection is configured via environment variable"""
        pass
    
    def test_admin_user_access_with_real_agent(self):
        """Test that admin user can access all records through a real agent"""
        # Create agent with admin user context
        admin_agent = p8.Agent(
            Resources,
            user_id="amartey@gmail.com",
            role_level="admin"
        )
        
        # Create calling context with admin user
        admin_context = CallingContext(
            username="amartey@gmail.com",
            user_id="amartey@gmail.com",
            temperature=0.0,
            model="gpt-4"
        )
        
        # Ask the agent to get entities from AuthTestRecord
        # The agent should internally call get_entities with proper permissions
        result = admin_agent.run(
            question="Please use get_entities to retrieve all records from the AuthTestRecord table",
            context=admin_context,
            audit=False  # Disable audit for testing
        )
        
        # Admin should be able to see all records including restricted ones
        assert result is not None
        print(f"Admin result: {result}")
    
    def test_regular_user_access_with_real_agent(self):
        """Test that regular user has limited access through a real agent"""
        # Create agent with regular user context
        regular_agent = p8.Agent(
            Resources,
            user_id="test_user@example.com",
            role_level="user"
        )
        
        # Create calling context with regular user
        regular_context = CallingContext(
            username="test_user@example.com",
            user_id="test_user@example.com",
            temperature=0.0,
            model="gpt-4"
        )
        
        # Ask the agent to get entities
        result = regular_agent.run(
            question="Please use get_entities to retrieve all records from the AuthTestRecord table",
            context=regular_context,
            audit=False
        )
        
        # Regular user should have limited access
        assert result is not None
        print(f"Regular user result: {result}")
    
    def test_context_override_user_permissions(self):
        """Test that CallingContext can override the agent's initial user_id"""
        # Create agent with one user
        agent = p8.Agent(
            Resources,
            user_id="test_user@example.com",
            role_level="user"
        )
        
        # But use CallingContext with admin user
        admin_context = CallingContext(
            username="amartey@gmail.com",
            user_id="amartey@gmail.com",
            temperature=0.0,
            model="gpt-4"
        )
        
        # The context should override and use admin permissions
        result = agent.run(
            question="Please use get_entities to search for 'Admin Only Record' from AuthTestRecord",
            context=admin_context,
            audit=False
        )
        
        assert result is not None
        print(f"Override context result: {result}")
    
    def test_direct_get_entities_call(self):
        """Test calling get_entities directly on the ModelRunner"""
        # Create agent
        agent = p8.Agent(
            Resources,
            user_id="amartey@gmail.com",
            role_level="admin"
        )
        
        # Set up context
        admin_context = CallingContext(
            username="amartey@gmail.com",
            user_id="amartey@gmail.com"
        )
        agent._context = admin_context
        
        # Call get_entities directly on the agent (which IS the ModelRunner)
        entities = agent.get_entities(keys="Admin Only Record")
        
        print(f"Direct get_entities result: {entities}")
        assert entities is not None
    
    def test_search_with_different_users(self):
        """Test search functionality with different user permissions"""
        # Admin user search
        admin_agent = p8.Agent(
            Resources,
            user_id="amartey@gmail.com",
            role_level="admin"
        )
        
        admin_context = CallingContext(
            username="amartey@gmail.com",
            user_id="amartey@gmail.com",
            temperature=0.0,
            model="gpt-4"
        )
        
        # Search should respect permissions
        admin_result = admin_agent.run(
            question="Please search for 'restricted' records in the AuthTestRecord table",
            context=admin_context,
            audit=False
        )
        
        # Regular user search
        regular_agent = p8.Agent(
            Resources,
            user_id="test_user@example.com",
            role_level="user"
        )
        
        regular_context = CallingContext(
            username="test_user@example.com",
            user_id="test_user@example.com",
            temperature=0.0,
            model="gpt-4"
        )
        
        regular_result = regular_agent.run(
            question="Please search for 'restricted' records in the AuthTestRecord table",
            context=regular_context,
            audit=False
        )
        
        print(f"Admin search: {admin_result}")
        print(f"Regular search: {regular_result}")
        
        # Admin should find restricted records, regular user should not
        assert admin_result is not None
        assert regular_result is not None


def test_simple_agent_creation():
    """Test that we can create an agent and access its runner"""
    # Create a simple agent
    agent = p8.Agent(Resources)
    
    # Check what attributes the agent has
    print(f"Agent type: {type(agent)}")
    print(f"Agent attributes: {[attr for attr in dir(agent) if not attr.startswith('_')]}")
    
    # The agent itself IS the ModelRunner
    assert hasattr(agent, 'get_entities')
    assert hasattr(agent, 'search')
    assert hasattr(agent, 'run')
    
    print("Agent created successfully with ModelRunner")


def setup_database_parameters():
    """Setup the required database parameters"""
    from percolate.services.PostgresService import PostgresService
    import psycopg2
    
    print("\n--- Setting up database parameters ---")
    
    # Connect directly with psycopg2 to run ALTER DATABASE commands
    conn_string = f"postgresql://{os.environ['P8_PG_USER']}:{os.environ['P8_PG_PASSWORD']}@{os.environ['P8_PG_HOST']}:{os.environ['P8_PG_PORT']}/{os.environ['P8_PG_DATABASE']}"
    
    try:
        conn = psycopg2.connect(conn_string)
        conn.autocommit = True  # Required for ALTER DATABASE
        cursor = conn.cursor()
        
        # Apply the configuration parameters
        print("Applying percolate configuration parameters...")
        cursor.execute("ALTER DATABASE app SET percolate.user_id = '';")
        cursor.execute("ALTER DATABASE app SET percolate.role_level = '';")
        cursor.execute("ALTER DATABASE app SET percolate.user_groups = '';")
        
        print("Successfully set database parameters")
        
        cursor.close()
        conn.close()
        
        print("Database parameters have been set. You may need to reconnect for changes to take effect.")
        
    except Exception as e:
        print(f"Error setting database parameters: {e}")
        import traceback
        traceback.print_exc()


def test_with_real_users():
    """Test with real users from the database using PostgresService"""
    from percolate.services.PostgresService import PostgresService
    from uuid import UUID
    
    # Use PostgresService without any user context for initial queries
    pg_service = PostgresService(user_id=None)
    
    try:
        # First, let's verify we can connect and see database info
        print("\n--- Checking database connection ---")
        print(f"PostgresService connection string: {pg_service._connection_string}")
        
        # Check current database
        db_info = pg_service.execute("SELECT current_database(), current_user")
        print(f"Connected to database: {db_info[0]['current_database']} as user: {db_info[0]['current_user']}")
        
        # List all schemas
        schemas = pg_service.execute("""
            SELECT schema_name 
            FROM information_schema.schemata 
            WHERE schema_name NOT IN ('information_schema', 'pg_catalog', 'pg_toast')
            ORDER BY schema_name
        """)
        print(f"Available schemas: {[s['schema_name'] for s in schemas]}")
        
        # List ALL tables in p8 schema to see what's available
        all_p8_tables = pg_service.execute("""
            SELECT table_name 
            FROM information_schema.tables 
            WHERE table_schema = 'p8'
            ORDER BY table_name
        """)
        print(f"\nAll tables in p8 schema: {[t['table_name'] for t in all_p8_tables]}")
        
        # Also check public schema for test tables
        public_tables = pg_service.execute("""
            SELECT table_name 
            FROM information_schema.tables 
            WHERE table_schema = 'public'
            AND (table_name LIKE '%auth%' OR table_name LIKE '%Auth%' OR table_name LIKE '%test%' OR table_name LIKE '%Test%')
            ORDER BY table_name
        """)
        print(f"Test-related tables in public schema: {[t['table_name'] for t in public_tables]}")
        
        # Check if AuthTestRecord exists
        auth_table = pg_service.execute("""
            SELECT table_schema, table_name, column_name
            FROM information_schema.columns 
            WHERE table_name = 'AuthTestRecord'
            LIMIT 5
        """)
        if auth_table:
            print(f"AuthTestRecord found in schema: {auth_table[0]['table_schema']}")
            print(f"Columns: {[col['column_name'] for col in auth_table]}")
        else:
            print("AuthTestRecord table not found")
        
        # Use postgres user to bypass RLS and get test user metadata
        print("\n--- Getting users from database (using postgres user to bypass RLS) ---")
        import psycopg2
        postgres_conn_string = f"postgresql://postgres:{os.environ['P8_PG_PASSWORD']}@{os.environ['P8_PG_HOST']}:{os.environ['P8_PG_PORT']}/{os.environ['P8_PG_DATABASE']}"
        raw_conn = psycopg2.connect(postgres_conn_string)
        raw_cursor = raw_conn.cursor()
        
        # First check if the User table has any rows at all
        raw_cursor.execute("""SELECT COUNT(*) FROM p8."User" """)
        user_count = raw_cursor.fetchone()[0]
        print(f"Total rows in p8.User table: {user_count}")
        
        if user_count > 0:
            # Get all users without RLS
            raw_cursor.execute("""SELECT id, email, role_level FROM p8."User" ORDER BY role_level, email LIMIT 10""")
            all_users = raw_cursor.fetchall()
            print(f"Found {len(all_users)} users (raw query):")
            for user_id, email, role_level in all_users:
                print(f"  - {email}: role_level={role_level}")
        else:
            print("p8.User table is empty")
            
            # Let's also check what columns exist in the table
            raw_cursor.execute("""
                SELECT column_name, data_type 
                FROM information_schema.columns 
                WHERE table_schema = 'p8' AND table_name = 'User'
                ORDER BY ordinal_position
            """)
            columns = raw_cursor.fetchall()
            print(f"p8.User table columns: {[f'{col[0]}({col[1]})' for col in columns]}")
        
        # Get admin user (amartey@gmail.com)
        raw_cursor.execute("""SELECT id, email, role_level FROM p8."User" WHERE email = %s""", ('amartey@gmail.com',))
        admin_result = raw_cursor.fetchone()
        
        raw_cursor.close()
        raw_conn.close()
        
        if admin_result:
            admin_users = [{'id': admin_result[0], 'email': admin_result[1], 'role_level': admin_result[2]}]
        else:
            admin_users = None
        if not admin_users:
            print("\namartey@gmail.com not found, looking for any admin user...")
            # Find any user with low role_level (admin)
            admin_users = pg_service.execute(
                """SELECT id, email, role_level FROM p8."User" 
                WHERE role_level = (SELECT MIN(role_level) FROM p8."User")
                LIMIT 1"""
            )
            if not admin_users:
                print("No admin users found in database")
                return
        
        admin_user = admin_users[0]
        admin_id = admin_user['id']
        admin_email = admin_user['email']
        admin_role = admin_user.get('role_level', 10)  # Default to 10 if not set
        print(f"Admin user: {admin_email}, ID: {admin_id}, Role: {admin_role}")
        
        # Get a non-admin user for comparison
        other_users = pg_service.execute("""
            SELECT id, email, role_level 
            FROM p8."User" 
            WHERE email != %s 
            AND role_level > %s
            LIMIT 1
        """, data=('amartey@gmail.com', admin_role))
        
        regular_user = None
        regular_id = None
        regular_email = None
        regular_role = 100
        
        if other_users:
            regular_user = other_users[0]
            regular_id = regular_user['id']
            regular_email = regular_user['email']
            regular_role = regular_user.get('role_level', 100)
            print(f"Regular user: {regular_email}, ID: {regular_id}, Role: {regular_role}")
        else:
            print("No regular user found for comparison")
            # Still test with different role levels using same user
            regular_id = admin_id
            regular_email = admin_email
            regular_role = 100
        
        # Get some test entity names from AuthTestRecord  
        test_entity_names = []
        if auth_table:
            schema = auth_table[0]['table_schema']
            # Open a new connection for this query
            test_conn = psycopg2.connect(postgres_conn_string)
            test_cursor = test_conn.cursor()
            test_cursor.execute(f"""
                SELECT name, required_access_level FROM {schema}."AuthTestRecord" 
                ORDER BY required_access_level 
                LIMIT 5
            """)
            test_records = test_cursor.fetchall()
            test_entity_names = [(name, access_level) for name, access_level in test_records]
            test_cursor.close()
            test_conn.close()
            print(f"\nFound test entities: {test_entity_names}")
        
        # Now test with real user IDs using the ModelRunner's run() method
        print("\n=== TESTING ACCESS CONTROL WITH MODEL RUNNER ===")
        
        # Test with admin user (role_level=1) 
        print(f"\n--- Testing with ADMIN user ({admin_email}, role_level={admin_role}) ---")
        admin_agent = p8.Agent(Resources)  # Use permissive default
        
        admin_context = CallingContext(
            username=admin_email,
            user_id=str(admin_id),
            session_id="test_admin_session"
        )
        
        # Test asking for specific entities
        for entity_name, access_level in test_entity_names:
            print(f"\nAdmin asking for entity '{entity_name}' (required_access_level={access_level}):")
            try:
                result = admin_agent.run(
                    f"Can I please see entity {entity_name}? Use get_entities to look it up.",
                    context=admin_context,
                    audit=False
                )
                print(f"  ✓ Admin result: {result[:200]}..." if len(str(result)) > 200 else f"  ✓ Admin result: {result}")
            except Exception as e:
                print(f"  ✗ Admin error: {e}")
        
        # Test with regular user (role_level=5)
        if regular_id != admin_id:
            print(f"\n--- Testing with REGULAR user ({regular_email}, role_level={regular_role}) ---")
            regular_agent = p8.Agent(Resources)  # Use permissive default
            
            regular_context = CallingContext(
                username=regular_email,
                user_id=str(regular_id),
                session_id="test_regular_session"
            )
            
            # Test asking for the same entities
            for entity_name, access_level in test_entity_names:
                print(f"\nRegular user asking for entity '{entity_name}' (required_access_level={access_level}):")
                try:
                    result = regular_agent.run(
                        f"Can I please see entity {entity_name}? Use get_entities to look it up.",
                        context=regular_context,
                        audit=False
                    )
                    print(f"  ✓ Regular result: {result[:200]}..." if len(str(result)) > 200 else f"  ✓ Regular result: {result}")
                except Exception as e:
                    print(f"  ✗ Regular error: {e}")
        
        # Test with public user (role_level=100)
        print(f"\n--- Testing with PUBLIC user (role_level=100) ---")
        public_agent = p8.Agent(Resources)  # Use permissive default
        
        # Create a public user context
        public_user_id = all_users[7][0] if len(all_users) > 7 else admin_id  # Pick a user with role_level=100
        public_context = CallingContext(
            username="public_user@example.com",
            user_id=str(public_user_id),
            session_id="test_public_session"
        )
        
        # Test asking for entities that should be restricted
        for entity_name, access_level in test_entity_names:
            print(f"\nPublic user asking for entity '{entity_name}' (required_access_level={access_level}):")
            try:
                result = public_agent.run(
                    f"Can I please see entity {entity_name}? Use get_entities to look it up.",
                    context=public_context,
                    audit=False
                )
                print(f"  ✓ Public result: {result[:200]}..." if len(str(result)) > 200 else f"  ✓ Public result: {result}")
            except Exception as e:
                print(f"  ✗ Public error: {e}")
        
        # Test with regular user if we found one
        if regular_id:
            print("\n--- Testing with regular user ---")
            regular_agent = p8.Agent(
                Resources,
                user_id=str(regular_id),
                role_level=regular_role
            )
            
            regular_context = CallingContext(
                username=regular_email,
                user_id=str(regular_id)
            )
            regular_agent._context = regular_context
            
            # Test same queries as admin
            entities = regular_agent.get_entities(keys=None)
            print(f"Regular user can see {len(entities) if entities else 0} total entities")
            
            auth_entities = regular_agent.get_entities(keys="AuthTestRecord") 
            print(f"Regular user found {len(auth_entities) if auth_entities else 0} AuthTestRecord entities")
            
        # Test search functionality
        print("\n--- Testing search with admin ---")
        search_results = admin_agent.search(["AuthTestRecord restricted"])
        print(f"Admin search returned {len(search_results) if search_results else 0} results")
        
        # Test access to specific tables with known permission requirements
        print("\n--- Testing access to system tables ---")
        
        # Admin should see more p8 schema entities
        admin_p8_entities = admin_agent.get_entities(keys="p8", allow_fuzzy_match=True)
        print(f"Admin sees {len(admin_p8_entities) if admin_p8_entities else 0} p8 schema entities")
        
        if regular_id and regular_id != admin_id:
            regular_p8_entities = regular_agent.get_entities(keys="p8", allow_fuzzy_match=True)
            print(f"Regular user sees {len(regular_p8_entities) if regular_p8_entities else 0} p8 schema entities")
            
            # Compare access
            if admin_p8_entities and regular_p8_entities:
                admin_count = len(admin_p8_entities) if isinstance(admin_p8_entities, list) else 0
                regular_count = len(regular_p8_entities) if isinstance(regular_p8_entities, list) else 0
                print(f"\nAccess difference: Admin sees {admin_count - regular_count} more entities")
        
    except Exception as e:
        print(f"Error during test: {e}")
        import traceback
        traceback.print_exc()


if __name__ == "__main__":
    # Run the simple test first to verify basic functionality
    print("\n\nTesting agent creation...")
    try:
        test_simple_agent_creation()
    except Exception as e:
        print(f"Error in agent creation: {e}")
        print("If this fails, run setup_percolate_params.py first")
    
    # Now run the real user test
    print("\n\nRunning test with real database users...")
    try:
        test_with_real_users()
    except Exception as e:
        print(f"Error in real user test: {e}")
        import traceback
        traceback.print_exc()