#!/usr/bin/env python
"""
Test script to verify AbstractModel config inheritance
"""

from percolate.models.AbstractModel import AbstractModel
from percolate.models.p8.types import Resources
from percolate.models.p8.db_types import AccessLevel

def test_config_inheritance():
    """Test that model config inheritance works correctly."""
    
    print("=== Testing AbstractModel Config Inheritance ===\n")
    
    # Test 1: Create model with access_level
    print("Test 1: Create model with access_level")
    model1 = AbstractModel.create_model(
        name="TestModel1",
        namespace="test",
        description="Test model with access level",
        access_level=AccessLevel.ADMIN
    )
    
    print(f"Model config: {model1.model_config}")
    assert model1.model_config['access_level'] == AccessLevel.ADMIN.value
    print("✓ Access level set correctly\n")
    
    # Test 2: Create model inheriting from Resources
    print("Test 2: Create model inheriting from Resources")
    model2 = Resources.create_model(
        name="TestResources",
        namespace="test",
        description="Test resources with inherited config",
        access_level=AccessLevel.INTERNAL,
        inherit_config=True
    )
    
    print(f"Model config: {model2.model_config}")
    assert model2.model_config['access_level'] == AccessLevel.INTERNAL.value
    print("✓ Access level set correctly on Resources subclass\n")
    
    # Test 3: Create model without inheritance
    print("Test 3: Create model without config inheritance")
    model3 = Resources.create_model(
        name="TestNoInherit",
        namespace="test",
        description="Test without inheritance",
        access_level=AccessLevel.PUBLIC,
        inherit_config=False
    )
    
    print(f"Model config: {model3.model_config}")
    assert model3.model_config['access_level'] == AccessLevel.PUBLIC.value
    assert 'name' in model3.model_config
    assert 'namespace' in model3.model_config
    print("✓ Config created without inheritance\n")
    
    # Test 4: Test with custom parent config
    print("Test 4: Test with custom parent model config")
    
    # Create a parent class with custom config
    class ParentModel(AbstractModel):
        model_config = {
            'custom_field': 'parent_value',
            'access_level': AccessLevel.PARTNER.value,
            'other_setting': True
        }
    
    # Create child with inheritance
    child = ParentModel.create_model(
        name="ChildModel",
        namespace="test",
        description="Child with inheritance",
        access_level=AccessLevel.ADMIN,  # Override parent's access_level
        inherit_config=True
    )
    
    print(f"Parent config: {ParentModel.model_config}")
    print(f"Child config: {child.model_config}")
    
    # Check inheritance worked
    assert child.model_config['custom_field'] == 'parent_value'  # Inherited
    assert child.model_config['other_setting'] == True  # Inherited
    assert child.model_config['access_level'] == AccessLevel.ADMIN.value  # Overridden
    assert child.model_config['name'] == 'ChildModel'  # New value
    print("✓ Config inheritance with override works correctly\n")
    
    # Test 5: Additional kwargs
    print("Test 5: Test additional kwargs in config")
    model5 = AbstractModel.create_model(
        name="TestKwargs",
        namespace="test",
        description="Test with extra kwargs",
        access_level=AccessLevel.GOD,
        custom_setting="test_value",
        enable_feature=True,
        max_items=100
    )
    
    print(f"Model config: {model5.model_config}")
    assert model5.model_config['custom_setting'] == 'test_value'
    assert model5.model_config['enable_feature'] == True
    assert model5.model_config['max_items'] == 100
    print("✓ Additional kwargs merged into config\n")
    
    print("=== All tests passed! ===")

if __name__ == "__main__":
    test_config_inheritance()