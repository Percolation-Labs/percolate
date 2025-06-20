# Access Level Configuration in Percolate Models

This document explains how to configure row-level security for Percolate models using the `access_level` parameter in the model's configuration.

## Overview

Row-level security in Percolate is implemented using a combination of:
- Role-based access levels
- User ownership
- Group membership

The `access_level` parameter in a model's configuration sets the default required access level for all records of that type.

## Using the AccessLevel Enum

Percolate provides an `AccessLevel` enum in `percolate.models.p8.db_types` to standardize access level definitions:

```python
from percolate.models.p8.db_types import AccessLevel

class SensitiveDocument(BaseModel):
    id: uuid.UUID
    title: str
    content: str
    
    model_config = {
        "access_level": AccessLevel.ADMIN  # Admin access required
    }
```

This ensures consistent access level definitions throughout the codebase.

## Access Level Definitions

Percolate uses the following numeric access levels, where lower numbers indicate higher privileges:

| Level | Role     | Description                           |
|-------|----------|---------------------------------------|
| 0     | God      | Unrestricted access to all data       |
| 1     | Admin    | Administrative access                 |
| 5     | Internal | Internal/employee access              |
| 10    | Partner  | External partner access               |
| 100   | Public   | Public access (most restricted)       |

## Configuring Access Levels in Models

To set the access level for a model, add the `access_level` parameter to the model's configuration:

```python
from pydantic import BaseModel, Field
from typing import Optional
import uuid

class User(BaseModel):
    id: uuid.UUID
    name: str
    email: str
    
    model_config = {
        "access_level": 1  # Admin access required
    }

class PublicDocument(BaseModel):
    id: uuid.UUID
    title: str
    content: str
    
    model_config = {
        "access_level": 100  # Public access
    }
```

## Recommended Access Levels for Different Model Types

### System-Level Models (Access Level 0)

These models require the highest level of access and are typically used for system operations:

- Session records
- AIResponse records
- Audit logs
- System configurations

Example:
```python
class AIResponse(BaseModel):
    id: uuid.UUID
    content: str
    session_id: uuid.UUID
    
    model_config = {
        "access_level": 0  # System-level access
    }
```

### Administrative Models (Access Level 1)

These models contain sensitive information that should only be accessible to administrators:

- User accounts
- API keys
- Authentication tokens
- System health metrics

Example:
```python
class ApiKey(BaseModel):
    id: uuid.UUID
    key: str
    owner_id: uuid.UUID
    
    model_config = {
        "access_level": 1  # Admin access
    }
```

### Internal-Only Models (Access Level 5)

These models contain information that should be accessible to all employees but not external users:

- Internal documentation
- Employee resources
- Company announcements

Example:
```python
class InternalDocument(BaseModel):
    id: uuid.UUID
    title: str
    content: str
    
    model_config = {
        "access_level": 5  # Internal access
    }
```

### Partner-Level Models (Access Level 10)

These models contain information that can be shared with external partners:

- Partner documentation
- Collaboration resources
- Shared projects

Example:
```python
class PartnerResource(BaseModel):
    id: uuid.UUID
    title: str
    resource_url: str
    
    model_config = {
        "access_level": 10  # Partner access
    }
```

### Public Models (Access Level 100)

These models contain information that can be publicly accessible:

- Public documentation
- Marketing materials
- Public FAQs

Example:
```python
class PublicResource(BaseModel):
    id: uuid.UUID
    title: str
    content: str
    
    model_config = {
        "access_level": 100  # Public access
    }
```

## How Access Levels Are Applied

When a model is registered in the database:

1. The `create_script` method in `SqlModelHelper` reads the `access_level` from the model's configuration
2. The script adds a `required_access_level` column to the table with the specified default value
3. A row-level security policy is applied to the table using the `attach_rls_policy` function

This ensures that all records in the table have the appropriate access level by default.

## Overriding Access Level for Individual Records

Individual records can have their access level overridden by explicitly setting the `required_access_level` field when creating or updating the record:

```python
# Create a document with restricted access
restricted_doc = PublicDocument(
    id=uuid.uuid4(),
    title="Confidential Report",
    content="Secret information",
    required_access_level=1  # Override default public access to admin-only
)
```

## System User for Background and System Operations

For operations without explicit user context (like batch jobs, background tasks, etc.), Percolate uses a system user:

```python
from percolate.utils.env import SYSTEM_USER_ID, SYSTEM_USER_ROLE_LEVEL

# System user constants can be used directly
print(f"System user ID: {SYSTEM_USER_ID}")
print(f"System user role level: {SYSTEM_USER_ROLE_LEVEL}")

# PostgresService uses system user automatically when no user_id is provided
repo = PostgresService(model=MyModel)  # Uses system user with admin privileges
```

The system user has these characteristics:
- Fixed UUID generated from "system-user" string, ensuring consistency
- Admin privileges by default (access_level = 1)
- Can be overridden by setting the `P8_SYSTEM_USER_ID` environment variable
- Automatically used by PostgresService when no user_id is provided

## Row-Level Security Policy

The PostgreSQL security policy applies the following rules:

- Users can access a record if ANY of these conditions are met:
  1. The user owns the record (`user_id` matches the user's ID)
  2. The record has no specific owner (`user_id` is NULL)
  3. The user belongs to the record's group (`group_id` matches one of the user's groups)
  4. The user's role level is sufficient (lower than or equal to the record's `required_access_level`)

This flexible approach allows for both role-based and ownership-based access control.