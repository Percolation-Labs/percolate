#!/usr/bin/env python3
"""
Set up test users for authentication testing
"""

import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import percolate as p8
from percolate.models.p8.types import User
from percolate.utils import make_uuid
from datetime import datetime, timedelta


def create_test_users():
    """Create test users for each authentication mode"""
    
    user_repo = p8.repository(User)
    
    # Mode 1: Legacy bearer token user
    print("Creating Mode 1 test user...")
    user1 = User(
        id=make_uuid("mode1.test@example.com"),
        name="Mode 1 Test User",
        email="mode1.test@example.com",
        token="sk-mode1-test-token",
        token_expiry=datetime.utcnow() + timedelta(days=365),
        role_level=10,
        groups=["test_group", "mode1"]
    )
    user_repo.upsert_records(user1)
    print(f"✓ Created: {user1.email} with token: {user1.token}")
    
    # Mode 2: Percolate OAuth user (uses bearer for initial auth)
    print("\nCreating Mode 2 test user...")
    user2 = User(
        id=make_uuid("mode2.test@example.com"),
        name="Mode 2 Test User",
        email="mode2.test@example.com",
        token="sk-mode2-bearer-token",
        role_level=10,
        groups=["test_group", "mode2", "jwt_users"]
    )
    user_repo.upsert_records(user2)
    print(f"✓ Created: {user2.email} with token: {user2.token}")
    
    # Mode 3: Google OAuth user (no token stored)
    print("\nCreating Mode 3 test user...")
    user3 = User(
        id=make_uuid("amartey@gmail.com"),
        name="Amartey Test User",
        email="amartey@gmail.com",
        role_level=10,
        groups=["oauth_users", "google", "test_group"]
    )
    user_repo.upsert_records(user3)
    print(f"✓ Created: {user3.email} (no token - OAuth relay mode)")
    
    print("\nAll test users created successfully!")
    
    # List all users
    print("\nCurrent users in database:")
    all_users = user_repo.select()
    for user_data in all_users[:5]:  # Show first 5 users
        user = User(**user_data)
        print(f"  - {user.email} (token: {'Yes' if user.token else 'No'})")


def main():
    """Main entry point"""
    print("Setting up test users for authentication")
    print("=" * 50)
    
    try:
        create_test_users()
    except Exception as e:
        print(f"\n✗ Error creating users: {e}")
        return 1
    
    print("\n" + "=" * 50)
    print("Setup complete!")
    print("\nYou can now run:")
    print("  python test_oauth_endpoints.py  # Test all endpoints")
    print("  python test_google_oauth_interactive.py  # Interactive Google login")
    
    return 0


if __name__ == "__main__":
    sys.exit(main())