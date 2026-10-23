# Compose a job from workspace components

**Status:** implemented in `core/percolate_core/ui/static/workflow-composer.js`; uses the shared workspaces in [ui-design-language.md](ui-design-language.md).

## Problem and outcome

Workflow creation offered only a fixed retrieval/brief template and a
query-to-workflow shortcut. Both are useful pieces, but they presented too small
a part of the system. A workflow combines sources, queries, agents and plugin
capabilities into work that can run, be inspected and be packaged for reuse.

The author starts with the job and desired result. AI discovers available
components, explains what it would reuse, proposes missing sources or agents,
and produces a reviewable flow with inputs and a package. The person can
refine that proposal, create its missing components, save the workflow and
run it using the existing interfaces.

## Existing capabilities to use

- `SCHEMA "workflow"` publishes the installed grammar, compiler capabilities,
  queues, agents, registered functions and definitions. Query/schema discovery
  and caller-scoped catalogue reads provide the other component metadata.
- Sources already carry ingestion definitions. API sources have stable IDs,
  watermarks, pagination, transforms and package export. Reuse their existing
  builder and save RPC; do not create another connector format.
- Agents bind tools and skills. Plugin provenance groups those components;
  packages extend the plugin document with sources and workflows.
- `public.p8_compile_workflow(yaml)` is accessible through the existing REST
  deployment and can compile without registration. `workflow.define_yaml`
  performs authoritative validation when the user saves. The private
  `validate_spec` function is not a browser RPC and stays private.
- The package installer exists. `percolate` is not an exposed REST schema in
  the default deployment; package export uses its current manifest format. The UI
  must not simulate an atomic package installation with several writes.

## Authoring contract

1. **Describe the job.** Workflow creation offers Design with AI alongside
   Definition, Run with inputs and Package. Keep the existing starter and
   query handoff. Preserve the mounted draft when moving between these modes.
2. **Discover components.** Read visible API/file sources, agents and their
   tool/skill bindings, plugins, skills, tool servers and saved workflow names.
   Show a searchable catalogue and let the person select relevant components.
   AI also considers the available catalogue without requiring manual picks.
   Failed reads are unavailable, never zero matching components.
3. **Propose the composition.** Return an explicit outcome, explanation,
   component choices with reuse/new reasons, ordered steps and dependencies,
   input JSON, assumptions, setup requirements and a package name. The proposal
   may contain several query, agent, source-ingestion, control or supported
   workflow steps. Step syntax comes from the live workflow grammar.
4. **Propose missing components.** New API sources use the existing API source
   settings/builder. New agents use visible configured model choices and known
   tool/skill bindings. Missing API contracts or destinations produce an
   explicit clarification or setup requirement. Do not invent credentials,
   worker handlers, endpoints, installed plugins or available models.
5. **Review and apply.** Show the outcome and flow before raw definition text.
   Applying changes only the local draft and input example. A stale proposal
   cannot replace newer edits. The current YAML remains available for review.
6. **Create and save explicitly.** Creating a proposed component is an explicit
   action with a visible receipt. Existing components are reused unchanged.
   Do not claim all components were saved if a later operation fails. The
   workflow's existing Validate & save action remains separate from execution;
   missing required components and authoritative validation failures are shown.
7. **Package the work.** Export the workflow and selected/new source and agent
   definitions using the existing package manifest. Queries belong to their
   workflow steps. Keep records, run history, progress and credential values
   out. List external requirements, including tool/skill/plugin bindings or
   existing workflow definitions that cannot be reconstructed from the public
   catalogue. Do not describe such an export as self-contained. Never prune or
   retag a live plugin while merely reusing its agent in a proposal.

The assistant follows [browser-ui.md](browser-ui.md) §7: schema-constrained proposal, separate
clarification field, one correction attempt for invalid output, caller identity,
untrusted samples treated as data, and no execution or save claims. The browser supplies catalogue and schema
reads and performs compiler checks. The assistant uses `tool_choice: "none"`,
which the runtime enforces by removing tool bindings and chained actions for
that turn without changing the stored agent. The browser checks the runtime
OpenAPI contract before using it, because older runtimes ignore unknown fields.
The assistant does not run its proposed queries, pull feeds or call mutation tools.

## UI and validation

Use the shared tabs, action bars, focus modes, component rows and disclosures.
Examples should show complete jobs, such as refresh an API feed → query the
latest records → use an agent to write a reviewable brief. A simple query-only
workflow remains valid when it satisfies the task; it is a shortcut rather
than the main explanation of workflows.

Compile proposals through the installed compiler before offering Apply. Basic
reference/graph checks can reject malformed proposals before registration;
Save remains the database's authoritative dependency and capability check.
No new SQL permission, REST schema, worker, package registry or framework is
required by this work.

## Evidence required

- Ask for a useful job against the live workspace. The proposal identifies a
  real source and agent, composes more than a query when the job requires it,
  compiles, saves explicitly and produces a successful recorded run.
- Ask for a missing component. The proposal shows a usable source/agent draft
  or an explicit question, and does not report creation until the action runs.
- Export the composed package and inspect included definitions and external
  requirements. Use the existing installer in a rollback-only verification
  where the destination requirements are available; no live plugin pruning.
- An invalid/cyclic workflow is refused without registration; a stale proposal
  cannot overwrite the current draft; unavailable catalogue reads remain
  visible. A prompt-injection sample cannot turn proposal generation into a
  save or execution.
- Exercise the composer on wide and narrow screens. Update the public UI guide
  and helper guide to lead with the complete composition and package flow.

Standalone Agents retains its own editor; agent drafting is also
available as part of composing a workflow. Access controls, endpoint settings
and credentials remain manual configuration. There is no new plugin-code
installation flow: the composer discovers installed plugin capabilities and
packages the definitions it can export, identifying the remaining requirements.

## Local verification

A local run on 2026-09-10 recorded two successful source → query → agent runs, explicit creation of a proposed agent, actual package downloads, recovery and stale-proposal checks. A delayed request exposes Stop waiting and its conversation; completed designs can be recovered from recent caller-owned sessions and recompiled. Package installation was attempted inside a rolled-back transaction and refused missing plugin-authoring permission. Export and execution are verified; installation into another workspace is not claimed.
