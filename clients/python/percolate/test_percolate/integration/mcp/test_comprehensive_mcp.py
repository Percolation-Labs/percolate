#!/usr/bin/env python
"""Comprehensive test of all MCP server functionality"""

import asyncio
import tempfile
import os
from pathlib import Path
from fastmcp.client import Client, PythonStdioTransport

async def test_all_mcp_functionality():
    """Test all MCP server tools comprehensively"""
    # Set up environment
    env = os.environ.copy()
    
    # Create transport
    runner_script = Path("percolate/api/mcp_server/tests/run_server.py")
    transport = PythonStdioTransport(
        script_path=runner_script,
        env=env
    )
    
    # Use client as context manager
    async with Client(transport=transport) as client:
        print("🚀 Connected to MCP server")
        print("=" * 60)
        
        test_results = {}
        
        # Test 1: Entity Retrieval
        print("\n1️⃣  Testing Entity Retrieval")
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
            
            data = result.structured_content['result'] if hasattr(result, 'structured_content') and 'result' in result.structured_content else result.data
            
            if isinstance(data, dict) and not data.get('error'):
                print(f"   ✅ SUCCESS: Retrieved entity '{data.get('name')}'")
                test_results['entity_retrieval'] = 'PASS'
            else:
                print(f"   ❌ FAILED: {data}")
                test_results['entity_retrieval'] = 'FAIL'
                
        except Exception as e:
            print(f"   ❌ ERROR: {e}")
            test_results['entity_retrieval'] = 'ERROR'
        
        # Test 2: Function Search
        print("\n2️⃣  Testing Function Search")
        try:
            result = await client.call_tool(
                "function_search",
                {
                    "params": {
                        "query": "find pets by status",
                        "limit": 3
                    }
                }
            )
            
            data = result.structured_content['result'] if hasattr(result, 'structured_content') and 'result' in result.structured_content else result.data
            
            if isinstance(data, list) and len(data) > 0 and isinstance(data[0], dict):
                pet_functions = [f for f in data if 'pet' in f.get('name', '').lower()]
                print(f"   ✅ SUCCESS: Found {len(data)} functions, {len(pet_functions)} pet-related")
                test_results['function_search'] = 'PASS'
            else:
                print(f"   ❌ FAILED: No valid functions returned")
                test_results['function_search'] = 'FAIL'
                
        except Exception as e:
            print(f"   ❌ ERROR: {e}")
            test_results['function_search'] = 'ERROR'
        
        # Test 3: Function Evaluation
        print("\n3️⃣  Testing Function Evaluation")
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
            
            data = result.structured_content['result'] if hasattr(result, 'structured_content') and 'result' in result.structured_content else result.data
            
            if isinstance(data, dict) and data.get('success'):
                result_data = data.get('result', [])
                pet_count = len(result_data) if isinstance(result_data, list) else 0
                print(f"   ✅ SUCCESS: Function executed, returned {pet_count} pets")
                test_results['function_eval'] = 'PASS'
            elif isinstance(data, list):
                # Sometimes function eval returns a list directly
                print(f"   ✅ SUCCESS: Function executed, returned {len(data)} results")
                test_results['function_eval'] = 'PASS'
            else:
                error_msg = data.get('error', 'Unknown error') if isinstance(data, dict) else f"Unexpected format: {type(data)}"
                print(f"   ❌ FAILED: {error_msg}")
                test_results['function_eval'] = 'FAIL'
                
        except Exception as e:
            print(f"   ❌ ERROR: {e}")
            test_results['function_eval'] = 'ERROR'
        
        # Test 4: File Upload
        print("\n4️⃣  Testing File Upload")
        try:
            # Create a temporary test file
            with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
                f.write("This is a comprehensive test file for MCP upload functionality.\n")
                f.write("Testing file upload capabilities with proper error handling.\n")
                temp_file_path = f.name
            
            try:
                result = await client.call_tool(
                    "file_upload",
                    {
                        "params": {
                            "file_path": temp_file_path,
                            "description": "Comprehensive MCP test file",
                            "tags": ["test", "mcp", "comprehensive"]
                        }
                    }
                )
                
                data = result.structured_content['result'] if hasattr(result, 'structured_content') and 'result' in result.structured_content else result.data
                
                if isinstance(data, dict) and data.get('success'):
                    print(f"   ✅ SUCCESS: File uploaded to {data.get('s3_url', 'unknown location')}")
                    test_results['file_upload'] = 'PASS'
                else:
                    print(f"   ❌ FAILED: {data.get('error', 'Unknown error')}")
                    test_results['file_upload'] = 'FAIL'
                    
            finally:
                # Clean up temp file
                os.unlink(temp_file_path)
                
        except Exception as e:
            print(f"   ❌ ERROR: {e}")
            test_results['file_upload'] = 'ERROR'
        
        # Test 5: Resource Search
        print("\n5️⃣  Testing Resource Search")
        try:
            result = await client.call_tool(
                "resource_search",
                {
                    "params": {
                        "query": "documentation",
                        "limit": 5
                    }
                }
            )
            
            data = result.structured_content['result'] if hasattr(result, 'structured_content') and 'result' in result.structured_content else result.data
            
            if isinstance(data, list):
                print(f"   ✅ SUCCESS: Resource search completed, found {len(data)} resources")
                test_results['resource_search'] = 'PASS'
            else:
                print(f"   ❌ FAILED: Unexpected response format")
                test_results['resource_search'] = 'FAIL'
                
        except Exception as e:
            print(f"   ❌ ERROR: {e}")
            test_results['resource_search'] = 'ERROR'
        
        # Test 6: Help Functionality
        print("\n6️⃣  Testing Help Functionality")
        try:
            result = await client.call_tool(
                "help",
                {
                    "params": {
                        "query": "How do I use function search?",
                        "context": "MCP server usage",
                        "max_depth": 2
                    }
                }
            )
            
            data = result.structured_content['result'] if hasattr(result, 'structured_content') and 'result' in result.structured_content else result.data
            
            if isinstance(data, str) and len(data) > 0:
                print(f"   ✅ SUCCESS: Help system responded")
                test_results['help'] = 'PASS'
            else:
                print(f"   ❌ FAILED: No help response")
                test_results['help'] = 'FAIL'
                
        except Exception as e:
            print(f"   ❌ ERROR: {e}")
            test_results['help'] = 'ERROR'
        
        # Summary
        print("\n" + "=" * 60)
        print("📊 TEST RESULTS SUMMARY")
        print("=" * 60)
        
        passed = sum(1 for result in test_results.values() if result == 'PASS')
        failed = sum(1 for result in test_results.values() if result == 'FAIL')
        errors = sum(1 for result in test_results.values() if result == 'ERROR')
        total = len(test_results)
        
        for test_name, result in test_results.items():
            status_icon = "✅" if result == 'PASS' else "❌" if result == 'FAIL' else "⚠️"
            print(f"{status_icon} {test_name.replace('_', ' ').title()}: {result}")
        
        print(f"\n📈 Overall Results: {passed}/{total} passed ({passed/total*100:.1f}%)")
        if failed > 0:
            print(f"❌ Failed: {failed}")
        if errors > 0:
            print(f"⚠️  Errors: {errors}")
        
        if passed == total:
            print("\n🎉 ALL TESTS PASSED! MCP server is fully functional.")
        elif passed >= total * 0.8:
            print("\n✅ Most tests passed. MCP server is operational with minor issues.")
        else:
            print("\n⚠️  Several tests failed. MCP server needs attention.")
        
        return test_results

if __name__ == "__main__":
    asyncio.run(test_all_mcp_functionality())