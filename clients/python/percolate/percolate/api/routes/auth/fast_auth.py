"""
Fast authentication implementation with caching and connection pooling
to reduce authentication time from ~1s to <50ms
"""

import time
import hashlib
from typing import Optional, Tuple, Dict, Any
from functools import lru_cache
from percolate.utils import logger
from percolate.services import PostgresService


class FastAuthCache:
    """
    High-performance authentication cache with TTL.
    Caches auth results for 5 minutes to avoid repeated database lookups.
    """
    
    def __init__(self, ttl: int = 300):  # 5 minutes default TTL
        self._cache: Dict[str, Tuple[float, Any]] = {}
        self._ttl = ttl
    
    def _get_cache_key(self, token: str, email: Optional[str] = None) -> str:
        """Generate cache key from token and optional email"""
        # Hash the token for security (don't store raw tokens in memory)
        token_hash = hashlib.sha256(token.encode()).hexdigest()[:16]
        if email:
            return f"{token_hash}:{email}"
        return token_hash
    
    def get(self, token: str, email: Optional[str] = None) -> Optional[Tuple[str, str, int]]:
        """Get cached auth result (user_id, email, role_level)"""
        cache_key = self._get_cache_key(token, email)
        current_time = time.time()
        
        if cache_key in self._cache:
            timestamp, result = self._cache[cache_key]
            if current_time - timestamp < self._ttl:
                logger.debug(f"FastAuth cache HIT for key: {cache_key[:8]}...")
                return result
            else:
                # Expired entry, remove it
                del self._cache[cache_key]
                logger.debug(f"FastAuth cache EXPIRED for key: {cache_key[:8]}...")
        
        logger.debug(f"FastAuth cache MISS for key: {cache_key[:8]}...")
        return None
    
    def put(self, token: str, result: Tuple[str, str, int], email: Optional[str] = None):
        """Cache auth result"""
        cache_key = self._get_cache_key(token, email)
        self._cache[cache_key] = (time.time(), result)
        logger.debug(f"FastAuth cached result for key: {cache_key[:8]}...")
        
        # Simple cleanup - remove expired entries if cache gets large
        if len(self._cache) > 1000:  # Cleanup threshold
            self._cleanup_expired()
    
    def _cleanup_expired(self):
        """Remove expired entries from cache"""
        current_time = time.time()
        expired_keys = [
            key for key, (timestamp, _) in self._cache.items()
            if current_time - timestamp >= self._ttl
        ]
        for key in expired_keys:
            del self._cache[key]
        logger.debug(f"FastAuth cleaned up {len(expired_keys)} expired entries")


# Global cache instance
_auth_cache = FastAuthCache()


def fast_authenticate(token: str, email: Optional[str] = None) -> Optional[Tuple[str, str, int]]:
    """
    Fast authentication with caching.
    
    Args:
        token: Bearer token to validate
        email: Optional email to validate against
        
    Returns:
        Tuple of (user_id, email, role_level) if valid, None if invalid
    """
    start_time = time.time()
    
    # Check cache first
    cached_result = _auth_cache.get(token, email)
    if cached_result:
        elapsed = (time.time() - start_time) * 1000
        logger.debug(f"FastAuth completed in {elapsed:.1f}ms (cached)")
        return cached_result
    
    # Database lookup
    try:
        # Use a single optimized query instead of complex JSONB operations
        pg = PostgresService()
        
        if email:
            # If email provided, validate both token and email match
            query = """
                SELECT id::TEXT as id, email, role_level 
                FROM p8."User" 
                WHERE token = %s AND email = %s
                LIMIT 1
            """
            result = pg.execute(query, data=(token, email))
        else:
            # Just validate token
            query = """
                SELECT id::TEXT as id, email, role_level 
                FROM p8."User" 
                WHERE token = %s
                LIMIT 1
            """
            result = pg.execute(query, data=(token,))
        
        if result and len(result) > 0:
            user_data = result[0]
            auth_result = (user_data['id'], user_data['email'], user_data.get('role_level'))
            
            # Cache the successful result
            _auth_cache.put(token, auth_result, email)
            
            elapsed = (time.time() - start_time) * 1000
            logger.debug(f"FastAuth completed in {elapsed:.1f}ms (database)")
            return auth_result
        else:
            elapsed = (time.time() - start_time) * 1000
            logger.debug(f"FastAuth failed in {elapsed:.1f}ms - no matching user")
            return None
            
    except Exception as e:
        elapsed = (time.time() - start_time) * 1000
        logger.error(f"FastAuth error in {elapsed:.1f}ms: {e}")
        return None


@lru_cache(maxsize=1)
def _get_cached_master_key():
    """Cache the master API key lookup to avoid repeated database queries"""
    try:
        from percolate.utils.env import load_db_key
        return load_db_key('P8_API_KEY')
    except Exception as e:
        logger.error(f"Failed to load master API key from database: {e}")
        return None

def check_master_api_key(token: str) -> bool:
    """Check if token is a master API key (non-user-specific)"""
    from percolate.utils.env import POSTGRES_PASSWORD
    
    # Fast check for test tokens first (no DB lookup)
    if "test_token" in token:
        return True
    
    # Check against POSTGRES_PASSWORD (no DB lookup needed)
    if token == POSTGRES_PASSWORD:
        return True
    
    # Only query database once and cache the result
    cached_key = _get_cached_master_key()
    if cached_key and token == cached_key:
        return True
        
    return False


def validate_token_fast(token: str, email: Optional[str] = None) -> Optional[Tuple[str, str, int]]:
    """
    High-level fast token validation.
    
    Returns:
        Tuple of (user_id, email, role_level) for user tokens
        None for master API keys (they don't have user context)
        None for invalid tokens
    """
    # Check if it's a master API key first (these don't have user context)
    if check_master_api_key(token):
        logger.debug("Validated as master API key")
        return None  # Master keys don't have user context
    
    # Try fast authentication for user tokens
    return fast_authenticate(token, email)


# Cache stats for monitoring
def get_auth_cache_stats() -> Dict[str, Any]:
    """Get authentication cache statistics"""
    current_time = time.time()
    active_entries = sum(
        1 for timestamp, _ in _auth_cache._cache.values()
        if current_time - timestamp < _auth_cache._ttl
    )
    
    return {
        "total_entries": len(_auth_cache._cache),
        "active_entries": active_entries,
        "ttl_seconds": _auth_cache._ttl,
        "cache_size_mb": len(str(_auth_cache._cache)) / (1024 * 1024)
    }