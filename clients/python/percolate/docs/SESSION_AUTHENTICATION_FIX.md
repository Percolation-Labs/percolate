# Session Authentication Fix

## Problem

The session authentication wasn't working because the SessionMiddleware was using a randomly generated secret key on each server restart:

```python
k = str(uuid1())  # Random key each time!
app.add_middleware(SessionMiddleware, secret_key=k)
```

This caused all existing session cookies to become invalid whenever the server restarted, breaking session persistence.

## Solution

I've implemented a stable session key management system that:

1. Checks for a session key in the environment variable `P8_SESSION_KEY`
2. Loads from `~/.percolate/auth/session_key.json` if it exists
3. Generates and saves a new key if needed

### Files Changed

1. **Created `/percolate/utils/session_key.py`**:
   - Provides `get_stable_session_key()` function
   - Manages session key persistence
   - Handles key generation and storage

2. **Updated `/percolate/api/main.py`**:
   - Imports `get_stable_session_key`
   - Uses stable key instead of random UUID
   - Ensures session persistence across restarts

## How it Works

```python
# Use stable session key for session persistence across restarts
session_key = get_stable_session_key()

logger.info('Percolate api app started with stable session key')
 
app.add_middleware(SessionMiddleware, secret_key=session_key)
```

The `get_stable_session_key()` function:
1. First checks `P8_SESSION_KEY` environment variable
2. Falls back to loading from `~/.percolate/auth/session_key.json`
3. Generates a new key and saves it if neither exists

## Usage

### Option 1: Environment Variable (Recommended for Production)

```bash
export P8_SESSION_KEY="your-stable-secret-key"
uvicorn percolate.api.main:app --port 5000
```

### Option 2: Automatic File-Based (Development)

Simply start the server - it will automatically create and use a persistent key:

```bash
uvicorn percolate.api.main:app --port 5000
```

The key is stored in `~/.percolate/auth/session_key.json` with restricted permissions (0600).

## Testing

1. Start the server and login via Google
2. Note your session cookie works
3. Stop and restart the server
4. Verify the same session cookie still works

## Security Considerations

- The session key file has restricted permissions (0600)
- For production, use the `P8_SESSION_KEY` environment variable
- Never commit the session key to version control
- Rotate the key periodically for security

## Benefits

1. **Session Persistence**: Sessions survive server restarts
2. **User Experience**: Users stay logged in across deployments
3. **Development**: Easier testing without constant re-authentication
4. **Security**: Controlled key management with proper permissions