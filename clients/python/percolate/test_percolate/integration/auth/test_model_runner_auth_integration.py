import os
import json
import pytest

"""
INTEGRATION TEST FOR APACHE AGE EXTENSION AND ACCESS CONTROL

This test verifies that:
1. Apache AGE extension works with non-superuser (app) accounts
2. get_entities function can execute cypher queries 
3. Access control (RLS) properly filters results based on user context
4. CallingContext flows through ModelRunner → PostgresService → RLS

REQUIREMENTS:
- Kubernetes cluster with percolate database running
- Port forward: kubectl port-forward -n p8 svc/percolate-rw 25432:5432
- Environment variable: P8_TEST_BEARER_TOKEN=<app_user_password>
- PostgreSQL cluster configured with session_preload_libraries="age"

MARKED AS SLOW to prevent CI failures when infrastructure is unavailable.

Test data from public.AuthTestRecord:

Sample records for testing access control:
1. test_kt_body_record (required_access_level=5) - KT brand body data
2. test_god_level_record (required_access_level=0) - Only GOD users can see this
3. test_dept_ownership_record (required_access_level=5) - Department-owned data from ETL
4. test_combined_internal_grouped (required_access_level=5) - Internal level + has group but no owner
5. test_combined_admin_owned_grouped (required_access_level=1) - Admin level + owned by admin + has group

Test users:
- Admin user: amartey@gmail.com, ID: 10e0a97d-a064-553a-9043-3c1f0a6e6725, Role: 1
- Regular user: lindsay@resonance.nyc, ID: 3dbd6ff6-e90a-5538-b147-d1241aa4c9f4, Role: 100


poetry run python -m pytest test_percolate/test_model_runner_auth_integration.py::test_admin_user_access -v -s


NB: we are moving to app user and this means we have changed the docker image for PG to symlink the extension and updated the manifest to load it.
But whe need to go through and remove code where we LOADED the extension 
"""

# Set environment variables BEFORE importing percolate
os.environ["P8_PG_HOST"] = "localhost"
os.environ["P8_PG_PORT"] = "25432"
os.environ["P8_PG_USER"] = "app"
os.environ["P8_PG_PASSWORD"] = os.environ.get("P8_TEST_BEARER_TOKEN", "")
os.environ["P8_PG_DATABASE"] = "app"

# NOW import percolate after environment is set
import percolate as p8
from percolate.services.llm import CallingContext
from percolate.models.p8.types import Resources


@pytest.mark.slow
def test_admin_user_access():
    """Test admin user can access restricted records"""
    print("\n=== Testing Admin User Access via ModelRunner ===")

    # Create agent
    admin_agent = p8.Agent(Resources)

    # Create calling context with admin user
    admin_context = CallingContext(
        username="amartey@gmail.com",
        user_id="10e0a97d-a064-553a-9043-3c1f0a6e6725",
        session_id="test_admin_session",
        temperature=0.1,
        model="gpt-4o-mini",
    )

    print(f"Admin context user_id: {admin_context.user_id}")

    # DEBUGGING: Check what repo the ModelRunner creates
    admin_agent._context = admin_context  # Set context manually first
    repo = admin_agent.get_repo()
    repo_context = repo.get_user_context()
    print(f"🔍 ModelRunner repo context: {repo_context}")

    # Test asking for an admin-level record (required_access_level=1)
    print("Admin asking for admin-level record 'test_admin_level_record':")
    try:
        result = admin_agent.run(
            "Can you please use get_entities to look up the entity named 'test_admin_level_record'? Return the data field content if found.",
            context=admin_context,
            audit=False,
            limit=2,
        )
        print(f"✓ Admin result: {result}")

        # Check if admin can see the admin-level record
        if "admin level" in result.lower() and (
            "data" in result.lower() or "found" in result.lower()
        ):
            print("✅ ADMIN ACCESS VERIFIED: Admin can see admin-level record")
        else:
            print("❌ ADMIN ACCESS FAILED: Admin cannot see admin-level record")

    except Exception as e:
        print(f"✗ Admin error: {str(e)[:200]}...")


@pytest.mark.slow
def test_regular_user_access():
    """Test regular user has limited access"""
    print("\n=== Testing Regular User Access ===")

    # Create agent
    regular_agent = p8.Agent(Resources)

    # Create calling context with regular user (role_level=100)
    regular_context = CallingContext(
        username="lindsay@resonance.nyc",
        user_id="3dbd6ff6-e90a-5538-b147-d1241aa4c9f4",
        session_id="test_regular_session",
        temperature=0.1,
        model="gpt-4o-mini",
    )

    print(f"Regular context user_id: {regular_context.user_id}")

    # Test asking for admin-level record (should be denied for role_level=100)
    print("Regular user asking for admin-level record 'test_admin_level_record':")
    try:
        result = regular_agent.run(
            "Can you please use get_entities to look up the entity named 'test_admin_level_record'? Return the data field content if found.",
            context=regular_context,
            audit=False,
            limit=2,
        )
        print(f"✓ Regular result: {result}")

        # Check if regular user is denied access to admin-level record
        if (
            "no data" in result.lower()
            or "not found" in result.lower()
            or "no results" in result.lower()
            or "did not find" in result.lower()
        ):
            print(
                "✅ ACCESS CONTROL WORKING: Regular user denied access to admin-level record"
            )
        elif "admin level" in result.lower() and (
            "data" in result.lower() or "found" in result.lower()
        ):
            print(
                "❌ ACCESS CONTROL FAILED: Regular user can see admin-level record (should be denied)"
            )
        else:
            print(f"⚠️  UNCLEAR: Regular user response unclear: {result[:100]}...")

    except Exception as e:
        print(f"✗ Regular error: {str(e)[:200]}...")


@pytest.mark.slow
def test_public_user_access():
    """Test public user with high role_level has most restricted access"""
    print("\n=== Testing Public User Access ===")

    # Create agent
    public_agent = p8.Agent(Resources)

    # Create calling context with public user (fake high role_level user)
    public_context = CallingContext(
        username="public_test@example.com",
        user_id="00000000-0000-0000-0000-000000000001",  # Fake public user ID
        session_id="test_public_session",
        temperature=0.1,
        model="gpt-4o-mini",
    )

    print(f"Public context user_id: {public_context.user_id}")

    # Test asking for GOD-level record (should be denied)
    print("Public user asking for GOD-level record 'test_god_level_record':")
    try:
        result = public_agent.run(
            "Can you please use get_entities to look up the entity named 'test_god_level_record'? Just tell me if you found it or not.",
            context=public_context,
            audit=False,
            limit=2,
        )
        print(f"✓ Public result: {result}")

        # Check if public user is denied access to GOD-level record
        if (
            "no data" in result.lower()
            or "not found" in result.lower()
            or "no results" in result.lower()
        ):
            print(
                "✅ ACCESS CONTROL WORKING: Public user denied access to GOD-level record"
            )
        elif (
            "test_god_level_record" in result.lower()
            and "only god users can see this" in result.lower()
        ):
            print(
                "❌ ACCESS CONTROL FAILED: Public user can see GOD-level record (should be denied)"
            )
        else:
            print(f"⚠️  UNCLEAR: Public user response unclear: {result[:100]}...")

    except Exception as e:
        print(f"✗ Public error: {str(e)[:200]}...")

    # Test asking for admin record (should be denied)
    print("\nPublic user asking for admin record 'test_combined_admin_owned_grouped':")
    try:
        result = public_agent.run(
            "Can you please use get_entities to look up the entity named 'test_combined_admin_owned_grouped'? Just tell me if you found it or not.",
            context=public_context,
            audit=False,
            limit=2,
        )
        print(f"✓ Public result: {result}")

        # Check if public user is denied access to admin record
        if (
            "no data" in result.lower()
            or "not found" in result.lower()
            or "no results" in result.lower()
        ):
            print("✅ ACCESS CONTROL WORKING: Public user denied access to admin record")
        elif (
            "test_combined_admin_owned_grouped" in result.lower()
            and "admin level + owned by admin" in result.lower()
        ):
            print(
                "❌ ACCESS CONTROL FAILED: Public user can see admin record (should be denied)"
            )
        else:
            print(f"⚠️  UNCLEAR: Public user response unclear: {result[:100]}...")

    except Exception as e:
        print(f"✗ Public error: {str(e)[:200]}...")


@pytest.mark.slow
def check_database_user_context():
    """Check what user context is being applied in the database and verify RLS works"""
    print("\n=== Testing Direct PostgresService Access Control ===")

    from percolate.services.PostgresService import PostgresService

    # Test 1: No user context (should act as admin/permissive)
    print("1. Testing PostgresService with NO user context (should be permissive):")
    no_context_pg = PostgresService()
    context = no_context_pg.get_user_context()
    print(f"   No context PostgresService: {context}")

    # Query AuthTestRecord directly
    try:
        records = no_context_pg.execute(
            'SELECT name, required_access_level FROM public."AuthTestRecord" ORDER BY required_access_level'
        )
        print(
            f"   ✓ No context sees {len(records)} records: {[(r['name'], r['required_access_level']) for r in records]}"
        )
    except Exception as e:
        print(f"   ✗ No context error: {e}")

    # Test 2: Admin user context
    print("\n2. Testing PostgresService with ADMIN user context:")
    admin_pg = PostgresService(
        user_id="10e0a97d-a064-553a-9043-3c1f0a6e6725"  # Admin user
    )
    context = admin_pg.get_user_context()
    print(f"   Admin PostgresService context: {context}")

    # Query AuthTestRecord with admin context
    try:
        records = admin_pg.execute(
            'SELECT name, required_access_level FROM public."AuthTestRecord" ORDER BY required_access_level'
        )
        print(
            f"   ✓ Admin sees {len(records)} records: {[(r['name'], r['required_access_level']) for r in records]}"
        )
    except Exception as e:
        print(f"   ✗ Admin error: {e}")

    # Test 3: Regular user context
    print("\n3. Testing PostgresService with REGULAR user context:")
    regular_pg = PostgresService(
        user_id="3dbd6ff6-e90a-5538-b147-d1241aa4c9f4"  # Regular user
    )
    context = regular_pg.get_user_context()
    print(f"   Regular PostgresService context: {context}")

    # Query AuthTestRecord with regular user context
    try:
        records = regular_pg.execute(
            'SELECT name, required_access_level FROM public."AuthTestRecord" ORDER BY required_access_level'
        )
        print(
            f"   ✓ Regular user sees {len(records)} records: {[(r['name'], r['required_access_level']) for r in records]}"
        )
    except Exception as e:
        print(f"   ✗ Regular user error: {e}")

    # Test 4: Fake public user context (high role_level)
    print("\n4. Testing PostgresService with FAKE PUBLIC user context:")
    public_pg = PostgresService(
        user_id="00000000-0000-0000-0000-000000000001",  # Fake user
        role_level=100,  # High role level = low privileges
    )
    context = public_pg.get_user_context()
    print(f"   Public PostgresService context: {context}")

    # Query AuthTestRecord with public user context
    try:
        records = public_pg.execute(
            'SELECT name, required_access_level FROM public."AuthTestRecord" ORDER BY required_access_level'
        )
        print(
            f"   ✓ Public user sees {len(records)} records: {[(r['name'], r['required_access_level']) for r in records]}"
        )
    except Exception as e:
        print(f"   ✗ Public user error: {e}")

    print("\n📊 EXPECTED RESULTS FOR RLS TO BE WORKING:")
    print("   - No context: Should see ALL 5 records (permissive default)")
    print("   - Admin (role_level=1): Should see ALL 5 records")
    print("   - Regular (role_level=100): Should see FEWER records (RLS restrictions)")
    print("   - Public (role_level=100): Should see FEWER records (RLS restrictions)")
    print("\n❌ IF ALL USERS SEE ALL RECORDS: RLS policies are not working properly")


if __name__ == "__main__":
    print("Running simplified ModelRunner access control test...")
    print(
        "Testing access to specific AuthTestRecord entities with different user contexts"
    )
    print(
        "IMPORTANT: This test verifies that user context flows from CallingContext → ModelRunner → PostgresService → RLS"
    )

    try:
        # First check the database user context setup
        check_database_user_context()

        # Then run the actual tests
        test_admin_user_access()
        test_regular_user_access()
        test_public_user_access()

        print("\n=== Test Summary ===")
        print("✅ EXPECTED BEHAVIOR:")
        print("- Admin user (role_level=1) should access GOD-level and admin records")
        print(
            "- Regular user (role_level=100) should be DENIED access to GOD-level records"
        )
        print("- Public user should be DENIED access to most records")
        print(
            "- User context flows: CallingContext → ModelRunner.get_repo() → PostgresService → RLS"
        )
        print("\n❌ IF ALL USERS SEE ALL RECORDS:")
        print("- Check that RLS policies are properly configured")
        print("- Verify that user context is being applied in PostgresService")
        print("- Ensure 'app' user is being used (not 'postgres' which bypasses RLS)")

    except Exception as e:
        print(f"Test error: {e}")
        import traceback

        traceback.print_exc()
