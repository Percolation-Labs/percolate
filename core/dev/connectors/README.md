# Stable HTTPS relay for a local Percolate connector

The deployed development endpoint is `https://mcp-dev.percolationlabs.ai/mcp`.
The local database stays on the developer's machine. Requests travel through:

```
HTTPS → Hetzner nginx ingress → private bridge 10.42.0.1:18142
      → restricted reverse SSH tunnel → localhost:8142 → local PostgREST
```

The endpoint requires the per-user Authorization header from
[local-connectors.md](../../docs/local-connectors.md). The relay has no database,
JWT signing or connector credentials. It forwards HTTP and retains the caller's
Authorization header. The SSH private key stays on the developer's machine.

## Deployed resources

- Hetzner zone `percolationlabs.ai`: `mcp-dev A 204.168.206.185`, TTL 300.
- Dedicated `percolate-local-dev` namespace, Service, EndpointSlice and Ingress
  in `hetzner-ingress.yaml`. Existing application resources are unchanged.
- Existing `letsencrypt-prod` ClusterIssuer issues and renews the TLS certificate
  through HTTP-01. No DNS credential is needed by the runtime or cert-manager.
- Dedicated node account `percolate-relay` with a nologin shell. Install
  `relay-sshd.conf` as `/etc/ssh/sshd_config.d/60-percolate-relay.conf`, validate
  with `sshd -t`, then reload SSH. Restrictions apply only to this account.
- Its authorized key begins with
  `restrict,port-forwarding,permitlisten="10.42.0.1:18142"`. The SSH configuration
  allows remote forwarding only, restricts the listening address/port, forbids
  local forwarding, agent forwarding, TTY and interactive commands.

The remote listener binds only the node's private cluster bridge, not its public
interface. Other cluster workloads may reach that bridge, but MCP authentication
is still required. Only the exact `/mcp` path is routed publicly. The endpoint
fails closed when the local machine or tunnel is unavailable.

These files are a deployment record/template for this development relay, not an
application-chart dependency. For another node, verify its bridge address and
choose an unused port, namespace, hostname and dedicated SSH account before
applying. Keep the EndpointSlice and `PermitListen` restrictions consistent.
Multiple users of this local Percolate share the endpoint with distinct keys;
a different developer's local instance needs its own relay mapping.

## Local reconnect service

Generate a dedicated Ed25519 key with `ssh-keygen`, install only its public key
on the relay account, and verify the host key using the operator's existing
trusted SSH connection. Never disable host-key verification. Then:

```sh
python3 dev/connectors/install_macos_relay.py \
  --host 204.168.206.185 \
  --key ~/.local/share/percolate-canvas-tunnel/relay_ed25519 \
  --remote-bind 10.42.0.1 \
  --log-directory ~/.local/share/percolate-canvas-tunnel
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.percolate.local-connector-tunnel.plist
```

The job starts at login and reconnects after failure. SSH keepalives detect a
lost connection in approximately 45 seconds; launchd retries after 10 seconds.
The separate `dev.percolate.local-connectors` job serves authenticated MCP.
Docker and the Mac must remain running; this does not make a sleeping laptop
available. No scheduled client-header replacement is needed. TLS renewal is
cert-manager's responsibility and internal JWT renewal is Percolate's.

## Observe and stop

```sh
launchctl print gui/$(id -u)/dev.percolate.local-connector-tunnel
kubectl --context p8-arm -n percolate-local-dev get certificate,ingress,endpointslice
# Stop forwarding from this machine:
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/dev.percolate.local-connector-tunnel.plist
```

To retire the deployment, stop the job, remove only the resources in
`hetzner-ingress.yaml`, remove the dedicated account and its SSH drop-in (validate
and reload SSH), and remove only the `mcp-dev` A record. The namespace is dedicated
to this relay; inspect it before deletion. The previous Quick Tunnel is a
separate fallback and is not involved in the stable address.
