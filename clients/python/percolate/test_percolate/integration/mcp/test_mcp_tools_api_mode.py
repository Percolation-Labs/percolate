#!/usr/bin/env python
"""Full integration test for MCP tools in API mode (default for DXT)"""

import os
import asyncio
import tempfile
from pathlib import Path
import pytest
from fastmcp.client import Client, PythonStdioTransport
from percolate.utils import logger

# Test configuration - this simulates DXT environment
API_ENDPOINT = os.getenv("P8_API_ENDPOINT", "http://localhost:5008")
API_KEY = "postgres"  # Use postgres token for localhost testing
USER_EMAIL = os.getenv("X-User-Email", os.getenv("P8_USER_EMAIL", "test@percolate.ai"))


@pytest.mark.integration
class TestMCPToolsAPIMode:
    """Test all MCP tools in API mode (default DXT configuration)"""
    
    async def test_all_mcp_tools(self):
        """Test all MCP tools via stdio transport in API mode"""
        print("\n🚀 Testing MCP Tools in API Mode (DXT Default)")
        print(f"   API Endpoint: {API_ENDPOINT}")
        print(f"   Using token: {API_KEY[:10]}...")
        print(f"   User email: {USER_EMAIL}")
        print("=" * 60)
        
        # Set up environment for API mode
        env = os.environ.copy()
        env.update({
            "P8_USE_API_MODE": "true",  # Force API mode (default for DXT)
            "P8_API_ENDPOINT": API_ENDPOINT,
            "P8_API_KEY": API_KEY,
            "X-User-Email": USER_EMAIL,
            "P8_MCP_DESKTOP_EXT": "true",  # Simulate DXT environment
            "P8_LOG_LEVEL": "INFO"
        })
        
        # Create transport
        runner_script = Path(__file__).parent.parent.parent / "api" / "mcp_server" / "tests" / "run_server.py"
        if not runner_script.exists():
            # Try alternate path
            runner_script = Path("percolate/api/mcp_server/tests/run_server.py")
        
        transport = PythonStdioTransport(
            script_path=runner_script,
            env=env
        )
        
        # Track results
        results = {}
        
        # Use client as context manager
        async with Client(transport=transport) as client:
            print("✅ Connected to MCP server in API mode")
            
            # 1. Test get_entity
            print("\n1️⃣ Testing get_entity tool...")
            try:
                result = await client.call_tool(
                    "get_entity",
                    {
                        "params": {
                            "entity_id": "96d1a2ff-045b-55cc-a7de-543d1d3cccf8",
                            "entity_type": "Agent"
                        }
                    }
                )
                
                data = result.structured_content.get('result') if hasattr(result, 'structured_content') else result.data
                
                if isinstance(data, dict) and "error" not in data:
                    print(f"   ✅ SUCCESS: Retrieved entity '{data.get('name', 'Unknown')}'")
                    results['get_entity'] = 'PASS'
                else:
                    print(f"   ❌ FAILED: {data}")
                    results['get_entity'] = 'FAIL'
            except Exception as e:
                print(f"   ❌ ERROR: {str(e)}")
                results['get_entity'] = 'ERROR'
            
            # 2. Test entity_search
            print("\n2️⃣ Testing entity_search tool...")
            try:
                result = await client.call_tool(
                    "entity_search",
                    {
                        "params": {
                            "query": "agent",
                            "limit": 5
                        }
                    }
                )
                
                data = result.structured_content.get('result') if hasattr(result, 'structured_content') else result.data
                
                if isinstance(data, list) and len(data) > 0:
                    print(f"   ✅ SUCCESS: Found {len(data)} entities")
                    for i, entity in enumerate(data[:3]):
                        print(f"      - {entity.get('name', f'Entity {i+1}')}")
                    results['entity_search'] = 'PASS'
                else:
                    print(f"   ❌ FAILED: No entities found")
                    results['entity_search'] = 'FAIL'
            except Exception as e:
                print(f"   ❌ ERROR: {str(e)}")
                results['entity_search'] = 'ERROR'
            
            # 3. Test function_search
            print("\n3️⃣ Testing function_search tool...")
            try:
                result = await client.call_tool(
                    "function_search",
                    {
                        "params": {
                            "query": "pet",
                            "limit": 5
                        }
                    }
                )
                
                data = result.structured_content.get('result') if hasattr(result, 'structured_content') else result.data
                
                if isinstance(data, list) and len(data) > 0:
                    print(f"   ✅ SUCCESS: Found {len(data)} functions")
                    for func in data[:3]:
                        print(f"      - {func.get('name', 'Unknown function')}")
                    results['function_search'] = 'PASS'
                else:
                    print(f"   ❌ FAILED: No functions found")
                    results['function_search'] = 'FAIL'
            except Exception as e:
                print(f"   ❌ ERROR: {str(e)}")
                results['function_search'] = 'ERROR'
            
            # 4. Test function_eval
            print("\n4️⃣ Testing function_eval tool...")
            try:
                result = await client.call_tool(
                    "function_eval",
                    {
                        "params": {
                            "function_name": "get_pet_findByStatus",
                            "args": {"status": "available"}
                        }
                    }
                )
                
                data = result.structured_content.get('result') if hasattr(result, 'structured_content') else result.data
                
                if isinstance(data, dict) and data.get("success"):
                    print(f"   ✅ SUCCESS: Function executed")
                    if isinstance(data.get("result"), list):
                        print(f"      - Returned {len(data['result'])} items")
                    results['function_eval'] = 'PASS'
                else:
                    print(f"   ❌ FAILED: {data.get('error', 'Unknown error')}")
                    results['function_eval'] = 'FAIL'
            except Exception as e:
                print(f"   ❌ ERROR: {str(e)}")
                results['function_eval'] = 'ERROR'
            
            # 5. Test help tool
            print("\n5️⃣ Testing help tool...")
            try:
                result = await client.call_tool(
                    "help",
                    {
                        "params": {
                            "query": "How do I create an agent in Percolate?",
                            "context": "MCP development",
                            "max_depth": 2
                        }
                    }
                )
                
                data = result.structured_content.get('result') if hasattr(result, 'structured_content') else result.data
                
                if isinstance(data, str) and len(data) > 0:
                    print(f"   ✅ SUCCESS: Got help response ({len(data)} chars)")
                    print(f"      Preview: {data[:100]}...")
                    results['help'] = 'PASS'
                else:
                    print(f"   ❌ FAILED: No help text returned")
                    results['help'] = 'FAIL'
            except Exception as e:
                print(f"   ❌ ERROR: {str(e)}")
                results['help'] = 'ERROR'
            
            # 6. Test file_upload tool
            print("\n6️⃣ Testing file_upload tool...")
            try:
                # Create a temporary test file
                with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
                    f.write("This is a test file for MCP tools integration.\n")
                    f.write(f"MCP API Mode Test\n")
                    f.write(f"Endpoint: {API_ENDPOINT}\n")
                    f.write(f"Time: {asyncio.get_event_loop().time()}\n")
                    temp_file = f.name
                
                try:
                    result = await client.call_tool(
                        "file_upload",
                        {
                            "params": {
                                "file_path": temp_file,
                                "description": "MCP tools integration test file",
                                "tags": ["test", "mcp", "integration"]
                            }
                        }
                    )
                    
                    data = result.structured_content.get('result') if hasattr(result, 'structured_content') else result.data
                    
                    if isinstance(data, dict) and data.get("success"):
                        print(f"   ✅ SUCCESS: File uploaded")
                        print(f"      - S3 URL: {data.get('s3_url', 'Unknown')}")
                        print(f"      - File size: {data.get('file_size', 0)} bytes")
                        results['file_upload'] = 'PASS'
                    else:
                        print(f"   ❌ FAILED: {data.get('error', 'Unknown error')}")
                        results['file_upload'] = 'FAIL'
                finally:
                    # Clean up temp file
                    os.unlink(temp_file)
                    
            except Exception as e:
                print(f"   ❌ ERROR: {str(e)}")
                results['file_upload'] = 'ERROR'
            
            # 7. Test resource_search tool
            print("\n7️⃣ Testing resource_search tool...")
            try:
                result = await client.call_tool(
                    "resource_search",
                    {
                        "params": {
                            "query": "test",
                            "limit": 5
                        }
                    }
                )
                
                data = result.structured_content.get('result') if hasattr(result, 'structured_content') else result.data
                
                if isinstance(data, list):
                    print(f"   ✅ SUCCESS: Resource search completed")
                    print(f"      - Found {len(data)} resources")
                    results['resource_search'] = 'PASS'
                else:
                    print(f"   ❌ FAILED: Invalid response format")
                    results['resource_search'] = 'FAIL'
            except Exception as e:
                print(f"   ❌ ERROR: {str(e)}")
                results['resource_search'] = 'ERROR'
            
            # Summary
            print("\n" + "=" * 60)
            print("📊 MCP TOOLS TEST RESULTS (API Mode)")
            print("=" * 60)
            
            passed = sum(1 for r in results.values() if r == 'PASS')
            failed = sum(1 for r in results.values() if r == 'FAIL')
            errors = sum(1 for r in results.values() if r == 'ERROR')
            total = len(results)
            
            for tool_name, result in results.items():
                icon = "✅" if result == 'PASS' else "❌" if result == 'FAIL' else "⚠️"
                print(f"{icon} {tool_name}: {result}")
            
            print(f"\n📈 Overall: {passed}/{total} passed ({passed/total*100:.1f}%)")
            
            if passed == total:
                print("\n🎉 ALL MCP TOOLS WORKING IN API MODE!")
                print("   Ready for DXT deployment")
            elif passed >= total * 0.8:
                print("\n✅ Most tools working. API mode is functional.")
            else:
                print("\n⚠️ Several tools failing. Check API endpoints.")
            
            # Assert core tools work
            assert results.get('entity_search') != 'ERROR', "Entity search tool must not error"
            assert results.get('function_search') != 'ERROR', "Function search tool must not error"
            assert passed >= total * 0.5, "At least 50% of tools must work"


def run_test():
    """Run the test standalone"""
    test = TestMCPToolsAPIMode()
    asyncio.run(test.test_all_mcp_tools())


if __name__ == "__main__":
    run_test()