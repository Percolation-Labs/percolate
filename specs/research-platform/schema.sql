-- ============================================================
-- The research platform in core: one access decision, plans and usage,
-- research revisions, engagement, and the trust read.
--
-- Core owns them, so any application gets them without installing another. Written in beta mode: lean,
-- and meant to be read, argued with and changed. build-sql.py replays this
-- file on every upgrade, so every statement is idempotent.
--
-- What is NOT here yet: capture links from a source to content.resources,
-- Coherence interpretations, writing requests (the hub's), and identity
-- declarations for the new tables.
-- ============================================================


-- ------------------------------------------------------------
-- 1. One access decision (§2)
-- ------------------------------------------------------------

insert into rbac.permission_kinds (resource, action, checked_by, human_only, every_person) values
    ('research',   'select',   'function research.get_package',          false, true),
    ('research',   'insert',   'function research.submit_package',       false, true),
    ('research',   'list',     'function research.submit_package',       false, false),
    ('research',   'publish',  'function research.expose_for_publication', true, false),
    ('research',   'endorse',  'function research.endorse',              true,  true),
    ('engagement', 'select',   'policy saves_self',                      false, true),
    ('engagement', 'insert',   'function engagement.add_comment',        true,  true),
    ('engagement', 'discuss',  'function engagement.discuss',            true,  true),
    ('engagement', 'moderate', 'function engagement.moderate_comment',   true,  false)
on conflict (resource, action) do update
    set checked_by = excluded.checked_by,
        human_only = excluded.human_only,
        every_person = excluded.every_person;
-- The scopes an existing credential carries, aliased onto the kinds above. A
-- foreign key ties each to a permission_kinds row this file inserts, so the
-- rows live here and the table lives in user-rbac/schema.sql.
insert into rbac.scope_aliases (scope, resource, action) values
    ('packages:read-own',       'research', 'select'),
    ('packages:create-private', 'research', 'select'),
    ('packages:create-private', 'research', 'insert')
on conflict do nothing;

-- Publishing is the one core kind a person may delegate. Endorsing, commenting and moderating are not.
update rbac.permission_kinds set delegable = true
 where resource = 'research' and action = 'publish' and not delegable;
-- ------------------------------------------------------------
-- 3. Research: works, immutable revisions, heads, idempotency (§4)
-- ------------------------------------------------------------
-- Adapted from specs/tables/migrations/001_research.sql, which stays as the
-- recovered fixture. A work's visibility is the rbac scope; 'public' is what
-- the package contract calls listed. Only these functions write.

create schema if not exists research;

create table if not exists research.works (
    id            uuid primary key default uuidv7(),
    public_id     text not null unique check (public_id ~ '^[a-z0-9][a-z0-9-]{2,80}$'),
    document_type text not null default 'research-package',
    owner_id      uuid not null references rbac.users(id),
    org_id        uuid not null default rbac.shared_org_id() references rbac.orgs(id),
    visibility    text not null default 'private' references rbac.visibilities(scope),
    listed_at     timestamptz,
    created_at    timestamptz not null default now()
);
comment on table research.works is
    'A piece of research as a durable thing: a public id, an owner, an org and a visibility. Its content lives in revisions.';

create table if not exists research.revisions (
    id             uuid primary key default uuidv7(),
    work_id        uuid not null references research.works(id) on delete cascade,
    number         int  not null check (number > 0),
    label          text not null,
    schema_version text not null,
    document       jsonb not null check (jsonb_typeof(document) = 'object'),
    content_hash   text not null,
    predecessor_id uuid references research.revisions(id),
    actor_id       uuid not null references rbac.users(id),
    actor_kind     text not null check (actor_kind in ('person', 'agent', 'platform')),
    credential_id  uuid references rbac.api_keys(id),
    created_at     timestamptz not null default now(),
    unique (work_id, number),
    unique (work_id, label)
);
comment on table research.revisions is
    'An immutable version of a work, with its document, content hash, predecessor, and who wrote it as which kind of actor.';

-- WHAT A REVISION'S HASH WAS COMPUTED OVER, kept on the row (REM-151). The
-- digest is sha256 over the jsonb text Postgres prints for the document. A later canonical form is a new
-- hash_format_version, never a silent change to what an old content_hash meant.
alter table research.revisions add column if not exists hash_algorithm text not null default 'sha256';
alter table research.revisions add column if not exists hash_format_version text not null default 'pg-jsonb-text-1';

-- THE WORKFLOW RUN A REVISION WAS WRITTEN IN (REM-237: run provenance is derived from
-- trusted request context and checked for consistency). Filled from workflow.current_run_id, which only the
-- engine's step executor publishes -- a person's role may not call set_config (REM-44) -- and checked by
-- trg_revisions_row. Null when no step was executing. `on delete set null`, so pruning old runs never takes a
-- revision with it; the revision keeps everything else it says about who wrote it.
alter table research.revisions add column if not exists run_id uuid references workflow.runs(id) on delete set null;

-- A PREDECESSOR IS A REVISION OF THE SAME WORK, by key rather than by each definer's care: the composite
-- foreign key refuses a row whose predecessor belongs to another work, whoever writes it.
alter table research.revisions drop constraint if exists revisions_predecessor_same_work;
alter table research.revisions drop constraint if exists revisions_work_id_id_key;
alter table research.revisions add constraint revisions_work_id_id_key unique (work_id, id);
alter table research.revisions add constraint revisions_predecessor_same_work
    foreign key (work_id, predecessor_id) references research.revisions (work_id, id);

-- A DERIVATIVE WORK names its parent, and each of its revisions names the exact parent revision it answers
-- Core stores the relationship; which document types may nest is the product validator's.
-- trg_revisions_row proves a base belongs to the parent.
alter table research.works add column if not exists parent_work_id uuid references research.works(id);
alter table research.revisions add column if not exists base_revision_id uuid references research.revisions(id);
-- LOOKUPS THAT HAD NO INDEX, measured (specs/research-platform/scale.md §2). "My packages" reads works by owner, and erasure's
-- cascade checks each deleted work and revision for children through these references: without an index
-- each check was a scan of the whole table, so erasing one work cost a scan per revision.
create index if not exists works_by_owner on research.works (owner_id);
create index if not exists works_by_parent on research.works (parent_work_id) where parent_work_id is not null;
create index if not exists revisions_by_base on research.revisions (base_revision_id) where base_revision_id is not null;
create index if not exists revisions_by_predecessor on research.revisions (predecessor_id) where predecessor_id is not null;

-- WHY THE REVISION WAS MADE, beside who made it (REM-464). Optional, and given by the writer: "corrected S2's
-- date" is what a reader comparing two revisions wants, and until now it lived only in whatever the client put in
-- the document. Written once with the revision; research.refuse_rewrite keeps it there.
alter table research.revisions add column if not exists reason text check (reason is null or length(reason) between 1 and 500);

create table if not exists research.heads (
    work_id     uuid primary key references research.works(id) on delete cascade,
    revision_id uuid not null references research.revisions(id),
    updated_at  timestamptz not null default now()
);
comment on table research.heads is
    'Which revision is currently the head of each work.';
create index if not exists heads_by_revision on research.heads (revision_id);

create table if not exists research.operations (
    owner_id    uuid not null references rbac.users(id) on delete cascade,
    key         text not null,
    body_hash   text not null,
    work_id     uuid not null references research.works(id) on delete cascade,
    revision_id uuid not null references research.revisions(id),
    created_at  timestamptz not null default now(),
    primary key (owner_id, key)
);
comment on table research.operations is
    'The idempotency record: an owner''s operation key and body hash mapped to the revision it produced, so a retry returns the first receipt.';
create index if not exists operations_by_work on research.operations (work_id);

create table if not exists research.claims (
    id          uuid primary key,
    revision_id uuid not null references research.revisions(id) on delete cascade,
    claim_key   text not null,
    kind        text not null,
    text        text not null,
    locator     text not null default '',
    unique (revision_id, claim_key)
);
comment on table research.claims is
    'A claim as it occurs in one revision: its local key, kind, text and where in the document it sits.';

create table if not exists research.sources (
    id          uuid primary key,
    revision_id uuid not null references research.revisions(id) on delete cascade,
    source_key  text not null,
    title       text not null,
    url         text not null,
    origin      text not null,
    status      text not null,
    locator     text not null,
    unique (revision_id, source_key)
);
comment on table research.sources is
    'A source a revision cites, with its origin, status and the capture that pinned it.';
-- Sources citing one origin, across packages (REM-219), without reading every source (specs/research-platform/scale.md §2).
create index if not exists sources_by_origin on research.sources (origin) where origin <> '';

create table if not exists research.citations (
    revision_id uuid not null,
    claim_key   text not null,
    source_key  text not null,
    primary key (revision_id, claim_key, source_key),
    foreign key (revision_id, claim_key) references research.claims (revision_id, claim_key) on delete cascade,
    foreign key (revision_id, source_key) references research.sources (revision_id, source_key) on delete cascade
);
comment on table research.citations is
    'Which claim in a revision rests on which source. A claim with no row here is uncited, which the trust read reports.';

create table if not exists research.argument_edges (
    revision_id      uuid not null,
    source_claim_key text not null,
    relation         text not null check (relation in ('supports', 'challenges', 'motivates', 'qualifies', 'limits', 'compares with')),
    target_claim_key text not null,
    primary key (revision_id, source_claim_key, relation, target_claim_key),
    foreign key (revision_id, source_claim_key) references research.claims (revision_id, claim_key) on delete cascade,
    foreign key (revision_id, target_claim_key) references research.claims (revision_id, claim_key) on delete cascade
);
comment on table research.argument_edges is
    'How one claim in a revision bears on another — supports, challenges, qualifies — so the argument is data rather than prose.';

-- SEARCH OVER CLAIMS AND SOURCES, SCOPED BY THE ROWS THEMSELVES (REM-152). Lexical
-- sources rather than entity projections: revision_readable decides what a search returns, and a package
-- write adds no aiq row -- nobody needs a
-- write grant on aiq, on the first insert or any other. The registration adds a generated search_tsv
-- column and its GIN index to each table; the projections stay the record, and the index is derived.
select aiq.register_lexical_source('research_claims', 'research.claims', 'text');
select aiq.register_lexical_source('research_sources', 'research.sources', 'title');
-- Both are searched through their definer searches, research.search_claims and research.search_sources

-- (REM-519): as the caller, the policy ran on every row before the index, 7 minutes at 960 K claims.
update aiq.lexical_sources set search_with = 'research.search_claims'  where name = 'research_claims';
update aiq.lexical_sources set search_with = 'research.search_sources' where name = 'research_sources';

-- A source may pin a capture. Null is the explicit "declared, not captured" state; a later capture is a new
-- revision, never an update to this one (clients hold no update on projections).
alter table research.sources add column if not exists snapshot_id uuid references content.resource_snapshots(id);

-- Hosted evidence for an artifact: the exact capture its table, note or chart was drawn from. Keyed by the
-- artifact's own id when the document names one, otherwise by its position (A1, A2, ...), which cannot move
-- because a revision cannot.
create table if not exists research.revision_files (
    revision_id  uuid not null references research.revisions(id) on delete cascade,
    artifact_key text not null,
    snapshot_id  uuid not null references content.resource_snapshots(id),
    purpose      text not null default '',
    primary key (revision_id, artifact_key)
);
comment on table research.revision_files is
    'The artifacts a revision carries — images, attachments — each pinned to a capture.';

-- research.resolve_image finds the revisions that pin an image by its snapshot (REM-309).
create index if not exists idx_revision_files_snapshot on research.revision_files (snapshot_id);

-- May the current caller pin this capture? It must exist, still hold its bytes, and belong to a resource the
-- caller may read -- so nobody cites another tenant's private evidence into their own package.
create or replace function research.snapshot_pinnable(p_snapshot uuid) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
    select exists (select 1 from content.resource_snapshots s join content.resources r on r.id = s.resource_id
                    where s.id = p_snapshot and s.removed_at is null
                      and rbac.may_read(r.owner_id, r.org_id, r.visibility));
$$;

-- What a reader is told about a source's capture. The hash and dates only reach a caller who may read the
-- resource; anybody else learns that a capture exists and is not theirs to see.
create or replace function research.capture_state(p_snapshot uuid) returns jsonb
language sql stable security definer set search_path = pg_catalog, public as $$
    select case
        when p_snapshot is null then jsonb_build_object('status', 'unverified', 'reason', 'no capture is linked to this source')
        when s.id is null then jsonb_build_object('status', 'unavailable', 'reason', 'the capture is not readable by this reader')
        when s.removed_at is not null then jsonb_build_object('status', 'removed', 'checksum', s.checksum,
                                                              'removed_at', s.removed_at, 'reason', s.removed_reason)
        else jsonb_build_object('status', 'captured', 'checksum', s.checksum, 'captured_at', s.captured_at,
                                'snapshot_id', s.id)
    end
      from (select 1) one
      left join (select sn.id, sn.checksum, sn.captured_at, sn.removed_at, sn.removed_reason
                   from content.resource_snapshots sn join content.resources r on r.id = sn.resource_id
                  where sn.id = p_snapshot and rbac.may_read(r.owner_id, r.org_id, r.visibility)) s on true;
$$;

-- An endorsement says what a person checked in an exact revision. It is not
-- a finding that a claim is true, and a correction does not inherit it.
create table if not exists research.endorsements (
    id              uuid primary key default uuidv7(),
    revision_id     uuid not null references research.revisions(id) on delete cascade,
    endorser_id     uuid not null references rbac.users(id),
    scope           text not null check (length(scope) between 3 and 500),
    checked         text not null check (length(checked) between 3 and 1000),
    created_at      timestamptz not null default now(),
    withdrawn_at    timestamptz,
    withdraw_reason text,
    constraint endorsements_withdrawal_says_why check ((withdrawn_at is null) = (withdraw_reason is null))
);
comment on table research.endorsements is
    'What a person checked in an exact revision, at what scope. Not a finding that a claim is true, and a correction does not inherit it.';
create unique index if not exists endorsements_one_active
    on research.endorsements (revision_id, endorser_id) where withdrawn_at is null;
-- A revision's endorsements, withdrawn ones included: trust reads them all, and a partial index answers
-- only queries that imply its predicate, so trust scanned the table (specs/research-platform/scale.md §2).
create index if not exists endorsements_by_revision on research.endorsements (revision_id);

-- WHAT WAS CHECKED, AS KEYS AND NOT ONLY AS PROSE (REM-154). A document-scoped
-- endorsement may name no claim; a claim-scoped one names at least one, and research.endorse refuses it
-- otherwise. The free text stays beside the keys: it says how, the keys say which.
alter table research.endorsements add column if not exists kind text not null default 'document'
    check (kind in ('document', 'claims'));

-- Each checked claim, proved by composite keys to be a claim OF THE ENDORSED REVISION: the endorsement's
-- (id, revision_id) and the claim's (revision_id, claim_key) share one revision_id column, so a link to a
-- claim from any other revision cannot be written, by a definer or anybody else.
create table if not exists research.endorsement_claims (
    endorsement_id uuid not null,
    revision_id    uuid not null,
    claim_key      text not null,
    primary key (endorsement_id, claim_key),
    foreign key (revision_id, claim_key) references research.claims (revision_id, claim_key)
);
comment on table research.endorsement_claims is
    'Which exact claims an endorsement covers, when it is scoped to claims rather than the whole revision.';
-- Erasing a claim checks this reference; without the index each deleted claim scanned the table.
create index if not exists endorsement_claims_by_claim on research.endorsement_claims (revision_id, claim_key);
-- The FK that reaches through the endorsement is dropped before the unique key it needs, and added after it,
-- so the replayed upgrade can drop and re-add both.
alter table research.endorsement_claims drop constraint if exists endorsement_claims_same_revision;
alter table research.endorsements drop constraint if exists endorsements_id_revision_key;
alter table research.endorsements add constraint endorsements_id_revision_key unique (id, revision_id);
alter table research.endorsement_claims add constraint endorsement_claims_same_revision
    foreign key (endorsement_id, revision_id) references research.endorsements (id, revision_id) on delete cascade;

-- WITHDRAWAL IS ITS OWN EVENT (§5): who withdrew, why and when, appended once and never rewritten. The
-- endorsement row keeps withdrawn_at and withdraw_reason in step, because the applications read them and
-- endorsements_one_active is keyed on them; this table is the record, and a retry adds nothing to it.
create table if not exists research.endorsement_withdrawals (
    endorsement_id uuid primary key references research.endorsements(id) on delete cascade,
    withdrawn_by   uuid not null references rbac.users(id),
    reason         text not null,
    withdrawn_at   timestamptz not null default now()
);
comment on table research.endorsement_withdrawals is
    'The withdrawal of an endorsement as its own event: who withdrew, why and when.';
-- Withdrawals from before the event table, carried over once: only the endorser could ever withdraw, so the
-- endorser is who withdrew. Replay-safe, and a no-op on a fresh install.
insert into research.endorsement_withdrawals (endorsement_id, withdrawn_by, reason, withdrawn_at)
select id, endorser_id, withdraw_reason, withdrawn_at from research.endorsements where withdrawn_at is not null
on conflict (endorsement_id) do nothing;

-- An exposure says one exact revision may be read by anybody who may read the
-- work's public projection (authoring-and-publication.md §4, REM-185). A
-- listed work no longer exposes every revision it has: an owner's private
-- working successor, a draft from before it was listed, and their claims,
-- sources, citations, edges, endorsements and comments stay the owner's.
-- Exposures are kept after a correction, so a link or a blog entry pinned to
-- an earlier public revision still resolves; unlisting the work hides them all.
create table if not exists research.exposures (
    revision_id uuid primary key references research.revisions(id) on delete cascade,
    work_id     uuid not null references research.works(id) on delete cascade,
    exposed_by  uuid references rbac.users(id),
    exposed_at  timestamptz not null default now()
);
comment on table research.exposures is
    'That a revision was made readable beyond its owner, and by whom.';
create index if not exists exposures_by_work on research.exposures (work_id);
-- The listing walks exposures newest first (research.list_listed).
create index if not exists exposures_newest on research.exposures (exposed_at desc, revision_id);

-- A publication exposure says one exact revision may be read by anybody because
-- its owner added it to one publication, in an org where they hold
-- research:publish (authoring-and-publication.md §5, REM-252). It lists
-- nothing: the work stays out of the marketplace, and its head and every other
-- revision stay the owner's. It is kept apart from research.exposures so that
-- listing and unlisting never touch it, and withdrawing it never touches them.
-- The application keeps the entry (slug, author, decision); core keeps only
-- that this revision is readable for that publication.
create table if not exists research.publication_exposures (
    revision_id uuid not null references research.revisions(id) on delete cascade,
    work_id     uuid not null references research.works(id) on delete cascade,
    publication text not null check (publication ~ '^[a-z0-9][a-z0-9-]{0,62}$'),
    org_id      uuid not null references rbac.orgs(id) on delete cascade,
    exposed_by  uuid references rbac.users(id),
    exposed_via uuid references rbac.api_keys(id) on delete set null,
    exposed_at  timestamptz not null default now(),
    primary key (revision_id, publication)
);
comment on table research.publication_exposures is
    'That an exact revision was added to a named publication in an org, and through what route.';
-- exposed_via: the credential that acted, when an agent published through a delegation; null when the person did.
alter table research.publication_exposures add column if not exists exposed_via uuid references rbac.api_keys(id) on delete set null;
create index if not exists publication_exposures_by_work on research.publication_exposures (work_id);

-- WHAT A TRUST READ AS OF A PAST DATE NEEDS, AND THE TWO TABLES THAT OVERWRITE IT (REM-464). works.visibility is
-- rewritten by every listing and unlisting, and a withdrawn publication exposure is deleted, so "was this revision
-- public on the 3rd, and in which publication" had no answer. Each change is appended below by a trigger on the
-- table that changes (section 6), not by each definer, so a writer added later records it too: the shape
-- aiq.edge_retractions settled (REM-65).
--
-- A work that predates this table gets one row. A listed work gets its listed_at, which survives every relisting
-- and is cleared by unlisting, so the work has been public since then without a break. An unlisted work gets the
-- upgrade itself, because nothing records whether it was ever listed before. Before a work's first row its
-- visibility is unknown, and research.trust_state says so rather than guessing. The column is changed_to, not
-- visibility: a `visibility` column is what rbac/02 reads as a row scope, and this row's scope is its work's.
create table if not exists research.visibility_changes (
    id         bigint generated always as identity primary key,
    work_id    uuid not null references research.works(id) on delete cascade,
    changed_to text not null,
    changed_by uuid references rbac.users(id),
    changed_at timestamptz not null default now()
);
comment on table research.visibility_changes is
    'Every change to a work''s visibility, so what was public when is answerable later.';
create index if not exists visibility_changes_by_work on research.visibility_changes (work_id, changed_at);
insert into research.visibility_changes (work_id, changed_to, changed_at)
select w.id, w.visibility, case when w.visibility = 'public' then coalesce(w.listed_at, now()) else now() end
  from research.works w
 where not exists (select 1 from research.visibility_changes v where v.work_id = w.id);

-- A publication exposure that stopped: the row as it stood, and who ended it and when. The exposure was readable
-- from exposed_at until withdrawn_at, and re-adding the same revision later is a new exposure with its own start.
create table if not exists research.publication_withdrawals (
    id           bigint generated always as identity primary key,
    revision_id  uuid not null references research.revisions(id) on delete cascade,
    work_id      uuid not null references research.works(id) on delete cascade,
    publication  text not null,
    exposed_by   uuid references rbac.users(id),
    exposed_at   timestamptz not null,
    withdrawn_by uuid references rbac.users(id),
    withdrawn_at timestamptz not null default now()
);
comment on table research.publication_withdrawals is
    'A publication exposure that ended: the row as it stood, and who ended it when.';
create index if not exists publication_withdrawals_by_work on research.publication_withdrawals (work_id);

-- ERASURE IS THE ONE WAY HISTORY LEAVES (a documented privileged lifecycle). The row
-- outlives the work it names, so it holds no foreign key: what was erased, by whom and why stays when the erased
-- rows do not. `xact` is the transaction that erased it, and it is what research.refuse_rewrite asks, so the
-- permission is exactly as wide as research.erase_work's one statement and ends with it. Nobody is granted this
-- table: it is written by the operator's function and read by the operator.
create table if not exists research.erasures (
    id         bigint generated always as identity primary key,
    work_id    uuid not null,
    public_id  text not null,
    reason     text not null check (length(btrim(reason)) > 0),
    erased_by  text not null default session_user,
    erased_at  timestamptz not null default now(),
    xact       xid8 not null default pg_current_xact_id()
);
comment on table research.erasures is
    'The tombstone left when a work is erased: what it was and why, keeping no text.';
-- Every org_id column defaults to the shared org (specs/identity/spec.md). The functions below always name the
-- publication's org, and rbac.decide_in_org refuses the shared org, so the default is never what a row holds.
select rbac.adopt_shared_org('research.publication_exposures');

-- Before exposures existed, every revision of a public work was readable, so an
-- upgrade exposes exactly those and changes nothing anybody could read. Only
-- for a public work with no exposure at all: this file is replayed on every
-- upgrade, and a replay must never expose a private working revision written
-- after the first one.
insert into research.exposures (revision_id, work_id, exposed_by, exposed_at)
select r.id, r.work_id, r.actor_id, coalesce(w.listed_at, r.created_at)
  from research.revisions r
  join research.works w on w.id = r.work_id
 where w.visibility = 'public'
   and not exists (select 1 from research.exposures e where e.work_id = w.id)
on conflict (revision_id) do nothing;

create or replace function research.readable(p_work uuid) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
    select coalesce((select rbac.may_read(owner_id, org_id, visibility)
                            and (rbac.current_user_id() is null or rbac.may('research', 'select'))
                       from research.works where id = p_work), false);
$$;

-- Everything in the work: its owner, or its org when the work is org-scoped.
-- Public visibility adds nothing here, because it exposes exact revisions only.
create or replace function research.work_readable_in_full(p_work uuid) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
    select coalesce((select rbac.may_read(owner_id, org_id, case when visibility = 'public' then 'private' else visibility end)
                            and (rbac.current_user_id() is null or rbac.may('research', 'select'))
                       from research.works where id = p_work), false);
$$;

-- A revision is readable in full, or when its work is readable and this exact
-- revision was exposed, or when its owner added this exact revision to a
-- publication (REM-252), which needs no public work. Every nested read --
-- claims, sources, citations, edges, endorsements, comments, votes -- asks
-- this, so it narrows with it. visible_head and the listing do not: a
-- publication exposure is reached by its exact revision, never found as a head.
-- COST 1000, not the default 100: each call reads the revision, its work, the caller's grants and two exposure
-- tables, about 0.3 ms. Priced at the default, the planner checked every row of a table once rather than the few
-- rows a policy asked about, and a claim page on production spent 3.3 s doing it (REM-626).
create or replace function research.revision_readable(p_revision uuid) returns boolean
language sql stable security definer cost 1000 set search_path = pg_catalog, public as $$
    select coalesce((select research.work_readable_in_full(r.work_id)
                            or (research.readable(r.work_id)
                                and exists (select 1 from research.exposures e where e.revision_id = r.id))
                            or ((rbac.current_user_id() is null or rbac.may('research', 'select'))
                                and exists (select 1 from research.publication_exposures pe where pe.revision_id = r.id))
                       from research.revisions r where r.id = p_revision), false);
$$;

-- The revision a caller is shown for a work: the head to a caller with full
-- access, otherwise the latest exposed revision. Null when neither applies, so
-- a caller who may not read the work learns nothing, not even that a head moved.
create or replace function research.visible_head(p_work uuid) returns uuid
language sql stable security definer set search_path = pg_catalog, public as $$
    select case
        when research.work_readable_in_full(p_work) then (select revision_id from research.heads where work_id = p_work)
        when research.readable(p_work) then (select e.revision_id from research.exposures e
                                               join research.revisions r on r.id = e.revision_id
                                              where e.work_id = p_work order by r.number desc limit 1)
    end;
$$;

create or replace function research.receipt(p_revision uuid, p_created boolean) returns jsonb
language sql stable security definer set search_path = pg_catalog, public as $$
    select jsonb_build_object(
        'package_id', w.public_id, 'work_id', w.id, 'revision_id', r.id, 'revision', r.label,
        'content_hash', r.content_hash, 'hash_format', 'pg-jsonb-sha256',
        'schema_version', r.schema_version, 'hash_algorithm', r.hash_algorithm,
        'hash_format_version', r.hash_format_version,
        'visibility', case when w.visibility = 'public' then 'listed' else 'private' end,
        'exposed', exists (select 1 from research.exposures e where e.revision_id = r.id),
        'created', p_created, 'created_at', r.created_at, 'reason', r.reason)
      from research.revisions r join research.works w on w.id = r.work_id
     where r.id = p_revision
       and research.revision_readable(r.id);
$$;

-- Claims, sources, citations and edges, projected from the revision's own
-- document. Ids are derived from the revision and the local key, so a replay
-- of the same document yields the same ids.
--
-- ONE DERIVATION, TWO MODES (REM-152). A write (p_fill false) inserts every row, so a duplicate key, a
-- dangling citation or edge, or an unknown relation raises and the whole submit or revise rolls back. A
-- repair (p_fill true, only from research.rebuild_projection) adds the rows that are missing and leaves the
-- rest: the document was validated when it was written, and a delete-and-replay cannot run at all once
-- engagement.comments anchors a claim, which it references without a cascade.
drop function if exists research.project(uuid, jsonb);
create or replace function research.project(p_revision uuid, p_document jsonb, p_fill boolean default false) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare c jsonb; s jsonb; e jsonb; src text; a record; k text;
begin
    for s in select value from jsonb_array_elements(coalesce(p_document->'sources', '[]'::jsonb)) loop
        if coalesce(s->>'id', '') = '' then
            raise check_violation using message = 'Every source needs an id';
        end if;
        -- A pin is checked when the revision is written, as its author (REM-153). A rebuild re-derives rows the
        -- author was already allowed to write, with no author in the request to ask, so it does not re-check.
        if not p_fill and nullif(s->>'snapshot_id', '') is not null
           and not research.snapshot_pinnable((s->>'snapshot_id')::uuid) then
            raise foreign_key_violation using message = 'A source can pin only a capture its author may read',
                detail = s->>'id';
        end if;
        if not p_fill or not exists (select 1 from research.sources
                                      where revision_id = p_revision and source_key = s->>'id') then
            insert into research.sources (id, revision_id, source_key, title, url, origin, status, locator, snapshot_id)
            values (percolate.uuidv5(p_revision, 'source:' || (s->>'id')), p_revision, s->>'id',
                    coalesce(s->>'title', ''), coalesce(s->>'url', ''), coalesce(s->>'origin', ''),
                    coalesce(s->>'status', ''), coalesce(s->>'locator', ''), nullif(s->>'snapshot_id', '')::uuid);
        end if;
    end loop;
    for c in select value from jsonb_array_elements(coalesce(p_document->'claims', '[]'::jsonb)) loop
        if coalesce(c->>'id', '') = '' then
            raise check_violation using message = 'Every claim needs an id';
        end if;
        if not p_fill or not exists (select 1 from research.claims
                                      where revision_id = p_revision and claim_key = c->>'id') then
            insert into research.claims (id, revision_id, claim_key, kind, text, locator)
            values (percolate.uuidv5(p_revision, 'claim:' || (c->>'id')), p_revision, c->>'id',
                    coalesce(c->>'kind', ''), coalesce(c->>'text', ''), coalesce(c->>'locator', ''));
        end if;
        for src in select value from jsonb_array_elements_text(coalesce(c->'source_ids', '[]'::jsonb)) loop
            if not p_fill or not exists (select 1 from research.citations
                                          where revision_id = p_revision and claim_key = c->>'id' and source_key = src) then
                insert into research.citations (revision_id, claim_key, source_key) values (p_revision, c->>'id', src);
            end if;
        end loop;
    end loop;
    for e in select value from jsonb_array_elements(coalesce(p_document->'edges', '[]'::jsonb)) loop
        if not p_fill or not exists (select 1 from research.argument_edges
                                      where revision_id = p_revision and source_claim_key = e->>'source'
                                        and relation = e->>'relation' and target_claim_key = e->>'target') then
            insert into research.argument_edges (revision_id, source_claim_key, relation, target_claim_key)
            values (p_revision, e->>'source', e->>'relation', e->>'target');
        end if;
    end loop;
    for a in select value as art, ordinality as n
               from jsonb_array_elements(coalesce(p_document->'artifacts', '[]'::jsonb)) with ordinality loop
        continue when nullif(a.art->>'snapshot_id', '') is null;
        if not p_fill and not research.snapshot_pinnable((a.art->>'snapshot_id')::uuid) then
            raise foreign_key_violation using message = 'An artifact can pin only a capture its author may read',
                detail = coalesce(a.art->>'id', 'A' || a.n);
        end if;
        k := coalesce(nullif(a.art->>'id', ''), 'A' || a.n);
        if not p_fill or not exists (select 1 from research.revision_files
                                      where revision_id = p_revision and artifact_key = k) then
            insert into research.revision_files (revision_id, artifact_key, snapshot_id, purpose)
            values (p_revision, k, (a.art->>'snapshot_id')::uuid, coalesce(a.art->>'kind', ''));
        end if;
    end loop;
    -- Each occurrence expresses a claim (REM-473, specs/claims/schema.sql). A repair links only what is unlinked.
    perform claims.link_revision(p_revision);
    perform claims.project_edges(p_revision);   -- and its argument edges as relations (REM-474)
    perform claims.project_frames(p_revision);  -- and its frames, and the questions they answer (REM-476)
    perform claims.project_cites(p_revision);   -- and the origins its claims cite (REM-477)
    -- And its claims, and any question its frames posed, are queued to be embedded (REM-662). Queued and never
    -- embedded here: a vector is a model call, which a save never waits on. With no model to embed with, the
    -- revision is projected all the same and a NOTICE says so (aiq.queue_source_embedding).
    perform aiq.queue_source_embedding(format('the claims of revision %s', p_revision));
end;
$$;

-- REBUILD A REVISION'S PROJECTION FROM ITS OWN DOCUMENT (REM-152: rebuilding projections never
-- rewrites revisions). Operator-only: nothing grants it to authenticated, and identity/closing.sql takes
-- PUBLIC's EXECUTE away. It adds what is missing, with the ids the first projection gave them, then refuses a
-- projection holding anything its document does not say -- a row that no rebuild can explain is corruption to
-- look at, not something to delete quietly. The revision row itself is only read.
create or replace function research.rebuild_projection(p_revision uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    d      jsonb;
    extras jsonb;
begin
    select document into d from research.revisions where id = p_revision for share;
    if not found then
        raise no_data_found using message = 'Research revision not found';
    end if;
    perform research.project(p_revision, d, true);
    select jsonb_strip_nulls(jsonb_build_object(
        'claims', (select jsonb_agg(x.claim_key) from research.claims x where x.revision_id = p_revision
                     and not exists (select 1 from jsonb_array_elements(coalesce(d->'claims', '[]')) j
                                      where j->>'id' = x.claim_key)),
        'sources', (select jsonb_agg(x.source_key) from research.sources x where x.revision_id = p_revision
                      and not exists (select 1 from jsonb_array_elements(coalesce(d->'sources', '[]')) j
                                       where j->>'id' = x.source_key)),
        'citations', (select jsonb_agg(x.claim_key || '->' || x.source_key) from research.citations x
                       where x.revision_id = p_revision
                         and not exists (select 1 from jsonb_array_elements(coalesce(d->'claims', '[]')) j
                                          where j->>'id' = x.claim_key
                                            and coalesce(j->'source_ids', '[]') ? x.source_key)),
        'edges', (select jsonb_agg(x.source_claim_key || ' ' || x.relation || ' ' || x.target_claim_key)
                    from research.argument_edges x where x.revision_id = p_revision
                     and not exists (select 1 from jsonb_array_elements(coalesce(d->'edges', '[]')) j
                                      where j->>'source' = x.source_claim_key and j->>'relation' = x.relation
                                        and j->>'target' = x.target_claim_key)))) into extras;
    if extras <> '{}'::jsonb then
        raise exception using errcode = 'data_corrupted',
            message = 'The projection holds rows its revision''s document does not say', detail = extras::text;
    end if;
    return jsonb_build_object(
        'claims', (select count(*) from research.claims where revision_id = p_revision),
        'sources', (select count(*) from research.sources where revision_id = p_revision),
        'citations', (select count(*) from research.citations where revision_id = p_revision),
        'edges', (select count(*) from research.argument_edges where revision_id = p_revision));
end;
$$;

-- CAPTURE A RESOURCE'S CURRENT BYTES (REM-153). The file and its hash come from the resource row, locked, at
-- this moment -- never from the caller -- so a snapshot cannot pair a resource with bytes that were not its
-- own. A resource with nothing stored is refused: a declared URL stays unverified until content storage
-- holds its bytes.
create or replace function content.capture_snapshot(p_resource uuid) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_user uuid := rbac.require('research', 'insert');
    r      content.resources;
    f      content.files;
    v_id   uuid;
begin
    select * into r from content.resources where id = p_resource for update;
    if not found or not rbac.may_read(r.owner_id, r.org_id, r.visibility) then
        raise no_data_found using message = 'Resource not found';
    end if;
    if r.file_id is null then
        raise check_violation using message = 'This resource has no stored bytes to capture';
    end if;
    select * into f from content.files where id = r.file_id;
    insert into content.resource_snapshots (resource_id, file_id, checksum, size_bytes, content_type, uri,
                                            captured_by, actor_kind, credential_id)
    values (r.id, f.id, f.checksum, f.size_bytes, f.content_type, r.uri,
            v_user, rbac.current_actor(), rbac.current_credential_id())
    returning id into v_id;
    return v_id;
end;
$$;

-- Where a snapshot's bytes are, for a caller who may read its resource, and nothing once they are removed.
-- The same one answer resolve_file gives, so a stranger cannot tell "not yours" from "not there".
create or replace function content.resolve_snapshot(p_snapshot uuid)
returns table(bucket text, object_key text, content_type text, size_bytes bigint, checksum text)
language sql stable security definer set search_path = pg_catalog, public as $$
    select f.bucket, f.object_key, s.content_type, s.size_bytes, s.checksum
      from content.resource_snapshots s
      join content.resources r on r.id = s.resource_id
      join content.files f on f.id = s.file_id
     where s.id = p_snapshot and s.removed_at is null
       and rbac.may_read(r.owner_id, r.org_id, r.visibility);
$$;

-- THE CHANNEL SAVED EVIDENCE LANDS IN. Shipped and public, as `uploads` is and for its reason
-- (world-model-ingestion/ingestion.sql): a channel must be readable to be found, while every resource in it keeps
-- its own visibility, which register_evidence sets private. No ingest_workflow, so nothing is chunked or
-- embedded. WHERE NOT EXISTS then a marking UPDATE, the pattern `uploads` uses, so a replayed upgrade converges.
insert into content.channels (name, kind, config, visibility)
select 'research_evidence', 'manual',
       jsonb_build_object('description', 'public pages kept as research evidence by content.register_evidence'),
       'public'
where not exists (select 1 from content.channels
                   where name = 'research_evidence' and org_id = rbac.shared_org_id());
update content.channels
   set shipped = true, visibility = 'public'
 where name = 'research_evidence' and org_id = rbac.shared_org_id()
   and (not shipped or visibility is distinct from 'public');

-- KEEP A PUBLIC PAGE AS SOMEBODY'S EVIDENCE (REM-239). capture_snapshot pins only bytes that are already stored,
-- and register_upload stores bytes only for a caller holding resources:create, which no person an application
-- provisions holds or can be given (REM-193). So a cited link could never become captured evidence.
--
-- THE POLICY IS AN INTERIM ONE, SET BY A PERSON (REM-242, 2026-09-14): anybody who may write research may keep a
-- copy of a public page, limited only by bytes, until the policy is reviewed (REM-245). Hence research:insert
-- rather than resources:create, the evidence_bytes budget as the only limit, and a channel with no
-- ingest_workflow: a saved page is `stored`, not chunked or embedded, so saving one costs storage and nothing else.
--
-- The Content Server fetches the page and stores the bytes content-addressed; this records them. The copy is
-- private to its saver. The same page and bytes saved again is the same resource and the same charge (the
-- operation id is the external id), and the same bytes read from another address are that address's evidence.
-- A refusal by the budget is 42501, so both HTTP surfaces answer it 403 with the reason.
create or replace function content.register_evidence(
    p_uri          text,
    p_checksum     text,
    p_bucket       text,
    p_object_key   text,
    p_size_bytes   bigint,
    p_content_type text default null,
    p_title        text default null
) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_user    uuid := rbac.require('research', 'insert');
    v_key     text;
    v_budget  jsonb;
    v_channel uuid;
    v_file    uuid;
    v_res     uuid;
begin
    if coalesce(p_uri, '') !~* '^https?://[^/[:space:]]+' then
        raise check_violation using message = 'Evidence is saved from an http or https address';
    end if;
    if coalesce(p_checksum, '') = '' or coalesce(p_bucket, '') = '' or coalesce(p_object_key, '') = '' then
        raise invalid_parameter_value using message = 'Saved evidence needs its stored object and hash';
    end if;
    if p_size_bytes is null or p_size_bytes <= 0 then
        raise check_violation using message = 'The page was empty, so there is nothing to keep';
    end if;

    v_key := v_user::text || ':' || p_checksum || ':' || md5(p_uri);
    v_budget := rbac.reserve_usage('evidence_bytes', p_size_bytes, 'evidence:' || v_key);
    if coalesce((v_budget->>'reserved')::boolean, false) then
        perform rbac.consume_usage('evidence_bytes', 'evidence:' || v_key);
    elsif v_budget->>'state' is distinct from 'consumed' then
        -- Consumed means this page was saved and paid for already: the insert below returns that resource.
        raise insufficient_privilege
            using message = 'Your allowance for saving evidence is used up for now',
                  hint = 'needs evidence_bytes',
                  detail = coalesce(v_budget->'limit', '{}'::jsonb)::text;
    end if;

    select id into v_channel from content.channels
     where name = 'research_evidence' and org_id = rbac.shared_org_id();
    if v_channel is null then
        raise no_data_found using message = 'The research_evidence channel is missing from this installation';
    end if;

    insert into content.files (checksum, bucket, object_key, size_bytes, content_type)
    values (p_checksum, p_bucket, p_object_key, p_size_bytes, p_content_type)
    on conflict (checksum) do update set checksum = excluded.checksum
    returning id into v_file;

    insert into content.resources (channel_id, file_id, external_id, uri, title, status, org_id, owner_id,
                                   visibility, metadata)
    values (v_channel, v_file, v_key, p_uri, p_title, 'stored', rbac.shared_org_id(), v_user, 'private',
            jsonb_build_object('saved_as', 'research evidence', 'content_type', p_content_type))
    on conflict (channel_id, external_id) do update set updated_at = now()
    returning id into v_res;
    return v_res;
end;
$$;

-- AN IMAGE A WRITER PUTS IN AN ARTICLE (REM-309). The same
-- gap register_evidence closed, for bytes the person sends rather than a page the Content Server fetched: no
-- person holds resources:create (REM-193), so an uploaded picture could never be stored. research:insert, the
-- evidence_bytes budget and the research_evidence channel, for the same reasons given there. The Content Server
-- checks the bytes themselves (magic number, 600 x 400 at least) because only it has them; this refuses every
-- type the spec does not name and anything over 2 MB, so a second caller of this function cannot skip the rule.
-- The copy is private to its uploader, who reads it through resolve_image at once; others only through a revision
-- that pins it (resolve_image, REM-813).
create or replace function content.register_research_image(
    p_checksum     text,
    p_bucket       text,
    p_object_key   text,
    p_size_bytes   bigint,
    p_content_type text,
    p_title        text default null
) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_user    uuid := rbac.require('research', 'insert');
    v_key     text;
    v_budget  jsonb;
    v_channel uuid;
    v_file    uuid;
    v_res     uuid;
begin
    if p_content_type is null or p_content_type not in ('image/png', 'image/jpeg', 'image/webp') then
        raise check_violation using message = 'An article image is a PNG, JPEG or WebP file';
    end if;
    if p_size_bytes is null or p_size_bytes <= 0 or p_size_bytes > 2097152 then
        raise check_violation using message = 'An article image is at most 2 MB';
    end if;
    if coalesce(p_checksum, '') = '' or coalesce(p_bucket, '') = '' or coalesce(p_object_key, '') = '' then
        raise invalid_parameter_value using message = 'An uploaded image needs its stored object and hash';
    end if;

    v_key := v_user::text || ':' || p_checksum || ':image';
    v_budget := rbac.reserve_usage('evidence_bytes', p_size_bytes, 'image:' || v_key);
    if coalesce((v_budget->>'reserved')::boolean, false) then
        perform rbac.consume_usage('evidence_bytes', 'image:' || v_key);
    elsif v_budget->>'state' is distinct from 'consumed' then
        raise insufficient_privilege
            using message = 'Your allowance for keeping evidence and images is used up for now',
                  hint = 'needs evidence_bytes',
                  detail = coalesce(v_budget->'limit', '{}'::jsonb)::text;
    end if;

    select id into v_channel from content.channels
     where name = 'research_evidence' and org_id = rbac.shared_org_id();
    if v_channel is null then
        raise no_data_found using message = 'The research_evidence channel is missing from this installation';
    end if;

    insert into content.files (checksum, bucket, object_key, size_bytes, content_type)
    values (p_checksum, p_bucket, p_object_key, p_size_bytes, p_content_type)
    on conflict (checksum) do update set checksum = excluded.checksum
    returning id into v_file;

    insert into content.resources (channel_id, file_id, external_id, uri, title, status, org_id, owner_id,
                                   visibility, metadata)
    values (v_channel, v_file, v_key, null, p_title, 'stored', rbac.shared_org_id(), v_user, 'private',
            jsonb_build_object('saved_as', 'research image', 'content_type', p_content_type))
    on conflict (channel_id, external_id) do update set updated_at = now()
    returning id into v_res;
    return v_res;
end;
$$;

-- WHERE AN ARTICLE IMAGE'S BYTES ARE, for anybody who may read some revision that pins it as an image.
-- resolve_snapshot asks whether the caller may read the RESOURCE, which is private to its uploader, so a reader of
-- a published article would be refused its own pictures. The access question here is the revision's
-- (data-model.md, hosted artifacts). Keyed by the snapshot alone, so one stored image has one address whichever
-- revision or work shows it, and the article's document can carry that address. Only purpose 'image' and only
-- image types: a table's pinned evidence page is never served through this path. One answer for "not yours" and
-- "not there", as resolve_snapshot gives. Its UPLOADER also reads it before any revision cites it (REM-813): a
-- picture is shown before it is cited (the upload's own preview, a reviewer's portrait, which is private to its
-- owner), and without this nobody could read their own upload. Nobody else gains anything.
create or replace function research.resolve_image(p_snapshot uuid)
returns table(bucket text, object_key text, content_type text, size_bytes bigint, checksum text)
language sql stable security definer set search_path = pg_catalog, public as $$
    select f.bucket, f.object_key, s.content_type, s.size_bytes, s.checksum
      from content.resource_snapshots s
      join content.files f on f.id = s.file_id
     where s.id = p_snapshot and s.removed_at is null
       and s.content_type in ('image/png', 'image/jpeg', 'image/webp')
       and (s.captured_by = rbac.current_user_id()
            or exists (select 1 from research.revision_files rf
                        where rf.snapshot_id = p_snapshot and rf.purpose = 'image'
                          and research.revision_readable(rf.revision_id)));
$$;

-- REMOVE PINNED BYTES, AUTHORIZED AND EXPLICIT (REM-153). Operator-only: nothing grants it. The
-- snapshot stays as a tombstone with its checksum, who removed it and why, so every revision that pinned it
-- says "removed" rather than pointing at nothing -- and the file row is then free for content storage to prune.
create or replace function content.remove_snapshot_bytes(p_snapshot uuid, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
    if coalesce(btrim(p_reason), '') = '' then
        raise check_violation using message = 'Removing pinned evidence needs a reason';
    end if;
    update content.resource_snapshots
       set file_id = null, removed_at = now(), removed_by = rbac.current_user_id(), removed_reason = p_reason
     where id = p_snapshot and removed_at is null;
    if not found then
        raise no_data_found using message = 'No capture with bytes to remove';
    end if;
end;
$$;

create or replace function research.submit_package(p_document jsonb, p_idempotency_key text default null,
                                                   p_public_id text default null)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_user   uuid := rbac.require('research', 'insert');
    v_hash   text := encode(digest(p_document::text, 'sha256'), 'hex');
    v_listed boolean := p_document->>'visibility' = 'listed';
    v_op     research.operations;
    v_work   uuid;
    v_rev    uuid;
begin
    if jsonb_typeof(p_document) <> 'object' or p_document->>'schema_version' is distinct from '0.1' then
        raise check_violation using message = 'A package is a JSON object with schema_version 0.1';
    end if;
    if p_idempotency_key is not null then
        perform pg_advisory_xact_lock(hashtextextended(v_user::text || '/' || p_idempotency_key, 0));
        select * into v_op from research.operations where owner_id = v_user and key = p_idempotency_key;
        if found then
            if v_op.body_hash <> v_hash then
                raise unique_violation using message = 'This idempotency key was used for a different package';
            end if;
            return research.receipt(v_op.revision_id, false);
        end if;
    end if;
    if v_listed then
        perform rbac.require('research', 'list');
    end if;
    insert into research.works (public_id, owner_id, visibility, listed_at)
    values (coalesce(p_public_id, 'rp-' || substr(md5(uuidv7()::text), 1, 12)), v_user,
            case when v_listed then 'public' else 'private' end, case when v_listed then now() end)
    returning id into v_work;
    insert into research.revisions (work_id, number, label, schema_version, document, content_hash,
                                    actor_id, actor_kind, credential_id, run_id)
    values (v_work, 1, 'draft-1', '0.1', p_document, v_hash, v_user, rbac.current_actor(), rbac.current_credential_id(),
            nullif(current_setting('workflow.current_run_id', true), '')::uuid)
    returning id into v_rev;
    perform research.project(v_rev, p_document);
    insert into research.heads (work_id, revision_id) values (v_work, v_rev);
    if v_listed then
        insert into research.exposures (revision_id, work_id, exposed_by) values (v_rev, v_work, v_user);
    end if;
    if p_idempotency_key is not null then
        insert into research.operations (owner_id, key, body_hash, work_id, revision_id)
        values (v_user, p_idempotency_key, v_hash, v_work, v_rev);
    end if;
    return research.receipt(v_rev, true);
end;
$$;

-- Append from the head the caller last read. A stale head is PT409 (HTTP 409
-- through PostgREST) with the current label as detail; an unchanged document
-- is a no-op. Somebody else's package is not found, not forbidden.
-- p_reason (REM-464) is new and last, so a caller passing three arguments is unchanged. The three-argument
-- function is dropped first, or a three-argument call would match both and be refused as ambiguous.
drop function if exists research.revise_package(text, jsonb, text);
create or replace function research.revise_package(p_public_id text, p_document jsonb, p_expected_revision text,
                                                   p_reason text default null)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_user   uuid := rbac.require('research', 'insert');
    v_hash   text := encode(digest(p_document::text, 'sha256'), 'hex');
    v_listed boolean := p_document->>'visibility' = 'listed';
    w        research.works;
    h        research.revisions;
    v_rev    uuid;
begin
    select * into w from research.works where public_id = p_public_id for update;
    if not found or w.owner_id <> v_user then
        raise no_data_found using message = 'Research package not found';
    end if;
    select r.* into h from research.heads hd join research.revisions r on r.id = hd.revision_id where hd.work_id = w.id;
    if h.label <> p_expected_revision then
        raise exception using errcode = 'PT409', message = 'This package has a newer revision', detail = h.label;
    end if;
    -- A private-writing key must not rewrite already-public work either.
    if v_listed or w.visibility = 'public' then
        perform rbac.require('research', 'list');
    end if;
    if h.content_hash = v_hash then
        -- LISTING AN UNCHANGED HEAD IS STILL A LISTING (REM-269). The owner's private working revision (or the head
        -- of an unlisted work) keeps its exact text when the listing authority lists it. Returning here, before the
        -- listing below, left that revision private while every reader kept the older one, so a correction could be
        -- listed only by changing its text. No revision is created, and a replay adds no second exposure.
        if v_listed and (w.visibility <> 'public'
                         or not exists (select 1 from research.exposures e where e.revision_id = h.id)) then
            update research.works set visibility = 'public', listed_at = coalesce(listed_at, now()) where id = w.id;
            insert into research.exposures (revision_id, work_id, exposed_by) values (h.id, w.id, v_user)
                on conflict (revision_id) do nothing;
        end if;
        return research.receipt(h.id, false);
    end if;
    insert into research.revisions (work_id, number, label, schema_version, document, content_hash,
                                    predecessor_id, actor_id, actor_kind, credential_id, run_id, reason)
    values (w.id, h.number + 1, 'draft-' || (h.number + 1), '0.1', p_document, v_hash,
            h.id, v_user, rbac.current_actor(), rbac.current_credential_id(),
            nullif(current_setting('workflow.current_run_id', true), '')::uuid, nullif(btrim(p_reason), ''))
    returning id into v_rev;
    perform research.project(v_rev, p_document);
    update research.heads set revision_id = v_rev, updated_at = now() where work_id = w.id;
    update research.works
       set visibility = case when v_listed then 'public' else 'private' end,
           listed_at = case when v_listed then coalesce(listed_at, now()) end
     where id = w.id;
    if v_listed then
        insert into research.exposures (revision_id, work_id, exposed_by) values (v_rev, w.id, v_user);
    end if;
    return research.receipt(v_rev, true);
end;
$$;

-- Add an exact revision of your own work to a publication (authoring-and-
-- publication.md §5, REM-252). A person's own decision: an agent or a token is
-- refused, and so is anybody without research:publish granted in the
-- publication's org, where a grant held in the shared org does not count
-- (rbac.decide_in_org, REM-255). The work need not be listed and is not listed
-- by this. Somebody else's package is not found. Adding the same revision to
-- the same publication again changes nothing; naming another org for it is a
-- conflict.
create or replace function research.expose_for_publication(p_public_id text, p_revision text, p_publication text,
                                                            p_org uuid)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_decision jsonb := rbac.decide_in_org('research', 'publish', p_org);
    v_user     uuid := rbac.current_user_id();
    w          research.works;
    v_rev      uuid;
    v_row      research.publication_exposures;
begin
    if not coalesce((v_decision->>'allowed')::boolean, false) then
        raise insufficient_privilege using message = 'Adding work to this publication needs research:publish in its org',
                                           hint = coalesce(v_decision->>'reason', 'no_grant');
    end if;
    if coalesce(p_publication, '') !~ '^[a-z0-9][a-z0-9-]{0,62}$' then
        raise invalid_parameter_value using message = 'A publication is named by a lower-case slug';
    end if;
    select * into w from research.works where public_id = p_public_id;
    if not found or w.owner_id is distinct from v_user then
        raise no_data_found using message = 'Research package not found';
    end if;
    select r.id into v_rev from research.revisions r where r.work_id = w.id and r.label = p_revision;
    if v_rev is null then
        raise no_data_found using message = 'Research revision not found';
    end if;
    insert into research.publication_exposures (revision_id, work_id, publication, org_id, exposed_by, exposed_via)
    values (v_rev, w.id, p_publication, p_org, v_user, rbac.current_credential_id())
    on conflict (revision_id, publication) do nothing;
    select * into v_row from research.publication_exposures where revision_id = v_rev and publication = p_publication;
    if v_row.org_id <> p_org then
        raise unique_violation using message = 'This revision is already in that publication under another org';
    end if;
    return jsonb_build_object('package_id', w.public_id, 'revision', p_revision, 'publication', p_publication,
                              'org_id', v_row.org_id, 'exposed_at', v_row.exposed_at);
end;
$$;

-- Take an exact revision of your own work out of a publication. The owner, as a
-- person, needs no publish grant, so losing one never traps work in a
-- publication. An agent may take out what it may put in (REM-532): the same
-- research:publish decision expose_for_publication takes, in the org the
-- exposure was made in, so a delegation that publishes can also unpublish and a
-- revoked or narrowed one can do neither. True when something was removed; a
-- listing is untouched.
create or replace function research.withdraw_publication_exposure(p_public_id text, p_revision text,
                                                                   p_publication text)
returns boolean language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_user     uuid := rbac.require('research', 'select');
    w          research.works;
    v_org      uuid;
    v_decision jsonb;
    v_count    int;
begin
    select * into w from research.works where public_id = p_public_id;
    if not found or w.owner_id is distinct from v_user then
        raise no_data_found using message = 'Research package not found';
    end if;
    if rbac.current_actor() <> 'person' then
        select pe.org_id into v_org
          from research.publication_exposures pe join research.revisions r on r.id = pe.revision_id
         where r.work_id = w.id and r.label = p_revision and pe.publication = p_publication;
        if v_org is null then
            return false;
        end if;
        v_decision := rbac.decide_in_org('research', 'publish', v_org);
        if not coalesce((v_decision->>'allowed')::boolean, false) then
            raise insufficient_privilege using message = 'Taking work out of this publication needs research:publish in its org',
                                               hint = coalesce(v_decision->>'reason', 'no_grant');
        end if;
    end if;
    delete from research.publication_exposures pe
     using research.revisions r
     where pe.revision_id = r.id and r.work_id = w.id and r.label = p_revision and pe.publication = p_publication;
    get diagnostics v_count = row_count;
    return v_count > 0;
end;
$$;

-- MOVE A PUBLICATION'S PIN FROM ONE REVISION TO ANOTHER (REM-423). Publishing a
-- correction is two acts on the exposure table: the new revision becomes
-- readable and the old one stops being. The second act alone is
-- research.withdraw_publication_exposure, which is a person's and needs no
-- grant, so that losing a grant never traps work in a publication. Inside a
-- move that rule refuses the wrong thing: the work is not leaving the
-- publication, and the caller is exercising research:publish, which they
-- passed to put the new revision there. An agent publishing through a
-- delegation could therefore add an entry and never correct it.
--
-- So a move is one call, authorised exactly as the add is, and it can do
-- nothing a caller could not already do: it exposes p_to_revision under the
-- same org decision, and removes p_from_revision of THE SAME WORK in THE SAME
-- publication. It cannot retire a revision of another work. Since REM-532 a
-- withdrawal takes the same decision for an agent, so the two now agree.
create or replace function research.move_publication_exposure(p_public_id text, p_from_revision text,
                                                              p_to_revision text, p_publication text, p_org uuid)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_user   uuid;
    w        research.works;
    v_from   uuid;
    v_added  jsonb;
    v_count  int := 0;
begin
    -- The add decides the authority; a move that cannot add is refused before anything is removed.
    v_added := research.expose_for_publication(p_public_id, p_to_revision, p_publication, p_org);
    v_user := rbac.current_user_id();
    select * into w from research.works where public_id = p_public_id;
    if not found or w.owner_id is distinct from v_user then
        raise no_data_found using message = 'Research package not found';
    end if;
    if p_from_revision is not null and p_from_revision <> p_to_revision then
        select r.id into v_from from research.revisions r where r.work_id = w.id and r.label = p_from_revision;
        if v_from is not null then
            delete from research.publication_exposures pe
             where pe.revision_id = v_from and pe.publication = p_publication and pe.work_id = w.id;
            get diagnostics v_count = row_count;
        end if;
    end if;
    return v_added || jsonb_build_object('moved_from', p_from_revision, 'retired', v_count > 0);
end;
$$;

-- A private working revision (authoring-and-publication.md §4, REM-185). The
-- owner appends from the head they last read, whether or not the work is
-- listed, and a stale head conflicts exactly as revise_package's does. It
-- exposes nothing and leaves the work's listing alone, so it needs no listing
-- authority: anybody else keeps reading the revision that was exposed. Listing
-- a correction, or unlisting, is still revise_package.
drop function if exists research.revise_working(text, jsonb, text);
create or replace function research.revise_working(p_public_id text, p_document jsonb, p_expected_revision text,
                                                   p_reason text default null)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_user   uuid := rbac.require('research', 'insert');
    v_hash   text := encode(digest(p_document::text, 'sha256'), 'hex');
    w        research.works;
    h        research.revisions;
    v_rev    uuid;
begin
    if jsonb_typeof(p_document) <> 'object' or p_document->>'schema_version' is distinct from '0.1' then
        raise check_violation using message = 'A package is a JSON object with schema_version 0.1';
    end if;
    select * into w from research.works where public_id = p_public_id for update;
    if not found or w.owner_id <> v_user then
        raise no_data_found using message = 'Research package not found';
    end if;
    select r.* into h from research.heads hd join research.revisions r on r.id = hd.revision_id where hd.work_id = w.id;
    if h.label <> p_expected_revision then
        raise exception using errcode = 'PT409', message = 'This package has a newer revision', detail = h.label;
    end if;
    if h.content_hash = v_hash then
        return research.receipt(h.id, false);
    end if;
    insert into research.revisions (work_id, number, label, schema_version, document, content_hash,
                                    predecessor_id, actor_id, actor_kind, credential_id, run_id, reason)
    values (w.id, h.number + 1, 'draft-' || (h.number + 1), '0.1', p_document, v_hash,
            h.id, v_user, rbac.current_actor(), rbac.current_credential_id(),
            nullif(current_setting('workflow.current_run_id', true), '')::uuid, nullif(btrim(p_reason), ''))
    returning id into v_rev;
    perform research.project(v_rev, p_document);
    update research.heads set revision_id = v_rev, updated_at = now() where work_id = w.id;
    return research.receipt(v_rev, true);
end;
$$;

create or replace function research.get_package(p_public_id text, p_revision text default null) returns jsonb
language sql stable security definer set search_path = pg_catalog, public as $$
    select r.document || jsonb_build_object(
               'id', w.public_id, 'revision', r.label, 'owner_id', w.owner_id,
               'visibility', case when w.visibility = 'public' then 'listed' else 'private' end,
               'is_head', r.id = v.head, 'receipt', research.receipt(r.id, false))
      from research.works w
      cross join lateral (select research.visible_head(w.id) as head) v
      join research.revisions r on r.work_id = w.id
                               and (case when p_revision is null then r.id = v.head else r.label = p_revision end)
     where w.public_id = p_public_id
       and research.revision_readable(r.id);
$$;

create or replace function research.list_packages(p_owned_only boolean default false) returns setof jsonb
language sql stable security definer set search_path = pg_catalog, public as $$
    select jsonb_build_object(
               'id', w.public_id, 'title', r.document->>'title', 'summary', r.document->>'summary',
               'revision', r.label, 'visibility', case when w.visibility = 'public' then 'listed' else 'private' end,
               'owned', w.owner_id = rbac.current_user_id(), 'updated_at', u.updated_at)
      from research.works w
      cross join lateral (select research.visible_head(w.id) as head) v
      join research.revisions r on r.id = v.head
      -- To anybody without full access, the time of the exposure, not of the
      -- latest private edit.
      cross join lateral (select case when research.work_readable_in_full(w.id)
                                      then (select hd.updated_at from research.heads hd where hd.work_id = w.id)
                                      else (select e.exposed_at from research.exposures e where e.revision_id = r.id)
                                 end as updated_at) u
     where not p_owned_only or w.owner_id = rbac.current_user_id()
     order by u.updated_at desc, w.public_id;
$$;

-- A PAGE OF THE LISTING, READ AS A PAGE (REM-500, specs/research-platform/scale.md §2). list_packages visits
-- every work, asks visible_head of each, sorts them all and returns everything, so a caller's LIMIT saves
-- nothing: 21.7 s for the first 20 at 960 K claims. This walks exposures newest first through
-- exposures_newest and stops at the page, so it costs the same at any size (319 pages at 960 K). The
-- next page passes the last row's exposed_at. Readability is asked of each row, as list_packages does.
create or replace function research.list_listed(p_before timestamptz default null, p_limit int default 20)
returns setof jsonb language sql stable security definer set search_path = pg_catalog, public as $$
    select jsonb_build_object('id', w.public_id, 'title', r.document->>'title', 'summary', r.document->>'summary',
                              'revision', r.label, 'exposed_at', e.exposed_at)
      from research.exposures e
      join research.revisions r on r.id = e.revision_id
      join research.works w on w.id = e.work_id
     where (p_before is null or e.exposed_at < p_before) and research.readable(w.id)
     order by e.exposed_at desc, e.revision_id
     limit least(greatest(p_limit, 1), 100)
$$;

-- CLAIM SEARCH THAT ASKS THE INDEX FIRST (REM-500, scale.md §2). Under row security the planner must run
-- claims_readable on every claim before `@@`, because ts_match_vq is not leakproof, so a search as the
-- caller reads the whole table (7 minutes at 960 K claims). As the definer, the GIN index answers first,
-- and readability is asked of each candidate, so the answer holds no claim the caller could not read.
-- p_candidates bounds the work for a term that matches millions; a common term still costs what its
-- matches cost (scale.md §3), which is the open part.
--
-- THE QUERY IS PARSED WITH THE REGCONFIG THE COLUMN WAS BUILT WITH (REM-519). It was 'simple' against an
-- 'english' search_tsv, so "rates" never matched "Interest rates are rising": the column holds the stem.
-- The probes used unstemmed synthetic words, and test 17 a word with no stem, so nothing saw it.
create or replace function research.search_claims(p_query text, p_limit int default 20, p_candidates int default 2000)
returns table (claim_id uuid, revision_id uuid, claim_key text, text text, score real)
language sql stable security definer set search_path = pg_catalog, public as $$
    with q as (select plainto_tsquery(l.regconfig::regconfig, p_query) as q
                 from aiq.lexical_sources l where l.name = 'research_claims'),
    candidates as (
        select c.id, c.revision_id, c.claim_key, c.text, c.search_tsv
          from research.claims c, q where c.search_tsv @@ q.q
         limit least(greatest(p_candidates, 1), 10000))
    select k.id, k.revision_id, k.claim_key, k.text, ts_rank(k.search_tsv, q.q)::real
      from candidates k, q
     where research.revision_readable(k.revision_id)
     order by 5 desc
     limit least(greatest(p_limit, 1), 100)
$$;

-- SOURCE SEARCH, on the same terms as search_claims (REM-519): the index first, then readability of each
-- candidate's revision, which is what sources_readable asks.
create or replace function research.search_sources(p_query text, p_limit int default 20, p_candidates int default 2000)
returns table (source_id uuid, revision_id uuid, source_key text, title text, url text, score real)
language sql stable security definer set search_path = pg_catalog, public as $$
    with q as (select plainto_tsquery(l.regconfig::regconfig, p_query) as q
                 from aiq.lexical_sources l where l.name = 'research_sources'),
    candidates as (
        select s.id, s.revision_id, s.source_key, s.title, s.url, s.search_tsv
          from research.sources s, q where s.search_tsv @@ q.q
         limit least(greatest(p_candidates, 1), 10000))
    select k.id, k.revision_id, k.source_key, k.title, k.url, ts_rank(k.search_tsv, q.q)::real
      from candidates k, q
     where research.revision_readable(k.revision_id)
     order by 6 desc
     limit least(greatest(p_limit, 1), 100)
$$;

-- A person says what they checked in one exact revision (§5). With no claim keys it is document-scoped, as
-- before; with keys it is claim-scoped and names at least one, each a claim of that revision. research:endorse
-- is human-only, so an agent's credential is refused here whatever it has been granted.
drop function if exists research.endorse(uuid, text, text);
create or replace function research.endorse(p_revision uuid, p_scope text, p_checked text,
                                            p_claim_keys text[] default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_user uuid := rbac.require('research', 'endorse'); v_id uuid;
begin
    if not research.revision_readable(p_revision) then
        raise no_data_found using message = 'Revision not found';
    end if;
    if p_claim_keys is not null and coalesce(cardinality(p_claim_keys), 0) = 0 then
        raise check_violation using message = 'A claim-scoped endorsement names at least one checked claim';
    end if;
    insert into research.endorsements (revision_id, endorser_id, scope, checked, kind)
    values (p_revision, v_user, p_scope, p_checked, case when p_claim_keys is null then 'document' else 'claims' end)
    returning id into v_id;
    insert into research.endorsement_claims (endorsement_id, revision_id, claim_key)
    select distinct v_id, p_revision, k from unnest(p_claim_keys) k;
    return v_id;
end;
$$;

-- The endorser withdraws their own endorsement, once (§5). A retry converges on the first withdrawal -- its
-- reason and time stand -- rather than failing or appending a second event for the same act.
create or replace function research.withdraw_endorsement(p_endorsement uuid, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_user uuid := rbac.require('research', 'endorse');
    e      research.endorsements;
begin
    select * into e from research.endorsements where id = p_endorsement and endorser_id = v_user for update;
    if not found then
        raise no_data_found using message = 'Endorsement not found';
    end if;
    if e.withdrawn_at is not null then
        return;
    end if;
    update research.endorsements set withdrawn_at = now(), withdraw_reason = p_reason where id = e.id;
    insert into research.endorsement_withdrawals (endorsement_id, withdrawn_by, reason, withdrawn_at)
    values (e.id, v_user, p_reason, now());
end;
$$;

-- WHAT A CORRECTION TOUCHES (§5): the endorsements of the revision this one corrects whose checked claims it
-- removed or reworded. Listed, never transferred -- a corrected revision starts with no endorsements, and
-- whoever endorsed the old claim decides whether to endorse the new one. Only claim-scoped endorsements can
-- be affected by a claim; readable on the same terms as both revisions.
create or replace function research.endorsements_affected_by(p_revision uuid)
returns table(endorsement_id uuid, endorsed_revision text, claim_key text, change text)
language sql stable security definer set search_path = pg_catalog, public as $$
    select e.id, p.label, ec.claim_key,
           case when c_new.claim_key is null then 'removed' else 'changed' end
      from research.revisions r
      join research.revisions p on p.id = r.predecessor_id
      join research.endorsements e on e.revision_id = p.id
      join research.endorsement_claims ec on ec.endorsement_id = e.id
      join research.claims c_old on c_old.revision_id = p.id and c_old.claim_key = ec.claim_key
      left join research.claims c_new on c_new.revision_id = r.id and c_new.claim_key = ec.claim_key
     where r.id = p_revision
       and research.revision_readable(r.id) and research.revision_readable(p.id)
       and (c_new.claim_key is null or c_new.text is distinct from c_old.text or c_new.kind is distinct from c_old.kind)
     order by e.created_at, ec.claim_key;
$$;


-- ------------------------------------------------------------
-- 4. Engagement survives the hub (§5)
-- ------------------------------------------------------------
-- Every mutation needs a person (engagement:insert is human-only). Votes and
-- likes keep their withdrawals; comments keep every version. What a caller
-- sees is the intersection of the record's own scope and the target's.

create schema if not exists engagement;

create table if not exists engagement.saves (
    user_id    uuid not null references rbac.users(id) on delete cascade,
    work_id    uuid not null references research.works(id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (user_id, work_id)
);
comment on table engagement.saves is
    'That a person kept a work. Private, idempotent, and it follows the work across revisions.';
create index if not exists saves_by_work on engagement.saves (work_id);

create table if not exists engagement.follows (
    user_id    uuid not null references rbac.users(id) on delete cascade,
    -- The org being followed, not a scope column: named apart from org_id so
    -- the shared-tier default (identity/spec.md §4) is not implied.
    target_org_id uuid not null references rbac.orgs(id) on delete cascade,
    created_at    timestamptz not null default now(),
    primary key (user_id, target_org_id)
);
comment on table engagement.follows is
    'That a person follows an org, which is how a publication is followed.';

-- Preserve follows when applying this schema over the original platform slice.
do $$
begin
    if exists (select 1 from information_schema.columns
                where table_schema = 'engagement' and table_name = 'follows' and column_name = 'org_id') then
        alter table engagement.follows rename column org_id to target_org_id;
    end if;
end $$;

create table if not exists engagement.votes (
    id           uuid primary key default uuidv7(),
    user_id      uuid not null references rbac.users(id) on delete cascade,
    revision_id  uuid not null references research.revisions(id) on delete cascade,
    created_at   timestamptz not null default now(),
    withdrawn_at timestamptz
);
comment on table engagement.votes is
    'That a person found an exact revision useful. One live vote each, self-votes refused, withdrawals kept.';
create unique index if not exists votes_one_active on engagement.votes (user_id, revision_id) where withdrawn_at is null;
-- A revision's votes: revision_signals counts them, and erasure deletes them, withdrawn ones too, which a
-- partial index cannot serve (specs/research-platform/scale.md §2).
create index if not exists votes_by_revision on engagement.votes (revision_id);

create table if not exists engagement.valuations (
    id           uuid primary key default uuidv7(),
    user_id      uuid not null references rbac.users(id) on delete cascade,
    revision_id  uuid not null references research.revisions(id) on delete cascade,
    amount_minor bigint not null check (amount_minor >= 0),
    currency     text not null check (currency ~ '^[A-Z]{3}$'),
    created_at   timestamptz not null default now()
);
comment on table engagement.valuations is
    'What a person privately thought a revision was worth, in its own currency. Never part of a public signal.';
create index if not exists valuations_by_revision on engagement.valuations (revision_id);

create table if not exists engagement.comments (
    id              uuid primary key default uuidv7(),
    revision_id     uuid not null references research.revisions(id) on delete cascade,
    claim_key       text,
    author_id       uuid not null references rbac.users(id),
    body            text not null check (length(body) between 1 and 4000),
    version         int  not null default 1,
    created_at      timestamptz not null default now(),
    edited_at       timestamptz,
    withdrawn_at    timestamptz,
    withdrawn_by    uuid references rbac.users(id),
    withdraw_reason text,
    foreign key (revision_id, claim_key) references research.claims (revision_id, claim_key),
    constraint comments_withdrawal_says_why check ((withdrawn_at is null) = (withdraw_reason is null))
);
comment on table engagement.comments is
    'A person''s comment on a revision, optionally anchored to one claim, with its moderation and withdrawal state.';

create table if not exists engagement.comment_versions (
    comment_id uuid not null references engagement.comments(id) on delete cascade,
    version    int  not null,
    body       text not null,
    created_at timestamptz not null default now(),
    primary key (comment_id, version)
);
comment on table engagement.comment_versions is
    'Each earlier body of an edited comment, so a reader can see what changed.';

create table if not exists engagement.comment_likes (
    id           uuid primary key default uuidv7(),
    comment_id   uuid not null references engagement.comments(id) on delete cascade,
    user_id      uuid not null references rbac.users(id) on delete cascade,
    created_at   timestamptz not null default now(),
    withdrawn_at timestamptz
);
comment on table engagement.comment_likes is
    'That a person liked a comment, withdrawable.';
create unique index if not exists comment_likes_one_active on engagement.comment_likes (comment_id, user_id) where withdrawn_at is null;

-- Discussions (REM-507). A comment is a post in a thread: it may answer another
-- post (parent_id), take a stance toward what it answers or the claim it sits on,
-- and be about a resource instead of a revision. One table rather than a second
-- one for discussions, so versions, likes, withdrawal and moderation hold for
-- every post unchanged. A reply stays on its parent's target and claim, which
-- engagement.discuss enforces: there is no direct write path.
-- The stance words are research.argument_edges' own, a deliberate narrowing of that vocabulary: a
-- question is a post with no stance.
alter table engagement.comments alter column revision_id drop not null;
alter table engagement.comments add column if not exists resource_id uuid references content.resources(id) on delete cascade;
alter table engagement.comments add column if not exists parent_id uuid references engagement.comments(id);
alter table engagement.comments add column if not exists stance text;
alter table engagement.comments drop constraint if exists comments_one_target;
alter table engagement.comments add constraint comments_one_target check ((revision_id is null) <> (resource_id is null));
alter table engagement.comments drop constraint if exists comments_stance_known;
alter table engagement.comments add constraint comments_stance_known
    check (stance is null or stance in ('supports', 'challenges', 'qualifies'));
alter table engagement.comments drop constraint if exists comments_claim_needs_revision;
alter table engagement.comments add constraint comments_claim_needs_revision check (claim_key is null or revision_id is not null);
create index if not exists comments_by_revision on engagement.comments (revision_id, created_at) where revision_id is not null;
create index if not exists comments_by_resource on engagement.comments (resource_id, created_at) where resource_id is not null;
create index if not exists comments_by_parent on engagement.comments (parent_id) where parent_id is not null;

-- Whether the caller may read what a post is about: the revision rule, or the
-- one read rule content.resources carries (rbac.may_read). Definer, so the
-- answer is the same from a policy and from inside another definer function.
create or replace function engagement.target_readable(p_revision uuid, p_resource uuid) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
    select case
        when p_revision is not null then research.revision_readable(p_revision)
        when p_resource is not null then coalesce((select rbac.may_read(r.owner_id, r.org_id, r.visibility)
                                                     from content.resources r where r.id = p_resource), false)
        else false end;
$$;

create or replace function engagement.set_saved(p_work uuid, p_saved boolean) returns boolean
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_user uuid := rbac.require('engagement', 'insert');
begin
    if not research.readable(p_work) then
        raise no_data_found using message = 'Research not found';
    end if;
    if p_saved then
        insert into engagement.saves (user_id, work_id) values (v_user, p_work) on conflict do nothing;
    else
        delete from engagement.saves where user_id = v_user and work_id = p_work;
    end if;
    return p_saved;
end;
$$;

-- EVERY WORK A PERSON SAVED, READABLE OR NOT (REM-307). Library keeps a saved work listed, marked unavailable, after
-- its reader loses access to it (REM-196). A join through research.works cannot: works_access hides the row, and with
-- it the id. This returns only the caller's own saves and only a work's public id, with whether they may read it now.
-- set_saved refuses an unreadable work, so an id is on this list only if its reader could read it when they saved it.
-- engagement:select, like the saves_self policy on the table it reads, so a person's own agent reads it too.
create or replace function engagement.my_saves() returns table (public_id text, saved_at timestamptz, readable boolean)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v_user uuid := rbac.require('engagement', 'select');
begin
    return query
    select w.public_id, s.created_at, research.readable(s.work_id)
      from engagement.saves s join research.works w on w.id = s.work_id
     where s.user_id = v_user
     order by s.created_at desc, w.public_id;
end;
$$;

create or replace function engagement.set_following(p_org uuid, p_following boolean) returns boolean
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_user uuid := rbac.require('engagement', 'insert');
begin
    if not exists (select 1 from rbac.orgs where id = p_org) then
        raise no_data_found using message = 'Org not found';
    end if;
    if p_following then
        insert into engagement.follows (user_id, target_org_id) values (v_user, p_org) on conflict do nothing;
    else
        delete from engagement.follows where user_id = v_user and target_org_id = p_org;
    end if;
    return p_following;
end;
$$;

create or replace function engagement.set_useful(p_revision uuid, p_useful boolean) returns boolean
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_user uuid := rbac.require('engagement', 'insert'); v_owner uuid;
begin
    select w.owner_id into v_owner from research.revisions r join research.works w on w.id = r.work_id where r.id = p_revision;
    if not found or not research.revision_readable(p_revision) then
        raise no_data_found using message = 'Revision not found';
    end if;
    if p_useful and v_owner = v_user then
        raise check_violation using message = 'You cannot mark your own research useful';
    end if;
    if p_useful then
        insert into engagement.votes (user_id, revision_id) values (v_user, p_revision)
        on conflict (user_id, revision_id) where withdrawn_at is null do nothing;
    else
        update engagement.votes set withdrawn_at = now()
         where user_id = v_user and revision_id = p_revision and withdrawn_at is null;
    end if;
    return p_useful;
end;
$$;

create or replace function engagement.set_valuation(p_revision uuid, p_amount_minor bigint, p_currency text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_user uuid := rbac.require('engagement', 'insert'); v_id uuid;
begin
    if not research.revision_readable(p_revision) then
        raise no_data_found using message = 'Revision not found';
    end if;
    insert into engagement.valuations (user_id, revision_id, amount_minor, currency)
    values (v_user, p_revision, p_amount_minor, p_currency)
    returning id into v_id;
    return v_id;
end;
$$;

create or replace function engagement.add_comment(p_revision uuid, p_body text, p_claim_key text default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_user uuid := rbac.require('engagement', 'insert'); v_id uuid;
begin
    if not research.revision_readable(p_revision) then
        raise no_data_found using message = 'Revision not found';
    end if;
    if p_claim_key is not null
       and not exists (select 1 from research.claims where revision_id = p_revision and claim_key = p_claim_key) then
        raise foreign_key_violation using message = 'That claim is not in this revision';
    end if;
    insert into engagement.comments (revision_id, claim_key, author_id, body)
    values (p_revision, p_claim_key, v_user, p_body)
    returning id into v_id;
    insert into engagement.comment_versions (comment_id, version, body) values (v_id, 1, p_body);
    return v_id;
end;
$$;

-- A post in a discussion (REM-507): a root on a revision, one of its claims, or a
-- resource, or a reply to a post the caller can read. engagement:discuss is its own
-- human-only kind so it can be granted apart from likes and saves; REM-509 moves
-- who holds it to reputation.
create or replace function engagement.discuss(
    p_body text, p_revision uuid default null, p_resource uuid default null,
    p_parent uuid default null, p_claim_key text default null, p_stance text default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_user uuid := rbac.require('engagement', 'discuss'); p engagement.comments; v_id uuid;
begin
    if p_parent is not null then
        select * into p from engagement.comments where id = p_parent and withdrawn_at is null;
        if not found or not engagement.target_readable(p.revision_id, p.resource_id) then
            raise no_data_found using message = 'Comment not found';
        end if;
        if (p_revision is not null and p_revision is distinct from p.revision_id)
           or (p_resource is not null and p_resource is distinct from p.resource_id)
           or (p_claim_key is not null and p_claim_key is distinct from p.claim_key) then
            raise check_violation using message = 'A reply stays on the revision, resource and claim of the post it answers';
        end if;
        p_revision := p.revision_id; p_resource := p.resource_id; p_claim_key := p.claim_key;
    end if;
    if (p_revision is null) = (p_resource is null) then
        raise invalid_parameter_value using message = 'A discussion is about one revision or one resource';
    end if;
    if not engagement.target_readable(p_revision, p_resource) then
        raise no_data_found using message = case when p_revision is null then 'Resource not found' else 'Revision not found' end;
    end if;
    if p_claim_key is not null
       and not exists (select 1 from research.claims where revision_id = p_revision and claim_key = p_claim_key) then
        raise foreign_key_violation using message = 'That claim is not in this revision';
    end if;
    insert into engagement.comments (revision_id, resource_id, parent_id, claim_key, stance, author_id, body)
    values (p_revision, p_resource, p_parent, p_claim_key, p_stance, v_user, p_body)
    returning id into v_id;
    insert into engagement.comment_versions (comment_id, version, body) values (v_id, 1, p_body);
    return v_id;
end;
$$;

create or replace function engagement.edit_comment(p_comment uuid, p_body text, p_expected_version int) returns int
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_user uuid := rbac.require('engagement', 'insert'); v_version int;
begin
    update engagement.comments set body = p_body, version = version + 1, edited_at = now()
     where id = p_comment and author_id = v_user and withdrawn_at is null and version = p_expected_version
    returning version into v_version;
    if not found then
        if exists (select 1 from engagement.comments where id = p_comment and author_id = v_user and withdrawn_at is null) then
            raise exception using errcode = 'PT409', message = 'This comment changed since you read it';
        end if;
        raise no_data_found using message = 'Comment not found';
    end if;
    insert into engagement.comment_versions (comment_id, version, body) values (p_comment, v_version, p_body);
    return v_version;
end;
$$;

create or replace function engagement.withdraw_comment(p_comment uuid, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_user uuid := rbac.require('engagement', 'insert');
begin
    update engagement.comments set withdrawn_at = now(), withdrawn_by = v_user, withdraw_reason = p_reason
     where id = p_comment and author_id = v_user and withdrawn_at is null;
    if not found then
        raise no_data_found using message = 'Comment not found';
    end if;
end;
$$;

create or replace function engagement.moderate_comment(p_comment uuid, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_user uuid := rbac.require('engagement', 'moderate');
begin
    update engagement.comments set withdrawn_at = now(), withdrawn_by = v_user, withdraw_reason = p_reason
     where id = p_comment and withdrawn_at is null;
    if not found then
        raise no_data_found using message = 'Comment not found';
    end if;
end;
$$;

create or replace function engagement.set_like(p_comment uuid, p_liked boolean) returns boolean
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_user uuid := rbac.require('engagement', 'insert'); c engagement.comments;
begin
    select * into c from engagement.comments where id = p_comment and withdrawn_at is null;
    if not found or not engagement.target_readable(c.revision_id, c.resource_id) then
        raise no_data_found using message = 'Comment not found';
    end if;
    if p_liked and c.author_id = v_user then
        raise check_violation using message = 'You cannot like your own comment';
    end if;
    if p_liked then
        insert into engagement.comment_likes (comment_id, user_id) values (p_comment, v_user)
        on conflict (comment_id, user_id) where withdrawn_at is null do nothing;
    else
        update engagement.comment_likes set withdrawn_at = now()
         where comment_id = p_comment and user_id = v_user and withdrawn_at is null;
    end if;
    return p_liked;
end;
$$;

-- Counts only for a revision the caller can read, so a count cannot reveal a
-- private target.
create or replace function engagement.revision_signals(p_revision uuid) returns jsonb
language sql stable security definer set search_path = pg_catalog, public as $$
    select case when research.revision_readable(p_revision) then jsonb_build_object(
        'useful_votes', (select count(*) from engagement.votes where revision_id = p_revision and withdrawn_at is null),
        'comments', (select count(*) from engagement.comments where revision_id = p_revision and withdrawn_at is null),
        'my_vote', exists (select 1 from engagement.votes
                            where revision_id = p_revision and user_id = rbac.current_user_id() and withdrawn_at is null))
    end;
$$;


-- ------------------------------------------------------------
-- 5. The trust read (§6)
-- ------------------------------------------------------------
-- Each component keeps its own meaning and says when it does not know. No
-- number combines them. Shared origins are reported, not counted as
-- independent corroboration.

create or replace function research.trust(p_revision uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare r research.revisions; w research.works; v_head uuid; v_full boolean;
begin
    select * into r from research.revisions where id = p_revision;
    if not found or not research.revision_readable(p_revision) then
        return null;
    end if;
    select * into w from research.works where id = r.work_id;
    v_full := research.work_readable_in_full(w.id);
    v_head := research.visible_head(w.id);
    return jsonb_build_object(
        'revision', jsonb_build_object('id', r.id, 'package_id', w.public_id, 'revision', r.label,
                                       'content_hash', r.content_hash, 'created_at', r.created_at,
                                       'is_head', v_head = r.id, 'author_kind', r.actor_kind),
        'claims', coalesce((
            select jsonb_agg(jsonb_build_object(
                       'id', c.claim_key, 'kind', c.kind, 'text', c.text,
                       'sources', coalesce((select jsonb_agg(ct.source_key order by ct.source_key) from research.citations ct
                                             where ct.revision_id = r.id and ct.claim_key = c.claim_key), '[]'::jsonb),
                       'uncited', not exists (select 1 from research.citations ct
                                               where ct.revision_id = r.id and ct.claim_key = c.claim_key))
                   order by c.claim_key)
              from research.claims c where c.revision_id = r.id), '[]'::jsonb),
        'sources', coalesce((
            select jsonb_agg(jsonb_build_object(
                       'id', s.source_key, 'title', s.title, 'url', s.url, 'origin', s.origin, 'status', s.status,
                       'cited_by', (select count(*) from research.citations ct
                                     where ct.revision_id = r.id and ct.source_key = s.source_key),
                       'capture', research.capture_state(s.snapshot_id))
                   order by s.source_key)
              from research.sources s where s.revision_id = r.id), '[]'::jsonb),
        'shared_origins', coalesce((
            select jsonb_agg(jsonb_build_object('origin', g.origin, 'sources', g.keys) order by g.origin)
              from (select s.origin, jsonb_agg(s.source_key order by s.source_key) as keys
                      from research.sources s
                     where s.revision_id = r.id and s.origin <> ''
                     group by s.origin having count(*) > 1) g), '[]'::jsonb),
        'endorsements', coalesce((
            select jsonb_agg(jsonb_build_object(
                       'id', e.id, 'scope', e.scope, 'checked', e.checked, 'self', e.endorser_id = w.owner_id,
                       'active', e.withdrawn_at is null, 'withdrawn_at', e.withdrawn_at, 'created_at', e.created_at,
                       'kind', e.kind,
                       'claims', coalesce((select jsonb_agg(ec.claim_key order by ec.claim_key)
                                             from research.endorsement_claims ec where ec.endorsement_id = e.id), '[]'::jsonb))
                   order by e.created_at)
              from research.endorsements e where e.revision_id = r.id), '[]'::jsonb),
        'corrections', jsonb_build_object(
            'supersedes', (select p.label from research.revisions p
                            where p.id = r.predecessor_id and research.revision_readable(p.id)),
            'superseded_by', coalesce((select jsonb_agg(s.label order by s.number) from research.revisions s
                                        where s.work_id = w.id and s.number > r.number
                                          and (v_full or research.revision_readable(s.id))),
                                      '[]'::jsonb)),
        'engagement', engagement.revision_signals(r.id),
        'interpretations', jsonb_build_object('status', 'unavailable', 'reason', 'no analysis provider is configured'));
end;
$$;

-- WHAT STOOD ON A DATE (REM-464). research.trust reads one revision as it is now; this reads a work as it was at
-- p_at: its visibility, the revision its owner had as head, the revision anybody else was shown, the publications
-- that carried a revision, and the endorsements that stood and had not been withdrawn. Every part is derived
-- from rows that are never rewritten -- created_at, exposed_at, the withdrawal events and visibility_changes -- so
-- the same question asked next year gets the same answer.
--
-- It shows only what the caller may read NOW. A past state is not a way into a revision a caller cannot open
-- today, so a revision they cannot read is left out, and the head is shown only to a caller with full access, as
-- visible_head does. Visibility before the first recorded change is 'unknown', with recorded_since saying when
-- the record starts: a work upgraded from before REM-464 has no history before the upgrade, and a guess would
-- be read as a fact.
create or replace function research.trust_state(p_public_id text, p_at timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
    w        research.works;
    v_full   boolean;
    v_vis    text;
    v_since  timestamptz;
    v_head   research.revisions;
    v_shown  research.revisions;
begin
    select * into w from research.works where public_id = p_public_id;
    if not found or not exists (select 1 from research.revisions r
                                 where r.work_id = w.id and research.revision_readable(r.id)) then
        return null;
    end if;
    v_full := research.work_readable_in_full(w.id);
    select min(changed_at) into v_since from research.visibility_changes where work_id = w.id;
    select changed_to into v_vis from research.visibility_changes
     where work_id = w.id and changed_at <= p_at order by changed_at desc, id desc limit 1;
    if v_full then
        select * into v_head from research.revisions
         where work_id = w.id and created_at <= p_at order by number desc limit 1;
    end if;
    if v_vis = 'public' then
        select r.* into v_shown from research.exposures e join research.revisions r on r.id = e.revision_id
         where e.work_id = w.id and e.exposed_at <= p_at and research.revision_readable(r.id)
         order by r.number desc limit 1;
    end if;
    return jsonb_build_object(
        'package_id', w.public_id,
        'at', p_at,
        'recorded_since', v_since,
        'visibility', case when v_vis is null then 'unknown' when v_vis = 'public' then 'listed' else 'private' end,
        'head', v_head.label,
        'shown', v_shown.label,
        'publications', coalesce((
            select jsonb_agg(jsonb_build_object('publication', p.publication, 'revision', r.label,
                                                'exposed_at', p.exposed_at) order by p.publication, r.number)
              from (select revision_id, publication, exposed_at from research.publication_exposures
                     where work_id = w.id and exposed_at <= p_at
                    union all
                    select revision_id, publication, exposed_at from research.publication_withdrawals
                     where work_id = w.id and exposed_at <= p_at and withdrawn_at > p_at) p
              join research.revisions r on r.id = p.revision_id
             where research.revision_readable(r.id)), '[]'::jsonb),
        'endorsements', coalesce((
            select jsonb_agg(jsonb_build_object('id', e.id, 'revision', r.label, 'kind', e.kind, 'scope', e.scope,
                                                'self', e.endorser_id = w.owner_id, 'created_at', e.created_at)
                             order by e.created_at, e.id)
              from research.endorsements e join research.revisions r on r.id = e.revision_id
             where r.work_id = w.id and e.created_at <= p_at
               and (e.withdrawn_at is null or e.withdrawn_at > p_at)
               and research.revision_readable(r.id)), '[]'::jsonb));
end;
$$;


-- ------------------------------------------------------------
-- 6. Row security and grants
-- ------------------------------------------------------------


-- The generated scope policy: rbac/02 requires it of any table carrying the
-- scope columns, so the tenancy rule has one home.
drop policy if exists works_readable on research.works;
select rbac.add_scope_policy('research.works');
-- Visibility is necessary but cannot override a revoked key or inactive owner.
-- A restrictive policy intersects with the generated tenancy policy above.
-- ONCE PER QUERY, NOT PER ROW (REM-528). Both calls depend only on the caller's transaction-scoped claims, so as
-- subselects Postgres evaluates each once, as an InitPlan. Written bare they ran on every row a query touched, and
-- an anonymous Edition read paid for them on every private work too (the application's load review, 18 September).
drop policy if exists works_access on research.works;
create policy works_access on research.works as restrictive for select
    using ((select rbac.current_user_id()) is null or (select rbac.may('research', 'select')));
-- A work with a revision in a publication is visible as a row, so that exact revision can be read joined to its work
-- (REM-252). Only the row: its head stays hidden (heads_readable) and visible_head never returns a publication's
-- revision, so the work is still absent from every listing. The subquery is under publication_exposures' own row
-- security, which asks the definer research.revision_readable, so this cannot recurse into works.
drop policy if exists works_in_a_publication on research.works;
create policy works_in_a_publication on research.works for select
    using (exists (select 1 from research.publication_exposures pe where pe.work_id = works.id));
-- The same guard rbac.add_scope_columns() attaches: 'org' visibility needs a
-- real org, whichever definer writes the row (rbac/02).
create or replace trigger trg_works_visibility before insert or update on research.works
    for each row execute function rbac.enforce_visibility();

-- EVERY REVISION'S LINEAGE AND PROVENANCE, checked on the row (REM-151). The
-- definers derive both from trusted claims; this makes one that gets it wrong fail instead of recording it.
--   * A derivative work's revision names a base revision of its parent work; any other revision names none.
--   * An agent's revision carries its credential and only an agent's does, and the credential is the actor's.
--   * With a caller in the request, the actor is that caller: nobody records a revision as somebody else.
--   * The run is the workflow run the engine is executing, or none; and that run is the actor's own (REM-237).
create or replace function research.enforce_revision_row() returns trigger
language plpgsql set search_path = pg_catalog, public as $$
declare
    v_parent uuid;
    v_caller uuid := rbac.current_user_id();
    v_run    uuid := nullif(current_setting('workflow.current_run_id', true), '')::uuid;
begin
    select parent_work_id into v_parent from research.works where id = new.work_id;
    if new.base_revision_id is null then
        if v_parent is not null then
            raise foreign_key_violation using message = 'A revision of a derivative work names the parent revision it answers';
        end if;
    elsif v_parent is null or not exists (select 1 from research.revisions b
                                           where b.id = new.base_revision_id and b.work_id = v_parent) then
        raise foreign_key_violation using message = 'A base revision belongs to the parent work';
    end if;
    if (new.actor_kind = 'agent') <> (new.credential_id is not null) then
        raise check_violation using message = 'An agent''s revision carries its credential, and only an agent''s does';
    end if;
    if new.credential_id is not null and not exists (select 1 from rbac.api_keys k
                                                      where k.id = new.credential_id and k.user_id = new.actor_id) then
        raise check_violation using message = 'A revision''s credential belongs to its actor';
    end if;
    if v_caller is not null and new.actor_id <> v_caller then
        raise check_violation using message = 'A revision is recorded as the caller who made it';
    end if;
    -- The run cannot be named, only inherited: whatever a writer puts in run_id must be the run the engine is
    -- executing right now, so a row claiming a run with no step running, or a different run, is a forgery.
    if new.run_id is distinct from v_run then
        raise check_violation using message = 'A revision records only the workflow run it is written in';
    end if;
    -- And a run carries its owner's authority, not anybody's: a revision written inside somebody else's run,
    -- or inside a system run with no owner, is refused rather than recorded as provenance it does not have.
    if new.run_id is not null and workflow.run_owner_of(new.run_id) is distinct from new.actor_id then
        raise check_violation using message = 'A revision''s workflow run belongs to its actor';
    end if;
    return new;
end;
$$;
create or replace trigger trg_revisions_row before insert on research.revisions
    for each row execute function research.enforce_revision_row();

-- HISTORY CANNOT BE REWRITTEN (REM-464). The grants were the whole rule: a caller holds
-- SELECT and nothing else. But every writer here is a SECURITY DEFINER running as the owner, and the owner holds
-- UPDATE and DELETE, so the next definer written by somebody who has not read this file could change what an
-- endorsement was of, and deleting a work took every revision with it by cascade. This refuses both from anybody,
-- the owner included. It is the trigger workflow.refuse_field_mutation is for deposits, applied to trust history.
--
-- Three changes a history row may take, each once and each toward a recorded end:
--   * an endorsement is withdrawn: withdrawn_at and withdraw_reason, from null, nothing else;
--   * a capture loses its bytes: content.remove_snapshot_bytes's tombstone, from a capture that had them;
--   * a revision loses its workflow run when old runs are pruned: run_id to null, the foreign key's set null.
-- A delete passes only inside research.erase_work's transaction. An operator can still disable the trigger, which
-- §3 says: this stops a definer's mistake and a cascade, not the database's owner acting on purpose.
create or replace function research.refuse_rewrite() returns trigger
language plpgsql set search_path = pg_catalog, public as $$
declare
    o jsonb;
    n jsonb;
begin
    if tg_op = 'DELETE' and exists (select 1 from research.erasures where xact = pg_current_xact_id()) then
        return old;
    end if;
    if tg_op = 'UPDATE' then
        o := to_jsonb(old);
        n := to_jsonb(new);
        if tg_table_name = 'endorsements' and o->'withdrawn_at' = 'null' and n->'withdrawn_at' <> 'null'
           and n - 'withdrawn_at' - 'withdraw_reason' = o - 'withdrawn_at' - 'withdraw_reason' then
            return new;
        elsif tg_table_name = 'resource_snapshots' and o->'removed_at' = 'null' and n->'removed_at' <> 'null'
           and n - 'file_id' - 'removed_at' - 'removed_by' - 'removed_reason'
             = o - 'file_id' - 'removed_at' - 'removed_by' - 'removed_reason' then
            return new;
        elsif tg_table_name = 'revisions' and n->'run_id' = 'null' and n - 'run_id' = o - 'run_id' then
            return new;
        end if;
    end if;
    raise exception using errcode = 'restrict_violation',
        message = format('%s.%s is history, and a %s would rewrite it', tg_table_schema, tg_table_name, lower(tg_op)),
        hint = 'A correction is a new revision; an endorsement is withdrawn; a capture''s bytes are removed; '
               'a work is erased only by research.erase_work.';
end;
$$;

do $$
declare t text;
begin
    foreach t in array array['research.revisions', 'research.claims', 'research.sources', 'research.citations',
                             'research.argument_edges', 'research.revision_files', 'research.endorsements',
                             'research.endorsement_claims', 'research.endorsement_withdrawals', 'research.exposures',
                             'research.visibility_changes', 'research.publication_withdrawals',
                             'content.resource_snapshots'] loop
        execute format('create or replace trigger trg_refuse_rewrite before update or delete on %s '
                       'for each row execute function research.refuse_rewrite()', t);
        execute format('create or replace trigger trg_refuse_truncate before truncate on %s '
                       'for each statement execute function research.refuse_rewrite()', t);
    end loop;
end $$;

-- The two overwrites a trust read as of a date needs undone, recorded where they happen (section 3).
create or replace function research.record_visibility_change() returns trigger
language plpgsql set search_path = pg_catalog, public as $$
begin
    insert into research.visibility_changes (work_id, changed_to, changed_by)
    values (new.id, new.visibility, rbac.current_user_id());
    return null;
end;
$$;
create or replace trigger trg_works_record_visibility after insert on research.works
    for each row execute function research.record_visibility_change();
create or replace trigger trg_works_record_visibility_change after update of visibility on research.works
    for each row when (old.visibility is distinct from new.visibility)
    execute function research.record_visibility_change();

-- An erasure removes the exposure with its revision, and records nothing: the revision it would name is going too.
create or replace function research.record_publication_withdrawal() returns trigger
language plpgsql set search_path = pg_catalog, public as $$
begin
    if not exists (select 1 from research.erasures where xact = pg_current_xact_id()) then
        insert into research.publication_withdrawals (revision_id, work_id, publication, exposed_by, exposed_at, withdrawn_by)
        values (old.revision_id, old.work_id, old.publication, old.exposed_by, old.exposed_at, rbac.current_user_id());
    end if;
    return null;
end;
$$;
create or replace trigger trg_publication_exposures_record_withdrawal after delete on research.publication_exposures
    for each row execute function research.record_publication_withdrawal();

-- ERASE A WORK AND ITS HISTORY (§3's privileged lifecycle). Operator-only: nothing grants it, so it runs as whoever
-- owns the database's objects, from psql. The erasure row is written first and survives: what was erased, why and
-- by whom. Everything that names the work goes with it by the existing cascades, which the guard lets through for
-- this transaction alone.
create or replace function research.erase_work(p_public_id text, p_reason text) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    w research.works;
    v_revisions int;
    v_revs uuid[];
    v_erasure bigint;
    v_counts jsonb;
begin
    if coalesce(btrim(p_reason), '') = '' then
        raise check_violation using message = 'Erasing a work needs a reason';
    end if;
    select * into w from research.works where public_id = p_public_id for update;
    if not found then
        raise no_data_found using message = 'Research package not found';
    end if;
    select count(*), array_agg(id) into v_revisions, v_revs from research.revisions where work_id = w.id;
    insert into research.erasures (work_id, public_id, reason) values (w.id, w.public_id, p_reason)
    returning id into v_erasure;
    -- The claims graph resting on the work (REM-481): counted before the cascade, swept after it, and the counts are
    -- the tombstone, with no text.
    v_counts := claims.graph_counts(coalesce(v_revs, '{}'));
    delete from research.works where id = w.id;
    v_counts := v_counts || claims.sweep_erased(coalesce(v_revs, '{}'));
    insert into claims.erasures (erasure_id, counts) values (v_erasure, v_counts);
    return jsonb_build_object('package_id', w.public_id, 'work_id', w.id, 'revisions', v_revisions, 'claims_graph', v_counts);
end;
$$;
revoke all on function research.erase_work(text, text) from public;

alter table research.revisions enable row level security;
drop policy if exists revisions_readable on research.revisions;
create policy revisions_readable on research.revisions for select using (research.revision_readable(id));

-- A head pointing at a private working revision is the owner's to see.
alter table research.heads enable row level security;
drop policy if exists heads_readable on research.heads;
create policy heads_readable on research.heads for select
    using (research.work_readable_in_full(work_id)
           or (research.readable(work_id) and exists (select 1 from research.exposures e where e.revision_id = heads.revision_id)));

alter table research.exposures enable row level security;
drop policy if exists exposures_readable on research.exposures;
create policy exposures_readable on research.exposures for select using (research.readable(work_id));

alter table research.publication_exposures enable row level security;
drop policy if exists publication_exposures_readable on research.publication_exposures;
create policy publication_exposures_readable on research.publication_exposures for select
    using (research.revision_readable(revision_id));

alter table research.operations enable row level security;
drop policy if exists operations_owner on research.operations;
create policy operations_owner on research.operations for select
    using (owner_id = rbac.current_user_id() and rbac.may('research', 'select'));

alter table research.claims enable row level security;
drop policy if exists claims_readable on research.claims;
create policy claims_readable on research.claims for select using (research.revision_readable(revision_id));

alter table research.sources enable row level security;
drop policy if exists sources_readable on research.sources;
create policy sources_readable on research.sources for select using (research.revision_readable(revision_id));

alter table research.citations enable row level security;
drop policy if exists citations_readable on research.citations;
create policy citations_readable on research.citations for select using (research.revision_readable(revision_id));

alter table research.argument_edges enable row level security;
drop policy if exists argument_edges_readable on research.argument_edges;
create policy argument_edges_readable on research.argument_edges for select using (research.revision_readable(revision_id));

alter table research.endorsements enable row level security;
drop policy if exists endorsements_readable on research.endorsements;
create policy endorsements_readable on research.endorsements for select using (research.revision_readable(revision_id));

alter table engagement.saves enable row level security;
drop policy if exists saves_self on engagement.saves;
create policy saves_self on engagement.saves for select
    using (user_id = rbac.current_user_id() and rbac.may('engagement', 'select'));

alter table engagement.follows enable row level security;
drop policy if exists follows_self on engagement.follows;
create policy follows_self on engagement.follows for select
    using (user_id = rbac.current_user_id() and rbac.may('engagement', 'select'));

alter table engagement.votes enable row level security;
drop policy if exists votes_self on engagement.votes;
create policy votes_self on engagement.votes for select
    using (user_id = rbac.current_user_id() and rbac.may('engagement', 'select'));

alter table engagement.valuations enable row level security;
drop policy if exists valuations_self on engagement.valuations;
create policy valuations_self on engagement.valuations for select
    using (user_id = rbac.current_user_id() and rbac.may('engagement', 'select'));

alter table engagement.comments enable row level security;
drop policy if exists comments_readable on engagement.comments;
create policy comments_readable on engagement.comments for select
    using (engagement.target_readable(revision_id, resource_id) and (withdrawn_at is null or author_id = rbac.current_user_id()));

alter table engagement.comment_versions enable row level security;
drop policy if exists comment_versions_author on engagement.comment_versions;
create policy comment_versions_author on engagement.comment_versions for select
    using (rbac.may('engagement', 'select')
           and exists (select 1 from engagement.comments c where c.id = comment_id and c.author_id = rbac.current_user_id()));

alter table engagement.comment_likes enable row level security;
drop policy if exists comment_likes_self on engagement.comment_likes;
create policy comment_likes_self on engagement.comment_likes for select
    using (user_id = rbac.current_user_id() and rbac.may('engagement', 'select'));

-- Signed-in callers only. No definer here is granted to web_anon (rbac/04);
-- an anonymous reader reaches listed research through an application.
grant usage on schema research, engagement to authenticated;
grant select on research.works, research.revisions, research.heads, research.exposures, research.publication_exposures,
                research.claims, research.sources,
                research.citations, research.argument_edges, research.endorsements to authenticated;

-- Checked claims are readable with their revision; a withdrawal event exactly when its endorsement is, asked
-- under the caller's own row security on research.endorsements (REM-154).
alter table research.endorsement_claims enable row level security;
drop policy if exists endorsement_claims_readable on research.endorsement_claims;
create policy endorsement_claims_readable on research.endorsement_claims for select
    using (research.revision_readable(revision_id));
alter table research.endorsement_withdrawals enable row level security;
drop policy if exists endorsement_withdrawals_via_endorsement on research.endorsement_withdrawals;
create policy endorsement_withdrawals_via_endorsement on research.endorsement_withdrawals for select
    using (exists (select 1 from research.endorsements e where e.id = endorsement_withdrawals.endorsement_id));
grant select on research.endorsement_claims, research.endorsement_withdrawals to authenticated;

-- The history a trust read as of a date is built from (REM-464), on the terms of the rows it records: a work's
-- visibility as its exposures are, and a withdrawn publication exposure as its revision is. Erasures are the
-- operator's, so the table has row security and no grant.
alter table research.visibility_changes enable row level security;
drop policy if exists visibility_changes_readable on research.visibility_changes;
create policy visibility_changes_readable on research.visibility_changes for select using (research.readable(work_id));
alter table research.publication_withdrawals enable row level security;
drop policy if exists publication_withdrawals_readable on research.publication_withdrawals;
create policy publication_withdrawals_readable on research.publication_withdrawals for select
    using (research.revision_readable(revision_id));
alter table research.erasures enable row level security;
grant select on research.visibility_changes, research.publication_withdrawals to authenticated;
grant select on research.operations to authenticated;
grant select on engagement.saves, engagement.follows, engagement.votes, engagement.valuations, engagement.comments,
                engagement.comment_versions, engagement.comment_likes to authenticated;

alter table research.revision_files enable row level security;
drop policy if exists revision_files_readable on research.revision_files;
create policy revision_files_readable on research.revision_files for select using (research.revision_readable(revision_id));
grant select on research.revision_files to authenticated;

grant execute on function
    rbac.request_claims(), rbac.current_credential_id(), rbac.current_actor(),
    rbac.decide(text, text), rbac.may(text, text), rbac.require(text, text),
    rbac.decide_in_org(text, text, uuid), rbac.may_in_org(text, text, uuid),
    rbac.delegate(uuid, text, text, uuid), rbac.revoke_delegation(uuid, text),
    rbac.plan_of(uuid), rbac.limit_state(uuid, text), rbac.has_quota_remaining(uuid, text),
    rbac.access_snapshot(text),
    research.readable(uuid), research.work_readable_in_full(uuid), research.revision_readable(uuid),
    research.visible_head(uuid), research.receipt(uuid, boolean),
    research.get_package(text, text), research.list_packages(boolean), research.trust(uuid),
    research.list_listed(timestamptz, int), research.search_claims(text, int, int),
    research.search_sources(text, int, int),
    research.trust_state(text, timestamptz),
    engagement.revision_signals(uuid), content.resolve_snapshot(uuid), research.endorsements_affected_by(uuid),
    research.resolve_image(uuid)
to authenticated;

grant execute on function
    rbac.grant_with_basis(uuid, text, text, text, text, uuid), rbac.revoke_grant(uuid, text),
    rbac.reserve_usage(text, bigint, text, interval), rbac.consume_usage(text, text, bigint),
    rbac.release_usage(text, text),
    research.submit_package(jsonb, text, text), research.revise_package(text, jsonb, text, text),
    research.revise_working(text, jsonb, text, text), content.capture_snapshot(uuid),
    research.expose_for_publication(text, text, text, uuid), research.withdraw_publication_exposure(text, text, text),
    research.move_publication_exposure(text, text, text, text, uuid),
    content.register_evidence(text, text, text, text, bigint, text, text),
    content.register_research_image(text, text, text, bigint, text, text),
    research.endorse(uuid, text, text, text[]), research.withdraw_endorsement(uuid, text),
    engagement.set_saved(uuid, boolean), engagement.my_saves(), engagement.set_following(uuid, boolean),
    engagement.set_useful(uuid, boolean), engagement.set_valuation(uuid, bigint, text),
    engagement.add_comment(uuid, text, text), engagement.edit_comment(uuid, text, int),
    engagement.withdraw_comment(uuid, text), engagement.moderate_comment(uuid, text),
    engagement.set_like(uuid, boolean),
    engagement.discuss(text, uuid, uuid, uuid, text, text), engagement.target_readable(uuid, uuid)
to authenticated;


-- ------------------------------------------------------------
-- 7. Application provisioning: the app_provisioner role
-- ------------------------------------------------------------
-- An application gives its people, their credentials and its own grants a
-- core identity through the four functions below and rbac.declare_application,
-- over a login role that is a member of app_provisioner (dev/image-init/
-- 00-superuser.sql creates it). They run as their owner, so the role holds no
-- table grants and needs no write policies: it can create exactly these rows
-- and read none of them. A superuser passes too, for tests and hand repair.

create or replace function rbac.is_app_provisioner() returns boolean
language sql stable set search_path = pg_catalog, public as $$
    select coalesce((select rolsuper from pg_roles where rolname = session_user), false)
        or case when exists (select 1 from pg_roles where rolname = 'app_provisioner')
                then pg_has_role(session_user, 'app_provisioner', 'member')
                else false end;
$$;

create or replace function rbac.require_app_provisioner() returns void
language plpgsql stable set search_path = pg_catalog, public as $$
begin
    if not rbac.is_app_provisioner() then
        raise insufficient_privilege using message = 'Only the application provisioner does this';
    end if;
end;
$$;

create or replace function rbac.provision_application_user(p_user uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
    perform rbac.require_app_provisioner();
    insert into rbac.users (id, email, status)
    values (p_user, p_user::text || '@users.percolate.invalid', 'active')
    -- NO CONFLICT TARGET (REM-792). The email is made from the id and has its
    -- own unique index, and `on conflict (id)` makes only the id an arbiter:
    -- two first calls for one new person both passed the id check, and the
    -- second met users_email_key as a unique violation. Measured on 0.2.22,
    -- eight concurrent calls failed in 18 of 20 batches, and the app answered
    -- 409. Either index clashing means this person is already here.
    on conflict do nothing;
end;
$$;

-- The application verified the secret; core keeps the credential so it can
-- apply its scopes and see its revocation. The hash names it as provisioned.
create or replace function rbac.provision_application_credential(p_key uuid, p_user uuid, p_label text, p_scopes text[])
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
begin
    perform rbac.require_app_provisioner();
    if not exists (select 1 from rbac.users where id = p_user) then
        raise foreign_key_violation using message = 'Provision the user before their credential';
    end if;
    insert into rbac.api_keys (id, user_id, label, key_hash, scopes)
    values (p_key, p_user, coalesce(nullif(p_label, ''), 'application credential'),
            'application:' || p_key::text, coalesce(p_scopes, '{}'))
    -- No target, as for the user above: key_hash is made from the id and is
    -- unique too (REM-792).
    on conflict do nothing;
end;
$$;

-- Only a credential an application provisioned: never a key a person made in core.
create or replace function rbac.revoke_application_credential(p_key uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
    perform rbac.require_app_provisioner();
    update rbac.api_keys set revoked_at = now()
     where id = p_key and revoked_at is null
       and key_hash in ('application:' || p_key::text, 'app-token:' || p_key::text);
end;
$$;

-- A role an application may hand out carries only application-qualified
-- capabilities (hub.*) or the three platform ones an application decides:
-- listing research, adding it to a publication (REM-252) and moderating
-- comments. Anything else -- users:admin, a
-- grants_all role -- is refused, so the provisioner cannot mint an administrator.
create or replace function rbac.grant_application_role(p_user uuid, p_role text, p_resource text, p_action text,
                                                       p_basis text, p_evidence text, p_application text, p_org uuid)
returns uuid language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid; v_org uuid := coalesce(p_org, rbac.shared_org_id());
begin
    perform rbac.require_app_provisioner();
    if coalesce(p_application, '') !~ '^[a-z][a-z0-9_-]{1,40}$' then
        raise invalid_parameter_value using message = 'A grant names its application';
    end if;
    if p_role !~ '^[a-z][a-z0-9_-]{1,60}$' then
        raise invalid_parameter_value using message = 'A role name is a lower-case word';
    end if;
    if not rbac.application_may_hold(p_resource, p_action) then
        raise insufficient_privilege using message = 'An application grants only its own capabilities, research:list, research:publish or engagement:moderate';
    end if;
    if exists (select 1 from rbac.roles where name = p_role and grants_all)
       or exists (select 1 from rbac.role_permissions where role = p_role
                   and not rbac.application_may_hold(resource, action)) then
        raise insufficient_privilege using message = 'That role carries capabilities an application cannot grant';
    end if;
    perform pg_advisory_xact_lock(hashtextextended(p_user::text || '/' || p_role || '/' || p_application || '/' || v_org::text, 0));
    insert into rbac.roles (name, description) values (p_role, 'granted by an application') on conflict do nothing;
    insert into rbac.role_permissions (role, resource, action) values (p_role, p_resource, p_action) on conflict do nothing;
    -- Provisioning is not a regrant. A revoked historical entry remains the
    -- result of this operation, including after an application restart.
    select id into v_id from rbac.grants
     where user_id = p_user and role = p_role and application in (p_application, 'percolate') and org_id = v_org
     order by created_at, id limit 1;
    if v_id is null then
        insert into rbac.grants (user_id, role, basis, evidence_ref, application, org_id)
        values (p_user, p_role, p_basis, p_evidence, p_application, v_org)
        returning id into v_id;
        insert into rbac.user_roles (user_id, role) values (p_user, p_role) on conflict do nothing;
    end if;
    return v_id;
end;
$$;

-- REVOKING WHAT AN APPLICATION GRANTED (REM-248). grant_application_role lets
-- the provisioner issue a grant, but only an operator or a person with
-- users:admin could end one, so an admission decided inside the application
-- could not be withdrawn there. This ends only a grant issued under
-- p_application, for a role carrying nothing but capabilities an application
-- may grant, and always with a reason. The grant stays, as history.
-- p_decided_by is the person whose decision it was, which the application has
-- already checked; it is recorded as revoked_by. Revoking a revoked grant
-- changes nothing and answers false.
create or replace function rbac.revoke_application_role(p_grant uuid, p_reason text, p_application text,
                                                        p_decided_by uuid default null)
returns boolean language plpgsql security definer set search_path = pg_catalog, public as $$
declare g rbac.grants;
begin
    perform rbac.require_app_provisioner();
    if coalesce(btrim(p_reason), '') = '' then
        raise invalid_parameter_value using message = 'A revocation says why';
    end if;
    select * into g from rbac.grants where id = p_grant for update;
    if not found or g.application is distinct from p_application then
        raise no_data_found using message = 'Grant not found';
    end if;
    if exists (select 1 from rbac.roles where name = g.role and grants_all)
       or exists (select 1 from rbac.role_permissions where role = g.role
                   and not rbac.application_may_hold(resource, action)) then
        raise insufficient_privilege using message = 'That grant carries capabilities an application cannot revoke';
    end if;
    if p_decided_by is not null and not exists (select 1 from rbac.users where id = p_decided_by) then
        raise invalid_parameter_value using message = 'The deciding person is not a user';
    end if;
    if g.revoked_at is not null then
        return false;
    end if;
    update rbac.grants set revoked_at = now(), revoked_by = p_decided_by, revoke_reason = btrim(p_reason)
     where id = g.id;
    if not exists (select 1 from rbac.grants where user_id = g.user_id and role = g.role and revoked_at is null) then
        delete from rbac.user_roles where user_id = g.user_id and role = g.role;
    end if;
    return true;
end;
$$;

-- Keep existing six-argument clients compatible; new clients name their scope.
create or replace function rbac.grant_application_role(p_user uuid, p_role text, p_resource text, p_action text,
                                                       p_basis text, p_evidence text default null)
returns uuid language sql security invoker set search_path = pg_catalog, public as $$
    select rbac.grant_application_role(p_user, p_role, p_resource, p_action, p_basis, p_evidence, 'percolate', null);
$$;

-- Granted only where the role exists: a from-zero install without it still
-- installs, and ALTER EXTENSION after the role is created picks these up.
do $$
begin
    if exists (select 1 from pg_roles where rolname = 'app_provisioner') then
        grant usage on schema rbac to app_provisioner;
        grant execute on function
            rbac.provision_application_user(uuid),
            rbac.provision_application_credential(uuid, uuid, text, text[]),
            rbac.revoke_application_credential(uuid),
            rbac.grant_application_role(uuid, text, text, text, text, text),
            rbac.grant_application_role(uuid, text, text, text, text, text, text, uuid),
            rbac.revoke_application_role(uuid, text, text, uuid),
            rbac.declare_application(text, text, jsonb)
        to app_provisioner;
    end if;
end $$;
