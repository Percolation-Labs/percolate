# Shared canvas in the core workspace

REM-1329. This is the open Percolate workspace (`percolate ui serve`, `#/canvas`),
not `percolate-application`. It uses the existing paper/ink theme and sidebar.
Query results also use the same Table / Cards / Plot / Graph renderer.

The core extension supplies `workflow.canvas(p_action text, p_body jsonb)`.
Install the extension containing this function before enabling the canvas MCP
surface with `P8_CANVAS_ENABLED=1` on `percolate query mcp`. The browser sends
its own token directly to PostgREST; the UI server still only serves files.
MCP forwards the caller's Authorization header, with no service credential.
`canvas:read` and `canvas:write` are scoped capabilities. Sessions, result turns
and selection audit use existing workflow records. Only the caller's own rows
are included in the two reports, `workflow_runs` and `workflow_steps`.
The MCP canvas tool also accepts a read-only SQL `statement`. It runs through `aiq.sql_passthrough` with the caller token, then saves the returned rows through `workflow.canvas(present)`. The definer function never executes supplied SQL. Saved SQL text is caller-supplied provenance, not an attestation. Results are bounded to 500 rows, 50 columns and 48KB.

Open Canvas under Work and choose a report. Table, Cards, Plot and Graph switch the
same saved result. Plot chooses a numeric value automatically; choose axes and
Bar, Line or Scatter using the controls. Scatter explains why a text axis is
unsuitable. Click anywhere on a row or card to toggle its selection; no checkbox or separate Select action is needed. Enter/Space offer the same action by keyboard. Selections survive view switches and reloads. Report and axis choices use custom popover menus with arrow-key navigation and Escape/outside-click dismissal. The canvas uses compact toolbars without introductory copy or a separate report panel. The next core
MCP tool call returns pending canvas touches (when enabled); the canvas tool
can also consume them directly. Recent column selections can supply plot axes.
The timing window starts at 15 seconds; ten mark/consume samples calibrate it.
This measures tool timing, not human speech latency.

## Local review

The retained preview for this change is at `http://127.0.0.1:8140/#/canvas`.
Use `http://127.0.0.1:8140/?dev=1#/canvas` for the direct local preview; the disposable development account
contains explicitly labeled example workflow records. PostgREST is on 5841,
MCP on 8141. No application database or production configuration is used.
The local credentials are in ignored `.local/` files with mode 600.

`dev/canvas_call.py` demonstrates calls with `P8_CANVAS_REST` and
`P8_CANVAS_TOKEN`, or `.local/canvas-client.json` for this preview:

```sh
python dev/canvas_call.py open
python dev/canvas_call.py query '{"query":"workflow_steps"}'
python dev/canvas_call.py view '{"control":"plot","options":{"x":"step","y":"tasks"}}'
python dev/canvas_call.py consume
```

`dev/canvas-preview-seed.sql` is test scaffolding for a disposable database only.
It creates the example account and report records. The function itself lives
in percolate's `specs/workflow-engine/integration-rbac.sql`; nothing is copied
from the proprietary application at runtime.

## Validation

- `dev/check-canvas-polish.cjs`: whole-row/card clicks, keyboard selection, custom menu dismissal/navigation, automatic report loading and content starting above 200px desktop / 235px phone.

- `dev/check-result-canvas.cjs`: Cards, automatic bar, line/scatter, invalid axis,
  selection continuity, sorting and 320/390px layouts.
- `dev/check-shared-canvas.cjs`: real core RPC and browser, shared result identity,
  saved cards/plots, selections, reload and external view switch.
- `dev/check_canvas_mcp.py`: real MCP discovery, saved plot and selection returned
  by both canvas and query calls.
- Core UI tests and existing query MCP tests pass.
- Extension `dev/tests/workflow/40-canvas-keeps-results-and-selections.sql`:
  owner isolation, anonymous denial, saved result without a new query task,
  selection cursor. Surface and definer authorization audits pass.
- Extension tree checks: 21 passed. Broad database run: 34 gates passed;
  registration/count failures were corrected and rechecked individually.
  Remaining workflow/cookbook failures use `mode: inline`, unsupported by the
  available compiled parser 0.2.38 against main's 0.2.39 SQL. They are not
  reported as passing or silently skipped. Subsequent extension CI with the current parser passed all 40 gates and PR393 merged. No production release was made.

## Live SQL and network rehearsal

`dev/canvas_walkthrough.py` simulates user prompts and uses actual local MCP queries for physical table counts by schema, workflow foreign keys, and recorded canvas tasks. `dev/check-canvas-graph.cjs` clicks an actual node and verifies its identity/incident rows reach the next chat tool call. `dev/canvas_followup.py` uses that selection to query its neighborhood. The transcript is [canvas-conversation.md](canvas-conversation.md). These are local metadata and runtime records, not production business data; existing local test records are included in runtime counts.

Graph columns are configured through Source/Target menus and optional `relation` in tool options. Nodes/edges select by click or keyboard; drag nodes, pan, zoom and Fit are supported. Parallel edges and self-links remain visible. The graph is bounded to 150 nodes/300 edges and shares the saved result with table/cards/plots. Selection persists across views and reloads. Failed SQL leaves the current canvas intact.

Validation: live graph/browser/MCP checks, renderer regression, caller-token/error/row-limit unit tests, 28 UI tests, extension graph selection/isolation SQL test and 21 extension tree gates. Full extension database CI remains required for integration.

## Embedded Claude Desktop canvas

With `P8_CANVAS_ENABLED=1`, the MCP server advertises the MCP Apps extension,
links `canvas` to `ui://percolate/canvas-<content-hash>.html`, and serves its self-contained
HTML through `resources/read`. The app bundles the official MCP Apps SDK and
reuses the workspace renderer. No token or PostgREST URL is embedded in the page.
All reads, view changes and selections go through the host's `tools/call` bridge
using the caller's MCP credentials. The app-only `canvas_ui` tool permits
read/view/selection only; it returns full saved rows and never consumes the
model's touch cursor. Selections also update host model context when supported.
Visible apps poll for external chat changes; direct browser networking is not
required. Ordinary browser workspace and non-UI MCP clients remain supported.

Rebuild the checked-in resource with `npm ci --prefix dev/mcp-app` then
`npm run --prefix dev/mcp-app build`. The wheel carries the HTML; Node is only
needed to rebuild it. The pinned SDK and build dependencies are in that folder.

Restart Claude Desktop after updating the server, then start a fresh chat with
percolate-local enabled. Ask: “Use the canvas tool to query workflow tables and
show cards inside this chat. Do not generate an HTML artifact.” The host must
support MCP Apps; a normal localhost link is still a separate browser page.

`dev/check-canvas-app.cjs` exercises the real server and SDK in an opaque-origin
sandbox with connect-src none: full live rows, cards, selections and model
context, cursor retention through polling, plots and external chat view changes.
Seven canvas unit tests, 15 query tests and 28 UI tests pass. Actual Claude
Desktop rendering requires a fresh host session; unavailable native computer
access prevents verifying that window from this session.

## Query and session semantics

`open` returns `session_action: created` or `resumed`. Resuming deliberately
retains the current view; use `close` followed by `open` for a fresh session.
`query` applies an explicit `control` and `options` in the same database
transaction as saving the result. An invalid view rolls back the new result.
This applies to both named reports and live SQL results.

A new result clears the active selection. The retained audit still records old
clicks, but `consume` only returns selection events for the displayed result.
Reads mask stale selections from older sessions, and switching results clears
the embedded host's selection context. `dev/check_canvas_semantics.py` verifies
these behaviors through live MCP, and the extension SQL regression verifies
atomic rollback and created/resumed outcomes.

A user test through Claude's remote-devices bridge returned JSON without an app
view. That route is not evidence of direct Claude Desktop rendering support;
only the direct local adapter and sandboxed app have been verified here.

The app resource URI includes its content hash, so hosts cannot reuse an older
UI bundle after a renderer or selection-context fix. Reconnect to refresh tool metadata.

### Explicit renderer configuration

The canvas now defaults to Table. View as offers only valid configured views;
Configure view defines field mappings and applies them after the server accepts
the change. Cards require a meaningful title and up to six chosen detail fields.
Plot and graph mappings are explicit, never inferred from column order.

```json
{"action":"query","query":"workflow_runs","caption":"Run counts by status","renderer":{"type":"plot","x":"status","y":"runs","form":"bar"}}
```

```json
{"action":"view","renderer":{"type":"cards","title":"status","fields":["runs"]}}
```

The renderer argument is supported by the canvas tool for query/view. Existing
control/options calls remain supported: card_title/card_fields configure cards;
x/y/form configure plots; source/target/relation configure graphs. Use either
renderer or control/options, not both. Deploy the coordinated extension change
(core c411d30, extension 8e98216c); the database validates layouts and retains
mappings across views of the same result. New query results start fresh.

The sidebar groups occasional screens under Data, Operations and Administration.
Canvas, Chat, Runs and Workflows stay visible. Long table values have an Inspect
value button that opens a touch-friendly dialog without selecting the row.
