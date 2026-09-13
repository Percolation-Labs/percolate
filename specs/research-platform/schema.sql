-- ============================================================
-- The research platform in core: one access decision, plans and usage,
-- research revisions, engagement, and the trust read.
--
-- specs/research-platform/architecture.md §2-§6. Written in beta mode: lean,
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
-- Extends permission_kinds rather than building a second capability table.
-- human_only: an agent or a platform job is refused even with a grant.
-- every_person: any active person holds it without a role (reading and
-- writing their own research); roles still decide everything else.

alter table rbac.permission_kinds add column if not exists human_only boolean not null default false;
alter table rbac.permission_kinds add column if not exists every_person boolean not null default false;

insert into rbac.permission_kinds (resource, action, checked_by, human_only, every_person) values
    ('research',   'select',   'function research.get_package',          false, true),
    ('research',   'insert',   'function research.submit_package',       false, true),
    ('research',   'list',     'function research.submit_package',       false, false),
    ('research',   'endorse',  'function research.endorse',              true,  true),
    ('engagement', 'select',   'policy saves_self',                      false, true),
    ('engagement', 'insert',   'function engagement.add_comment',        true,  true),
    ('engagement', 'moderate', 'function engagement.moderate_comment',   true,  false)
on conflict (resource, action) do update
    set checked_by = excluded.checked_by,
        human_only = excluded.human_only,
        every_person = excluded.every_person;

-- The ledger behind user_roles: who granted a role, on what basis, and how it
-- ended. user_roles stays the effective set every existing policy reads;
-- grant_with_basis and revoke_grant keep the two in step.
create table if not exists rbac.grants (
    id            uuid primary key default uuidv7(),
    user_id       uuid not null references rbac.users(id) on delete cascade,
    role          text not null references rbac.roles(name),
    application   text not null default 'percolate',
    org_id        uuid not null default rbac.shared_org_id() references rbac.orgs(id),
    granted_by    uuid references rbac.users(id),
    basis         text not null check (basis in ('installation', 'operator', 'invitation', 'recommendation', 'contribution')),
    evidence_ref  text,
    created_at    timestamptz not null default now(),
    revoked_at    timestamptz,
    revoked_by    uuid references rbac.users(id),
    revoke_reason text,
    constraint grants_revocation_says_why check ((revoked_at is null) = (revoke_reason is null))
);
create index if not exists grants_active on rbac.grants (user_id, role) where revoked_at is null;

-- An application (the writing hub) declares its own qualified capabilities.
create table if not exists rbac.applications (
    name        text primary key,
    version     text not null,
    declared_at timestamptz not null default now()
);

-- Credential scopes that predate canonical capabilities keep their narrow
-- meaning: neither package scope lists research.
create table if not exists rbac.scope_aliases (
    scope    text not null,
    resource text not null,
    action   text not null,
    primary key (scope, resource, action),
    foreign key (resource, action) references rbac.permission_kinds (resource, action) on delete cascade
);
insert into rbac.scope_aliases (scope, resource, action) values
    ('packages:read-own',       'research', 'select'),
    ('packages:create-private', 'research', 'select'),
    ('packages:create-private', 'research', 'insert')
on conflict do nothing;

create or replace function rbac.request_claims() returns jsonb
language sql stable set search_path = pg_catalog, public as $$
    select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
$$;

create or replace function rbac.current_credential_id() returns uuid
language sql stable set search_path = pg_catalog, public as $$
    select case when v ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then v::uuid end
      from (select rbac.request_claims()->>'api_key_id') as t(v);
$$;

-- The trusted boundary mints the claims. A credential makes the caller an
-- agent unless the boundary says platform: nothing a caller can leave out
-- turns an agent back into a person.
create or replace function rbac.current_actor() returns text
language sql stable set search_path = pg_catalog, public as $$
    select case
        when rbac.request_claims()->>'actor' = 'platform' then 'platform'
        when rbac.request_claims()->>'actor' = 'agent' or rbac.current_credential_id() is not null then 'agent'
        else 'person'
    end;
$$;

-- THE decision. Every protected operation below asks it, and the access
-- snapshot reports it, so the two cannot disagree. Order of refusal:
-- unknown capability, anonymous, inactive, human-only, credential, grant.
create or replace function rbac.decide(p_resource text, p_action text) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
    v_user   uuid := rbac.current_user_id();
    v_key    uuid := rbac.current_credential_id();
    v_kind   rbac.permission_kinds;
    v_scopes text[];
    v_reason text;
begin
    select * into v_kind from rbac.permission_kinds where resource = p_resource and action = p_action;
    v_reason := case
        when not found then 'unknown_capability'
        when v_user is null then 'anonymous'
        when not exists (select 1 from rbac.users where id = v_user and status = 'active') then 'inactive'
        when v_kind.human_only and rbac.current_actor() <> 'person' then 'human_only'
        when rbac.request_claims() ? 'api_key_id' and v_key is null then 'credential_invalid'
        when rbac.current_actor() = 'agent' and v_key is null then 'credential_required'
    end;
    if v_reason is null and v_key is not null then
        select scopes into v_scopes from rbac.api_keys
         where id = v_key and user_id = v_user and revoked_at is null;
        if not found then
            v_reason := 'credential_revoked';
        elsif not (p_resource || ':' || p_action = any (v_scopes)
                   or exists (select 1 from rbac.scope_aliases a
                               where a.scope = any (v_scopes) and a.resource = p_resource and a.action = p_action)) then
            v_reason := 'scope_missing';
        end if;
    end if;
    if v_reason is null and not (v_kind.every_person or exists (
        select 1 from rbac.user_roles ur join rbac.role_permissions rp on rp.role = ur.role
         where ur.user_id = v_user and rp.resource = p_resource and rp.action = p_action
           and (
               -- Pre-ledger core roles keep their existing meaning. Once this
               -- role has a ledger entry, only an active, matching grant counts.
               not exists (select 1 from rbac.grants g where g.user_id = v_user and g.role = ur.role)
               or exists (
                   select 1 from rbac.grants g
                    where g.user_id = v_user and g.role = ur.role and g.revoked_at is null
                      and (g.application = 'percolate'
                           or g.application = rbac.request_claims()->>'application'
                           or (position('.' in p_resource) > 0 and g.application = split_part(p_resource, '.', 1)))
                      and (g.org_id = rbac.shared_org_id()
                           or (g.org_id::text = rbac.request_claims()->>'org_id'
                               and g.org_id in (select rbac.current_org_ids())))
               )
           )
    )) then
        v_reason := 'no_grant';
    end if;
    return jsonb_build_object('resource', p_resource, 'action', p_action,
                              'allowed', v_reason is null, 'reason', coalesce(v_reason, 'allowed'));
end;
$$;

create or replace function rbac.may(p_resource text, p_action text) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
    select (rbac.decide(p_resource, p_action)->>'allowed')::boolean;
$$;

-- Raise unless allowed; return the caller. The reason code travels as the hint.
create or replace function rbac.require(p_resource text, p_action text) returns uuid
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v jsonb := rbac.decide(p_resource, p_action);
begin
    if not (v->>'allowed')::boolean then
        raise insufficient_privilege
            using message = 'Not allowed: ' || p_resource || ':' || p_action, hint = v->>'reason';
    end if;
    return rbac.current_user_id();
end;
$$;

create or replace function rbac.grant_with_basis(
    p_user uuid, p_role text, p_basis text, p_evidence text default null,
    p_application text default 'percolate', p_org uuid default null)
returns uuid language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid; v_by uuid := rbac.current_user_id();
begin
    if not rbac.is_operator() then
        if rbac.current_actor() <> 'person' then
            raise insufficient_privilege using message = 'Only a person grants a role';
        end if;
        perform rbac.require('users', 'admin');
    end if;
    insert into rbac.grants (user_id, role, application, org_id, granted_by, basis, evidence_ref)
    values (p_user, p_role, p_application, coalesce(p_org, rbac.shared_org_id()), v_by, p_basis, p_evidence)
    returning id into v_id;
    insert into rbac.user_roles (user_id, role) values (p_user, p_role) on conflict do nothing;
    insert into rbac.auth_events (user_id, event_type, detail)
    values (p_user, 'role_granted', jsonb_build_object('role', p_role, 'by', v_by, 'grant_id', v_id, 'basis', p_basis));
    return v_id;
end;
$$;

create or replace function rbac.revoke_grant(p_grant uuid, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare g rbac.grants; v_by uuid := rbac.current_user_id();
begin
    if coalesce(p_reason, '') = '' then
        raise invalid_parameter_value using message = 'A revocation says why';
    end if;
    if not rbac.is_operator() then
        if rbac.current_actor() <> 'person' then
            raise insufficient_privilege using message = 'Only a person revokes a role';
        end if;
        perform rbac.require('users', 'admin');
    end if;
    update rbac.grants set revoked_at = now(), revoked_by = v_by, revoke_reason = p_reason
     where id = p_grant and revoked_at is null
    returning * into g;
    if not found then
        return;
    end if;
    if not exists (select 1 from rbac.grants where user_id = g.user_id and role = g.role and revoked_at is null) then
        delete from rbac.user_roles where user_id = g.user_id and role = g.role;
    end if;
end;
$$;

create or replace function rbac.declare_application(p_name text, p_version text, p_capabilities jsonb)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
declare c jsonb;
begin
    if not rbac.is_operator() then
        raise insufficient_privilege using message = 'Only an installation step declares an application';
    end if;
    if p_name !~ '^[a-z][a-z0-9_-]{1,40}$' then
        raise invalid_parameter_value using message = 'An application name is a lower-case word';
    end if;
    insert into rbac.applications (name, version) values (p_name, p_version)
    on conflict (name) do update set version = excluded.version, declared_at = now();
    for c in select value from jsonb_array_elements(coalesce(p_capabilities, '[]'::jsonb)) loop
        insert into rbac.permission_kinds (resource, action, checked_by, human_only, every_person)
        values (p_name || '.' || (c->>'resource'), c->>'action', 'application ' || p_name,
                coalesce((c->>'human_only')::boolean, false), coalesce((c->>'every_person')::boolean, false))
        on conflict (resource, action) do update
            set checked_by = excluded.checked_by,
                human_only = excluded.human_only,
                every_person = excluded.every_person;
    end loop;
end;
$$;


-- ------------------------------------------------------------
-- 2. Plans and usage (§3)
-- ------------------------------------------------------------
-- No row in plan_limits is UNSET; 'unlimited' and 'finite' are rows. A
-- required resource with no policy refuses; an optional one allows.
-- The default plan is unlimited for model tokens so a self-hosted install
-- keeps working: nobody chose a number, and this file does not choose one.

create table if not exists rbac.plans (
    name        text primary key,
    description text not null,
    version     int  not null default 1
);

create table if not exists rbac.resource_kinds (
    name        text primary key,
    description text not null,
    required    boolean not null default false
);

create table if not exists rbac.plan_limits (
    plan          text not null references rbac.plans(name) on delete cascade,
    resource_kind text not null references rbac.resource_kinds(name),
    mode          text not null check (mode in ('unlimited', 'finite')),
    amount        bigint check (amount is null or amount >= 0),
    period        interval not null default interval '1 month',
    -- true on the rows this file ships, so a dump carries only the deployment's
    -- (contract/schema.sql §4, the seeded tables).
    shipped       boolean not null default false,
    primary key (plan, resource_kind),
    constraint plan_limits_finite_has_amount check ((mode = 'finite') = (amount is not null))
);

create table if not exists rbac.plan_assignments (
    user_id     uuid primary key references rbac.users(id) on delete cascade,
    plan        text not null references rbac.plans(name),
    assigned_at timestamptz not null default now(),
    assigned_by uuid references rbac.users(id)
);

-- One budget per person, shared by every agent acting for them. A
-- reservation holds capacity; consume settles it; release returns it. The
-- operation id makes a retry charge once, and a failed transaction takes its
-- reservation with it.
create table if not exists rbac.usage_ledger (
    id            uuid primary key default uuidv7(),
    user_id       uuid not null references rbac.users(id) on delete cascade,
    resource_kind text not null references rbac.resource_kinds(name),
    operation_id  text not null,
    amount        bigint not null check (amount >= 0),
    state         text not null check (state in ('reserved', 'consumed', 'released')),
    actor         text not null check (actor in ('person', 'agent', 'platform')),
    created_at    timestamptz not null default now(),
    expires_at    timestamptz,
    unique (user_id, resource_kind, operation_id)
);

insert into rbac.plans (name, description) values
    ('default', 'Every account without an assigned plan')
on conflict (name) do nothing;
insert into rbac.resource_kinds (name, description, required) values
    ('llm_tokens', 'Model tokens a run spends through the agent runtime', true)
on conflict (name) do nothing;
insert into rbac.plan_limits (plan, resource_kind, mode, shipped) values
    ('default', 'llm_tokens', 'unlimited', true)
on conflict (plan, resource_kind) do update set shipped = true;

create or replace function rbac.plan_of(p_user uuid) returns text
language sql stable security definer set search_path = pg_catalog, public as $$
    select coalesce((select plan from rbac.plan_assignments where user_id = p_user), 'default');
$$;

create or replace function rbac.limit_state(p_user uuid, p_kind text) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare k rbac.resource_kinds; l rbac.plan_limits; v_used bigint;
begin
    if p_user is distinct from rbac.current_user_id() and not rbac.is_operator() then
        return jsonb_build_object('resource_kind', p_kind, 'status', 'unknown', 'remaining', null);
    end if;
    select * into k from rbac.resource_kinds where name = p_kind;
    if not found then
        return jsonb_build_object('resource_kind', p_kind, 'status', 'unknown', 'remaining', null);
    end if;
    select * into l from rbac.plan_limits where plan = rbac.plan_of(p_user) and resource_kind = p_kind;
    if not found then
        return jsonb_build_object('resource_kind', p_kind, 'status', 'unset', 'required', k.required, 'remaining', null,
                                  'reason', case when k.required then 'no budget is configured' else 'no limit is configured' end);
    end if;
    select coalesce(sum(amount), 0) into v_used from rbac.usage_ledger
     where user_id = p_user and resource_kind = p_kind and created_at > now() - l.period
       and (state = 'consumed' or (state = 'reserved' and expires_at > now()));
    if l.mode = 'unlimited' then
        return jsonb_build_object('resource_kind', p_kind, 'status', 'unlimited', 'used', v_used,
                                  'remaining', null, 'period', l.period::text);
    end if;
    return jsonb_build_object('resource_kind', p_kind,
        'status', case when v_used >= l.amount then 'exhausted' else 'finite' end,
        'limit', l.amount, 'used', v_used, 'remaining', greatest(l.amount - v_used, 0), 'period', l.period::text);
end;
$$;

-- The runtime's existing entry point (percolate-core repository.py). A run
-- with no person has no personal budget to charge: model spend on platform
-- jobs is a provider concern, not an account quota.
create or replace function rbac.has_quota_remaining(p_user uuid, p_kind text) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
    select case
        when p_user is null then true
        else case rbac.limit_state(p_user, p_kind)->>'status'
            when 'unlimited' then true
            when 'finite' then true
            when 'unset' then not coalesce((select required from rbac.resource_kinds where name = p_kind), true)
            else false
        end
    end;
$$;

create or replace function rbac.reserve_usage(p_kind text, p_amount bigint, p_operation_id text,
                                              p_ttl interval default interval '15 minutes')
returns jsonb language plpgsql volatile security definer set search_path = pg_catalog, public as $$
declare v_user uuid := rbac.current_user_id(); s jsonb; held rbac.usage_ledger;
begin
    if v_user is null then
        raise insufficient_privilege using message = 'Usage belongs to a signed-in person';
    end if;
    if p_amount is null or p_amount < 0 or coalesce(p_operation_id, '') = '' then
        raise invalid_parameter_value using message = 'A reservation needs an amount and an operation id';
    end if;
    perform pg_advisory_xact_lock(hashtextextended(v_user::text || '/' || p_kind, 0));
    select * into held from rbac.usage_ledger
     where user_id = v_user and resource_kind = p_kind and operation_id = p_operation_id;
    if found then
        return jsonb_build_object('reserved', held.state <> 'released', 'operation_id', p_operation_id,
                                  'state', held.state, 'retry', true);
    end if;
    s := rbac.limit_state(v_user, p_kind);
    if s->>'status' = 'unknown' or (s->>'status' = 'unset' and (s->>'required')::boolean) then
        return jsonb_build_object('reserved', false, 'reason', 'no_policy', 'limit', s);
    end if;
    if s->>'status' in ('finite', 'exhausted') and (s->>'remaining')::bigint < p_amount then
        return jsonb_build_object('reserved', false, 'reason', 'quota_exceeded', 'limit', s);
    end if;
    insert into rbac.usage_ledger (user_id, resource_kind, operation_id, amount, state, actor, expires_at)
    values (v_user, p_kind, p_operation_id, p_amount, 'reserved', rbac.current_actor(), now() + p_ttl);
    return jsonb_build_object('reserved', true, 'operation_id', p_operation_id, 'state', 'reserved',
                              'limit', rbac.limit_state(v_user, p_kind));
end;
$$;

create or replace function rbac.consume_usage(p_kind text, p_operation_id text, p_actual bigint default null)
returns jsonb language plpgsql volatile security definer set search_path = pg_catalog, public as $$
declare v_user uuid := rbac.current_user_id(); row rbac.usage_ledger;
begin
    update rbac.usage_ledger set state = 'consumed', amount = coalesce(p_actual, amount)
     where user_id = v_user and resource_kind = p_kind and operation_id = p_operation_id and state = 'reserved'
    returning * into row;
    if not found then
        select * into row from rbac.usage_ledger
         where user_id = v_user and resource_kind = p_kind and operation_id = p_operation_id;
    end if;
    return jsonb_build_object('operation_id', p_operation_id, 'state', row.state, 'amount', row.amount);
end;
$$;

create or replace function rbac.release_usage(p_kind text, p_operation_id text)
returns void language sql volatile security definer set search_path = pg_catalog, public as $$
    update rbac.usage_ledger set state = 'released'
     where user_id = rbac.current_user_id() and resource_kind = p_kind
       and operation_id = p_operation_id and state = 'reserved';
$$;

-- Explanatory, not reusable: every mutation rechecks in its own transaction.
create or replace function rbac.access_snapshot(p_application text default null) returns jsonb
language sql stable security definer set search_path = pg_catalog, public as $$
    select jsonb_build_object(
        'version', 1,
        'principal', rbac.current_user_id(),
        'actor', rbac.current_actor(),
        'credential_id', rbac.current_credential_id(),
        'roles', coalesce((select jsonb_agg(role order by role) from rbac.user_roles
                            where user_id = rbac.current_user_id()), '[]'::jsonb),
        'capabilities', coalesce((
            select jsonb_agg(rbac.decide(k.resource, k.action) || jsonb_build_object('human_only', k.human_only)
                             order by k.resource, k.action)
              from rbac.permission_kinds k
             where k.resource in ('research', 'engagement')
                or (p_application is not null and k.resource like p_application || '.%')), '[]'::jsonb),
        'plan', case when rbac.current_user_id() is not null then rbac.plan_of(rbac.current_user_id()) end,
        'limits', coalesce((select jsonb_agg(rbac.limit_state(rbac.current_user_id(), r.name) order by r.name)
                              from rbac.resource_kinds r
                             where rbac.current_user_id() is not null), '[]'::jsonb));
$$;


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

create table if not exists research.heads (
    work_id     uuid primary key references research.works(id) on delete cascade,
    revision_id uuid not null references research.revisions(id),
    updated_at  timestamptz not null default now()
);

create table if not exists research.operations (
    owner_id    uuid not null references rbac.users(id) on delete cascade,
    key         text not null,
    body_hash   text not null,
    work_id     uuid not null references research.works(id) on delete cascade,
    revision_id uuid not null references research.revisions(id),
    created_at  timestamptz not null default now(),
    primary key (owner_id, key)
);

create table if not exists research.claims (
    id          uuid primary key,
    revision_id uuid not null references research.revisions(id) on delete cascade,
    claim_key   text not null,
    kind        text not null,
    text        text not null,
    locator     text not null default '',
    unique (revision_id, claim_key)
);

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

create table if not exists research.citations (
    revision_id uuid not null,
    claim_key   text not null,
    source_key  text not null,
    primary key (revision_id, claim_key, source_key),
    foreign key (revision_id, claim_key) references research.claims (revision_id, claim_key) on delete cascade,
    foreign key (revision_id, source_key) references research.sources (revision_id, source_key) on delete cascade
);

create table if not exists research.argument_edges (
    revision_id      uuid not null,
    source_claim_key text not null,
    relation         text not null check (relation in ('supports', 'challenges', 'motivates', 'qualifies', 'limits', 'compares with')),
    target_claim_key text not null,
    primary key (revision_id, source_claim_key, relation, target_claim_key),
    foreign key (revision_id, source_claim_key) references research.claims (revision_id, claim_key) on delete cascade,
    foreign key (revision_id, target_claim_key) references research.claims (revision_id, claim_key) on delete cascade
);

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
create unique index if not exists endorsements_one_active
    on research.endorsements (revision_id, endorser_id) where withdrawn_at is null;

create or replace function research.readable(p_work uuid) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
    select coalesce((select rbac.may_read(owner_id, org_id, visibility)
                            and (rbac.current_user_id() is null or rbac.may('research', 'select'))
                       from research.works where id = p_work), false);
$$;

create or replace function research.revision_readable(p_revision uuid) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
    select coalesce((select research.readable(work_id) from research.revisions where id = p_revision), false);
$$;

create or replace function research.receipt(p_revision uuid, p_created boolean) returns jsonb
language sql stable security definer set search_path = pg_catalog, public as $$
    select jsonb_build_object(
        'package_id', w.public_id, 'work_id', w.id, 'revision_id', r.id, 'revision', r.label,
        'content_hash', r.content_hash, 'hash_format', 'pg-jsonb-sha256',
        'visibility', case when w.visibility = 'public' then 'listed' else 'private' end,
        'created', p_created, 'created_at', r.created_at)
      from research.revisions r join research.works w on w.id = r.work_id
     where r.id = p_revision
       and research.readable(w.id);
$$;

-- Claims, sources, citations and edges, projected from the revision's own
-- document. Ids are derived from the revision and the local key, so a replay
-- of the same document yields the same ids.
create or replace function research.project(p_revision uuid, p_document jsonb) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare c jsonb; s jsonb; e jsonb; src text;
begin
    for s in select value from jsonb_array_elements(coalesce(p_document->'sources', '[]'::jsonb)) loop
        if coalesce(s->>'id', '') = '' then
            raise check_violation using message = 'Every source needs an id';
        end if;
        insert into research.sources (id, revision_id, source_key, title, url, origin, status, locator)
        values (percolate.uuidv5(p_revision, 'source:' || (s->>'id')), p_revision, s->>'id',
                coalesce(s->>'title', ''), coalesce(s->>'url', ''), coalesce(s->>'origin', ''),
                coalesce(s->>'status', ''), coalesce(s->>'locator', ''));
    end loop;
    for c in select value from jsonb_array_elements(coalesce(p_document->'claims', '[]'::jsonb)) loop
        if coalesce(c->>'id', '') = '' then
            raise check_violation using message = 'Every claim needs an id';
        end if;
        insert into research.claims (id, revision_id, claim_key, kind, text, locator)
        values (percolate.uuidv5(p_revision, 'claim:' || (c->>'id')), p_revision, c->>'id',
                coalesce(c->>'kind', ''), coalesce(c->>'text', ''), coalesce(c->>'locator', ''));
        for src in select value from jsonb_array_elements_text(coalesce(c->'source_ids', '[]'::jsonb)) loop
            insert into research.citations (revision_id, claim_key, source_key) values (p_revision, c->>'id', src);
        end loop;
    end loop;
    for e in select value from jsonb_array_elements(coalesce(p_document->'edges', '[]'::jsonb)) loop
        insert into research.argument_edges (revision_id, source_claim_key, relation, target_claim_key)
        values (p_revision, e->>'source', e->>'relation', e->>'target');
    end loop;
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
                                    actor_id, actor_kind, credential_id)
    values (v_work, 1, 'draft-1', '0.1', p_document, v_hash, v_user, rbac.current_actor(), rbac.current_credential_id())
    returning id into v_rev;
    perform research.project(v_rev, p_document);
    insert into research.heads (work_id, revision_id) values (v_work, v_rev);
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
create or replace function research.revise_package(p_public_id text, p_document jsonb, p_expected_revision text)
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
        return research.receipt(h.id, false);
    end if;
    insert into research.revisions (work_id, number, label, schema_version, document, content_hash,
                                    predecessor_id, actor_id, actor_kind, credential_id)
    values (w.id, h.number + 1, 'draft-' || (h.number + 1), '0.1', p_document, v_hash,
            h.id, v_user, rbac.current_actor(), rbac.current_credential_id())
    returning id into v_rev;
    perform research.project(v_rev, p_document);
    update research.heads set revision_id = v_rev, updated_at = now() where work_id = w.id;
    update research.works
       set visibility = case when v_listed then 'public' else 'private' end,
           listed_at = case when v_listed then coalesce(listed_at, now()) end
     where id = w.id;
    return research.receipt(v_rev, true);
end;
$$;

create or replace function research.get_package(p_public_id text, p_revision text default null) returns jsonb
language sql stable security definer set search_path = pg_catalog, public as $$
    select r.document || jsonb_build_object(
               'id', w.public_id, 'revision', r.label, 'owner_id', w.owner_id,
               'visibility', case when w.visibility = 'public' then 'listed' else 'private' end,
               'is_head', hd.revision_id = r.id, 'receipt', research.receipt(r.id, false))
      from research.works w
      join research.heads hd on hd.work_id = w.id
      join research.revisions r on r.work_id = w.id
                               and (case when p_revision is null then r.id = hd.revision_id else r.label = p_revision end)
     where w.public_id = p_public_id
       and research.readable(w.id);
$$;

create or replace function research.list_packages(p_owned_only boolean default false) returns setof jsonb
language sql stable security definer set search_path = pg_catalog, public as $$
    select jsonb_build_object(
               'id', w.public_id, 'title', r.document->>'title', 'summary', r.document->>'summary',
               'revision', r.label, 'visibility', case when w.visibility = 'public' then 'listed' else 'private' end,
               'owned', w.owner_id = rbac.current_user_id(), 'updated_at', hd.updated_at)
      from research.works w
      join research.heads hd on hd.work_id = w.id
      join research.revisions r on r.id = hd.revision_id
     where research.readable(w.id)
       and (not p_owned_only or w.owner_id = rbac.current_user_id())
     order by hd.updated_at desc, w.public_id;
$$;

create or replace function research.endorse(p_revision uuid, p_scope text, p_checked text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_user uuid := rbac.require('research', 'endorse'); v_id uuid;
begin
    if not research.revision_readable(p_revision) then
        raise no_data_found using message = 'Revision not found';
    end if;
    insert into research.endorsements (revision_id, endorser_id, scope, checked)
    values (p_revision, v_user, p_scope, p_checked)
    returning id into v_id;
    return v_id;
end;
$$;

create or replace function research.withdraw_endorsement(p_endorsement uuid, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
    perform rbac.require('research', 'endorse');
    update research.endorsements set withdrawn_at = now(), withdraw_reason = p_reason
     where id = p_endorsement and endorser_id = rbac.current_user_id() and withdrawn_at is null;
    if not found then
        raise no_data_found using message = 'Active endorsement not found';
    end if;
end;
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

create table if not exists engagement.follows (
    user_id    uuid not null references rbac.users(id) on delete cascade,
    -- The org being followed, not a scope column: named apart from org_id so
    -- the shared-tier default (identity/spec.md §4) is not implied.
    target_org_id uuid not null references rbac.orgs(id) on delete cascade,
    created_at    timestamptz not null default now(),
    primary key (user_id, target_org_id)
);

create table if not exists engagement.votes (
    id           uuid primary key default uuidv7(),
    user_id      uuid not null references rbac.users(id) on delete cascade,
    revision_id  uuid not null references research.revisions(id) on delete cascade,
    created_at   timestamptz not null default now(),
    withdrawn_at timestamptz
);
create unique index if not exists votes_one_active on engagement.votes (user_id, revision_id) where withdrawn_at is null;

create table if not exists engagement.valuations (
    id           uuid primary key default uuidv7(),
    user_id      uuid not null references rbac.users(id) on delete cascade,
    revision_id  uuid not null references research.revisions(id) on delete cascade,
    amount_minor bigint not null check (amount_minor >= 0),
    currency     text not null check (currency ~ '^[A-Z]{3}$'),
    created_at   timestamptz not null default now()
);

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

create table if not exists engagement.comment_versions (
    comment_id uuid not null references engagement.comments(id) on delete cascade,
    version    int  not null,
    body       text not null,
    created_at timestamptz not null default now(),
    primary key (comment_id, version)
);

create table if not exists engagement.comment_likes (
    id           uuid primary key default uuidv7(),
    comment_id   uuid not null references engagement.comments(id) on delete cascade,
    user_id      uuid not null references rbac.users(id) on delete cascade,
    created_at   timestamptz not null default now(),
    withdrawn_at timestamptz
);
create unique index if not exists comment_likes_one_active on engagement.comment_likes (comment_id, user_id) where withdrawn_at is null;

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
    if not found or not research.revision_readable(c.revision_id) then
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
declare r research.revisions; w research.works; v_head uuid;
begin
    select * into r from research.revisions where id = p_revision;
    if not found or not research.revision_readable(p_revision) then
        return null;
    end if;
    select * into w from research.works where id = r.work_id;
    select revision_id into v_head from research.heads where work_id = w.id;
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
                       'capture', jsonb_build_object('status', 'unknown', 'reason', 'no capture is linked to this source'))
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
                       'active', e.withdrawn_at is null, 'withdrawn_at', e.withdrawn_at, 'created_at', e.created_at)
                   order by e.created_at)
              from research.endorsements e where e.revision_id = r.id), '[]'::jsonb),
        'corrections', jsonb_build_object(
            'supersedes', (select label from research.revisions where id = r.predecessor_id),
            'superseded_by', coalesce((select jsonb_agg(label order by number) from research.revisions
                                        where work_id = w.id and number > r.number), '[]'::jsonb)),
        'engagement', engagement.revision_signals(r.id),
        'interpretations', jsonb_build_object('status', 'unavailable', 'reason', 'no analysis provider is configured'));
end;
$$;


-- ------------------------------------------------------------
-- 6. Row security and grants
-- ------------------------------------------------------------

alter table rbac.grants enable row level security;
drop policy if exists grants_self_or_admin on rbac.grants;
create policy grants_self_or_admin on rbac.grants for select
    using (user_id = rbac.current_user_id() or rbac.has_permission(rbac.current_user_id(), 'users', 'admin'));

alter table rbac.plan_assignments enable row level security;
drop policy if exists plan_assignments_self on rbac.plan_assignments;
create policy plan_assignments_self on rbac.plan_assignments for select using (user_id = rbac.current_user_id());

alter table rbac.usage_ledger enable row level security;
drop policy if exists usage_ledger_self on rbac.usage_ledger;
create policy usage_ledger_self on rbac.usage_ledger for select using (user_id = rbac.current_user_id());

-- The generated scope policy: rbac/02 requires it of any table carrying the
-- scope columns, so the tenancy rule has one home.
drop policy if exists works_readable on research.works;
select rbac.add_scope_policy('research.works');
-- Visibility is necessary but cannot override a revoked key or inactive owner.
-- A restrictive policy intersects with the generated tenancy policy above.
drop policy if exists works_access on research.works;
create policy works_access on research.works as restrictive for select
    using (rbac.current_user_id() is null or rbac.may('research', 'select'));
-- The same guard rbac.add_scope_columns() attaches: 'org' visibility needs a
-- real org, whichever definer writes the row (rbac/02).
create or replace trigger trg_works_visibility before insert or update on research.works
    for each row execute function rbac.enforce_visibility();

alter table research.revisions enable row level security;
drop policy if exists revisions_readable on research.revisions;
create policy revisions_readable on research.revisions for select using (research.readable(work_id));

alter table research.heads enable row level security;
drop policy if exists heads_readable on research.heads;
create policy heads_readable on research.heads for select using (research.readable(work_id));

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
    using (research.revision_readable(revision_id) and (withdrawn_at is null or author_id = rbac.current_user_id()));

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
grant select on rbac.grants, rbac.applications, rbac.scope_aliases, rbac.plans, rbac.resource_kinds,
                rbac.plan_limits, rbac.plan_assignments, rbac.usage_ledger to authenticated;
grant select on research.works, research.revisions, research.heads, research.claims, research.sources,
                research.citations, research.argument_edges, research.endorsements to authenticated;
grant select on research.operations to authenticated;
grant select on engagement.saves, engagement.follows, engagement.votes, engagement.valuations, engagement.comments,
                engagement.comment_versions, engagement.comment_likes to authenticated;

grant execute on function
    rbac.request_claims(), rbac.current_credential_id(), rbac.current_actor(),
    rbac.decide(text, text), rbac.may(text, text), rbac.require(text, text),
    rbac.plan_of(uuid), rbac.limit_state(uuid, text), rbac.has_quota_remaining(uuid, text),
    rbac.access_snapshot(text),
    research.readable(uuid), research.revision_readable(uuid), research.receipt(uuid, boolean),
    research.get_package(text, text), research.list_packages(boolean), research.trust(uuid),
    engagement.revision_signals(uuid)
to authenticated;

grant execute on function
    rbac.grant_with_basis(uuid, text, text, text, text, uuid), rbac.revoke_grant(uuid, text),
    rbac.reserve_usage(text, bigint, text, interval), rbac.consume_usage(text, text, bigint),
    rbac.release_usage(text, text),
    research.submit_package(jsonb, text, text), research.revise_package(text, jsonb, text),
    research.endorse(uuid, text, text), research.withdraw_endorsement(uuid, text),
    engagement.set_saved(uuid, boolean), engagement.set_following(uuid, boolean),
    engagement.set_useful(uuid, boolean), engagement.set_valuation(uuid, bigint, text),
    engagement.add_comment(uuid, text, text), engagement.edit_comment(uuid, text, int),
    engagement.withdraw_comment(uuid, text), engagement.moderate_comment(uuid, text),
    engagement.set_like(uuid, boolean)
to authenticated;
