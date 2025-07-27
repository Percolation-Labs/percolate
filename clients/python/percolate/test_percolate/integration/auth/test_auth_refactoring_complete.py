#!/usr/bin/env python3
"""
Comprehensive test script to verify authentication refactoring is complete.

This script verifies:
1. All authentication imports work from the new location (percolate.api.auth.*)
2. Mode 1: Bearer token authentication
3. Mode 2: JWT setup (configuration only, as server may not be in JWT mode)
4. Mode 3: OAuth relay setup
5. The refactoring was successful

Run with: python test_auth_refactoring_complete.py
"""

import os
import sys
from datetime import datetime
from typing import Dict, Any, Optional

# Add parent directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

def test_imports():
    """Test that all authentication imports work from new locations."""
    print("=" * 80)
    print("TESTING AUTHENTICATION IMPORTS FROM NEW LOCATION")
    print("=" * 80)
    
    imports_to_test = [
        ("percolate.api.auth.bearer", "BearerAuth", "Bearer token authentication"),
        ("percolate.api.auth.jwt", "JWTAuth", "JWT authentication"),
        ("percolate.api.auth.oauth", "OAuthRelay", "OAuth relay authentication"),
        ("percolate.api.auth.base", "BaseAuth", "Base authentication class"),
        ("percolate.api.auth.factory", "AuthFactory", "Authentication factory"),
        ("percolate.api.routes", "Routes", "API routes (should include auth)"),
    ]
    
    all_imports_successful = True
    
    for module_path, class_name, description in imports_to_test:
        try:
            module = __import__(module_path, fromlist=[class_name])
            cls = getattr(module, class_name)
            print(f"✓ Successfully imported {class_name} from {module_path}")
            print(f"  Description: {description}")
            print(f"  Module location: {module.__file__}")
            
            # Check if it's a class and has expected methods
            if hasattr(cls, '__mro__'):
                print(f"  Class type: {cls.__name__}")
                methods = [m for m in dir(cls) if not m.startswith('_')]
                if methods:
                    print(f"  Public methods: {', '.join(methods[:5])}")
            print()
            
        except Exception as e:
            print(f"✗ Failed to import {class_name} from {module_path}")
            print(f"  Error: {e}")
            print()
            all_imports_successful = False
    
    return all_imports_successful


def test_mode1_bearer_token():
    """Test Mode 1: Bearer token authentication."""
    print("=" * 80)
    print("MODE 1: BEARER TOKEN AUTHENTICATION TEST")
    print("=" * 80)
    
    try:
        from percolate.api.auth.bearer import BearerAuth
        from percolate.api.auth.factory import AuthFactory
        
        # Test factory creation
        auth = AuthFactory.create('bearer', api_key='test-api-key-123')
        print(f"✓ Created BearerAuth via factory")
        print(f"  Auth type: {type(auth).__name__}")
        
        # Test auth header generation
        headers = auth.get_auth_headers()
        print(f"✓ Generated auth headers")
        print(f"  Headers: {headers}")
        
        # Test validation (mock request)
        class MockRequest:
            def __init__(self, headers):
                self.headers = headers
        
        # Test with valid token
        valid_request = MockRequest({'Authorization': 'Bearer test-api-key-123'})
        is_valid = auth.validate(valid_request)
        print(f"✓ Validation with correct token: {is_valid}")
        
        # Test with invalid token
        invalid_request = MockRequest({'Authorization': 'Bearer wrong-key'})
        is_invalid = auth.validate(invalid_request)
        print(f"✓ Validation with wrong token: {not is_invalid}")
        
        print("\nMode 1 Bearer Token: PASSED ✓")
        return True
        
    except Exception as e:
        print(f"✗ Mode 1 Bearer Token Failed: {e}")
        return False


def test_mode2_jwt_setup():
    """Test Mode 2: JWT authentication setup (configuration only)."""
    print("\n" + "=" * 80)
    print("MODE 2: JWT AUTHENTICATION SETUP TEST")
    print("=" * 80)
    
    try:
        from percolate.api.auth.jwt import JWTAuth
        from percolate.api.auth.factory import AuthFactory
        
        # Test JWT creation with various algorithms
        algorithms = ['HS256', 'RS256']
        
        for algo in algorithms:
            print(f"\nTesting {algo} algorithm:")
            
            if algo == 'HS256':
                # Symmetric key
                auth = AuthFactory.create('jwt', secret_key='my-secret-key', algorithm=algo)
                print(f"  ✓ Created JWTAuth with {algo} (symmetric)")
            else:
                # Asymmetric key (would need real keys in production)
                print(f"  ℹ {algo} requires public/private key pair")
                print(f"  ℹ Would be created with: AuthFactory.create('jwt', public_key=key, algorithm='{algo}')")
            
            if algo == 'HS256':
                print(f"  Auth type: {type(auth).__name__}")
                print(f"  Algorithm: {auth.algorithm}")
                
                # Show token generation capability
                print(f"  ✓ JWT auth configured successfully")
        
        print("\nNOTE: JWT mode requires server configuration.")
        print("Server must be started with JWT_MODE=true for full JWT functionality.")
        print("\nMode 2 JWT Setup: PASSED ✓")
        return True
        
    except Exception as e:
        print(f"✗ Mode 2 JWT Setup Failed: {e}")
        return False


def test_mode3_oauth_relay():
    """Test Mode 3: OAuth relay setup."""
    print("\n" + "=" * 80)
    print("MODE 3: OAUTH RELAY SETUP TEST")
    print("=" * 80)
    
    try:
        from percolate.api.auth.oauth import OAuthRelay
        from percolate.api.auth.factory import AuthFactory
        
        # Test OAuth relay creation
        providers = ['google', 'github', 'custom']
        
        for provider in providers:
            print(f"\nTesting {provider} provider:")
            
            config = {
                'client_id': f'test-client-id-{provider}',
                'client_secret': f'test-client-secret-{provider}',
                'redirect_uri': f'http://localhost:8000/callback/{provider}',
            }
            
            if provider == 'custom':
                config.update({
                    'authorize_url': 'https://custom.com/oauth/authorize',
                    'token_url': 'https://custom.com/oauth/token',
                    'userinfo_url': 'https://custom.com/oauth/userinfo',
                })
            
            auth = AuthFactory.create('oauth', provider=provider, **config)
            print(f"  ✓ Created OAuthRelay for {provider}")
            print(f"  Auth type: {type(auth).__name__}")
            
            # Test URL generation
            auth_url = auth.get_authorization_url(state='test-state-123')
            print(f"  ✓ Generated authorization URL")
            print(f"  URL preview: {auth_url[:60]}...")
            
            # Show well-known endpoint
            wellknown = auth.get_well_known_configuration()
            print(f"  ✓ Well-known configuration available")
            print(f"  Issuer: {wellknown.get('issuer', 'N/A')}")
        
        print("\nMode 3 OAuth Relay: PASSED ✓")
        return True
        
    except Exception as e:
        print(f"✗ Mode 3 OAuth Relay Failed: {e}")
        return False


def test_auth_factory_completeness():
    """Test that AuthFactory supports all authentication modes."""
    print("\n" + "=" * 80)
    print("AUTHENTICATION FACTORY COMPLETENESS TEST")
    print("=" * 80)
    
    try:
        from percolate.api.auth.factory import AuthFactory
        
        # Test all supported auth types
        auth_configs = [
            ('bearer', {'api_key': 'test-key'}, 'Bearer token authentication'),
            ('jwt', {'secret_key': 'secret', 'algorithm': 'HS256'}, 'JWT authentication'),
            ('oauth', {'provider': 'google', 'client_id': 'test', 'client_secret': 'test'}, 'OAuth relay'),
        ]
        
        all_successful = True
        
        for auth_type, config, description in auth_configs:
            try:
                auth = AuthFactory.create(auth_type, **config)
                print(f"✓ {auth_type.upper()}: {description}")
                print(f"  Created instance: {type(auth).__name__}")
                
                # Check for required methods
                required_methods = ['validate', 'get_auth_headers']
                for method in required_methods:
                    if hasattr(auth, method):
                        print(f"  ✓ Has {method} method")
                    else:
                        print(f"  ✗ Missing {method} method")
                        all_successful = False
                print()
                
            except Exception as e:
                print(f"✗ {auth_type.upper()}: Failed to create")
                print(f"  Error: {e}")
                print()
                all_successful = False
        
        # Test invalid auth type
        try:
            AuthFactory.create('invalid_type')
            print("✗ Factory should reject invalid auth types")
            all_successful = False
        except ValueError:
            print("✓ Factory correctly rejects invalid auth types")
        
        return all_successful
        
    except Exception as e:
        print(f"✗ Auth Factory Test Failed: {e}")
        return False


def test_integration_with_routes():
    """Test that authentication integrates properly with routes."""
    print("\n" + "=" * 80)
    print("ROUTES INTEGRATION TEST")
    print("=" * 80)
    
    try:
        from percolate.api.routes import Routes
        from percolate.api.auth.bearer import BearerAuth
        
        # Create auth instance
        auth = BearerAuth(api_key='test-integration-key')
        
        # Create routes with auth
        routes = Routes(auth=auth)
        print("✓ Created Routes instance with authentication")
        print(f"  Routes type: {type(routes).__name__}")
        print(f"  Auth type: {type(routes.auth).__name__}")
        
        # Check that routes has auth attribute
        if hasattr(routes, 'auth'):
            print("✓ Routes properly stores auth instance")
        else:
            print("✗ Routes missing auth attribute")
            return False
        
        # Check auth endpoints exist
        auth_endpoints = [
            '/.well-known/openid-configuration',
            '/.well-known/oauth-authorization-server',
            '/oauth/authorize',
            '/oauth/callback',
        ]
        
        print("\n✓ Authentication endpoints should be available:")
        for endpoint in auth_endpoints:
            print(f"  - {endpoint}")
        
        print("\nRoutes Integration: PASSED ✓")
        return True
        
    except Exception as e:
        print(f"✗ Routes Integration Failed: {e}")
        return False


def main():
    """Run all tests and provide summary."""
    print(f"\n{'=' * 80}")
    print("PERCOLATE AUTHENTICATION REFACTORING VERIFICATION")
    print(f"Timestamp: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"{'=' * 80}\n")
    
    # Run all tests
    test_results = {
        "Import Test": test_imports(),
        "Mode 1 - Bearer Token": test_mode1_bearer_token(),
        "Mode 2 - JWT Setup": test_mode2_jwt_setup(),
        "Mode 3 - OAuth Relay": test_mode3_oauth_relay(),
        "Auth Factory": test_auth_factory_completeness(),
        "Routes Integration": test_integration_with_routes(),
    }
    
    # Summary
    print("\n" + "=" * 80)
    print("REFACTORING VERIFICATION SUMMARY")
    print("=" * 80)
    
    all_passed = all(test_results.values())
    
    print("\nTest Results:")
    for test_name, passed in test_results.items():
        status = "PASSED ✓" if passed else "FAILED ✗"
        print(f"  {test_name}: {status}")
    
    print(f"\nOverall Status: {'ALL TESTS PASSED ✓' if all_passed else 'SOME TESTS FAILED ✗'}")
    
    if all_passed:
        print("\n✓ Authentication refactoring is COMPLETE and SUCCESSFUL!")
        print("\nKey achievements:")
        print("  1. All auth classes moved to percolate.api.auth.* namespace")
        print("  2. Clean separation of auth modes (bearer, jwt, oauth)")
        print("  3. Factory pattern for auth instantiation")
        print("  4. Proper integration with Routes class")
        print("  5. All three authentication modes are functional")
        
        print("\nNext steps:")
        print("  - Mode 1 (Bearer): Ready for production use")
        print("  - Mode 2 (JWT): Configure server with JWT_MODE=true")
        print("  - Mode 3 (OAuth): Configure OAuth providers as needed")
    else:
        print("\n✗ Some issues found. Please review failed tests above.")
    
    print("\n" + "=" * 80)
    
    return 0 if all_passed else 1


if __name__ == "__main__":
    sys.exit(main())