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

### FastHTML Cookie Authentication

For FastHTML applications using cookie-based authentication with our hybrid auth system:

**How FastHTML Cookie Authentication Works:**

1. **Cookie-Based Sessions**: FastHTML can use its `Cookie` dependency to send session cookies that our hybrid auth will automatically recognize
2. **Expected Cookie Names**: The system looks for cookies named `session` (FastAPI default) or custom names like `session_` or `auth_token`
3. **Automatic Recognition**: Our hybrid auth will first check for session authentication before falling back to bearer tokens

**FastHTML Example:**

```python
from fasthtml import FastHTML, Cookie, Route, Response

app = FastHTML()

# After user login, set the session cookie
@app.route("/login", methods=["POST"])
async def login(response: Response):
    # Perform authentication with Percolate
    auth_response = requests.post("http://localhost:5000/auth/google/callback")
    session_token = auth_response.json()["token"]
    
    # Set cookie that Percolate will recognize
    response.set_cookie(
        key="session",
        value=session_token,
        httponly=True,
        secure=True,  # Use HTTPS in production
        samesite="lax"
    )
    return {"status": "logged in"}

# Making authenticated requests to Percolate
@app.route("/data")
async def get_data(session: str = Cookie(None)):
    # The session cookie is automatically sent with requests
    headers = {"Cookie": f"session={session}"} if session else {}
    
    # Request to Percolate API - hybrid auth will recognize the session
    response = requests.get(
        "http://localhost:5000/api/protected",
        headers=headers
    )
    
    return response.json()
```

**How Hybrid Auth Processes Cookie Authentication:**

1. **Session Check First**: When a request comes in, hybrid auth first checks for a valid session
2. **Cookie Extraction**: It looks for the session cookie in the request
3. **Session Validation**: The session is validated server-side (not just trusting the cookie)
4. **User Context**: If valid, it returns the user_id associated with the session
5. **Bearer Fallback**: Only if no valid session is found, it checks for bearer token authentication

**Example Flow:**

```python
# Hybrid auth flow for FastHTML requests
class HybridAuth:
    async def __call__(self, request: Request, credentials: Optional[HTTPAuthorizationCredentials] = Depends(bearer)):
        # 1. First check session from cookie
        user_id = get_user_from_session(request)  # Extracts from Cookie header
        if user_id:
            return user_id  # Session authenticated
        
        # 2. Only check bearer if no session
        if credentials:
            await get_api_key(credentials)
            return None  # Bearer authenticated (no user context)
        
        # 3. Neither method succeeded
        raise HTTPException(401)
```

**Cookie Configuration for FastHTML:**

```python
# Recommended cookie settings for production
response.set_cookie(
    key="session",
    value=session_token,
    max_age=86400,  # 24 hours
    httponly=True,  # Prevent XSS
    secure=True,    # HTTPS only
    samesite="lax", # CSRF protection
    domain=".yourdomain.com",  # Allow subdomains
    path="/"        # Available site-wide
)
```

**Security Benefits:**
- Session tokens never exposed to JavaScript (httponly)
- Automatic CSRF protection with proper samesite settings
- Sessions validated server-side, not just trusting cookies
- Bearer token fallback for API access without cookies

**Key Points:**
- FastHTML doesn't need to change how it handles cookies
- Our hybrid auth automatically recognizes standard session cookies
- The same endpoint works for both cookie sessions and bearer tokens
- User context is preserved with sessions, not available with bearer tokens

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
  - `redirect_uri`: Optional custom redirect after login (e.g., mobile app scheme, client page URL)
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

### Custom Redirect URI Support

Clients can provide a `redirect_uri` parameter when initiating login to control where users are redirected after authentication. This enables:

1. **Mobile App Integration**: Use custom URL schemes like `myapp://auth/callback`
2. **Web Client Pages**: Redirect to specific pages like `https://mysite.com/dashboard`
3. **Single Page Applications**: Return to the current client-side route

**Example Usage:**
```bash
# Mobile app with custom scheme
/auth/google/login?redirect_uri=myapp://auth/callback

# Web application
/auth/google/login?redirect_uri=https://myapp.com/auth/complete

# Local development
/auth/google/login?redirect_uri=http://localhost:3000/auth/callback
```

**What Happens:**
1. Client initiates login with `redirect_uri` parameter
2. User completes Google OAuth flow
3. Server callback receives the OAuth token
4. Server redirects to `{redirect_uri}?token={id_token}`
5. Client receives the JWT token in the query parameter

**Token Usage:**
- The token provided in the redirect is a JWT ID token containing user information
- Clients can decode this token to extract user profile data (name, email, picture, etc.)
- This token provides all necessary user info for client-side session persistence

**Note:** The `/auth/session/info` endpoint is available for retrieving user information later, but is not necessary during the login flow since the JWT token already contains the user profile data.

### `/auth/connect`
Get project configuration (requires authentication).
- **Method**: GET
- **Auth**: Bearer token required
- **Response**: Project configuration JSON

## Implementation Details

### Session Storage

Sessions are managed by FastAPI's SessionMiddleware with a stable secret key to ensure persistence across server restarts.

### Session Persistence Fix

The authentication system now uses a stable session key instead of generating a random key on each server restart. This ensures that user sessions persist across server restarts.

**Previous Issue:**
```python
k = str(uuid1())  # Random key each time!
app.add_middleware(SessionMiddleware, secret_key=k)
```

**Current Implementation:**
```python
# Use stable session key for session persistence across restarts
session_key = get_stable_session_key()
app.add_middleware(SessionMiddleware, secret_key=session_key)
```

### How Stable Session Keys Work

The `get_stable_session_key()` function:
1. First checks `P8_SESSION_KEY` environment variable
2. Falls back to loading from `~/.percolate/auth/session_key.json`
3. Generates and saves a new key if neither exists

This ensures:
- Sessions survive server restarts
- Users stay logged in during development
- Better user experience

### Configuration Options

#### Option 1: Environment Variable (Recommended for Production)
```bash
export P8_SESSION_KEY="your-stable-secret-key"
uvicorn percolate.api.main:app --port 5000
```

#### Option 2: Automatic File-Based (Development)
Simply start the server - it will automatically create and use a persistent key:
```bash
uvicorn percolate.api.main:app --port 5000
```

The key is stored in `~/.percolate/auth/session_key.json` with restricted permissions (0600).

### Security Considerations

- The session key file has restricted permissions (0600)
- For production, use the `P8_SESSION_KEY` environment variable
- Never commit the session key to version control
- Rotate the key periodically for security

### OAuth Re-Login Handling

The system handles re-login attempts when a user already has an active session:

1. **Detection**: Checks if a token exists in the session (indicating previous login)
2. **Session Clearing**: Clears the entire session to ensure fresh OAuth flow
3. **Data Preservation**: Preserves `app_redirect_uri` and `sync_files` settings
4. **Clean Start**: Removes any OAuth state keys to allow authlib to create new ones

**Implementation:**
```python
if 'token' in request.session:
    logger.info("Re-login detected - clearing session for fresh OAuth flow")
    # Keep only the app_redirect_uri and sync_files if they were just set
    temp_redirect = request.session.get('app_redirect_uri')
    temp_sync = request.session.get('sync_files', False)
    
    # Clear the entire session
    request.session.clear()
    
    # Restore the values we need
    if temp_redirect:
        request.session['app_redirect_uri'] = temp_redirect
    request.session['sync_files'] = temp_sync
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

## OAuth Troubleshooting Guide

### Common OAuth Issues and Solutions

#### 1. State Mismatch Error
**Symptom**: `MismatchingStateError: CSRF Warning! State not equal in request and response.`

**Causes**:
- Session persistence between login attempts
- OAuth state not being created due to existing session data
- Expired OAuth state keys

**Solution**: The system now automatically detects re-login attempts and clears the session:
```python
# Automatically handled in login endpoint
if 'token' in request.session:
    # Clear session for fresh OAuth flow
```

**Debug Logs**:
```
Session keys before OAuth redirect: ['sync_files', 'token', 'session_id']
Re-login detected - clearing session for fresh OAuth flow
```

#### 2. Session Not Persisting
**Symptom**: Users have to re-login after server restart

**Cause**: Random session key generation on startup

**Solution**: Use stable session key (implemented)
```python
session_key = get_stable_session_key()
app.add_middleware(SessionMiddleware, secret_key=session_key)
```

#### 3. OAuth State Debugging
To debug OAuth state issues, check the logs:

```
# Login attempt
Session keys before OAuth redirect: [...]
OAuth states in session: ['_state_google_knjekfzmvgWjEQdW7lkZdVb80F0LN4']

# Callback
Session keys at callback start: [...]
Query params: state=knjekfzmvgWjEQdW7lkZdVb80F0LN4, code=...
OAuth states in session: ['_state_google_knjekfzmvgWjEQdW7lkZdVb80F0LN4']
```

## Notes

- The system uses JWT tokens from Google OAuth
- Token expiry is automatically extracted from JWT claims
- Sessions are stored server-side for security
- Bearer tokens are suitable for testing and admin operations
- User context is required for personalized operations
- Session cookies are HttpOnly (not accessible via JavaScript)
- Session IDs are generated server-side (UUID)
- Each login creates a new session ID
- Re-login attempts automatically clear previous session data