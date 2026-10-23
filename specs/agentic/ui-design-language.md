# Workbench design language: browse, edit and inspect

**Status:** implemented in `core/percolate_core/ui/`.

## 1. Outcome and problem

A person opening any workbench screen should be able to identify the object
they are working on, its current state and the next action, with the relevant
list, editor or result already visible. Moving between screens should preserve
the same spatial and interaction conventions.

The current workbench has shared colours, typography and components, but
screens allocate space differently. In the reviewed Data Sources view, the
introduction, examples, process guide, feed library, operational controls and
configuration all appear together; configuration fields begin near the bottom
of the first screen. Workflow creation keeps the starter above an existing
draft. Files uses a fixed 340px panel for both reading a document and composing
one. Query appends results below the editor. Several responsive layouts stack
the library above the selected item, and CSS hides scrollbars globally.

These observations describe the baseline before this contract was applied.

The product continues to lead with workflows: define the job, develop its
queries, data sources and agent steps, run it, inspect the outcome and schedule
repeat work. A visual change must preserve the ability to complete that loop.

## 3. Shared layout contract

Consistency means the same placement, hierarchy and behaviour for equivalent
tasks. Content may use different widths or proportions within those rules.

| Mode | Main workspace | Supporting material | Typical actions |
|---|---|---|---|
| Browse | Search, filters and compact comparable rows | A selected-item preview that can expand | Create, open, filter |
| Create / edit | A form or editor sized for the active task | Contextual AI, examples and field help | Apply suggestion, validate, save |
| Inspect | The result, document or operational state | Configuration, history, evidence and technical details | Edit, run again, export |

### 3.1 Page structure and visual tokens

- Use one compact page header for title or object name, state and the primary
  action. Descriptions explain purpose briefly; repeated instructional banners
  belong in the empty state or contextual help.
- Keep the existing paper/ink palette, purple accent and type families. Define
  shared roles for page titles, section titles, body text, labels and technical
  values. Use monospace for code and identifiers where it helps reading.
- Consolidate spacing, control heights, borders, radii and selected/focus
  states into the existing theme. Use a small spacing scale across headers,
  toolbars, form groups and rows. Resolve its values during the final review;
  do not reduce legibility or click targets to meet a density target.
- Badges and chips are square-cornered: a claim's frame slots under the claim
  and the frame chips on the compare page read as the same thing. Only avatars,
  status dots and round icon buttons are round.
- Full-width data and code workspaces can use the available width. Reading
  views and ordinary forms retain a comfortable line length, which §3.5 states
  as a number. A narrow detail panel is expandable when its content needs
  sustained reading or editing.
- Equivalent toolbars, tabs, action groups, empty states and error messages
  have the same ordering and visual treatment across screens.

### 3.2 Actions and state

- Keep the object identity, dirty/saved state and primary action accessible
  while the active workspace scrolls. Persistent controls must not cover
  content or keyboard focus.
- Keep consequential primary actions such as Save, Run and Apply suggestion
  identifiable in words.
- **A control may be an icon when its worst outcome is that you do it again.**
  Reversible per-row actions — start, refresh, enable, disable, signal — are
  icons, because in a table the label is the widest thing in the row and it is
  competing with the data the row exists to show. Everything else keeps its
  words: destructive actions (`revoke`, `cancel a run`), access changes
  (`grant`), and anything that cannot be undone by pressing it a second time.
  This is a rule and not a preference, so an icon-only `revoke` is out of scope
  by the rule rather than by whoever reviews it.
- **Every icon owes a pointer user and a keyboard user the same name.** One
  component, one argument: the accessible name and the tooltip come from it
  together, so an icon cannot ship without a name — the failure a screenshot
  review cannot catch. The tooltip appears on focus as well as hover, because a
  control that explains itself to a mouse and stays silent to a keyboard is the
  same defect twice; a native `title` attribute does not satisfy this. Focus is
  visibly ringed, and a touch device, which has neither hover nor focus, gets a
  visible affordance instead of a tooltip it can never open.
- **One icon vocabulary, in one module.** A new icon is added to the shared set
  and never inline in a screen, because three sets is what a vocabulary decays
  into once adding one inline is cheaper than sharing it.
- Distinguish editing a draft, applying an AI suggestion, saving a definition
  and executing it. State should refer to the same revision as the visible
  editor or result; never label stale results as results of the current draft.
- Preserve selections, filters, drafts and list position when opening an item
  and returning. Closing a panel restores focus to the invoking control.

### 3.3 AI assistance and contextual help

- Provide one recognisable assistance entry point in authoring workspaces.
  Starting from words and starting from a form/code are alternative inputs to
  the same draft. Reviewing a draft should keep that draft available for
  comparison.
- On a wide screen, an optional assistance panel may sit beside the editor;
  on a narrow screen it becomes a focused view with a clear return to the
  preserved draft. Do not impose a permanent third column.
- Use consistent states for requesting, clarifying, proposing, applying and
  failing. Show the proposed content or changed fields, then require the
  explicit apply action. Apply must not overwrite newer edits without showing
  the conflict or obtaining the user's choice.
- Applying remains separate from saving, pulling, running and scheduling,
  following [browser-ui.md §7](browser-ui.md#7-a-suggestion-is-a-draft-and-says-only-what-it-did).
  This layout work does not introduce new AI capabilities or loosen that
  contract.
- Examples and starters take priority in an empty workspace, then reduce to
  an optional control after work begins. Put essential guidance and validation
  at the relevant field. Longer tips and reference material are available on
  demand, with an accessible name rather than an unexplained icon.

### 3.4 Resizing, scrolling and accessibility

- Give the main task a clear scrolling region. Contained scrolling is useful
  for substantial code, results and transcripts; avoid several nested scroll
  regions for one form or preview. Keep overflow discoverable using native
  scrollbars and clear boundaries, respecting platform behaviour.
- Query supports an adjustable editor/results allocation. Provide keyboard
  access to resizing or an equivalent expand/collapse action. Persist user
  sizing only when it remains valid at the new viewport size.
- When there is insufficient width for a library and detail view, show the
  selected item as a focused view with Back to list. Do not put an entire
  growing collection above its editor.
- Maintain readable text, visible keyboard focus, labelled controls, logical
  tab order and state announcements. Colour alone must not convey selection,
  errors or run state. Tooltips work on focus as well as hover; touch users
  must be able to identify and activate essential actions.
- At narrow widths and increased zoom, wrap toolbars and switch layout modes
  before controls collide or disappear. Tables and code may have intentional
  contained horizontal scrolling; ordinary page content must not require it.

### 3.5 Measure, wrapping, and the strings that must not break

The rest of this section says what should be consistent. This one says what the
values are, because "comfortable line length" and "readable text" were the whole
of the contract and both were satisfiable by any stylesheet. Measured on the
shipping build at a 1470px viewport, 2026-09-12: error and warning banners set
at **178 characters**, roughly two and a half times a comfortable measure.

- **One measure, one place.** Prose caps at 68 characters, declared once as a
  token in `ch` — a character count, not a width, so a serif lede and a sans
  note reach the same measure at different pixel widths. Prose means text read
  in lines: ledes, notes, banners, help. Data, tables, code, diagrams and the
  full-width workspaces §3.1 allows are not prose and keep the page width.
- **A banner keeps its box.** A note is prose and a status surface at once.
  Capping the box leaves a half-filled band inside the panel, so the tinted
  box spans its container and the measure is held by padding.
- **Wrapping is a default with named exceptions, never a per-component patch.**
  One declaration, inherited: any element may break inside a word rather than
  push the page wider than the window. A stylesheet that names the components
  allowed to wrap exempts every component added after it, which is how the
  class carrying ids, model names, cron expressions and dot paths came to be
  the one thing on the page that could not break.
- **An identifier stays whole.** Identifier columns, monospace cells and the
  first column of a data table — which is where every screen puts the thing's
  name — do not break mid-token at any width; the table's own container scrolls
  instead, which §3.4 permits for tables. The same rule applies at every
  viewport: a cell that wraps on a desktop and refuses to on a phone is two
  rules, and one of them is wrong.
- **Headings balance, prose is not left with an orphan.** `text-wrap: balance`
  on headings, `pretty` on prose; both degrade to normal wrapping.
- **The check is a browser, not a review.** Verified against a live stack at
  1440, 1280, 1024, 720 (the viewport a 1440px window has at the 200% zoom §7
  asks for) and 390 CSS pixels, on every route: prose on the measure, no
  page-level horizontal scroll anywhere, identifiers whole. Contained scrolling
  inside a table does not count against this — page-level scrolling does.

## 4. Screen coverage

The final review inventories every live navigation route, including authoring
and detail routes reached from a listing. Each receives a mapped pattern or a
documented reason for a variation; new routes from current tickets join this
inventory.

| Screen family | Proposed application of the contract |
|---|---|
| Data Sources: APIs and file/document sources | Browse feeds; open an existing source in records/progress inspection; Edit opens focused configuration. Create focuses on connection, incremental behaviour and transformation. Package preview is an explicit inspection mode. |
| Workflows and workflow creation | Compact registry; focused draft editor; starters primarily in the empty state; validation and save near the draft; explicit transition to run inputs and run results. |
| Query | Editor and results share the workspace; consistent AI proposal/review; query guide is contextual; Use in workflow preserves the authoring handoff. |
| Files | Searchable library with selection preview; expand for reading; upload/paste opens a suitably sized creation view; processing and evidence remain inspectable. |
| Runs and run details | Comparable run rows; result-first detail with task progress, failures, evidence and history available in consistent locations. |
| Schedules | Compact listing with readable cadence; focused create/edit and schedule preview. Preserve the interpretation, timezone and next-fire information. |
| Agents | List, inspect and edit with the same object header, action placement and assistance conventions. Retain model, tool and instruction visibility. |
| Chat | Preserve the conversation workspace and composer; align supporting panels, actions, state and typography with the shared contract. A conversation is not forced into a form layout. |
| Help | Readable product guidance and a clear assistant entry point; use the shared help presentation rather than repeating it on every page. |
| Overview, Queues & pools, Load & limits, Events | Compact operational summaries and lists; focused drill-down; consistent unavailable, empty and active states. |
| Users, Roles, Keys & sessions | Comparable access listings and focused detail/actions, retaining permission errors and the destructive-action contract. |
| Settings, Surface, Account / Sign in | Focused configuration, diagnostics and recovery; same field, status, error and action conventions. |

## 5. Scope boundaries

This work covers visual and interaction consistency across the existing
workbench. It reuses the current framework-free UI, theme, routing, read
contracts and draft state. It does not require a new frontend framework,
backend service, permission system, connector, AI tool or database schema.

Retain the underlying workflow, source, query and authentication semantics.
Preserve the supported authoring and inspection capabilities when a feature
moves to a tab or panel. A smaller first screen must not make failures,
evidence, advanced configuration or the next action inaccessible.

## 6. Review and implementation record

The shared primitives are `workspaceTabs`, `collectionWorkspace`,
`splitWorkspace`, `editorWorkspace` and `contextualHelp` in the existing static
UI. They retain mounted editors/results when modes change. The theme defines
a spacing scale of 4, 8, 12, 16, 24 and 32 CSS pixels, 36px text controls and
8px surfaces. These are shared defaults; content determines layout width.

Query uses equal editor/secondary columns on wide screens, with accessible
Both/Editor/Results controls. Below 900px it initially focuses the editor and
reveals results or AI on demand. Collections use a 190–240px library beside
the selected object; at 1050px or below the object occupies the workspace.
Below 760px the navigation rail contracts and forms/toolbars wrap. Tables can
scroll horizontally inside their collection; ordinary content reflows.

Tabs, examples, source progress, package export and run detail reuse existing
capabilities. AI application guards newer drafts. Save and execution remain
separate operations. Saved/dirty source state compares the visible fields
with the saved configuration, independent of local draft persistence.

## 7. Acceptance and practical verification

Review at 1440×900 and 1280×800 CSS pixels, a constrained 1024×768 viewport and
a narrow 390×844 viewport. Check 200% browser zoom on desktop. These are test
conditions, not hard-coded breakpoints. Use realistic long names, enough rows
to require scrolling and nontrivial content, together with empty, loading,
failed, unavailable, read-only and dirty states where applicable.

The baseline and later implementation review use the same task set:

1. Find an existing API feed, inspect freshness and records, edit its mapping,
   review an AI proposal and inspect a package preview. In the later live
   verification, save and pull a test-owned feed, including a continuation.
2. Write or describe a query, compare its proposal with the draft, run it,
   inspect rows and transfer it into a workflow. Create a workflow from an
   empty state and revisit a populated draft without the starter taking over.
3. Validate/save a test workflow, provide inputs, inspect its successful run
   and a failed run, then inspect the schedule proposal and next-fire times.
4. Find a file, expand its evidence, return to the same filtered list, and
   complete upload/paste in a test workspace without a cramped editor.
5. Inspect an agent and its Chat evidence; visit an operational listing, an
   access listing, Settings, Surface and expired-session recovery. Exercise
   representative keyboard and narrow-screen journeys through them.

Acceptance after implementation requires:

- Every route in the inventory maps to the shared contract, with justified
  variations recorded; equivalent actions and states behave consistently.
- On desktop, each mode initially exposes its main content and identifiable
  next action. Reading introductory material is not required to reach them.
  Long forms may scroll, with their identity, state and action accessible.
- Narrow and zoomed views preserve the selected object and provide a clear
  return path. Essential controls and focus remain visible and reachable.
- The task evidence demonstrates reduced avoidable scrolling or mode changes
  for the identified problems, while preserving legibility and task success.
- AI application, navigation and resizing preserve current drafts and valid
  context. Existing permission, failure and stale-result distinctions remain.
- Appropriate existing read-contract and interaction checks pass. Add focused
  regressions only for failure modes found through use, such as overwritten
  drafts, lost focus or an action targeting the wrong selected object. Do not
  assert each CSS value or add a broad screenshot suite as a substitute for
  task verification.

## 8. Implementation sequence

| Phase | Deliverable and gate |
|---|---|
| 1. Establish shared patterns | Extend the existing theme/components for headers, action bars, workspaces, selection/inspection, assistance and help. Prove the contract in Data Sources and workflow creation before extending it. |
| 2. Apply across authoring and content | Query, Files, Schedules and Agents use the same patterns; verify the API → query → workflow → run → schedule journey. |
| 3. Complete operational and access screens | Runs, fleet, events, access, settings, diagnostics, help and Chat alignment; the route inventory has no unreviewed family. |
| 4. Verify and document | Repeat §7 against the final build; record improvements and limitations; update workbench/public UI documentation for changed navigation and behaviour; close implementation only with that evidence. |

The implementation is in `core/percolate_core/ui/`.

**Since, 2026-09-12.** Three separate pieces landed on top of that
implementation, and the forward references this document carried to them are
now the rules themselves rather than promises:

| | |
|---|---|
| The icon action §3.2 describes | One icon set in `ui.js`, one component whose single `label` argument is both the accessible name and the tooltip, and four reversible per-row controls using it. |
| The measure §3.5 states | 68 characters, declared once; one inherited wrapping default in place of nineteen per-component declarations; the identifier exception applied at every width. |
| The suggestion contract | One `suggest()` for all six assistants. [browser-ui.md §7](browser-ui.md#7-a-suggestion-is-a-draft-and-says-only-what-it-did)'s audit is rerun there and every row is yes. |

Each is held by a test rather than by this page: `test_ui_controls.py`,
`test_ui_theme.py` and `test_suggestion_contract.py` respectively. A page that
says a thing was done is a claim about the past; those three fail on the commit
that undoes it.
