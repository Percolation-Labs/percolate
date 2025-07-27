# Authentication Guide

## Table of Contents
1. [Overview](#overview)
2. [Authentication Modes](#authentication-modes)
3. [Mode 1: Legacy Bearer Token](#mode-1-legacy-bearer-token)
4. [Mode 2: Percolate OAuth Provider](#mode-2-percolate-oauth-provider)
5. [Mode 3: External OAuth Relay](#mode-3-external-oauth-relay)
6. [API Endpoints](#api-endpoints)
7. [Token Management](#token-management)
8. [Security Considerations](#security-considerations)
9. [MCP Integration](#mcp-integration)
10. [Implementation Guide](#implementation-guide)
11. [Testing Authentication](#testing-authentication)

## Overview

Percolate implements OAuth 2.1 compliant authentication with three distinct modes of operation. Each mode serves different use cases while maintaining compatibility with MCP (Model Context Protocol) clients.

### Key Features

- **OAuth 2.1 Compliant**: Full implementation of OAuth 2.1 endpoints
- **Three Authentication Modes**: 
  - Mode 1: Legacy Bearer Token (simple API key authentication)
  - Mode 2: Percolate as OAuth Provider (JWT-based with refresh tokens)
  - Mode 3: External OAuth Relay (delegate to Google, GitHub, etc.)
- **MCP Compatible**: Works with Claude Code, Claude Desktop, and other MCP clients
- **Flexible Token Management**: Database storage, JWT validation, or external validation
- **User Registration**: All modes register users for memory/context management

## Authentication Modes

Percolate supports three authentication modes, each with different characteristics:

| Mode | Type | Token Storage | Token Type | Refresh Support | User Storage |
|------|------|---------------|------------|-----------------|--------------|
| 1 | Legacy Bearer | Database | API Key | No | Yes |
| 2 | Percolate OAuth | Database | JWT | Yes | Yes |
| 3 | External Relay | None | Provider Token | Provider Managed | Yes (email only) |

## Mode 1: Legacy Bearer Token

### Flow Diagram 1.1: Initial Authentication

```mermaid
sequenceDiagram
    participant Client
    participant Percolate
    participant Database
    
    Note over Client,Database: Every Request
    Client->>Percolate: Request + Bearer Token + X-User-Email
    Percolate->>Database: Validate token for user
    Database-->>Percolate: Token valid/invalid
    Percolate-->>Client: Response or 401
```

### Characteristics
- Simple API key authentication
- Requires `Authorization: Bearer <token>` and `X-User-Email` headers on every request
- Token stored in User table
- No token expiration or refresh
- Suitable for service accounts and simple integrations

### Configuration
```bash
# No special configuration needed
# X-User-Email can be provided as header or environment variable
export X_USER_EMAIL="user@example.com"
```

## Mode 2: Percolate OAuth Provider

### Flow Diagram 2.1: Initial Authorization

```mermaid
sequenceDiagram
    participant Client
    participant Percolate
    participant Database
    
    Note over Client,Database: Initial Login
    Client->>Percolate: GET /auth/authorize
    Percolate-->>Client: Login form or challenge
    Client->>Percolate: POST /auth/authorize<br/>Bearer Token + X-User-Email
    Percolate->>Database: Validate bearer token
    Database-->>Percolate: User found
    Percolate-->>Client: Authorization code
```

### Flow Diagram 2.2: Token Exchange

```mermaid
sequenceDiagram
    participant Client
    participant Percolate
    participant Database
    
    Note over Client,Database: Token Exchange
    Client->>Percolate: POST /auth/token<br/>code + PKCE
    Percolate->>Percolate: Generate JWT tokens
    Percolate->>Database: Store refresh token
    Percolate-->>Client: JWT access token<br/>+ refresh token
```

### Flow Diagram 2.3: API Access

```mermaid
sequenceDiagram
    participant Client
    participant Percolate
    participant Database
    
    Note over Client,Database: API Requests
    Client->>Percolate: Request + JWT token
    Percolate->>Percolate: Validate JWT<br/>Extract email
    Percolate->>Database: Get user by email
    Database-->>Percolate: User context
    Percolate-->>Client: Response
```

### Flow Diagram 2.4: Token Refresh

```mermaid
sequenceDiagram
    participant Client
    participant Percolate
    participant Database
    
    Note over Client,Database: Token Refresh
    Client->>Percolate: POST /auth/token<br/>refresh_token
    Percolate->>Database: Validate refresh token
    Database-->>Percolate: Token valid
    Percolate->>Percolate: Generate new JWT
    Percolate-->>Client: New access token
```

### Characteristics
- Full OAuth 2.1 provider implementation
- Initial auth uses bearer token to establish identity
- Issues JWT access tokens (1 hour expiry)
- Provides refresh tokens for long-lived access
- User email extracted from JWT for identification

### Configuration
```bash
# Enable Percolate as OAuth provider
export AUTH_MODE=percolate
export JWT_SECRET=your-secret-key
export JWT_EXPIRY=3600  # 1 hour
```

## Mode 3: External OAuth Relay

### Flow Diagram 3.1: Initial Authorization

```mermaid
sequenceDiagram
    participant Client
    participant Percolate
    participant Google
    participant Database
    
    Note over Client,Database: OAuth Flow Start
    Client->>Percolate: GET /auth/authorize
    Percolate-->>Client: Redirect to Google
    Client->>Google: Login at Google
    Google-->>Client: Authorization code
    Client->>Percolate: Code via callback
```

### Flow Diagram 3.2: Token Exchange

```mermaid
sequenceDiagram
    participant Client
    participant Percolate
    participant Google
    participant Database
    
    Note over Client,Database: Token Exchange
    Client->>Percolate: POST /auth/token<br/>code
    Percolate->>Google: Exchange code
    Google-->>Percolate: Access + Refresh tokens
    Percolate->>Google: Get user info
    Google-->>Percolate: User email
    Percolate->>Database: Register user (email only)
    Percolate-->>Client: Google tokens (not stored)
```

### Flow Diagram 3.3: Token Validation

```mermaid
sequenceDiagram
    participant Client
    participant Percolate
    participant Google
    participant Database
    
    Note over Client,Database: API Access
    Client->>Percolate: Request + Google token
    Percolate->>Google: Validate token
    Google-->>Percolate: Token info + email
    Percolate->>Database: Get user by email
    Database-->>Percolate: User context
    Percolate-->>Client: Response
    
    Note over Client,Database: Token Expired
    Client->>Percolate: Request + Expired token
    Percolate->>Google: Validate token
    Google-->>Percolate: Token expired
    Percolate-->>Client: 401 TokenExpiredError
```

### Characteristics
- Delegates authentication to external provider
- Does NOT store tokens in database
- Only stores user email for identification
- Client responsible for token refresh
- Raises TokenExpiredError when tokens expire

### Configuration
```bash
# Enable external OAuth relay
export AUTH_PROVIDER=google
export GOOGLE_OAUTH_CLIENT_ID=your-client-id
export GOOGLE_OAUTH_CLIENT_SECRET=your-client-secret
export GOOGLE_OAUTH_REDIRECT_URI=https://api.percolate.ai/auth/google/callback
```

## API Endpoints

### OAuth 2.1 Endpoint Behavior by Mode

| Endpoint | Mode 1: Legacy Bearer | Mode 2: Percolate OAuth | Mode 3: External Relay |
|----------|----------------------|-------------------------|------------------------|
| `GET /.well-known/oauth-authorization-server` | Returns metadata | Returns metadata | Returns metadata |
| `GET /.well-known/oauth-protected-resource` | Returns auth server | Returns auth server | Returns auth server |
| `GET /auth/authorize` | Not used | Shows login form | Redirects to provider |
| `POST /auth/authorize` | Not used | Validates bearer token, returns code | Not used |
| `POST /auth/token` | Not used | Issues JWT tokens | Relays provider tokens |
| `POST /auth/revoke` | Not used | Revokes tokens | Forwards to provider |
| `POST /auth/introspect` | Validates bearer token | Validates JWT | Queries provider |
| `GET /auth/ping` | Bearer + Email required | JWT or Bearer accepted | Provider token accepted |
| `POST /auth/refresh` | Not supported | Refreshes JWT | Not implemented (client handles) |

### API Request Authentication by Mode

| Mode | Authorization Header | Additional Headers | Token Validation |
|------|---------------------|-------------------|------------------|
| 1 | `Bearer <api-key>` | `X-User-Email` required | Database lookup |
| 2 | `Bearer <jwt-token>` | None (email in JWT) | JWT signature + expiry |
| 3 | `Bearer <provider-token>` | None (email from provider) | Provider API call |

### Token Lifecycle by Mode

| Aspect | Mode 1 | Mode 2 | Mode 3 |
|--------|--------|--------|--------|
| Initial Auth | API key + email | Bearer token → JWT | Provider login |
| Token Type | Static API key | JWT (1hr) + Refresh | Provider tokens |
| Storage | User.token field | Refresh token in DB | None |
| Expiration | Never | 1 hour (configurable) | Provider managed |
| Refresh | Not supported | POST /auth/token | Client responsibility |
| Revocation | Delete from DB | POST /auth/revoke | Provider API |

## Authentication Providers

For API keys and service accounts. Requires both:
- `Authorization: Bearer <token>` header
- `X-User-Email: user@example.com` header (or `X_USER_EMAIL` environment variable)

The bearer token provider validates tokens against the User table in the database. The X-User-Email header can be provided either:
- As an HTTP header: `X-User-Email: user@example.com`
- As an environment variable: `X_USER_EMAIL=user@example.com` (automatically mapped to header)

```python
# Example usage with header
headers = {
    "Authorization": "Bearer sk-1234567890abcdef",
    "X-User-Email": "user@example.com"
}

# Example usage with environment variable
# Set: export X_USER_EMAIL="user@example.com"
headers = {
    "Authorization": "Bearer sk-1234567890abcdef"
    # X-User-Email will be automatically populated from X_USER_EMAIL env var
}
```

**Important**: In this mode, the bearer token must exist in the User table and be associated with the provided email address.

### 2. Google OAuth Provider (Mode B)

For user authentication via Google accounts:
- Uses OAuth 2.1 authorization code flow
- Supports PKCE for enhanced security
- Automatic token refresh

When `AUTH_PROVIDER=google` environment variable is set:
- The system acts as a relay to Google's OAuth endpoints
- User tokens are NOT stored in the database
- Only the user's email is registered/stored for identification
- Token validation is performed against Google's servers
- When tokens expire, a `TokenExpiredError` is raised, prompting token refresh

### Authentication Flow Comparison

| Provider | Use Case | Token Storage | Token Type | Refresh | User Interaction |
|----------|----------|---------------|------------|---------|------------------|
| Bearer Token (Mode A) | API/Service | Stored in DB | Long-lived | Manual | None |
| Google OAuth (Mode B) | User Apps | NOT stored | Short-lived | Automatic via Google | Initial login |

## Implementation Structure

### Directory Organization

```
clients/python/percolate/percolate/
├── auth/                           # Core authentication package
│   ├── __init__.py                # Package exports
│   ├── models.py                  # OAuth data models
│   ├── providers.py               # Authentication providers (Bearer, Google)
│   ├── server.py                  # OAuth server implementation
│   └── middleware.py              # Authentication middleware
│
└── api/
    ├── main.py                    # App initialization & OAuth setup
    │
    ├── controllers/
    │   └── oauth.py               # OAuth business logic controller
    │
    ├── routes/
    │   └── auth/
    │       ├── __init__.py        # Auth module initialization
    │       ├── router.py          # Session auth routes (Google login, connect)
    │       ├── oauth.py           # OAuth 2.1 standard endpoints
    │       ├── google_oauth.py    # Google OAuth client implementation
    │       └── utils.py           # Auth utility functions
    │
    └── utils/
        └── oauth.py               # OAuth well-known endpoint utilities
```

### Component Responsibilities

#### Core Authentication (`/auth/`)

- **models.py**: OAuth 2.1 data models (AuthRequest, TokenResponse, etc.), authentication errors, grant types
- **providers.py**: Base `AuthProvider` interface and implementations (Bearer, Google)
- **server.py**: Main OAuth 2.1 server coordinating providers
- **middleware.py**: Request authentication middleware and FastAPI dependencies

#### API Layer (`/api/`)

- **controllers/oauth.py**: Business logic for OAuth operations
- **routes/auth/oauth.py**: HTTP endpoint handlers for OAuth flows
- **utils/oauth.py**: Well-known endpoint implementations

## Token Management

### Token Types

```mermaid
graph LR
    subgraph "Token Lifecycle"
        AT[Access Token<br/>1 hour]
        RT[Refresh Token<br/>Long-lived]
        IT[ID Token<br/>User info JWT]
    end
    
    AT -->|Expires| RT
    RT -->|Refreshes| AT
    IT -->|Contains| UI[User Info]
```

### Token Storage

Tokens are stored in multiple locations:
- **Database**: User table stores tokens with session mapping
- **Session**: Server-side session storage for active sessions
- **File System**: Optional token persistence at `~/.percolate/auth/google/token`
- **Never stored**: In logs, URLs, or non-secure locations

## API Endpoints

### OAuth 2.1 Endpoints

| Endpoint | Purpose | Method |
|----------|---------|--------|
| `/.well-known/oauth-authorization-server` | OAuth metadata | GET |
| `/.well-known/oauth-protected-resource` | MCP discovery | GET |
| `/auth/authorize` | Start authorization flow | GET |
| `/auth/token` | Exchange code for tokens | POST |
| `/auth/revoke` | Revoke tokens | POST |
| `/auth/introspect` | Validate tokens | POST |
| `/auth/session/info` | Get session and user information | GET |
| `/auth/google/login` | Initiate Google OAuth flow | GET |
| `/auth/google/callback` | Handle Google OAuth callback | GET |
| `/auth/connect` | Get project settings with API key | GET |
| `/auth/register` | Dynamic client registration | POST |

### Authentication Flow

```mermaid
sequenceDiagram
    participant Client as MCP Client
    participant Auth as Percolate Auth
    participant Provider as Auth Provider
    participant API as Percolate API
    
    Note over Client,API: Discovery Phase
    Client->>API: GET /mcp (no auth)
    API-->>Client: 401 + WWW-Authenticate
    Client->>Auth: GET /.well-known/oauth-protected-resource
    Auth-->>Client: Authorization server info
    
    Note over Client,API: Authorization Phase
    Client->>Auth: GET /auth/authorize
    
    alt Bearer Token Flow
        Auth-->>Client: Request credentials
        Client->>Auth: Bearer token + email
        Auth->>Provider: Validate token
        Provider-->>Auth: Token valid
        Auth-->>Client: Authorization code
    else Google OAuth Flow
        Auth-->>Client: Redirect to Google
        Client->>Provider: Login at Google
        Provider-->>Auth: Authorization code
        Auth-->>Client: Authorization code
    end
    
    Note over Client,API: Token Exchange
    Client->>Auth: POST /auth/token (code)
    Auth->>Provider: Exchange code
    Provider-->>Auth: Access/Refresh tokens
    Auth-->>Client: Tokens
    
    Note over Client,API: API Access
    Client->>API: Request + Bearer token
    API->>Auth: Validate token
    Auth-->>API: Token info + user
    API-->>Client: Protected resource
```

## Authentication Mode Configuration

### Mode A: Bearer Token Authentication

This mode uses database-stored bearer tokens with email verification:

```bash
# No AUTH_PROVIDER needed (default mode)
export X_USER_EMAIL="user@example.com"  # Optional, can use header instead
```

**Characteristics:**
- Tokens are stored in the User table
- Email must match the token's associated user
- Suitable for service accounts and API integration
- No external authentication provider needed

### Mode B: OAuth Provider Relay

This mode relays authentication to external providers:

```bash
export AUTH_PROVIDER=google  # Enable Google OAuth relay mode
export GOOGLE_OAUTH_CLIENT_ID=your-client-id
export GOOGLE_OAUTH_CLIENT_SECRET=your-client-secret
export GOOGLE_OAUTH_REDIRECT_URI=https://ask-one.resmagic.io/oauth/google/callback
```

**Characteristics:**
- Tokens are NOT stored in database
- Only user email is registered for identification
- Token validation happens against provider (e.g., Google)
- Automatic token refresh through provider
- Raises `TokenExpiredError` when tokens expire

## Security Considerations

### Security Best Practices

1. **PKCE Support**: OAuth flows support PKCE for enhanced security
2. **HTTPS Recommended**: Use HTTPS in production environments
3. **Session Security**: Server-side sessions with secure cookies
4. **Token Validation**: All tokens are validated before use
5. **Audit Logging**: Authentication events are logged

### Token Security

#### Token Validation Requirements

**Bearer Tokens:**
- Must be provided in `Authorization: Bearer <token>` header
- Must include `X-User-Email` header
- Validated against database records

**OAuth Tokens:**
- ID tokens are JWT format
- Access tokens from Google OAuth
- Stored in user session and database
- Expiration tracked for refresh

## MCP Integration

### Client Configuration

#### Claude Code
```json
{
  "percolate": {
    "transport": "http",
    "url": "https://p8.resmagic.io/mcp/",
    "auth": {
      "type": "oauth",
      "authorization_url": "https://p8.resmagic.io/auth/authorize",
      "token_url": "https://p8.resmagic.io/auth/token",
      "pkce": true
    }
  }
}
```

#### Claude Desktop
```json
{
  "mcpServers": {
    "percolate": {
      "transport": "http",
      "url": "https://p8.resmagic.io/mcp/",
      "env": {
        "PERCOLATE_API_KEY": "sk-...",
        "PERCOLATE_USER_EMAIL": "user@example.com"
      }
    }
  }
}
```

### Authentication Context

The authentication system provides context through different mechanisms:

1. **OAuth/Bearer Token**: Available via `request.state.auth`
2. **Session Authentication**: Available via `request.session`
3. **Hybrid Authentication**: The `hybrid_auth` dependency checks both

```python
# Using hybrid authentication in endpoints
from percolate.api.routes.auth import hybrid_auth
from fastapi import Depends

@app.get("/api/endpoint")
async def my_endpoint(user_id: Optional[str] = Depends(hybrid_auth)):
    if user_id:
        # User is authenticated
        return {"user_id": user_id}
    else:
        # Anonymous request
        return {"message": "Not authenticated"}
```

## Implementation Guide

### Configuration

Set environment variables:

```bash
# Base URL
PERCOLATE_BASE_URL=https://p8.resmagic.io

# Google OAuth (optional)
GOOGLE_OAUTH_CLIENT_ID=your-client-id
GOOGLE_OAUTH_CLIENT_SECRET=your-client-secret
GOOGLE_OAUTH_REDIRECT_URI=https://ask-one.resmagic.io/oauth/google/callback

# Automated authentication (optional)
OAUTH_USERNAME=user@example.com
OAUTH_PASSWORD=password
```

### Adding a New Provider

1. **Create provider class in `auth/providers.py`:**
```python
from percolate.auth.providers import AuthProvider
from percolate.auth.models import AuthRequest, AuthResponse, TokenRequest, TokenResponse, TokenInfo, AuthError
import time

class GitHubOAuthProvider(AuthProvider):
    def __init__(self, client_id: str, client_secret: str, redirect_uri: str):
        self.client_id = client_id
        self.client_secret = client_secret
        self.redirect_uri = redirect_uri
        
    async def authorize(self, request: AuthRequest) -> AuthResponse:
        """Handle authorization request"""
        # Validate the request
        if not request.client_id:
            raise AuthError("invalid_request", "Client ID required")
        
        # In real implementation, redirect to GitHub OAuth
        # This is a simplified example
        return AuthResponse(
            code="github-auth-code",
            state=request.state
        )
        
    async def token(self, request: TokenRequest) -> TokenResponse:
        """Exchange code for tokens"""
        # In real implementation, exchange with GitHub API
        return TokenResponse(
            access_token="github-access-token",
            token_type="Bearer",
            expires_in=3600,
            refresh_token="github-refresh-token"
        )
        
    async def validate(self, token: str) -> TokenInfo:
        """Validate access token"""
        # In real implementation, validate with GitHub API
        return TokenInfo(
            active=True,
            sub="github-user-id",
            email="user@example.com",
            exp=int(time.time()) + 3600
        )
        
    async def refresh(self, refresh_token: str) -> TokenResponse:
        """Refresh access token"""
        # In real implementation, refresh with GitHub API
        return TokenResponse(
            access_token="new-github-access-token",
            token_type="Bearer",
            expires_in=3600,
            refresh_token="new-github-refresh-token"
        )
```

2. **Register in `auth/server.py`:**
```python
# In OAuthServer.__init__
if os.getenv("GITHUB_CLIENT_ID"):
    self.providers["github"] = GitHubOAuthProvider(
        client_id=os.getenv("GITHUB_CLIENT_ID"),
        client_secret=os.getenv("GITHUB_CLIENT_SECRET"),
        redirect_uri=os.getenv("GITHUB_REDIRECT_URI")
    )
```

3. **Add provider-specific routes if needed in `api/routes/auth/`**

### Protecting Endpoints

```python
from percolate.auth.middleware import require_auth, get_auth
from percolate.auth.models import AuthContext
from fastapi import Depends

@app.get("/api/protected")
@require_auth(scopes=["read:data"])
async def protected_endpoint(auth: AuthContext = Depends(get_auth)):
    return {"user": auth.email, "data": "sensitive"}
```

### Client Implementation

```python
# Bearer token authentication with httpx
import httpx
import os

# Get credentials from environment
api_key = os.getenv("PERCOLATE_API_KEY")
user_email = os.getenv("PERCOLATE_USER_EMAIL")
base_url = os.getenv("PERCOLATE_BASE_URL", "http://localhost:5008")

# Create headers with both required values
headers = {
    "Authorization": f"Bearer {api_key}",
    "X-User-Email": user_email
}

# Make authenticated request
async with httpx.AsyncClient() as client:
    response = await client.get(
        f"{base_url}/api/chat",
        headers=headers
    )
    print(response.json())

# For OAuth flow, use the authorization endpoint
auth_url = f"{base_url}/auth/authorize?" + \
    "response_type=code&" + \
    "client_id=percolate-client&" + \
    "redirect_uri=http://localhost:8080/callback&" + \
    "code_challenge=your-pkce-challenge&" + \
    "code_challenge_method=S256"
# Open auth_url in browser for user authentication
```

## Testing Authentication

### Mode 1: Legacy Bearer Token Tests

```bash
# Every API request requires both headers
curl -H "Authorization: Bearer sk-your-api-key" \
     -H "X-User-Email: user@example.com" \
     http://localhost:5008/auth/ping

# Using environment variable for email
export X_USER_EMAIL="user@example.com"
curl -H "Authorization: Bearer sk-your-api-key" \
     http://localhost:5008/auth/ping

# Test script
python test_percolate/integration/auth/test_mode_a_bearer_auth.py
```

### Mode 2: Percolate OAuth Provider Tests

```bash
# Set up environment
export AUTH_MODE=percolate
export JWT_SECRET=your-secret-key

# Initial authorization (requires bearer token)
curl -X POST http://localhost:5008/auth/authorize \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "client_id=test-client" \
     -d "response_type=code" \
     -d "token=sk-your-bearer-token" \
     -d "email=user@example.com"

# Exchange code for JWT tokens
curl -X POST http://localhost:5008/auth/token \
     -d "grant_type=authorization_code" \
     -d "code=AUTH_CODE_FROM_ABOVE" \
     -d "client_id=test-client"

# Use JWT for API access (no email header needed)
curl -H "Authorization: Bearer JWT_TOKEN_FROM_ABOVE" \
     http://localhost:5008/auth/ping

# Refresh token
curl -X POST http://localhost:5008/auth/token \
     -d "grant_type=refresh_token" \
     -d "refresh_token=REFRESH_TOKEN_FROM_ABOVE"

# Test script
python test_percolate/integration/auth/test_all_auth_modes.py::TestMode2PercolateOAuth
```

### Mode 3: External OAuth Relay Tests

```bash
# Set up environment
export AUTH_PROVIDER=google
export GOOGLE_OAUTH_CLIENT_ID=your-client-id
export GOOGLE_OAUTH_CLIENT_SECRET=your-client-secret

# Run interactive test (opens browser)
python test_google_oauth_interactive.py

# Automated tests with mocks
python test_percolate/integration/auth/test_mode_b_oauth_relay.py

# Manual flow
# 1. Start OAuth
curl "http://localhost:5008/auth/authorize?provider=google&client_id=test"
# -> Redirects to Google

# 2. After Google login, exchange code
curl -X POST http://localhost:5008/auth/token \
     -d "grant_type=authorization_code" \
     -d "code=GOOGLE_AUTH_CODE"

# 3. Use Google token for API access
curl -H "Authorization: Bearer GOOGLE_ACCESS_TOKEN" \
     http://localhost:5008/auth/ping
```

### Running All Tests

```bash
# Run all authentication tests
pytest test_percolate/integration/auth/ -v

# Run specific mode tests
pytest test_percolate/integration/auth/test_all_auth_modes.py::TestMode1LegacyBearer -v
pytest test_percolate/integration/auth/test_all_auth_modes.py::TestMode2PercolateOAuth -v
pytest test_percolate/integration/auth/test_all_auth_modes.py::TestMode3ExternalOAuthRelay -v

# Run with coverage
pytest test_percolate/integration/auth/ --cov=percolate.auth --cov-report=html
```

## OAuth Well-Known Endpoints

Percolate implements OAuth 2.1 well-known endpoint discovery, allowing clients to automatically discover authentication endpoints and capabilities. The response varies based on the active authentication mode.

### Endpoint URLs

- **Authorization Server Metadata**: `/.well-known/oauth-authorization-server`
- **Protected Resource Metadata**: `/.well-known/oauth-protected-resource`

### Mode-Specific Responses

#### Mode 1: Legacy Bearer Token (Default)

```json
{
  "issuer": "http://localhost:5008",
  "authorization_endpoint": "http://localhost:5008/auth/authorize",
  "token_endpoint": "http://localhost:5008/auth/token",
  "token_endpoint_auth_methods_supported": [
    "client_secret_post",
    "client_secret_basic"
  ],
  "registration_endpoint": "http://localhost:5008/auth/register",
  "scopes_supported": ["read", "write", "admin"],
  "response_types_supported": ["code", "token"],
  "grant_types_supported": ["authorization_code", "refresh_token"],
  "revocation_endpoint": "http://localhost:5008/auth/revoke",
  "introspection_endpoint": "http://localhost:5008/auth/introspect",
  "code_challenge_methods_supported": ["S256", "plain"]
}
```

**Key Characteristics:**
- Basic OAuth endpoints are available
- No provider list included (implicit bearer provider)
- Supports both code and token response types
- No JWT-specific capabilities

#### Mode 2: Percolate OAuth Provider (AUTH_MODE=percolate)

```json
{
  "issuer": "http://localhost:5008",
  "authorization_endpoint": "http://localhost:5008/auth/authorize",
  "token_endpoint": "http://localhost:5008/auth/token",
  "introspection_endpoint": "http://localhost:5008/auth/introspect",
  "response_types_supported": ["code"],
  "grant_types_supported": ["authorization_code", "refresh_token"],
  "code_challenge_methods_supported": ["S256"],
  "scopes_supported": ["openid", "email", "profile"],
  "token_endpoint_auth_methods_supported": [
    "client_secret_post",
    "client_secret_basic"
  ],
  "providers": ["percolate"]
}
```

**Key Characteristics:**
- Includes `"providers": ["percolate"]` indicating JWT provider
- OpenID Connect scopes supported
- Only authorization code flow (more secure)
- JWT tokens issued for all successful authentications

#### Mode 3: External OAuth Relay (AUTH_PROVIDER=google)

```json
{
  "issuer": "https://p8.resmagic.io",
  "authorization_endpoint": "https://p8.resmagic.io/auth/authorize",
  "token_endpoint": "https://p8.resmagic.io/auth/token",
  "introspection_endpoint": "https://p8.resmagic.io/auth/introspect",
  "response_types_supported": ["code"],
  "grant_types_supported": ["authorization_code", "refresh_token"],
  "code_challenge_methods_supported": ["S256"],
  "scopes_supported": ["openid", "email", "profile"],
  "token_endpoint_auth_methods_supported": [
    "client_secret_post",
    "client_secret_basic"
  ],
  "providers": ["bearer", "google"]
}
```

**Key Characteristics:**
- Includes `"providers": ["bearer", "google"]` showing multiple providers
- Percolate acts as a relay proxy - endpoints point to Percolate's relay handlers
- When clients call `/auth/authorize`, Percolate redirects to Google's OAuth servers
- After Google authentication, Google redirects back to Percolate's callback
- Percolate exchanges the code with Google and returns tokens to the client
- Bearer provider remains available for API key auth

### Testing Well-Known Endpoints

```bash
# Check current mode's well-known configuration
curl http://localhost:5008/.well-known/oauth-authorization-server | jq

# Check protected resource metadata
curl http://localhost:5008/.well-known/oauth-protected-resource | jq

# Test with different modes
# Mode 1 (default)
curl http://localhost:5008/.well-known/oauth-authorization-server | jq '.providers'
# Returns: null (no providers field)

# Mode 2 (restart server with AUTH_MODE=percolate)
curl http://localhost:5008/.well-known/oauth-authorization-server | jq '.providers'
# Returns: ["percolate"]

# Mode 3 (restart server with AUTH_PROVIDER=google)
curl http://localhost:5008/.well-known/oauth-authorization-server | jq '.providers'
# Returns: ["bearer", "google"]
```

### Using Well-Known Endpoints in Clients

```python
import httpx
import json

async def discover_oauth_config(base_url):
    """Discover OAuth configuration from well-known endpoint"""
    async with httpx.AsyncClient() as client:
        # Get authorization server metadata
        response = await client.get(f"{base_url}/.well-known/oauth-authorization-server")
        config = response.json()
        
        # Determine authentication mode
        providers = config.get("providers", [])
        if "percolate" in providers:
            print("Mode 2: Percolate JWT Provider detected")
            print("Use OAuth flow for JWT tokens")
        elif "google" in providers:
            print("Mode 3: External OAuth relay detected")
            print(f"Available providers: {providers}")
        else:
            print("Mode 1: Legacy bearer token authentication")
            print("Use API key with X-User-Email header")
        
        return config

# Example usage
config = await discover_oauth_config("http://localhost:5008")
print(f"Authorization endpoint: {config['authorization_endpoint']}")
print(f"Token endpoint: {config['token_endpoint']}")
```

## Implementation Checklist

### Mode 1: Legacy Bearer Token ✓
- [x] Bearer token validation against database
- [x] X-User-Email header requirement
- [x] Environment variable mapping (X_USER_EMAIL)
- [x] Integration tests
- [x] Well-known endpoints
- [x] Documentation

### Mode 2: Percolate OAuth Provider ✓
- [x] JWT token generation and signing
- [x] Bearer token → JWT exchange flow
- [x] Refresh token support
- [x] JWT validation with expiry
- [x] Integration tests
- [x] Well-known endpoints with provider list
- [x] Documentation

### Mode 3: External OAuth Relay ✓
- [x] Google OAuth relay provider
- [x] No token storage in database
- [x] User registration (email only)
- [x] Token validation via provider API
- [x] TokenExpiredError handling
- [x] Integration tests
- [x] Interactive test script
- [x] Well-known endpoints with multiple providers
- [x] Documentation

## Summary

Percolate's authentication system provides three distinct modes:

1. **Mode 1 (Legacy)**: Simple API key authentication for backward compatibility
2. **Mode 2 (Percolate OAuth)**: Full OAuth 2.1 provider with JWT tokens for modern applications
3. **Mode 3 (External Relay)**: Delegate authentication to external providers for enterprise integration

Each mode is fully tested, documented, and ready for production use. The system automatically detects the desired mode based on environment variables, making it easy to switch between modes without code changes.