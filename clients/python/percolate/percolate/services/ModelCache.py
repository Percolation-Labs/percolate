"""
Model Cache singleton for storing and reusing loaded models.

This module provides a simple in-memory cache for agent models to avoid 
expensive reloading of models between requests, reducing latency when 
handling streaming requests.
"""

import threading
import time
from typing import Dict, Any, Optional, Tuple
from percolate.utils import logger
from percolate.models import AbstractModel


class ModelCache:
    """
    Singleton cache for agent models to reduce initialization overhead.
    
    This cache stores models by name, with optional expiration and size limits.
    It's thread-safe for use in multithreaded environments.
    """
    _instance = None
    _lock = threading.Lock()
    
    def __new__(cls):
        with cls._lock:
            if cls._instance is None:
                cls._instance = super(ModelCache, cls).__new__(cls)
                cls._instance._initialize()
            return cls._instance
    
    def _initialize(self):
        """Initialize the cache internals."""
        self._cache: Dict[str, Tuple[Any, float]] = {}
        self._access_times: Dict[str, float] = {}
        self._hit_count = 0
        self._miss_count = 0
        self._max_size = 100  # Maximum number of models to cache
        self._default_ttl = 3600  # Default TTL in seconds (1 hour)
        self._lock = threading.Lock()
        logger.info("ModelCache initialized")
    
    def get(self, model_name: str) -> Optional[AbstractModel]:
        """
        Get a model from the cache by name.
        
        Args:
            model_name: The fully qualified name of the model
            
        Returns:
            The cached model instance or None if not found/expired
        """
        with self._lock:
            current_time = time.time()
            
            # Convert hyphenated names (used in URLs) to dotted format
            if '-' in model_name:
                model_name = model_name.replace('-', '.')
            
            # Check if model exists in cache and isn't expired
            if model_name in self._cache:
                model, expiry_time = self._cache[model_name]
                if expiry_time > current_time or expiry_time == 0:
                    # Update access time for LRU logic
                    self._access_times[model_name] = current_time
                    self._hit_count += 1
                    logger.debug(f"Cache HIT for model: {model_name}")
                    return model
                else:
                    # Expired, remove from cache
                    self._remove(model_name)
            
            self._miss_count += 1
            logger.debug(f"Cache MISS for model: {model_name}")
            return None
    
    def put(self, model_name: str, model: Any, ttl: Optional[int] = None) -> None:
        """
        Add a model to the cache.
        
        Args:
            model_name: The fully qualified name of the model
            model: The model instance to cache
            ttl: Time-to-live in seconds, 0 for no expiration, None for default
        """
        with self._lock:
            # Ensure cache doesn't exceed max size by removing LRU items if needed
            if len(self._cache) >= self._max_size and model_name not in self._cache:
                self._evict_lru()
            
            # Set expiry time based on TTL
            current_time = time.time()
            if ttl is None:
                ttl = self._default_ttl
            
            expiry_time = 0 if ttl == 0 else current_time + ttl
            
            # Store model and update access time
            self._cache[model_name] = (model, expiry_time)
            self._access_times[model_name] = current_time
            
            logger.debug(f"Added model to cache: {model_name}")
    
    def _remove(self, model_name: str) -> None:
        """Remove a model from the cache."""
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
        logger.debug(f"Evicted LRU model from cache: {lru_key}")
    
    def clear(self) -> None:
        """Clear the entire cache."""
        with self._lock:
            self._cache.clear()
            self._access_times.clear()
            logger.info("Model cache cleared")
    
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
                "cached_models": list(self._cache.keys())
            }


# Convenience methods for global access to the singleton

def get_model(model_name: str) -> Optional[AbstractModel]:
    """
    Get a model from the cache, or load and cache it if not found.
    
    Args:
        model_name: The fully qualified name of the model
        
    Returns:
        The model instance or None if it couldn't be loaded
    """
    cache = ModelCache()
    model = cache.get(model_name)
    
    if model is None:
        try:
            # Import here to avoid circular import
            from percolate.interface import try_load_model
            
            # Try to load the model
            model = try_load_model(model_name)
            if model:
                # Cache the newly loaded model
                cache.put(model_name, model)
        except Exception as e:
            logger.warning(f"Failed to load model {model_name}: {str(e)}")
            return None
    
    return model


def cache_model(model_name: str, model: Any, ttl: Optional[int] = None) -> None:
    """
    Explicitly add a model to the cache.
    
    Args:
        model_name: The fully qualified name of the model
        model: The model instance to cache
        ttl: Time-to-live in seconds, 0 for no expiration, None for default
    """
    ModelCache().put(model_name, model, ttl)


def clear_cache() -> None:
    """Clear the entire model cache."""
    ModelCache().clear()


def get_cache_stats() -> Dict[str, Any]:
    """Get statistics about the model cache."""
    return ModelCache().get_stats()