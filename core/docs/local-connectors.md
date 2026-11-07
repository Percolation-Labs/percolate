# Per-user local MCP connectors

Run an authenticated MCP endpoint against a local Percolate deployment. Each
connector belongs to an existing active user. Database row-level security uses
that user's identity; the server does not share an operator's identity.

## Provision and serve

The operator supplies `P8_ADMIN_DSN` only to the provisioning CLI. Use the normal
Percolate user-management flow first to create users and grant their roles.

```sh
percolate auth connector issue --email person@example.com --label 'Claude local' --output /private/path/Authorization.txt
percolate auth connector list --email person@example.com
```

The output file is created with mode 600 and must not already exist. It contains
the complete `Authorization` header value. Standard output contains only the
key ID and file path. The database stores its SHA-256 hash and audit metadata.
Default scopes are `mcp:query`, `canvas:read`, and `canvas:write`; repeat `--scope`
to narrow them. For a read-only canvas use `--scope canvas:read`.

Store the deployment's PostgREST JWT signing secret in an owner-only file; do
not use the published development default. The serving process needs that
file, but does not need the owner DSN:

```sh
P8_CANVAS_ENABLED=1 percolate query mcp --host 127.0.0.1 --port 8142 \
  --postgrest http://127.0.0.1:3000 \
  --signing-key-file /private/path/signing.key --access-ttl 300
```

Use `http://127.0.0.1:8142/mcp` for local Codex/Claude clients and set their
Authorization header from the file. Cloud clients need an HTTPS tunnel to this
endpoint. In Claude custom connectors choose **No sign in**, then add the fixed
**Authorization** request header. Give each user their own key, even when they
share the same endpoint. Connector-key mode exposes query/canvas tools only;
other memory tools remain available on the existing JWT pass-through server.

## Renewal, revocation and rotation

Every MCP request verifies the key with `rbac.verify_api_key`, checks its scopes,
and creates an internal access JWT valid for five minutes. An expired access
JWT therefore needs no manual client update. Revoking a key or disabling its
user prevents subsequent requests; requests already admitted may finish.

This is a long-lived, revocable API key exchanged for short-lived access tokens,
**not OAuth or automatic refresh-token rotation**. Connector keys have no
scheduled expiry under the existing RBAC schema. Explicit key rotation changes
the fixed header; update the client immediately after running:

```sh
percolate auth connector rotate --email person@example.com --key-id KEY_UUID --output /private/path/new-Authorization.txt
percolate auth connector revoke --email person@example.com --key-id KEY_UUID
```

Rotation preserves scopes and label, creates a replacement and revokes the old
key in one database transaction. Serving fails closed if verification is down.
Requests are bounded to 128KB and 32 concurrent connections with socket timeouts.

## Keep development running

Manage the MCP command with launchd on macOS or a service manager/container on
Linux, with restart enabled and private logs. The database and PostgREST must
also be running. Keep PostgREST and the development UI off the public tunnel.
Use a named Cloudflare tunnel and a hostname in your Cloudflare account for a
stable connector URL. Quick Tunnel URLs change when their process restarts.
A stable hostname requires account/domain configuration; no hostname is implied
by provisioning a key. MCP App resource delivery can be tested over HTTP, but
actual embedded canvas rendering and voice must be checked in the target client.

## Verification

`python -m unittest discover -s tests -p test_connector_auth.py` checks renewal,
identity, scopes, revocation failure handling and HTTP admission. The query MCP
regression suite also runs without changes. A disposable database rehearsal
additionally verified two-user session isolation, cross-user access rejection,
continued access after a two-second JWT expires, immediate revoke/disable,
and issue/list/rotate/revoke using the operator CLI.

The managed development deployment now uses a stable Hetzner HTTPS relay with
an automatically reconnecting SSH tunnel and cert-manager TLS renewal. See
[the deployment runbook](../dev/connectors/README.md) for configuration and
recovery. Per-user connector keys and internal token renewal are unchanged.
