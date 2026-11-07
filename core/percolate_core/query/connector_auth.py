"""Per-user connector keys exchanged for short-lived, scoped internal JWTs.

Keys are verified against Percolate on EVERY request. No shared user, bearer
cache, or expiry bypass: revocation and account disable take effect immediately.
"""
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID
from ..core.identity import mint_jwt

CONNECTOR_SCOPES = frozenset({'mcp:query', 'canvas:read', 'canvas:write'})

class ConnectorAuthError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message

@dataclass(frozen=True)
class Principal:
    authorization: str
    user_id: str
    key_id: str
    scopes: frozenset[str]

    def allows(self, method, params):
        if method in ('initialize', 'ping', 'tools/list') or method.startswith('notifications/'):
            return True
        if method in ('resources/list', 'resources/read', 'resources/templates/list'):
            return 'canvas:read' in self.scopes
        if method != 'tools/call':
            return False
        name = params.get('name')
        if name == 'query':
            return 'mcp:query' in self.scopes
        if name not in ('canvas', 'canvas_ui'):
            return False
        args = params.get('arguments') or {}
        if not isinstance(args, dict):
            return False
        needed = {'canvas:read'}
        if args.get('action') != 'read':
            needed.add('canvas:write')
        if args.get('action') == 'query':
            needed.add('mcp:query')
        return needed <= self.scopes

class ConnectorAuth:
    def __init__(self, upstream, signing_key_file, ttl_seconds=300):
        path = Path(signing_key_file)
        if path.stat().st_mode & 0o077:
            raise ValueError('MCP signing key file must be owner-only (chmod 600).')
        self.secret = path.read_text().strip()
        if len(self.secret) < 32 or self.secret == 'change-me-a-long-random-string-at-least-32-chars':
            raise ValueError('Connector auth needs the deployment signing secret, not the published dev default.')
        if not 1 <= ttl_seconds <= 900:
            raise ValueError('Connector access-token TTL must be between 1 and 900 seconds.')
        self.upstream, self.ttl_seconds = upstream, ttl_seconds

    def authenticate(self, header):
        if not header or not header.startswith('Bearer ') or not 20 <= len(header[7:]) <= 512:
            raise ConnectorAuthError(401, 'A per-user connector key is required.')
        rows, error = self.upstream.rpc('verify_api_key', {'p_raw_key': header[7:]}, None, 'rbac')
        if error:
            raise ConnectorAuthError(503, 'Connector identity service is unavailable.')
        if not isinstance(rows, list) or len(rows) != 1 or not rows[0].get('user_id'):
            raise ConnectorAuthError(401, 'Connector key is invalid, revoked, or its user is inactive.')
        row = rows[0]
        try:
            user, key = str(UUID(row['user_id'])), str(UUID(row['key_id']))
            scopes = frozenset(row['scopes'])
            if not all(isinstance(scope, str) for scope in scopes): raise ValueError()
        except (ValueError, TypeError, KeyError):
            raise ConnectorAuthError(503, 'Connector identity service returned an invalid identity.') from None
        jwt = mint_jwt(user, self.secret, role='authenticated', ttl_seconds=self.ttl_seconds,
                       extra={'actor': 'agent', 'api_key_id': key})
        return Principal('Bearer ' + jwt, user, key, scopes)
