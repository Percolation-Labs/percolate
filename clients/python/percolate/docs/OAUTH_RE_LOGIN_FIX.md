# OAuth Re-Login Fix Summary

## Problem
When users attempted to login again with an existing session, they received:
```
MismatchingStateError: CSRF Warning! State not equal in request and response.
```

## Root Cause
The issue occurred because:
1. Users had existing session data from previous successful logins
2. The session contained `['sync_files', 'token', 'session_id']` but no OAuth state
3. Authlib couldn't create new OAuth state with the existing session data
4. The callback couldn't find the expected OAuth state, causing the mismatch error

## Solution
Implemented automatic re-login detection and session clearing:

```python
# In login_via_google endpoint
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

## Verification
The fix is working correctly when you see these logs:
```
Session keys before OAuth redirect: ['sync_files', 'token', 'session_id']
Re-login detected - clearing session for fresh OAuth flow
Session keys at callback start: ['sync_files', '_state_google_knjekfzmvgWjEQdW7lkZdVb80F0LN4']
OAuth states in session: ['_state_google_knjekfzmvgWjEQdW7lkZdVb80F0LN4']
```

## Key Insights
1. Persistent sessions can interfere with OAuth flows
2. Authlib needs a clean slate to create OAuth state
3. Re-login attempts are common during development
4. Session clearing must preserve user intent (redirect_uri, sync_files)

This fix ensures smooth re-login experiences while maintaining session persistence for normal usage.