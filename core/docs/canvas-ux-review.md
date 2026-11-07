# Canvas review: results need an explicit renderer

Review of the local workspace and embedded MCP App, 7 November 2026. The primary
workflow is inspecting an agent's work while talking: see real records, select
an example, ask about it, and change the visualization without losing context.

## Findings

1. The four view buttons imply every dataset can become a useful card deck,
   plot or network. Cards currently use the first column as a title and every
   remaining column as a definition list. That makes arbitrary database rows
   look like designed cards without establishing what a card represents.
2. The browser guesses plot axes and graph endpoints from column order. The
   database validates some mappings only after the UI has switched locally.
   This can leave a visible view that was never accepted as the saved view.
   A pair of columns is not, by itself, evidence of a relationship.
3. The embedded heading says only “Canvas”; the result caption is passed as an
   accessibility label but is not shown as the main result heading. The local
   report chooser mixes two aggregate presets with “Chat query”, which is not
   a selectable dataset. These controls conceal what the person is viewing.
4. Graph settings expose source and target but not the optional relationship
   label. Chart settings are always displayed, consuming space even when the
   agent already chose a valid mapping. There is no clear distinction between
   changing a presentation and running a new query.
5. Table selection reports plot-axis columns even in table mode. An assistant
   should receive the result identity and selected records independently of a
   chart's settings. New query selections already reset; preserve that rule.
6. Hover text helps desktop users inspect clipped JSON, but a tablet needs an
   explicit cell-detail affordance as well. It should open an inspector without
   expanding the row or stealing the row-selection action.
7. The compact-table change introduced an out-of-scope changedResult reference
   in the embedded touch acknowledgement. The server saved the selection, but
   the UI could report an error before updating model context. This review fixes
   that regression; the sandboxed MCP App interaction check passes again.

## Implemented renderer contract

A query supplies data plus a renderer specification. Table is the safe default
for an unspecified renderer; cards require an explicit layout. An example
tool shape:

```json
{
  "action": "query",
  "statement": "SELECT id, status FROM workflow.runs LIMIT 20",
  "caption": "Workflow runs",
  "renderer": {
    "type": "cards",
    "title": "id",
    "fields": ["status"]
  }
}
```

- Table: ordered visible columns; optional formatting. Always usable for rows.
- Cards: a scalar title field and an explicit short list of displayed fields;
  optional subtitle/status. Never infer a card layout from column order.
- Plot: explicit x, y and form. Validate numeric requirements and distinguish
  raw records from aggregated measures. Do not silently invent aggregation.
- Graph: explicit source and target, optional relationship label. Validate node
  identities and limits. Never invent edges by treating arbitrary columns as
  endpoints.

Use a named, supported renderer registry, not arbitrary agent-generated HTML or
JavaScript. Validate mappings against the actual result before changing the
saved view. An invalid request should explain the missing field or wrong type
and preserve the previous accepted result. Store the renderer with the result
so the tool response, standalone workspace and embedded app agree.

The SQL view function now validates card layouts and persists their fields
alongside plot and graph mappings, including while viewing the same result as
a table. Core normalizes renderer requests onto that durable view contract.
Legacy control/options callers remain supported, but cards require card_title
and card_fields, and plots/graphs require explicit mappings. Deploy the matching
extension change before the new client; it is applied to the local test stack.

## Implemented interface

Show the result's caption, row count and one compact “View as” menu. Offer only
renderers with valid configurations for this result. Cards appear only when a
layout exists. Keep the selected view visible; put field mapping under a clear
“Configure view” control, not a second permanent row of unexplained tabs.

Use a small “Query” disclosure for provenance and a separately labelled rerun
button. A view change must not rerun SQL. Name presets “Run counts by status”
and “Task counts by step and status”. Replace the generic “Chat query” picker
entry with a result source label. Empty states should give an example request,
such as “Ask your assistant to show recent workflow runs”.

Keep click-to-select rows/cards and provide a distinct inspect action for long
values. Add a compact selected-record summary suitable for spoken follow-up.
Expose connection state only when waiting, disconnected or in error.

## Acceptance checks for the renderer redesign

Test a text-only result, status/count aggregates, nested JSON records, explicit
card mappings, a numeric scatter dataset and a real edge list. Unsupported
renderers must not appear as working alternatives. Invalid mappings must leave
the accepted view unchanged. Check selection and renderer persistence through
polls and host tool refreshes, then repeat the actions on a narrow touch layout.
Finally verify the actual Claude host separately from the simulated MCP host.

## Sidebar

Overview, Canvas, Chat, Runs and Workflows remain directly visible. Data groups
Query, Sources, Files and optional Evidence. Operations groups Schedules,
Investigations, Queues, Load and Events. Administration groups Agents, Users,
Roles, Keys and Capabilities. Help and Settings remain directly reachable.
Groups start collapsed and open automatically for a route inside them; no screen
is removed.

## Agent examples

```json
{"action":"query","query":"workflow_runs","caption":"Run counts by status","renderer":{"type":"plot","x":"status","y":"runs","form":"bar"}}
```

```json
{"action":"view","renderer":{"type":"cards","title":"status","fields":["runs"]}}
```

The first executes a preset; the second changes only its presentation. A newly
queried result defaults to Table unless a renderer is specified. Graph requests
name source and target, and may name relation. The returned view includes its
normalized renderer. Cell inspectors and column widths are local UI state;
renderer and selection state remain in the caller-owned database session.
