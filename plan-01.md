# Plan-01: Role-Based Function Access Control & Dynamic System Prompts

## Overview

This plan outlines the implementation of two key features:
1. **Role-based access control for functions** - Restrict function access based on user role levels
2. **Dynamic system prompts from database** - Load customizable system prompts from the Settings table

## Current State Analysis

### Existing Infrastructure

1. **Authentication System** (already implemented):
   - API keys get `role_level = 1` (full access)
   - OAuth tokens get `role_level` from metadata or default to 100
   - Admin check requires `role_level <= 1`
   - Lower role_level = higher access (1 = admin, 100 = basic user)

2. **Database Schema**:
   - User table has `role_level` field (INTEGER)
   - Settings table exists for configuration values
   - RLS policies use role_level for security

3. **Current Issues**:
   - ModelRunner.py line 510 calls non-existent `context.user_role_level`
   - No `keys_for_level()` method on functions collection
   - No connection between auth role_level and CallingContext
   - No p8.tool decorator exists for access control

## Implementation Plan

### Phase 1: Add Role Level to CallingContext

#### 1.1 Update CallingContext Classes

**File**: `/clients/python/percolate/percolate/services/llm/CallingContext.py`

Add `role_level` field to both CallingContext and ApiCallingContext:
```python
class CallingContext:
    role_level: Optional[int] = None #if none, do not apply - assume system user
    # ... existing fields ...
```

#### 1.2 Create context_with_role_level Method

Add class method to CallingContext to augment with role from database:
```python
@classmethod
def context_with_role_level(cls, context: 'CallingContext', user_id: str) -> 'CallingContext':
    """
    Augment context with user's role_level from database
    """
    # Query user table for role_level
    # Return updated context
```

#### 1.3 Update Authentication to Pass Role Level

**File**: `/clients/python/percolate/percolate/api/endpoints.py`

Modify endpoints to pass role_level from auth context to CallingContext:
```python
# In run_prompt and similar endpoints
context = CallingContext(
    username=auth_context.username,
    user_id=auth_context.user_id,
    role_level=auth_context.role_level,  # Add this
    # ... other fields ...
)
```

### Phase 2: Create p8.tool Decorator

#### 2.1 Create Tool Decorator

**New File**: `/clients/python/percolate/percolate/decorators.py`

```python
def tool(access_required: int = 100):
    """
    Decorator to mark functions as tools with access control
    
    Args:
        access_required: Minimum role level required (lower = more restrictive)
                        Default 100 allows all users
    """
    def decorator(func):
        # Store access requirement as function attribute
        func._p8_access_required = access_required
        func._p8_is_tool = True
        return func
    return decorator
```

#### 2.2 Update p8 Interface

**File**: `/clients/python/percolate/percolate/interface.py`

Add tool decorator to exports:
```python
from .decorators import tool
# Export in __all__
```

### Phase 3: Enhance Function Management

#### 3.1 Update Functions

The tool decorator is added only on class method functions for now but could be included in the database later
see the agent example 
UserRoleAgent

#### 3.2 Add Filtering to FunctionManager

**File**: `/clients/python/percolate/percolate/services/FunctionManager.py`

Add role level tracking and filtering:

```python
class FunctionManager:
    def __init__(cls, use_concise_plan:bool=True, custom_planner=None):
        cls._functions = {}
        cls._function_access_levels = {}  # New: track access levels
        # ... existing code ...
    
    def add_function(cls, function: typing.Callable | Function):
        """Modified to track access levels from decorator"""
        # ... existing code ...
        if function.name not in cls._functions:
            if function.name[:1] != '_' and function.name not in EXCLUDED_SYSTEM_FUNCTIONS:
                cls._functions[function.name] = function
                
                # Check for access level from decorator
                if hasattr(function, 'fn') and hasattr(function.fn, '_p8_access_required'):
                    access_level = function.fn._p8_access_required
                    if access_level < 100:  # Only track restricted functions
                        cls._function_access_levels[function.name] = access_level
                
                logger.debug(f"added function {function.name}")
    
    def get_functions_for_role_level(cls, user_role_level: Optional[int]) -> Dict[str, Function]:
        """
        Return functions accessible to the given role level
        
        Args:
            user_role_level: User's role level (lower = more access)
                            None means system/unrestricted access
        
        Returns:
            Dictionary of accessible functions
        """
        if user_role_level is None:
            # System access - return all functions
            return cls._functions
        
        accessible_functions = {}
        for name, func in cls._functions.items():
            required_level = cls._function_access_levels.get(name, 100)
            if user_role_level <= required_level:
                accessible_functions[name] = func
        
        return accessible_functions
```


### Phase 4: Fix ModelRunner Integration

#### 4.1 Update ModelRunner.run Method

**File**: `/clients/python/percolate/percolate/services/ModelRunner.py`

Fix line 510 and properly filter functions:
```python
# Replace line 510
available_functions = self._function_manager.get_functions_for_role_level(
    context.role_level if context else 100
)

# Update line 514
self.messages = self.agent_model.build_message_stack(
    question=question,
    functions=list(available_functions.keys()),
    # ... rest of params ...
)
```

#### 4.2 Update Function Descriptions

Modify function_descriptions property to respect role level:
```python
@property
def function_descriptions(self) -> typing.List[dict]:
    """Provide function specs filtered by current user's role level"""
    role_level = self._context.role_level if self._context else 100
    filtered_functions = self._function_manager.get_functions_for_role_level(role_level)
    return [f.function_spec for _, f in filtered_functions.items()]
```

### Phase 5: Dynamic System Prompts

#### 5.1 Create Master Prompt Loader

**New File**: `/clients/python/percolate/percolate/utils/env.py`

```python
import os
from typing import Optional
from percolate.utils import logger

class _MasterPromptLoader:
    """Singleton loader for master prompt from database"""
    _instance = None
    _master_prompt: Optional[str] = None
    _loaded = False
    
    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance
    
    def get_prompt(self) -> str:
        """Get master prompt, loading from DB on first access"""
        if not self._loaded:
            self._load_prompt()
        return self._master_prompt or ""
    
    def _load_prompt(self):
        """Load prompt from database or environment"""
        self._loaded = True
        try:
            # Try environment variable first for override
            env_prompt = os.getenv('P8_MASTER_PROMPT')
            if env_prompt:
                self._master_prompt = env_prompt
                return
            
            # Load from database
            from percolate.services import Postgres
            result = p8.repository().execute(
                'SELECT value FROM p8."Settings" WHERE key = %s',
                ['system_prompt']
            )
            if result and result[0]['value']:
                self._master_prompt = result[0]['value']
                logger.info("Loaded master prompt from database")
            else:
                self._master_prompt = ""
                
        except Exception as e:
            logger.warning(f"Failed to load master prompt: {e}")
            self._master_prompt = ""

# Singleton instance
_loader = _MasterPromptLoader()
MASTER_PROMPT = property(lambda: _loader.get_prompt())
```

### Phase 6: Create UserRoleAgent Demo

#### 6.1 Create Demo Agent

**New File**: `/clients/python/percolate/percolate/types/UserRoleAgent.py`

```python
import percolate as p8
from percolate.models import AbstractModel
from percolate.utils.env import MASTER_PROMPT

class UserRoleAgent(AbstractModel):
    """Demo agent showing role-based function access"""
    
    @classmethod
    def get_model_description(cls) -> str:
        """Override to use MASTER_PROMPT if available"""
        prompt = MASTER_PROMPT()
        return prompt if prompt else cls.__doc__
    
    @p8.tool(access_required=100)  # All users
    def get_general_info(self, question: str, category: str = None):
        """
        Get general information from p8.Resources available to all users.
        
        Args:
            question: Natural language question to search for
            category: Optional category to filter results
        """
        # Load p8.Resources model
        model = p8.try_load_model('p8.Resources', allow_abstract=True)
        repo = p8.repository(model)
        
        # Perform semantic-only search (skip SQL search)
        results = repo.search(question, semantic_only=True)
        
        # Filter by category if provided
        if category and results:
            results = [r for r in results if r.get('category') == category]
        
        return {"results": results, "source": "p8.Resources"}
    
    @p8.tool(access_required=10)  # Partner level
    def get_partner_info(self, question: str, category: str = None):
        """
        Get partner-level information from public.CreateOneResources (partner access required).
        
        Args:
            question: Natural language question to search for
            category: Optional category to filter results
        """
        # Load public.CreateOneResources model
        model = p8.try_load_model('public.CreateOneResources', allow_abstract=True)
        repo = p8.repository(model)
        
        # Perform semantic-only search (skip SQL search)
        results = repo.search(question, semantic_only=True)
        
        # Filter by category if provided
        if category and results:
            results = [r for r in results if r.get('category') == category]
            
        return {"results": results, "source": "public.CreateOneResources"}
    
    @p8.tool(access_required=1)  # Admin only
    def get_executive_info(self, question: str, category: str = None):
        """
        Get executive information from executive.ExecutiveResources (admin access required).
        
        Args:
            question: Natural language question to search for
            category: Optional category to filter results
        """
        # Load executive.ExecutiveResources model
        model = p8.try_load_model('executive.ExecutiveResources', allow_abstract=True)
        repo = p8.repository(model)
        
        # Perform semantic-only search (skip SQL search)
        results = repo.search(question, semantic_only=True)
        
        # Filter by category if provided
        if category and results:
            results = [r for r in results if r.get('category') == category]
            
        return {"results": results, "source": "executive.ExecutiveResources"}
    
```

### Phase 7: PostgresService Enhancement

#### 7.1 Update PostgresService search method

**File**: `/clients/python/percolate/percolate/services/PostgresService.py`

Update the search method to support semantic_only parameter:

```python
def search(self, question: str, user_id: str = None, semantic_only: bool = False):
    """
    If the repository has been activated with a model we use the models search function
    Otherwise we use percolates generic plan and search.
    Either way, feel free to ask a detailed question and we will seek data.

    Args:
        question: detailed natural language question
        user_id: optional user id for row-level security (deprecated)
        semantic_only: if True, only perform vector/semantic search, skip SQL search
    """
    # ... existing code ...
    
    Q = f"""select * from p8.query_entity(%s,%s,%s,%s) """
    result = self.execute(Q, data=(question, self.model.get_model_full_name(), None, semantic_only))
```

This allows the UserRoleAgent to use semantic-only search for all resource queries, which is more appropriate for natural language questions against document resources.

### Phase 8: Integration with ModelRunner

#### 8.1 Update ModelRunner for Dynamic Prompts

**File**: `/clients/python/percolate/percolate/services/ModelRunner.py`

Update the run() method to use dynamic system prompt:

```python
# In run() method, around line 517:
from percolate.utils.env import MASTER_PROMPT

# Get dynamic prompt
dynamic_prompt = MASTER_PROMPT()
system_prompt = f"{GENERIC_P8_PROMPT}\n\n{dynamic_prompt}" if dynamic_prompt else GENERIC_P8_PROMPT

self.messages = self.agent_model.build_message_stack(
    question=question,
    functions=list(available_functions.keys()),
    data=data,
    system_prompt_preamble=system_prompt,
    user_memory=self._context.get_user_memory(),
)
```

Also update the stream() method similarly around line 355.

### Phase 9: Testing Plan

1. **Unit Tests**:
   - Test p8.tool decorator sets correct attributes
   - Test FunctionManager role filtering
   - Test CallingContext with role_level
   - Test MASTER_PROMPT singleton behavior

2. **Integration Tests**:
   - Test UserRoleAgent with different role levels:
     - Admin (role_level=1): Can access all functions
     - Partner (role_level=10): Can access general and partner functions
     - User (role_level=100): Can only access general functions
   - Test dynamic prompt loading from database

3. **Manual Testing**:
   ```python
   # Test with admin user (role_level=1)
   agent = p8.Agent(UserRoleAgent)
   context = CallingContext(role_level=1)
   
   # Admin can access all functions
   response = agent.run("Search for information about budgets", context=context)
   # Can call get_executive_info, get_partner_info, and get_general_info
   
   # Test with partner user (role_level=10)
   context = CallingContext(role_level=10)
   response = agent.run("Search for create one documentation", context=context)
   # Can call get_partner_info and get_general_info, but not get_executive_info
   
   # Test with regular user (role_level=100)
   context = CallingContext(role_level=100)
   response = agent.run("Search for general help", context=context)
   # Can only call get_general_info
   
   # Test category filtering
   response = agent.run("Search for technical docs in the engineering category", context=context)
   # Will search with category='engineering'
   ```

