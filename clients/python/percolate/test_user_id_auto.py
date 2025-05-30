"""
Test script to verify that User models automatically assign a userid when not provided.
This script creates a user with a name and email, then verifies that the userid is
automatically set and matches the hash of the email.
"""

import uuid
from percolate.models.p8.types import User
from percolate.utils import make_uuid

def test_user_id_auto_assignment():
    print("Testing automatic User ID assignment from email...")
    
    # Create test user data
    test_name = "Test User"
    test_email = f"test_{uuid.uuid4().hex[:8]}@example.com"
    
    # Calculate expected ID
    expected_id = make_uuid(test_email)
    
    print(f"Creating user with name: {test_name}, email: {test_email}")
    print(f"Expected ID from email hash: {expected_id}")
    
    # Method 1: Create user with ID explicitly set
    user1 = User(
        id=expected_id,  # Explicitly set ID to the email hash
        name=test_name,
        email=test_email,
        role_level=5  # INTERNAL access level
    )
    
    print("\nMethod 1: User with explicitly set ID")
    print(f"User ID: {user1.id}")
    print(f"User userid: {user1.userid}")
    
    # Verify that userid matches id
    if str(user1.id) == str(user1.userid):
        print("✅ SUCCESS: User ID and userid match!")
    else:
        print("❌ FAILURE: User ID and userid do not match!")
    
    # Method 2: Create user with ID from KeyField
    user2 = User(
        id=make_uuid(test_email),  # Generate ID from email
        name=test_name,
        email=test_email,
        userid=None,  # Explicitly set userid to None to test auto-assignment
        role_level=5  # INTERNAL access level
    )
    
    print("\nMethod 2: User with explicitly NULL userid")
    print(f"User ID: {user2.id}")
    print(f"User userid: {user2.userid}")
    
    # Verify that userid matches id
    if str(user2.id) == str(user2.userid):
        print("✅ SUCCESS: User ID and userid match even when userid was initially None!")
    else:
        print("❌ FAILURE: User ID and userid do not match when userid was initially None!")
    
    print("\nTest completed.")

if __name__ == "__main__":
    test_user_id_auto_assignment()