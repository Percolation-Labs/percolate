#!/usr/bin/env python3
"""
Simple test script to verify agent discoverability functionality.
Run this after setting up your Percolate database.
"""

import percolate as p8
from percolate.models import AbstractModel
from percolate.models.p8.types import Agent, Function
from pydantic import Field


def test_basic_discoverability():
    """Test basic agent registration and discoverability"""
    
    print("Testing Agent Discoverability\n")
    
    # 1. Define a simple test agent
    class TestCalculatorAgent(AbstractModel):
        """I am a calculator agent that can perform basic math operations."""
        
        model_config = {
            'name': 'TestCalculator',
            'namespace': 'test',
            'description': 'A simple calculator for basic math operations',
            'functions': {
                'add': 'Add two numbers',
                'multiply': 'Multiply two numbers',
                'calculate': 'Perform a calculation based on the expression'
            }
        }
        
        expression: str = Field(description="Mathematical expression to evaluate")
        
        @classmethod
        def add(cls, a: float, b: float) -> float:
            """Add two numbers together"""
            return a + b
        
        @classmethod
        def multiply(cls, a: float, b: float) -> float:
            """Multiply two numbers"""
            return a * b
    
    # 2. Register the agent
    print("1. Registering TestCalculatorAgent...")
    try:
        repo = p8.repository(TestCalculatorAgent)
        repo.register(make_discoverable=True)
        print("   ✓ Registration successful")
    except Exception as e:
        print(f"   ✗ Registration failed: {e}")
        return False
    
    # 3. Verify agent metadata was saved
    print("\n2. Checking agent metadata...")
    agents = p8.repository(Agent).select(name='test.TestCalculator')
    if agents:
        print(f"   ✓ Agent found in database: {agents[0]['name']}")
    else:
        print("   ✗ Agent not found in database")
        return False
    
    # 4. Verify function was created
    print("\n3. Checking function registry...")
    functions = p8.repository(Function).select(name='test_TestCalculator_run')
    if functions:
        func = functions[0]
        print(f"   ✓ Function created: {func['name']}")
        print(f"   ✓ Proxy URI: {func['proxy_uri']}")
    else:
        print("   ✗ Function not found")
        return False
    
    # 5. Test discoverability via search
    print("\n4. Testing search functionality...")
    search_results = p8.repository(Function).search("calculator math operations")
    calculator_funcs = [f for f in search_results if 'calculator' in f.get('description', '').lower()]
    if calculator_funcs:
        print(f"   ✓ Found {len(calculator_funcs)} calculator function(s) via search")
    else:
        print("   ✗ Calculator function not found via search")
    
    # 6. Test loading the agent
    print("\n5. Testing agent loading...")
    try:
        loaded_agent = Agent.load('test.TestCalculator')
        print(f"   ✓ Agent loaded successfully: {loaded_agent.get_model_full_name()}")
        
        # Create an instance
        instance = loaded_agent(expression="2 + 2")
        print(f"   ✓ Instance created with expression: {instance.expression}")
    except Exception as e:
        print(f"   ✗ Failed to load agent: {e}")
        return False
    
    # 7. Test using the agent
    print("\n6. Testing agent execution...")
    try:
        agent = p8.Agent(TestCalculatorAgent)
        result = agent.run("What is 5 + 3?")
        print(f"   ✓ Agent executed successfully")
        print(f"   Result: {result}")
    except Exception as e:
        print(f"   ✗ Agent execution failed: {e}")
    
    print("\n✅ All basic tests completed!")
    return True


def test_function_details():
    """Examine the function details created by make_discoverable"""
    
    print("\n\nExamining Function Details\n")
    
    # Get all functions that are agent proxies
    all_functions = p8.repository(Function).select()
    agent_functions = [f for f in all_functions if f.get('proxy_uri', '').startswith('p8agent/')]
    
    print(f"Found {len(agent_functions)} agent functions:")
    for func in agent_functions[:5]:  # Show first 5
        print(f"\n- Name: {func['name']}")
        print(f"  Proxy URI: {func['proxy_uri']}")
        print(f"  Description: {func['description'][:100]}...")
        if 'function_spec' in func:
            spec = func['function_spec']
            print(f"  Function spec: name={spec.get('name')}, params={list(spec.get('parameters', {}).get('properties', {}).keys())}")


if __name__ == "__main__":
    try:
        # Run basic tests
        success = test_basic_discoverability()
        
        if success:
            # Show function details
            test_function_details()
        
    except Exception as e:
        print(f"\n❌ Error during testing: {e}")
        import traceback
        traceback.print_exc()