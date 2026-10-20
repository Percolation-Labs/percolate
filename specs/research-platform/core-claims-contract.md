# Core claims for the insight marketplace

Status: approved direction, 19 September 2026. C1 and C7 are implemented for extension 0.2.15 and the next core release; the other increments remain queued in the Percolate project. Existing functions remain shipped; the increments below are not claimed complete.

Source: an accepted internal review, 19 September 2026. This contract extends [claims/graph.md](../claims/graph.md) and the research platform's architecture ([schema.sql](schema.sql)). It owns the new current/pinned/history distinction and bounded read envelope; those documents continue to own claim identity, assertion vocabulary, grants and publication boundaries.

## Scope and evidence

Checked 19 September against the extension, the runtime, the application and the distribution as they stood that day. Read claims SQL, research scale results, runtime modules and distribution compose/chart definitions. The extension has claim identities, attributed append-only relations, exact-revision trust and source grouping. The runtime has caller context, workers, content and agent services. Application research models and handlers remain the transport implementation.

Core owns inspect, compare, carry, follow and recheck primitives. The application owns presentation and editorial policy. No fitted truth score, new graph database, monetary market or production rollout is part of this slice. Ship each schema change through the current extension upgrade process; do not hard-code the release number from the review.

## C1. Consistent current, pinned and historical readings

Built by REM-584: `claims.reading(claim_id, mode, revision_ids, cutoff)` returns the selected revision set, assertion cutoff, occurrences, identity set, relations, answers and evidence. The legacy signatures still cover all readable revisions. The reviewed evidence reassignment and origin-time defects reproduced and are fixed in those signatures as well.

`dev/tests/research/29-claim-reading-modes.sql` is the chronological caller-role oracle. `dev/claim-reading-controls.py` verifies that occurrence, origin-state and permission regressions each make it fail. Current and historical selection presently enumerates accessible work heads; the serving limits and completeness envelope remain C2 work. Do not describe this first API as a bounded serving interface.

REM-606 repairs a compatibility regression found by REM-605's application exercise: repeated global origin-link reduction exceeded the application's 30-second timeout. Study traversal now reduces incident assertions and resolves transaction timestamps and origin endpoints through keyed caller-role reads. The assertion cutoff, selected revisions and weak-title rules are unchanged. `dev/tests/research/32-origin-traversal-work.sql` measures work at 10 and 100 unrelated readable works; the application's claim-page suite is the regression reproduction. Broader result-size limits and same-study discovery remain C2/C3.

Read modes:

| Mode | Revision selection | Assertion selection |
|---|---|---|
| current | Each work's caller-visible head at execution | Latest active state for each assertion statement, with evidence in the selected revisions |
| pinned | Explicit immutable revision set | Occurrences from that set; relation and review history evaluated at an explicit cutoff, defaulting to execution |
| historical | Caller-visible exposed/owned revisions as selected at the cutoff | Latest state known at or before the assertion cutoff |

All three modes apply present-day permissions. Past access never restores a revoked grant. An assertion is included only if every required evidence revision is readable and meets the selected view. The result names its selected revisions and cutoff. A pinned comparison can explicitly include several revisions; it cannot import outside relations without declaring their evidence in the reading.

Reduce assertion history by its declared statement key before testing assert/retract and status. Apply the same rule to occurrence identity, relations, answers and origin links. Propagate the cutoff through study grouping. Do not let a retracted old expresses row keep contributing to evidence or consensus. A later identity merge must not change a pre-merge historical result.

The mode is an additive versioned API contract. Keep legacy calls compatible, document their historical behaviour, and migrate named clients before removing them. Assertion time is knowledge time, not the time the claim describes; evidence dates remain separate. Define tie-breaking and transaction-cutoff semantics in tests, without claiming commit-time ordering from transaction start timestamps.

Gate: a separately written small oracle covers a removed challenge, rewording answered new, asserted/retracted origin link, merge after cutoff, duplicate historical rows, private draft, and revoked current/historical access. Tests run as caller roles, and removing latest-state reduction or the current permission check makes them fail. Update graph.md's open-choice paragraph when this contract ships.

## C2. Bounded claim reads and completeness

`identity_set` uses path enumeration with a 64-node path cap; `rests_on` caps depth at 12; `neighbourhood` at four. These do not bound high-degree path counts. Preserve named, access-filtered functions and typed assertions.

Version the common result envelope: anchor; view mode and selected revisions; cutoff/data watermark; method/policy version; result rows; per-section coverage; limits consumed; completeness; continuation where supported. Completeness is complete, partial, unavailable or not_applicable. An empty complete search reports the searched accessible corpus; it never asserts global absence. Denied or nonexistent anchors retain the same non-disclosing error contract.

Enforce server ceilings on visited nodes, edges, returned rows, bytes and elapsed time. Separate reachability from bounded witness-path enumeration. Deduplicate visited states for identity reachability, preserve cycle safety, and expose any depth restriction as an incomplete reading. A resumable cursor binds the query, cutoff and caller; it cannot widen authority. Non-resumable truncated graph results say so. Reuse existing statement cancellation and timeouts; an aborted transaction must not masquerade as an empty answer.

Gate: chain, diamond, cycle and dense-hub fixtures match the unbounded small oracle where complete, terminate within declared budgets where partial, and return no inaccessible paths or counts. Include two callers with different readable subgraphs. Record cold/warm timings and actual work counters; do not infer performance from depth alone.

## C3. Shared-origin lookup begins at the origin

`claims.same_study` builds other visible heads and citation studies before anchor matching. Profile the actual plan, then use the anchor's origin candidates and reverse citation indexes before checking selected heads and access. Preserve C1's temporal semantics and C2's pagination/completeness vocabulary.

If a serving projection is justified, it is rebuildable from authoritative assertions and records its source watermark. Corrections and origin splits invalidate it. Global component caches must not join public claims through a private identity edge. Filtering rows after a global union is insufficient.

Gate: equivalent results on the existing corpus plus title collisions, origin split/withdrawal and private bridges. Probe rare and popular origins at two sizes a decade apart, with real RLS and both cold/warm caches. Report pages, candidates, p95 and output size; name remaining growth with result cardinality. No full-corpus materialisation merely to return one page.

## C4. Research contracts work without application imports

Extract the reusable package/claim/trust DTOs, error mapping and read adapters into a supported percolate-core module. Reuse database RPCs and trusted caller context. Mount reusable REST and MCP handlers in a neutral core host; the application uses those shared adapters with its own publication/byline enrichment.

First surface: get exact package revision, get a claim reading, trust reading, and authorised paginated listing. Keep stable IDs, hashes and compatibility names. This card does not rebuild existing create/revise SQL, authoring flows or comparison ingestion owned by REM-479. Credentials carry actor kind, scope, org narrowing and revocation through the core boundary. Test standalone identity provisioning through existing core operations.

Gate: one fixture called through SQL, REST and MCP returns equivalent authorised content, view/completeness metadata and refusal semantics. Stop the application and remove its imports/configuration from one test environment. Structural trust still works with analysis unavailable, and an agent remains unable to endorse. Distribution documentation states how to start the neutral host and which schemas it needs.

## C5. Listings paginate through every layer

The measured database keyset listing exists, while the application's package service fetches all public heads. Add or reuse paginated public/owned listings in the core contract, then migrate the existing application and MCP consumers to pass cursors through. No layer fetches the whole corpus to return a page.

Order by an explicit stable tuple with a unique tie-breaker. A cursor binds filters and a snapshot/cutoff; changed authorisation is checked each page. Counts describe accessible rows only and can be omitted when expensive. Preserve revision exposure rules and the original create/retry receipts.

Gate: page-boundary ties, concurrent new publication, private head, changed grants and exhausted cursor fixtures. A large-corpus service test records bounded SQL rows and memory per page. The old unpaginated path is removed from named consumers or retained only as documented compatibility with a limit.

## C6. Origin identity and dependence keep their reasons

Reuse origins, cites, origin_links and transaction attribution. Add versioned matching-policy metadata and evidenced dependence assertions for derived_from, uses_dataset and republishes. Each relation records its subject/object, evidence revision/span, proposer, status and retraction history. Extend the typed vocabulary; do not reuse an unlabeled generic edge.

Normalisation preserves resource-defining query parameters. Explicitly disposable tracking parameters may be removed by a versioned policy. DOI, URL and weak-title decisions remain inspectable and reversible. A policy upgrade creates mapping assertions rather than rewriting prior IDs. Unknown dependence remains unknown.

Read outputs distinguish known origin groups, confirmed dependency links and unknown lineage. Retain the old independent_evidence field only with compatibility documentation; clients must not interpret it as an empirical independence certificate. Consensus origin eligibility remains separate from a resolver's judgement and outcome checking.

Gate: DOI aliases, query-string resource IDs, tracking URLs, duplicate titles, two papers on one dataset, syndicated text, uncertain dependence and later split. Repetition adds no new declared origin; grouping corrections preserve historical answers under C1. Public reads reveal no private dependency metadata. REM-573 remains the application presentation owner.

## C7. Generated assertions have durable execution receipts

Built by REM-590: `claims.execution_receipt(tx)` reads a detached transaction receipt, captured revision hashes, and provider metadata recorded by the runtime. `execution_receipts`, `execution_inputs` and `execution_results` are typed append-only tables, included in extension backups. The SQL engine binds the executing task; core signs the dispatch task, worker and attempt into its existing caller token. The worker-only `claims.record_execution_result` checks that lease, preserves producer usage, and rejects a changed retry.

Kinds distinguish manual assertions, platform projections, workflow execution and agents without tracked workflow context. The method version on the transaction describes the capture method; each recorded model run includes the runtime version and configured model, with a null provider version when none was supplied. Results describe the entire workflow task attempt and list its recorded agent runs; they do not claim that every listed model generated every assertion. Failed turns before a result is recorded show unavailable execution data. Older transactions are not given invented receipts.

The runtime adapter uses the existing worker connection (`P8_WORKER_DSN` when the caller login cannot become a worker). It checks extension capability before requiring that connection on an older installation. Both scheduled and synchronous workflow-driven model calls use the same producer hook. Provider usage is a snapshot of existing measurements, not a second spend counter. The runtime records after chained writes; the database retains results only for task attempts that have assertion receipts. Large evaluation logs stay in content resources; a missing or denied resource returns an unavailable marker without its locator. No evaluator is added by this card.

Bind run and actor metadata at the trusted execution boundary, never from an untrusted caller's claimed identity. A manual assertion is marked manual. A retained receipt survives operational run pruning without retaining a live FK that blocks retention. Private prompts, credentials and inaccessible inputs are excluded from public projections; a missing/removed input stays explicitly unavailable.

Gate: workflow-generated and manual assertions, replayed retry, forged run identity, pruned workflow row, missing content and two readers. The public receipt explains the method and allowed evidence without exposing protected text or tokens.

## C8. Followed claims expose an authorised change feed

Extend core engagement target types for stable claim/question follows, preserving human-only follow/unfollow authority. Store the reader checkpoint separately from publication or endorsement. Reuse the existing workflow/event machinery; any outbox record commits atomically with the source change and is delivered idempotently.

Support claim_reworded, origin_corrected, evidence_unavailable and resolution_reviewed events. Each names exact before/after revisions or assertion states, cause, and an inspectable path. A challenge is a new challenge, not automatically a correction. Group repeated events without losing their reason. Recheck access when listing/delivering, including after grant revocation; never emit protected titles or counts.

Gate: follow/unfollow, two clients, checkpoint replay, duplicate delivery, private-head revision, withdrawn capture and revoked reader. Provide a paginated pull feed first. REM-575 owns the Library binding and screen; this card owns reusable core subscriptions/events only. Email, push and ranking remain outside scope.

## C9. Carry a qualified claim in a portable bundle

Define a versioned export for one authorised occurrence: issuer-local claim ID, work/exact revision/hash, wording, frame/scope, material caveat, attribution, source pointers, check scope and unavailable-evidence markers. A hash identifies content and does not certify truth. Include only evidence the requesting caller may export; public share requires the existing public projection.

A neutral reader validates and renders the bundle offline. Embedded content is escaped/inert. Reject malformed references/hash mismatches; unavailable external captures remain visible as gaps. Never treat another issuer's UUID as canonical local identity. Import/merge/federation and full document export are deferred.

Gate: a revision changes after export, an endorsement covers older wording, a source is private or absent, payload is altered, and the bundle contains hostile markup. The neutral viewer preserves qualification and check scope. REM-574 owns the application's share preview and recipient UI.

## Shared release evidence

New SQL uses the normal extension build/upgrade path; new transport code uses existing runtime and application gates. Use named disposable containers for database checks. Record tested source/version/image combinations. Never use a database owner as the only RLS test subject. Performance assertions name workload, hardware and completeness; historical benchmark numbers are not new release measurements.

## Worked tutorial

Complete (REM-611): a trust and claims tutorial, not yet published, explains the implemented model with a fictional SQL lab and recorded readings. Its 21 caller-role assertions ran against extension `0.2.16` on a disposable instance. It covers identity, origins, scoped endorsements, rewording, current/pinned/historical selection, manual receipts and access withdrawal. Workflow/model execution, scale and deployment are outside this lab; the tutorial identifies the remaining core increments.
