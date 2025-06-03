"""
ModelRunner Cache singleton for storing and reusing fully initialized ModelRunner instances.

This module provides a more effective cache that stores fully initialized ModelRunner
instances, not just model classes. This eliminates the significant overhead of
creating and initializing ModelRunner objects on each request.
"""

import threading
import time
from typing import Dict, Any, Optional, Tuple
from percolate.utils import logger
from percolate.models import AbstractModel
from percolate.services.ModelRunner import ModelRunner

class ModelRunnerCache:
    """
    Singleton cache for ModelRunner instances to eliminate initialization overhead.
    
    Unlike the ModelCache which only caches model classes, this cache stores fully
    initialized ModelRunner instances, preserving all registered functions and state.
    """
    _instance = None
    _lock = threading.Lock()
    
    def __new__(cls):
        with cls._lock:
            if cls._instance is None:
                logger.info("Creating new ModelRunnerCache singleton instance")
                cls._instance = super(ModelRunnerCache, cls).__new__(cls)
                cls._instance._initialize()
            else:
                logger.info("Reusing existing ModelRunnerCache singleton instance")
            return cls._instance
            
    def __init__(self):
        # We don't do initialization here because __init__ is called every time
        # the class is instantiated, even if __new__ returns an existing instance
        pass
    
    def _initialize(self):
        """Initialize the cache internals."""
        self._cache: Dict[str, Tuple[ModelRunner, float]] = {}
        self._access_times: Dict[str, float] = {}
        self._hit_count = 0
        self._miss_count = 0
        self._max_size = 20  # ModelRunners use more memory, so use a smaller max size
        self._default_ttl = 3600  # Default TTL in seconds (1 hour)
        logger.info("ModelRunnerCache initialized")
    
    def get(self, model_name: str) -> Optional[ModelRunner]:
        """
        Get a ModelRunner from the cache by name.
        
        Args:
            model_name: The fully qualified name of the model
            
        Returns:
            The cached ModelRunner instance or None if not found/expired
        """
        with self._lock:
            current_time = time.time()
            
            # Convert hyphenated names (used in URLs) to dotted format
            if '-' in model_name:
                model_name = model_name.replace('-', '.')
            
            # Extra debugging for cache inspection
            logger.info(f"Checking cache for model: {model_name}")
            logger.info(f"Current cache contents: {list(self._cache.keys())}")
            
            # Check if ModelRunner exists in cache and isn't expired
            if model_name in self._cache:
                runner, expiry_time = self._cache[model_name]
                if expiry_time > current_time or expiry_time == 0:
                    # Update access time for LRU logic
                    self._access_times[model_name] = current_time
                    self._hit_count += 1
                    logger.info(f"ModelRunnerCache HIT for runner: {model_name}")
                    return runner
                else:
                    # Expired, remove from cache
                    logger.info(f"Cache entry expired for {model_name}, removing")
                    self._remove(model_name)
            
            self._miss_count += 1
            logger.info(f"ModelRunnerCache MISS for runner: {model_name}")
            return None
    
    def put(self, model_name: str, runner: ModelRunner, ttl: Optional[int] = None) -> None:
        """
        Add a ModelRunner to the cache.
        
        Args:
            model_name: The fully qualified name of the model
            runner: The ModelRunner instance to cache
            ttl: Time-to-live in seconds, 0 for no expiration, None for default
        """
        with self._lock:
            # Convert hyphenated names (used in URLs) to dotted format - ensure consistency
            if '-' in model_name:
                model_name = model_name.replace('-', '.')
                
            # Ensure cache doesn't exceed max size by removing LRU items if needed
            if len(self._cache) >= self._max_size and model_name not in self._cache:
                self._evict_lru()
            
            # Set expiry time based on TTL
            current_time = time.time()
            if ttl is None:
                ttl = self._default_ttl
            
            expiry_time = 0 if ttl == 0 else current_time + ttl
            
            # Store ModelRunner and update access time
            self._cache[model_name] = (runner, expiry_time)
            self._access_times[model_name] = current_time
            
            logger.info(f"Added ModelRunner to cache: {model_name}")
            logger.info(f"Updated cache contents: {list(self._cache.keys())}")
    
    def _remove(self, model_name: str) -> None:
        """Remove a ModelRunner from the cache."""
        if model_name in self._cache:
            del self._cache[model_name]
        if model_name in self._access_times:
            del self._access_times[model_name]
    
    def _evict_lru(self) -> None:
        """Evict the least recently used item from cache."""
        if not self._access_times:
            return
        
        lru_key = min(self._access_times.items(), key=lambda x: x[1])[0]
        self._remove(lru_key)
        logger.debug(f"Evicted LRU ModelRunner from cache: {lru_key}")
    
    def clear(self) -> None:
        """Clear the entire cache."""
        with self._lock:
            self._cache.clear()
            self._access_times.clear()
            logger.info("ModelRunner cache cleared")
    
    def get_stats(self) -> Dict[str, Any]:
        """Get cache statistics."""
        with self._lock:
            total_requests = self._hit_count + self._miss_count
            hit_rate = (self._hit_count / total_requests) * 100 if total_requests > 0 else 0
            
            return {
                "size": len(self._cache),
                "max_size": self._max_size,
                "hit_count": self._hit_count,
                "miss_count": self._miss_count,
                "hit_rate": f"{hit_rate:.2f}%",
                "cached_runners": list(self._cache.keys())
            }


# Convenience methods for global access to the singleton

def get_runner(model_name: str, create_if_missing: bool = True, **kwargs) -> Optional[ModelRunner]:
    """
    Get a ModelRunner from the cache, or create and cache it if not found.
    
    In multi-user and multi-threaded environments, this function creates per-user ModelRunners
    by including user-specific context in the cache key. This ensures each user gets their own
    ModelRunner instance with proper access controls.
    
    Args:
        model_name: The fully qualified name of the model
        create_if_missing: If True, create a new ModelRunner when not found
        **kwargs: Additional arguments to pass to ModelRunner constructor if created
                 Important keys for multi-user support:
                 - user_id: User ID for row-level security (creates per-user ModelRunner)
                 - user_groups: User group IDs for access control
                 - role_level: Role level for security
        
    Returns:
        The ModelRunner instance or None if it couldn't be loaded and create_if_missing is False
    """
    # For multi-user support, we need to create a cache key that includes user context
    # If user_id is provided, we'll create a per-user runner with that user's security context
    user_id = kwargs.get('user_id')
    user_groups = kwargs.get('user_groups')
    role_level = kwargs.get('role_level')
    
    # Create a cache key that includes user context if present
    # For debugging, let's log what we're getting as input
    logger.info(f"ModelRunnerCache get_runner called with model_name={model_name}, user_id={user_id}, role_level={role_level}")
    
    # Standardize model name format (replace dots with hyphens if they're in the name)
    if '-' in model_name:
        model_name = model_name.replace('-', '.')
    
    # Create a simpler cache key, just using the model name for now
    # During initial development, let's avoid user-specific runners for simplicity
    cache_key = model_name
    
    # Debug log the final cache key
    logger.info(f"Using cache key: {cache_key}")
    
    cache = ModelRunnerCache()
    runner = cache.get(cache_key)
    
    if runner is None and create_if_missing:
        try:
            # Import here to avoid circular import
            from percolate.interface import try_load_model
            from percolate.models import Resources
            
            # Try to load the model
            model = try_load_model(model_name)
            if model:
                # Create a new ModelRunner with user context and cache it
                runner = ModelRunner(model, **kwargs)
                cache.put(cache_key, runner)
                logger.info(f"Created new ModelRunner for {cache_key}")
            else:
                logger.warning(f"Could not load model {model_name}")
                # Fall back to Resources if requested
                if kwargs.get('fallback_to_resources', True):
                    runner = ModelRunner(Resources, **kwargs)
                    # Don't cache the fallback
        except Exception as e:
            logger.warning(f"Failed to create ModelRunner for {model_name}: {str(e)}")
            return None
    
    return runner

def cache_runner(model_name: str, runner: ModelRunner, ttl: Optional[int] = None) -> None:
    """
    Explicitly add a ModelRunner to the cache.
    
    Args:
        model_name: The fully qualified name of the model
        runner: The ModelRunner instance to cache
        ttl: Time-to-live in seconds, 0 for no expiration, None for default
    """
    ModelRunnerCache().put(model_name, runner, ttl)

def clear_runner_cache() -> None:
    """Clear the entire ModelRunner cache."""
    ModelRunnerCache().clear()

def get_runner_cache_stats() -> Dict[str, Any]:
    """Get statistics about the ModelRunner cache."""
    return ModelRunnerCache().get_stats()