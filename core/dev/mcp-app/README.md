# Embedded canvas build

Run `npm ci` and `npm run build` here. The generated canvas-app.html is package
 data and must be committed with changes to the SDK entrypoint or core renderer.
The official MCP Apps SDK provides the host bridge; no credentials, remote
assets or direct database requests belong in this bundle.

Protocol: https://modelcontextprotocol.github.io/ext-apps/api/
