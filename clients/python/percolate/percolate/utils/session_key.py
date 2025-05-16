"""
Session key management for Percolate API.

This module provides a stable session key for the SessionMiddleware,
ensuring session persistence across server restarts.
"""

import os
import uuid
from pathlib import Path
import json
from percolate.utils import logger
from typing import Optional


def get_session_key_path() -> Path:
    """Get the path to the session key file"""
    # Store in home directory under .percolate/session_key
    base_path = Path.home() / '.percolate' / 'auth'
    base_path.mkdir(parents=True, exist_ok=True)
    return base_path / 'session_key.json'


def load_session_key() -> Optional[str]:
    """
    Load the session key from file or environment variable.
    
    Returns:
        The session key if found, None otherwise
    """
    # First check environment variable
    env_key = os.environ.get('P8_SESSION_KEY')
    if env_key:
        logger.info("Using session key from environment variable")
        return env_key
    
    # Then check file
    key_path = get_session_key_path()
    if key_path.exists():
        try:
            with open(key_path, 'r') as f:
                data = json.load(f)
                key = data.get('session_key')
                if key:
                    logger.info("Loaded session key from file")
                    return key
        except Exception as e:
            logger.error(f"Error loading session key from file: {e}")
    
    return None


def generate_session_key() -> str:
    """
    Generate a new session key and save it to file.
    
    Returns:
        The generated session key
    """
    # Generate a new key
    key = str(uuid.uuid4())
    
    # Save to file
    key_path = get_session_key_path()
    try:
        with open(key_path, 'w') as f:
            json.dump({
                'session_key': key,
                'created_at': str(uuid.uuid1())
            }, f, indent=2)
        
        # Set restrictive permissions
        os.chmod(key_path, 0o600)
        
        logger.info(f"Generated new session key and saved to {key_path}")
    except Exception as e:
        logger.error(f"Error saving session key: {e}")
    
    return key


def get_stable_session_key() -> str:
    """
    Get a stable session key for the SessionMiddleware.
    
    This ensures session persistence across server restarts by:
    1. Checking for a key in environment variable P8_SESSION_KEY
    2. Loading from ~/.percolate/auth/session_key.json if exists
    3. Generating and saving a new key if needed
    
    Returns:
        A stable session key
    """
    # Try to load existing key
    key = load_session_key()
    
    # If no key exists, generate one
    if not key:
        key = generate_session_key()
    
    return key


# For backward compatibility, export a simple function
def get_session_secret() -> str:
    """Get the session secret key (backwards compatible)"""
    return get_stable_session_key()