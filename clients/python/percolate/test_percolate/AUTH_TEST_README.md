# Authentication Test Suite

This directory contains comprehensive tests for Percolate's three authentication modes.

## Test Organization

### Unit Tests (`/test_percolate/unit/auth/`)
Tests that use mocks and don't require external dependencies:
- `test_auth_structure_only.py` - Verifies auth module structure and imports

### Integration Tests (`/test_percolate/integration/auth/`)
Tests that require real environment setup (database, API endpoints):

#### Core Test Suites
- `test_all_auth_modes.py` - Primary test suite with classes for all three modes
  - `TestMode1LegacyBearer` - Mode 1 bearer token tests
  - `TestMode2PercolateOAuth` - Mode 2 JWT provider tests  
  - `TestMode3ExternalOAuthRelay` - Mode 3 external OAuth tests
  - `TestModeDetection` - Environment-based mode detection tests

- `test_mode_a_bearer_auth.py` - Dedicated Mode 1 (bearer token) tests
- `test_mode_b_oauth_relay.py` - Dedicated Mode 3 (OAuth relay) tests

#### Specialized Tests
- `test_auth_integration_detailed.py` - Detailed positive/negative test cases with DB verification
- `test_auth_with_user_info.py` - User information retrieval from database
- `test_wellknown_endpoints.py` - OAuth well-known endpoint responses for each mode
- `test_oauth_endpoints.py` - OAuth endpoint functionality tests
- `test_google_oauth_interactive.py` - Interactive Google OAuth flow (requires manual interaction)
- `test_mode2_jwt_simulation.py` - JWT token generation and validation simulation

#### Refactoring Verification
- `test_auth_refactoring_complete.py` - Verifies auth code refactoring to api/auth/
- `test_auth_refactoring_actual.py` - Tests actual auth implementation structure
- `test_all_modes_comprehensive.py` - Comprehensive coverage of all modes
- `test_auth_mode_a.py` - Additional Mode A (bearer token) coverage

## Running Tests

### Prerequisites
```bash
# Set up environment variables
export P8_PG_HOST=localhost
export P8_PG_PORT=5432
export P8_PG_DATABASE=app
export P8_PG_USER=postgres
export P8_PG_PASSWORD=postgres
export P8_API_ENDPOINT=http://localhost:5008

# For Polars compatibility on Apple Silicon
export POLARS_SKIP_CPU_CHECK=1
```

### Run All Auth Tests
```bash
# Using pytest (if environment is properly configured)
pytest test_percolate/integration/auth/ -v

# Or run individual test files directly
python test_percolate/integration/auth/test_auth_integration_detailed.py
```

### Run Specific Mode Tests
```bash
# Mode 1: Legacy Bearer Token
python test_percolate/integration/auth/test_mode_a_bearer_auth.py

# Mode 2: Percolate JWT (requires AUTH_MODE=percolate)
export AUTH_MODE=percolate
python test_percolate/integration/auth/test_all_auth_modes.py::TestMode2PercolateOAuth

# Mode 3: External OAuth Relay (requires provider setup)
export AUTH_PROVIDER=google
export GOOGLE_OAUTH_CLIENT_ID=your-client-id
export GOOGLE_OAUTH_CLIENT_SECRET=your-client-secret
python test_percolate/integration/auth/test_mode_b_oauth_relay.py
```

## Test Coverage

### Mode 1: Legacy Bearer Token
- ✓ Bearer token validation against database
- ✓ X-User-Email header requirement
- ✓ X_USER_EMAIL environment variable mapping
- ✓ Positive/negative test cases
- ✓ User info retrieval from database

### Mode 2: Percolate JWT Provider
- ✓ JWT token generation and signing
- ✓ Bearer token to JWT exchange flow
- ✓ Refresh token support
- ✓ JWT expiration handling
- ✓ Token validation

### Mode 3: External OAuth Relay
- ✓ Google OAuth provider relay
- ✓ No token storage verification
- ✓ User registration (email only)
- ✓ Token validation via provider API
- ✓ Expired token error handling

## Test Users

The integration tests create the following test users:
- `sirsh.test@example.com` - Sirsh Authenticated User (Mode 1)
- `jane.test@example.com` - Jane JWT Test User (Mode 2)
- `amartey@gmail.com` - Google OAuth test user (Mode 3)

## Notes

- Integration tests require a running Percolate server at `http://localhost:5008`
- Database must be accessible with the configured credentials
- Some tests (like `test_google_oauth_interactive.py`) require manual browser interaction
- JWT tests require server restart with `AUTH_MODE=percolate`
- OAuth relay tests require proper provider credentials