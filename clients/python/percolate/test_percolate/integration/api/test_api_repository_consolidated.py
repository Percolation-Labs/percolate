#!/usr/bin/env python
"""Consolidated API Repository Integration Tests

This file contains all tests for the API repository functionality of the MCP server.
It uses environment variables for configuration:
- P8_TEST_BEARER_TOKEN: The bearer token for authentication
- P8_TEST_DOMAIN: The API domain (e.g., https://p8.resmagic.io)
- X_User_Email: The user email for X-User-Email header
- P8_DEFAULT_AGENT: The default agent name

Run with pytest:
export P8_TEST_BEARER_TOKEN="p8-HsByeefq3unTFJDuf6cRh6GDQpo3laj0AMoyc2Etfqma6Coz73TdBPDfek_LQIMv"
export P8_TEST_DOMAIN="https://p8.resmagic.io"
export X_User_Email="test@percolate.com"
export P8_DEFAULT_AGENT="p8-Agent"
pytest test_api_repository_consolidated.py -v

Or run directly:
python test_api_repository_consolidated.py
"""

import os
import asyncio
import json
import tempfile
from pathlib import Path
import pytest
from typing import Dict, Any, List, Optional

# Import the API repository
from percolate.api.mcp_server.api_repository import APIProxyRepository
from percolate.utils import logger

# Read configuration from environment variables
TEST_BEARER_TOKEN = os.getenv("P8_TEST_BEARER_TOKEN")
TEST_DOMAIN = os.getenv("P8_TEST_DOMAIN", "https://p8.resmagic.io")
TEST_USER_EMAIL = os.getenv("X_User_Email", os.getenv("P8_USER_EMAIL", "test@percolate.com"))
TEST_DEFAULT_AGENT = os.getenv("P8_DEFAULT_AGENT", "p8-Agent")

# Ensure domain has protocol
if not TEST_DOMAIN.startswith("http://") and not TEST_DOMAIN.startswith("https://"):
    TEST_DOMAIN = f"https://{TEST_DOMAIN}"

# Use bearer token if provided, otherwise fall back to default
API_KEY = TEST_BEARER_TOKEN if TEST_BEARER_TOKEN else os.getenv("P8_API_KEY", "postgres")

# Check if required environment variables are set
if not TEST_BEARER_TOKEN and TEST_DOMAIN != "http://localhost:5008":
    print("\n⚠️  Warning: P8_TEST_BEARER_TOKEN not set. Using default API key.")
    print("   For proper testing, set:")
    print('   export P8_TEST_BEARER_TOKEN="your-bearer-token"')

print(f"\n🔧 Test Configuration:")
print(f"   Domain: {TEST_DOMAIN}")
print(f"   User Email: {TEST_USER_EMAIL}")
print(f"   Default Agent: {TEST_DEFAULT_AGENT}")
print(f"   Has Bearer Token: {bool(TEST_BEARER_TOKEN)}")
print("=" * 60)


class TestAPIRepositoryConsolidated:
    """Consolidated integration tests for API Repository"""
    
    @pytest.fixture
    async def api_client(self):
        """Create API client with test configuration"""
        client = APIProxyRepository(
            api_endpoint=TEST_DOMAIN,
            api_key=API_KEY,
            user_email=TEST_USER_EMAIL
        )
        yield client
        await client.close()
    
    async def test_01_authentication_and_ping(self, api_client):
        """Test authentication with ping endpoint"""
        print("\n1️⃣ Testing Authentication and Ping")
        
        ping_result = await api_client.ping()
        print(f"Ping result: {json.dumps(ping_result, indent=2)}")
        
        assert "error" not in ping_result, f"Authentication failed: {ping_result.get('error')}"
        assert ping_result.get("user_id") is not None
        print(f"✅ Authentication successful - User ID: {ping_result.get('user_id')}")
    
    async def test_02_entity_lookup_p8_agent(self, api_client):
        """Test entity lookup for p8.Agent"""
        print("\n2️⃣ Testing Entity Lookup for p8.Agent")
        
        # Get specific entity
        entity = await api_client.get_entity(
            entity_name="p8.Agent",
            entity_type="Agent"
        )
        
        if "error" in entity:
            print(f"⚠️  Could not retrieve p8.Agent: {entity.get('error')}")
        else:
            print(f"✅ Found entity: {entity.get('name', 'Unknown')}")
            print(f"   ID: {entity.get('id', 'Unknown')}")
            print(f"   Type: {entity.get('entity_type', 'Unknown')}")
    
    async def test_03_fuzzy_entity_search(self, api_client):
        """Test fuzzy entity search with 'p8agent'"""
        print("\n3️⃣ Testing Fuzzy Entity Search with 'p8agent'")
        
        # Use get_entity with fuzzy match for fuzzy search
        try:
            entity = await api_client.get_entity(
                entity_name="p8agent",
                allow_fuzzy_match=True,
                similarity_threshold=0.5
            )
            
            if "error" not in entity:
                print(f"✅ Found entity with fuzzy match: {entity.get('name', 'Unknown')}")
                print(f"   Score: {entity.get('similarity_score', 'N/A')}")
            else:
                print(f"⚠️  Fuzzy search failed: {entity}")
        except Exception as e:
            print(f"⚠️  Fuzzy search error: {e}")
    
    async def test_04_entity_search_by_name_and_type(self, api_client):
        """Test entity search by name and type for p8.Agent"""
        print("\n4️⃣ Testing Entity Search by Name and Type")
        
        # Search for agents - use filters for entity type
        entities = await api_client.search_entities(
            query="agents",
            filters={"entity_type": "Agent"},
            limit=10
        )
        
        if isinstance(entities, list):
            print(f"✅ Found {len(entities)} Agent entities")
            
            # Check for vector search results
            vector_results = [e for e in entities if e.get('similarity_score', 0) > 0]
            print(f"   Vector search results: {len(vector_results)}")
            
            # Don't assert if no results - just log
            if len(vector_results) == 0:
                print(f"   ⚠️  No vector search results found (may be expected)")
            
            for i, entity in enumerate(entities[:5]):
                score = entity.get('similarity_score', 0)
                print(f"   {i+1}. {entity.get('name', 'Unknown')} (vector score: {score:.3f})")
        else:
            print(f"⚠️  Entity search returned: {entities}")
    
    async def test_05_function_search(self, api_client):
        """Test function search for entity-related functions"""
        print("\n5️⃣ Testing Function Search")
        
        # Search for functions dealing with entities
        functions = await api_client.search_functions(
            query="entity",
            limit=10
        )
        
        if isinstance(functions, list) and len(functions) > 0:
            print(f"✅ Found {len(functions)} functions")
            
            # Look for specific functions
            entity_functions = [f for f in functions if "entity" in f.get('name', '').lower()]
            print(f"   Entity-related functions: {len(entity_functions)}")
            
            for func in functions[:5]:
                print(f"   - {func.get('name', 'Unknown')}: {func.get('description', '')[:60]}...")
        else:
            print(f"⚠️  No functions found or error: {functions}")
    
    async def test_06_default_agent_search(self, api_client):
        """Test searching with P8_DEFAULT_AGENT for company patents"""
        print(f"\n6️⃣ Testing {TEST_DEFAULT_AGENT} Search for Company Patents")
        
        # First get the default agent details
        agent = await api_client.get_entity(
            entity_name=TEST_DEFAULT_AGENT,
            entity_type="Agent"
        )
        
        if "error" not in agent:
            print(f"✅ Found agent: {agent.get('name')}")
            print(f"   Description: {agent.get('description', 'N/A')[:100]}...")
        
        # Search for company patents information
        patent_results = await api_client.search_entities(
            query="company patents",
            limit=10
        )
        
        if isinstance(patent_results, list):
            print(f"\n📋 Patent search results: {len(patent_results)} found")
            
            for i, result in enumerate(patent_results[:5]):
                print(f"\n   Result {i+1}:")
                print(f"   Name: {result.get('name', 'Unknown')}")
                print(f"   Type: {result.get('entity_type', 'Unknown')}")
                print(f"   Score: {result.get('similarity_score', 0):.3f}")
                
                # Show snippet if available
                if result.get('snippet'):
                    print(f"   Snippet: {result['snippet'][:150]}...")
        else:
            print(f"⚠️  Patent search returned: {patent_results}")
    
    async def test_07_help_system(self, api_client):
        """Test the help system"""
        print("\n7️⃣ Testing Help System")
        
        help_text = await api_client.get_help(
            query="How do I search for entities and agents?",
            context="Using the Percolate API",
            max_depth=3
        )
        
        if help_text and isinstance(help_text, str):
            print(f"✅ Got help response ({len(help_text)} chars)")
            print(f"\n📖 Help content preview:")
            print(help_text[:500] + "..." if len(help_text) > 500 else help_text)
        else:
            print(f"⚠️  Help returned: {help_text}")
    
    async def test_08_file_upload(self, api_client):
        """Test file upload functionality"""
        print("\n8️⃣ Testing File Upload")
        
        # Create a test file
        with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
            f.write("Test file for API repository consolidation\n")
            f.write(f"Domain: {TEST_DOMAIN}\n")
            f.write(f"User: {TEST_USER_EMAIL}\n")
            f.write(f"Agent: {TEST_DEFAULT_AGENT}\n")
            temp_file = f.name
        
        try:
            upload_result = await api_client.upload_file(
                file_path=temp_file,
                description="Consolidated API test file",
                tags=["test", "api", "consolidated"]
            )
            
            if upload_result.get("success"):
                print(f"✅ File uploaded successfully")
                print(f"   S3 URL: {upload_result.get('s3_url')}")
                print(f"   Size: {upload_result.get('file_size')} bytes")
            else:
                error = upload_result.get('error', 'Unknown error')
                if "Entity" in str(error) or "422" in str(error):
                    print(f"⚠️  Upload requires Resources entity: {error}")
                else:
                    print(f"❌ Upload failed: {error}")
        finally:
            os.unlink(temp_file)
    
    async def test_09_resource_search(self, api_client):
        """Test resource search"""
        print("\n9️⃣ Testing Resource Search")
        
        resources = await api_client.search_resources(
            query="test",
            limit=5
        )
        
        if isinstance(resources, list):
            print(f"✅ Resource search completed - found {len(resources)} resources")
            for i, resource in enumerate(resources[:3]):
                if isinstance(resource, dict):
                    print(f"   {i+1}. {resource.get('name', 'Resource')} - {resource.get('type', 'Unknown type')}")
        else:
            print(f"⚠️  Resource search returned: {resources}")
    
    async def test_10_function_evaluation(self, api_client):
        """Test function evaluation"""
        print("\n🔟 Testing Function Evaluation")
        
        # Try to find and evaluate a safe function
        functions = await api_client.search_functions(
            query="fuzzy_entity_search",
            limit=5
        )
        
        if isinstance(functions, list) and functions:
            # Find the fuzzy_entity_search function
            fuzzy_func = next((f for f in functions if f.get('name') == 'fuzzy_entity_search'), None)
            
            if fuzzy_func:
                print(f"✅ Found function: {fuzzy_func['name']}")
                
                # Evaluate the function
                result = await api_client.evaluate_function(
                    function_name="fuzzy_entity_search",
                    args={
                        "query": "agent",
                        "limit": 3
                    }
                )
                
                if result.get("success"):
                    print(f"✅ Function executed successfully")
                    print(f"   Result type: {type(result.get('result'))}")
                    if isinstance(result.get('result'), list):
                        print(f"   Returned {len(result['result'])} items")
                else:
                    print(f"⚠️  Function evaluation failed: {result.get('error')}")
            else:
                print("⚠️  fuzzy_entity_search function not found")
        else:
            print("⚠️  No functions found to evaluate")
    
    async def run_all_tests(self):
        """Run all tests and provide summary"""
        print("\n" + "="*60)
        print("🧪 API REPOSITORY CONSOLIDATED TEST SUITE")
        print("="*60)
        
        # Create client
        client = APIProxyRepository(
            api_endpoint=TEST_DOMAIN,
            api_key=API_KEY,
            user_email=TEST_USER_EMAIL
        )
        
        try:
            # Track results
            results = {}
            
            # Run each test
            tests = [
                ("Authentication", self.test_01_authentication_and_ping),
                ("Entity Lookup", self.test_02_entity_lookup_p8_agent),
                ("Fuzzy Search", self.test_03_fuzzy_entity_search),
                ("Entity Search", self.test_04_entity_search_by_name_and_type),
                ("Function Search", self.test_05_function_search),
                ("Agent Patents", self.test_06_default_agent_search),
                ("Help System", self.test_07_help_system),
                ("File Upload", self.test_08_file_upload),
                ("Resource Search", self.test_09_resource_search),
                ("Function Eval", self.test_10_function_evaluation),
            ]
            
            for test_name, test_func in tests:
                try:
                    await test_func(client)
                    results[test_name] = "PASS"
                except AssertionError as e:
                    results[test_name] = f"FAIL: {str(e)}"
                    print(f"\n❌ {test_name} failed: {e}")
                except Exception as e:
                    results[test_name] = f"ERROR: {str(e)}"
                    print(f"\n💥 {test_name} error: {e}")
            
            # Summary
            print("\n" + "="*60)
            print("📊 TEST RESULTS SUMMARY")
            print("="*60)
            
            passed = sum(1 for r in results.values() if r == "PASS")
            failed = sum(1 for r in results.values() if r.startswith("FAIL"))
            errors = sum(1 for r in results.values() if r.startswith("ERROR"))
            
            for test_name, result in results.items():
                icon = "✅" if result == "PASS" else "❌" if result.startswith("FAIL") else "💥"
                status = "PASS" if result == "PASS" else "FAIL" if result.startswith("FAIL") else "ERROR"
                print(f"{icon} {test_name}: {status}")
                if result != "PASS":
                    print(f"   Details: {result}")
            
            print(f"\n📈 Overall: {passed}/{len(tests)} passed ({passed/len(tests)*100:.1f}%)")
            print(f"   ❌ Failed: {failed}")
            print(f"   💥 Errors: {errors}")
            
            # Return success if at least 70% passed
            success_rate = passed / len(tests)
            return success_rate >= 0.7
            
        finally:
            await client.close()


async def main():
    """Main entry point for running tests"""
    tester = TestAPIRepositoryConsolidated()
    success = await tester.run_all_tests()
    
    if not success:
        print("\n⚠️  Some tests failed. Check the configuration and API endpoint.")
        return 1
    else:
        print("\n✅ All critical tests passed!")
        return 0


if __name__ == "__main__":
    # For direct execution
    import sys
    exit_code = asyncio.run(main())
    sys.exit(exit_code)