#!/usr/bin/env python3
"""
Test script for the new select_with_predicates method
"""
import sys
import os

# Add the percolate package to the path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'percolate'))

try:
    import percolate as p8
    from percolate.models.p8 import Agent
    from percolate.services.PostgresService import PostgresService
    
    def test_select_with_predicates():
        """Test the new select_with_predicates method"""
        print("Testing select_with_predicates method...")
        
        # Create a repository for Agent (which should exist in the database)
        repo = p8.repository(Agent)
        
        # Test 1: Basic filter with scalar values  
        print("\n1. Testing basic scalar filter...")
        try:
            result = repo.select_with_predicates(
                filter={'category': 'agent'},
                limit=5
            )
            print(f"   Query executed successfully, returned {len(result) if result else 0} records")
        except Exception as e:
            print(f"   Error: {e}")
        
        # Test 2: Filter with list (IN operator)
        print("\n2. Testing list filter (IN operator)...")
        try:
            result = repo.select_with_predicates(
                filter={'name': ['p8.PercolateAgent', 'p8.TestAgent']},
                limit=10
            )
            print(f"   Query executed successfully, returned {len(result) if result else 0} records")
        except Exception as e:
            print(f"   Error: {e}")
        
        # Test 3: Multiple filters with ordering
        print("\n3. Testing multiple filters with ordering...")
        try:
            result = repo.select_with_predicates(
                filter={'category': 'agent'},
                order_by='created_at DESC',
                limit=5
            )
            print(f"   Query executed successfully, returned {len(result) if result else 0} records")
        except Exception as e:
            print(f"   Error: {e}")
        
        # Test 4: No filters, just ordering and limit
        print("\n4. Testing no filters, just ordering and limit...")
        try:
            result = repo.select_with_predicates(
                order_by='created_at DESC',
                limit=3
            )
            print(f"   Query executed successfully, returned {len(result) if result else 0} records")
            if result:
                print(f"   Sample record: {result[0].get('name', 'No name field')}")
        except Exception as e:
            print(f"   Error: {e}")
        
        # Test 5: Specific fields selection
        print("\n5. Testing specific field selection...")
        try:
            result = repo.select_with_predicates(
                fields=['id', 'name', 'category'],
                limit=2
            )
            print(f"   Query executed successfully, returned {len(result) if result else 0} records")
            if result:
                print(f"   Sample record keys: {list(result[0].keys()) if result[0] else 'None'}")
                print(f"   Sample record: {result[0] if result[0] else 'None'}")
        except Exception as e:
            print(f"   Error: {e}")
        
        print("\nTest completed!")
        
    if __name__ == "__main__":
        test_select_with_predicates()
        
except ImportError as e:
    print(f"Import error: {e}")
    print("This test requires the percolate package to be properly installed")
except Exception as e:
    print(f"Unexpected error: {e}")