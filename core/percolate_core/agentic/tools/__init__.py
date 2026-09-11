"""Tool binding: register once, resolve per run, invoke over the network.

Zero built-in tools (``brief.md`` §5.2). Everything here reaches an
independently deployed service; nothing here answers a call itself.
"""

from .mcp import McpProvider
from .openapi import OpenApiProvider
from .provider import ToolProvider, resolve_credential
from .registry import (
    PROVIDERS,
    DiscoveryFailed,
    ResolvedToolset,
    invoke,
    resolve_toolset,
    sync_server,
)
from .toolset import build_pydantic_ai_tools

__all__ = [
    "PROVIDERS",
    "DiscoveryFailed",
    "McpProvider",
    "OpenApiProvider",
    "ResolvedToolset",
    "ToolProvider",
    "build_pydantic_ai_tools",
    "invoke",
    "resolve_credential",
    "resolve_toolset",
    "sync_server",
]
