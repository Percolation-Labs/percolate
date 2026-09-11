"""Shared by every p8 service: connecting as the caller, and configuration.

Deliberately small and dependency-light (asyncpg only). Anything that needs
boto3, FastAPI or pydantic-ai belongs in the subpackage that needs it, so
`pip install p8` for someone writing their own worker stays tiny.
"""

from .config import ConfigError, TerminalError, credential, dsn, optional, required
from .credentials import CredentialRefused, credential_for
from .identity import (
    as_caller,
    as_service,
    claims_from_jwt,
    close_pool,
    open_pool,
    pool,
    set_pool,
)

__all__ = [
    "ConfigError",
    "CredentialRefused",
    "TerminalError",
    "as_caller",
    "as_service",
    "claims_from_jwt",
    "close_pool",
    "credential",
    "credential_for",
    "dsn",
    "open_pool",
    "optional",
    "pool",
    "required",
    "set_pool",
]
