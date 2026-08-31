#!/usr/bin/env python3
"""Mint a test-only HS256 JWT for the dev stack.

Lives here rather than being borrowed from a sibling repo: a dev harness that
depends on a file in another checkout breaks the moment that checkout moves,
which is exactly what happened. Not for real use — the secret is a hardcoded
test value that matches dev/stack.sh's PostgREST configuration.
"""

import base64
import hashlib
import hmac
import json
import sys
import time

SECRET = "experiment-only-jwt-secret-not-for-real-use-0123456789"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def mint(sub: str, role: str = "authenticated", ttl: int = 3600) -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    payload = {"role": role, "sub": sub, "exp": int(time.time()) + ttl}
    signing_input = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(payload).encode())}"
    signature = hmac.new(SECRET.encode(), signing_input.encode(), hashlib.sha256).digest()
    return f"{signing_input}.{b64url(signature)}"


if __name__ == "__main__":
    sub = sys.argv[1] if len(sys.argv) > 1 else "aaaaaaaa-0000-0000-0000-000000000001"
    role = sys.argv[2] if len(sys.argv) > 2 else "authenticated"
    print(mint(sub, role))
