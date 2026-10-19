"""Shared by every p8 service: connecting as the caller, and configuration.

Deliberately small and dependency-light (asyncpg only). Anything that needs
boto3, FastAPI or pydantic-ai belongs in the subpackage that needs it, so
`pip install p8` for someone writing their own worker stays tiny.
"""

from .config import (
    ConfigError,
    S3Settings,
    TerminalError,
    credential,
    dsn,
    dsn_if_set,
    optional,
    required,
    s3,
)
from .credentials import CredentialRefused, credential_for
from .text import without_nul
from .identity import (
    as_caller,
    as_service,
    claims_from_jwt,
    close_pool,
    open_pool,
    pool,
    set_pool,
)
from .refusal import Refusal, refusal

__all__ = [
    "ConfigError",
    "CredentialRefused",
    "Refusal",
    "S3Settings",
    "TerminalError",
    "as_caller",
    "as_service",
    "claims_from_jwt",
    "close_pool",
    "credential",
    "credential_for",
    "dsn",
    "dsn_if_set",
    "open_pool",
    "optional",
    "pool",
    "refusal",
    "required",
    "s3",
    "set_pool",
    "without_nul",
]
