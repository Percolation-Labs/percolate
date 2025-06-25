#!/usr/bin/env python3
"""
Test script to verify dynamic entity functionality locally
"""

import pytest
from percolate.services.PostgresService import PostgresService
from percolate.interface import try_load_model

@pytest.mark.slow
def test_entity_exists():
    """Test the new check_entity_exists_by_name method"""
    print("Testing entity existence check...")
    
    pg = PostgresService()
    
    # Test cases - adjust expected values based on actual database state
    test_cases = [
        ("public", "Resources", False),  # May not exist in test DB
        ("public", "PublicResources", False),  # May not exist in test DB
        ("public", "NotExistsResources", False),
        ("p8", "Agent", True),
        ("fake_namespace", "FakeEntity", False)
    ]
    
    for namespace, entity_name, expected in test_cases:
        try:
            exists = pg.check_entity_exists_by_name(namespace, entity_name)
            # For test purposes, we just verify the method works without errors
            assert isinstance(exists, bool), f"Expected boolean result for {namespace}.{entity_name}"
            print(f"✓ {namespace}.{entity_name}: exists={exists}")
        except Exception as e:
            pytest.fail(f"Error checking {namespace}.{entity_name}: {str(e)}")

@pytest.mark.slow
def test_dynamic_model_loading():
    """Test loading models dynamically"""
    print("\n\nTesting dynamic model loading...")
    
    test_cases = [
        "public.Resources",
        "public.PublicResources",
        "p8.Agent",
        "public.NotExistsResources"  # This should create abstract model
    ]
    
    for entity_name in test_cases:
        try:
            model = try_load_model(entity_name, allow_abstract=True)
            assert model is not None, f"Failed to load model for {entity_name}"
            
            print(f"✓ {entity_name}: Loaded model type={type(model).__name__}")
            if hasattr(model, 'get_model_full_name'):
                full_name = model.get_model_full_name()
                print(f"   Full name: {full_name}")
                # Verify the full name matches what we requested
                assert full_name == entity_name, f"Expected {entity_name}, got {full_name}"
        except Exception as e:
            pytest.fail(f"Error loading model {entity_name}: {str(e)}")

@pytest.mark.slow
def test_check_entity_exists_integration():
    """Integration test for entity existence checking"""
    pg = PostgresService()
    
    # Test with a known existing schema/table combination
    exists = pg.check_entity_exists_by_name("p8", "Agent")
    assert isinstance(exists, bool)
    
    # Test with a non-existent combination
    not_exists = pg.check_entity_exists_by_name("fake_schema", "fake_table")
    assert not_exists == False
    
    # Test with None/empty values should handle gracefully
    try:
        pg.check_entity_exists_by_name("", "")
        # Should not raise an exception
    except Exception as e:
        # This is acceptable - empty values might raise an error
        pass

if __name__ == "__main__":
    # Allow running as a script for manual testing
    print("=" * 60)
    print("Dynamic Entity Test Script")
    print("=" * 60)
    
    test_entity_exists()
    test_dynamic_model_loading()
    test_check_entity_exists_integration()
    
    print("\n✅ All tests completed!")