# OAuth State Mismatch Fix

## Problem
The Google OAuth callback was failing with `MismatchingStateError: mismatching_state: CSRF Warning! State not equal in request and response.`

## Root Causes
1. Old OAuth state from previous attempts was persisting in the session
2. The callback was using `pop()` to remove items from the session prematurely
3. With persistent sessions, old state keys were conflicting with new ones

## Solution
Fixed the OAuth flow to properly maintain session state:

### 1. Login Endpoint (`/auth/google/login`)
- Added cleanup of old OAuth state keys before starting new flow
- This prevents conflicts from previous failed attempts

**Before:**
```python
if "oauth_state" in request.session:
    del request.session["oauth_state"]
```

**After:**
```python
# Clean up any old OAuth state from previous attempts
# This prevents state mismatch errors when reusing the same session
for key in list(request.session.keys()):
    if key.startswith('_state_google_'):
        del request.session[key]
```

### 2. Callback Endpoint (`/auth/google/callback`)
- Changed from `pop()` to `get()` to preserve session data during processing
- Only clean up session data after successful processing
- Added better error handling with helpful messages

**Before:**
```python
app_redirect_uri = request.session.pop("app_redirect_uri")
```

**After:**
```python
app_redirect_uri = request.session.get("app_redirect_uri")
# Clean up only after processing is complete
```

### 3. Error Handling
Added try-catch for OAuth errors with helpful debugging information:
```python
try:
    token = await google.authorize_access_token(request)
except Exception as e:
    logger.error(f"OAuth error: {str(e)}")
    logger.error(f"Session keys: {list(request.session.keys())}")
    return JSONResponse(
        status_code=400, 
        content={
            "error": "OAuth authentication failed",
            "detail": str(e),
            "hint": "This often happens when sessions are lost between requests. Try logging in again."
        }
    )
```

## Testing
After these changes:
1. Start the server: `uvicorn percolate.api.main:app --port 5008`
2. Login via Google: http://localhost:5008/auth/google/login
3. The OAuth flow should complete successfully without state mismatch errors

## Key Lessons
1. Don't manually manipulate OAuth state - let the library handle it
2. Be careful with `pop()` operations on session data
3. Clean up session data only after you're done using it
4. Add comprehensive error handling for OAuth flows