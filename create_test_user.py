#!/usr/bin/env python3
"""
Create test user for completions testing
"""

import sys
import os
from pathlib import Path

# Add the project root to Python path
project_root = Path(__file__).parent / "clients/python/percolate"
sys.path.insert(0, str(project_root))

import percolate as p8
from percolate.models.p8.types import User
from percolate.utils import make_uuid

def create_test_user():
    """Create a test user with appropriate role level"""
    
    email = "test@example.com"
    user_id = make_uuid(email)
    
    try:
        # Create user with role_level 50 (more than default 100, so they have access)
        user = User(
            id=user_id,
            email=email,
            name="Test User",
            role_level=50,  # Lower number = higher access level
            groups=["test_users"]
        )
        
        user_repo = p8.repository(User)
        user_repo.upsert_records(user)
        
        print(f"✅ Created test user: {email} with role_level=50")
        print(f"User ID: {user_id}")
        
        # Verify the user was created
        users = user_repo.select(email=email)
        if users:
            created_user = users[0]
            print(f"✅ Verified user exists: {created_user}")
            return True
        else:
            print(f"❌ Failed to verify user creation")
            return False
            
    except Exception as e:
        print(f"❌ Error creating user: {e}")
        return False

if __name__ == "__main__":
    success = create_test_user()
    print(f"\nResult: {'SUCCESS' if success else 'FAILED'}")