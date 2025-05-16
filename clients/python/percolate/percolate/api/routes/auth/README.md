# Authentication Router Documentation

This module handles authentication for the Percolate API, supporting both session-based authentication for web users and bearer token authentication for API access.

## Table of Contents
- [Overview](#overview)
- [Authentication Methods](#authentication-methods)
- [User Model](#user-model)
- [Hybrid Authentication](#hybrid-authentication)
- [Endpoints](#endpoints)
- [Implementation Details](#implementation-details)
- [Security Considerations](#security-considerations)

## Overview

The Percolate authentication system provides a flexible approach that supports:
1. **Session-based authentication** - For logged-in users via web interface
2. **Bearer token authentication** - For API testing and service-to-service communication
3. **Hybrid authentication** - Endpoints can accept either method

## Authentication Methods

### 1. Session-Based Authentication (Google OAuth)

For web users who need personalized access with user context.

**Login Flow:**
1. User initiates login via `/auth/google/login`
2. User is redirected to Google OAuth
3. After successful authentication, Google redirects back to `/auth/google/callback`
4. The OAuth token is:
   - Stored in the server-side session
   - Saved to the database with user information
   - **NOT** sent to the browser (only a session ID cookie is sent)
5. Subsequent requests use the session cookie to authenticate

**Current Implementation:**
```python
# During login callback
request.session['token'] = oauth_token  # Token stored in session
return {'token': id_token}              # Token ALSO sent to client
```

**Important Note:** The current implementation sends the actual ID token to the client, not just a session ID. This allows clients to use either:
- Session cookies for authentication
- The ID token directly for API calls

**Authentication Flows:**
1. **Session-based**: `Browser → Session Cookie → Server Session → OAuth Token → User Info`
2. **Token-based**: `Browser → ID Token (from callback) → Direct authentication`

**How Session Cookies Work in Subsequent Requests:**

1. **Automatic Cookie Handling**: After login, the server sets a session cookie that browsers automatically include in all subsequent requests to the same domain.

2. **No Manual Headers Needed**: Unlike bearer tokens, you don't need to manually add authentication headers. The browser handles this automatically.

3. **Example Flow**:
   ```
   1. Login: /auth/google/login → OAuth → Callback
   2. Server: Sets cookie: session=eyJ0eXAi...
   3. Browser: Stores cookie
   4. Next Request: GET /api/data
      Browser automatically adds: Cookie: session=eyJ0eXAi...
   5. Server: Reads session cookie → Authenticates request
   ```

4. **In Practice**:
   ```javascript
   // Browser JavaScript - cookies sent automatically
   fetch('/api/protected')
     .then(response => response.json())
   
   // Python requests - use session object
   session = requests.Session()
   response = session.get('http://localhost:5008/api/protected')
   ```

**Security Note:** The current implementation also returns the ID token directly to the client, which provides flexibility but is less secure than pure session-based auth. The code includes a TODO comment indicating this should be replaced with a more secure approach in the future.

### 2. Bearer Token Authentication

For API access, testing, and service-to-service communication.

**How It Works:**
- Client sends API key in Authorization header
- No user context (user_id is None)
- Suitable for admin operations and testing

**Valid Tokens:**
- `postgres` - Default test token
- Value of `P8_API_KEY` environment variable
- Any configured API keys

**Example:**
```bash
curl -X GET http://localhost:5000/auth/ping \
  -H "Authorization: Bearer postgres"
```

## User Model

The User model stores authentication and profile information:

```python
class User(AbstractEntityModel):
    id: UUID | str                    # Unique user ID (generated from email)
    email: Optional[str]              # User's email (key field)
    name: Optional[str]               # Display name
    token: Optional[str]              # OAuth token (JSON string)
    token_expiry: Optional[datetime]  # Token expiration time
    roles: Optional[List[str]]        # User roles
    metadata: Optional[dict]          # Additional user metadata
    # ... other fields
```

**Key Points:**
- User ID is generated from email using `make_uuid(email)`
- OAuth tokens are stored as JSON strings in the database
- Token expiry is extracted from the OAuth token
- Users are created/updated automatically on login

## Hybrid Authentication

The `HybridAuth` class allows endpoints to accept either authentication method:

```python
class HybridAuth:
    async def __call__(
        self, 
        request: Request,
        credentials: Optional[HTTPAuthorizationCredentials] = Depends(bearer)
    ) -> Optional[str]:
        # Try session auth first
        # Fall back to bearer token
        # Return user_id for sessions, None for bearer tokens
```

### Usage Patterns

#### 1. Hybrid Authentication (Default)
Accepts both session and bearer tokens:
```python
@router.get("/endpoint")
async def endpoint(user_id: Optional[str] = Depends(hybrid_auth)):
    if user_id:
        # Session user with context
    else:
        # Bearer token (admin access)
```

#### 2. User-Required Authentication
Only accepts session authentication:
```python
@router.get("/user-endpoint")
async def user_endpoint(user_id: str = Depends(require_user_auth)):
    # Guaranteed to have user context
```

#### 3. Traditional Authentication
Only accepts specific tokens:
```python
@router.get("/admin-endpoint")
async def admin_endpoint(token: str = Depends(get_current_token)):
    # Only accepts POSTGRES_PASSWORD
```

## Endpoints

### `/auth/ping`
Test endpoint for authentication verification.
- **Method**: GET
- **Auth**: Hybrid (bearer or session)
- **Response**: 
  ```json
  {
    "message": "pong",
    "auth_type": "bearer" | "session",
    "user_id": "uuid" (only for session),
    "session_id": "uuid" (only for session)
  }
  ```

### `/auth/session/info`
Get detailed session information for debugging.
- **Method**: GET
- **Auth**: Hybrid (bearer or session)
- **Response**:
  ```json
  {
    "user_id": "uuid" (if authenticated),
    "session_id": "uuid" (from session data),
    "session_cookie_present": true/false,
    "session_data_keys": ["token", "session_id", ...],
    "auth_type": "session" | "none"
  }
  ```

### `/auth/google/login`
Initiates Google OAuth login flow.
- **Method**: GET
- **Parameters**: 
  - `redirect_uri`: Optional custom redirect after login
  - `sync_files`: Whether to request file sync permissions
- **Response**: Redirect to Google OAuth

### `/auth/google/callback`
Handles OAuth callback from Google.
- **Method**: GET
- **Process**: 
  1. Receives OAuth token from Google
  2. Stores full token in session
  3. Stores token in database with user info
  4. Extracts `id_token` from OAuth response
- **Response**: 
  - With `redirect_uri`: Redirects to `{redirect_uri}?token={id_token}`
  - Without `redirect_uri`: Returns `{"token": id_token}`
- **Note**: Currently returns the actual ID token to the client (not just session)

### `/auth/connect`
Get project configuration (requires authentication).
- **Method**: GET
- **Auth**: Bearer token required
- **Response**: Project configuration JSON

## Implementation Details

### Session Storage

Sessions are managed by FastAPI's SessionMiddleware:
```python
app.add_middleware(SessionMiddleware, secret_key=generated_key)
```

### Token Validation

Bearer tokens are validated against:
1. `POSTGRES_PASSWORD` environment variable
2. `P8_API_KEY` loaded via `load_db_key()`

### User Lookup Flow

For session authentication:
1. Extract session from cookie
2. Get OAuth token from session
3. Extract email from token
4. Look up user by email
5. Return user ID

## Security Considerations

1. **OAuth tokens never leave the server** - Only session IDs are sent to browsers
2. **Token expiry is enforced** - Both database and token expiry are checked
3. **Bearer tokens provide admin access** - No user context restrictions
4. **Session cookies are HTTP-only** - Cannot be accessed by JavaScript
5. **HTTPS required in production** - Especially for OAuth redirects

## Example Usage

### Testing Authentication
```python
# Bearer token
headers = {"Authorization": "Bearer postgres"}
response = requests.get("/api/endpoint", headers=headers)

# Session (after login)
cookies = {"session": session_cookie}
response = requests.get("/api/endpoint", cookies=cookies)
```

### Implementing Protected Endpoints
```python
from percolate.api.routes.auth import hybrid_auth, require_user_auth

# Accept both authentication methods
@router.get("/data")
async def get_data(user_id: Optional[str] = Depends(hybrid_auth)):
    if user_id:
        # Return user-specific data
        return {"data": "user_specific", "user_id": user_id}
    else:
        # Return general data (bearer token)
        return {"data": "general"}

# Require user authentication
@router.get("/profile")
async def get_profile(user_id: str = Depends(require_user_auth)):
    # Always has user context
    return {"user_id": user_id}
```

## Session Testing Guide

### How to Test Session Authentication

#### 1. Login via Browser

First, create a session by logging in:

```bash
# Open in browser
http://localhost:5008/auth/google/login
```

This will:
1. Redirect you to Google OAuth
2. After successful login, redirect back to the callback
3. Create a session and set a session cookie
4. Store the session ID in the user record

#### 2. Get the Session Cookie

After logging in, get the session cookie from your browser:

**Chrome/Firefox Developer Tools:**
1. Press F12 to open Developer Tools
2. Go to the Application tab (Chrome) or Storage tab (Firefox)
3. Find Cookies → localhost:5008
4. Copy the value of the 'session' cookie

**From Network Tab:**
1. Open Developer Tools (F12)
2. Go to Network tab
3. Make any request to the API
4. Click on the request and check Headers
5. Find 'Cookie: session=...' in Request Headers

#### 3. Test with the Session Cookie

Use the session cookie in your tests:

```python
import requests

# Create a session
session = requests.Session()


session.cookies.set('session', 'eyJzZXNzaW9uX2lkIjoiYmI5YzU3MTEtNzFkZi00MzAzLTkxNzktY2I5OWMyNWU1NDFhIn0.ZxYz12.signature_here')

# Make authenticated requests
response = session.get('http://localhost:5008/auth/ping')
print(response.json())
# Output: {"message": "pong", "user_id": "...", "session_id": "...", "auth_type": "session"}

# Check session info
response = session.get('http://localhost:5008/auth/session/info')
print(response.json())
```

#### 4. Using cURL for Testing

```bash
# Test with session cookie
curl -X GET http://localhost:5008/auth/ping \
  -H "Cookie: session=YOUR_SESSION_COOKIE_HERE" | jq

# Get session info
curl -X GET http://localhost:5008/auth/session/info \
  -H "Cookie: session=YOUR_SESSION_COOKIE_HERE" | jq
```

#### 5. Check User's Session ID

After login, the session ID is stored in the user record:

```python
import percolate as p8
from percolate.models import User

# Get user by email
user = p8.repository(User).get_by_key("user@example.com")
print(f"Session ID: {user.session_id}")
print(f"Last session: {user.last_session_at}")
```

### Session Tracking

The system now tracks sessions in the User model:
- `session_id`: The unique session identifier
- `last_session_at`: Timestamp of last session activity

### Session ID vs Session Cookie

**IMPORTANT DISTINCTION:**
- **Session Cookie**: The encrypted/signed cookie value sent by the browser (e.g., `eyJzZXNzaW9uX2lkIjo...signature`)
- **Session ID**: A UUID we generate and store INSIDE the session data (e.g., `bb9c5711-71df-4303-9179-cb99c25e541a`)
- **User.session_id**: The session ID stored in the user record

**Common Mistake:** Using just the session ID as the cookie value won't work. You need the full encrypted session cookie from your browser.

### Example Test Flow

```python
# 1. Login via browser and get session cookie
# 2. Test the session
import requests

session = requests.Session()
session.cookies.set('session', 'your-cookie-here')

# Test ping
response = session.get('http://localhost:5008/auth/ping')
data = response.json()
print(f"Authenticated as user: {data['user_id']}")
print(f"Session ID: {data['session_id']}")

# Test protected endpoint
response = session.get('http://localhost:5008/tus/')
print(f"TUS endpoint status: {response.status_code}")
```

### Debugging Tips

1. Check if session cookie is being sent:
   - Look at request headers in browser developer tools
   - Use `-v` flag with curl to see headers

2. Verify session is stored in database:
   - Check the User record for session_id
   - Check last_session_at timestamp

3. Test hybrid authentication:
   - Bearer token: No session, no user context
   - Session cookie: Has session ID and user context

## Notes

- The system uses JWT tokens from Google OAuth
- Token expiry is automatically extracted from JWT claims
- Sessions are stored server-side for security
- Bearer tokens are suitable for testing and admin operations
- User context is required for personalized operations
- Session cookies are HttpOnly (not accessible via JavaScript)
- Session IDs are generated server-side (UUID)
- Each login creates a new session ID