-- ============================================================================
-- content.connectors -- a source is a row, registrable over PostgREST.
--
-- Four blocks, matching sources.md §16.1: connect, auth, paging, expect. The
-- runner reads rows; nothing about adding a source touches code.
-- ============================================================================
create table if not exists content.connectors (
    id          text primary key
                    check (id ~ '^[a-z0-9][a-z0-9_]{1,62}$'),
    category    text not null default 'uncategorised',

    -- CONNECT
    url         text not null check (url ~ '^https?://'),
    headers     jsonb not null default '{}'::jsonb,

    -- AUTH -- a NAME and a SHAPE. Never material (§15.1).
    auth        jsonb not null default '{"type":"none"}'::jsonb,

    -- PAGING -- the closed taxonomy (§4.1)
    paging      jsonb not null default '{"type":"none"}'::jsonb,
    max_pages   int  not null default 1 check (max_pages between 1 and 1000),

    -- EXPECT -- HTTP 200 is not success (§16.4)
    expect      jsonb not null default '{}'::jsonb,

    -- ------------------------------------------------------------------
    -- DECLARED operational limits (§19). Rate and quota are different
    -- things: rate paces requests, quota is a budget over a period. OpenDota
    -- advertises both in one response (per-minute AND per-day), which is the
    -- clearest possible argument against collapsing them into one number.
    -- ------------------------------------------------------------------
    rate_limit     jsonb not null default '{}'::jsonb,   -- {requests, per_seconds}
    quota          jsonb not null default '{}'::jsonb,   -- {calls, per, cost_per_call}
    -- Credentials the source needs, BY NAME. Present so a source can be
    -- registered before its credential exists and report "needs X" rather
    -- than returning an unexplained 401 (10 of 302 did exactly that).
    credentials    text[] not null default '{}',

    -- ------------------------------------------------------------------
    -- VALUATION (percolate-source-catalogue §17). Stored as scoring
    -- dimensions rather than as a decision, so a change of segment is a
    -- re-score rather than a re-argument. Each 0-5.
    --
    -- `clock_field` splits §17's C dimension in two, and the split came from
    -- checking: The Gazette scores C=5 but its feed exposes only `published`
    -- and `updated` -- the forward date is in notice prose. CISA KEV hands
    -- you `dueDate` as a typed field across 1,687 rows. Both are "has a
    -- clock"; only one is cheap.
    -- ------------------------------------------------------------------
    tier           text check (tier in ('A','B','C')),
    score_clock    int check (score_clock between 0 and 5),
    clock_field    text,          -- path to the forward date, null = in prose
    score_exclusivity int check (score_exclusivity between 0 and 5),
    score_resolvability int check (score_resolvability between 0 and 5),
    score_licence  int check (score_licence between 0 and 5),
    score_beat     int check (score_beat between 0 and 5),
    noise_tax      int check (noise_tax between 0 and 5),
    licence        text,

    -- ------------------------------------------------------------------
    -- OBSERVED. Written only by the runner, never by a registrant.
    -- ------------------------------------------------------------------
    last_run_at    timestamptz,
    last_status    text,
    last_records   int,
    last_layout    text,
    last_error     text,
    last_http      int,
    -- Parsed from whatever convention the source used, if any. Only 9% of
    -- sources advertise limits at all, and they do it four different ways
    -- with three reset formats -- so this is evidence, not configuration.
    observed_rate  jsonb,
    consecutive_failures int not null default 0,
    gotcha         text,

    -- ------------------------------------------------------------------
    -- LIFECYCLE. Two columns, deliberately, and NOT one status enum.
    --
    --   enabled -- human intent.    Only a person writes it.
    --   health  -- observed state.  Only the runner writes it.
    --
    -- Collapsing them loses the difference between "we turned this off" and
    -- "it broke", and the cost of that is re-enabling a source somebody
    -- disabled on purpose. Same desired/observed split as workflow.pools.
    -- ------------------------------------------------------------------
    enabled     boolean not null default true,
    health      text not null default 'unknown'
                    check (health in ('unknown','ok','degraded','needs_credential','blocked','gone')),
    health_since timestamptz,
    -- NOT NULL and defaulted to rbac.shared_org_id() the day this file ships
    -- (identity/spec.md §4 and its check 5, which scans the live catalogue).
    -- Left bare while the file is held out of ORDER: it takes neither
    -- rbac.add_scope_columns() nor rbac.adopt_shared_org(), so a hand-load
    -- into a live database would fail that check and name this table.
    org_id      uuid,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

create index if not exists idx_connectors_enabled on content.connectors (enabled) where enabled;
create index if not exists idx_connectors_category on content.connectors (category);

-- The closed sets are enforced, not documented. A typo in an auth type is a
-- rejected INSERT rather than a worker crash at 03:00.
create or replace function content.connectors_validate() returns trigger as $$
begin
    if not (new.auth->>'type' in ('none','user_agent','header','bearer','query_param','basic','oauth2_cc','signed')) then
        raise exception 'unknown auth type %', new.auth->>'type' using errcode='check_violation';
    end if;
    if not (new.paging->>'type' in ('none','link_header','next_url','page_token','offset','page','high_water','sequence','etag')) then
        raise exception 'unknown paging type %', new.paging->>'type' using errcode='check_violation';
    end if;
    -- A credential is referenced by NAME. A row containing what looks like
    -- material is refused: the database never holds a secret (§15.3).
    if new.auth ? 'value' or new.auth ? 'secret' or new.auth ? 'token' then
        raise exception 'auth may reference a credential by name, never carry its value'
            using errcode='check_violation';
    end if;
    -- A credential named in `auth` must also be declared in `credentials`, so
    -- "what does this deployment need?" is one query rather than a jsonb scan.
    if new.auth ? 'credential_ref'
       and not (new.auth->>'credential_ref' = any (new.credentials)) then
        new.credentials := new.credentials || (new.auth->>'credential_ref');
    end if;
    new.updated_at := now();
    return new;
end;
$$ language plpgsql;

drop trigger if exists trg_connectors_validate on content.connectors;
create or replace trigger trg_connectors_validate before insert or update on content.connectors
    for each row execute function content.connectors_validate();

-- What the runner claims. Ordinary SQL, exposed as an RPC so a worker with no
-- table grant can call it.
-- What the runner claims. `gone` and `needs_credential` are excluded: both
-- need a human, and re-polling them forever turns a fixable problem into
-- background noise that nobody reads.
create or replace function content.due_connectors(p_limit int default 50)
returns setof content.connectors
language sql stable security definer set search_path = content, pg_catalog as $$
    select * from content.connectors
    where enabled
      and health not in ('gone','needs_credential')
      and (health <> 'degraded'
           or health_since < now() - (interval '1 minute' * least(power(2, consecutive_failures)::int, 240)))
    order by coalesce(last_run_at, 'epoch') asc
    limit p_limit;
$$;

-- Classify an outcome into a health state. The transitions matter more than
-- the labels, and two of them were chosen from real failure data (§18.2):
--
--   * ONE 404 is not `gone`. A bad parameter looks identical to a retired
--     endpoint, so 404 needs repetition before it earns a terminal state.
--     410 does not -- it means gone, explicitly, and is believed immediately.
--   * 401/403 goes straight to `needs_credential` with no retry, because it
--     will never fix itself and retrying is how you get rate-limited too.
create or replace function content.classify_health(p_http int, p_error text, p_fails int)
returns text language sql immutable as $$
    select case
        when p_http between 200 and 299 and p_error is null then 'ok'
        when p_error like '%bot-challenge%'                 then 'blocked'
        when p_http in (401, 403)                           then 'needs_credential'
        when p_http = 410                                   then 'gone'
        when p_http = 404 and p_fails >= 2                  then 'gone'
        when p_error like '%NXDOMAIN%' and p_fails >= 2     then 'gone'
        when p_http is null or p_http >= 500 or p_http = 429 then 'degraded'
        else 'degraded'
    end;
$$;

create or replace function content.report_connector_run(
    p_id text, p_status text, p_records int default null,
    p_layout text default null, p_error text default null,
    p_http int default null, p_observed_rate jsonb default null
) returns void
language plpgsql security definer set search_path = content, pg_catalog as $$
declare v_fails int; v_health text; v_prev text;
begin
    select consecutive_failures, health into v_fails, v_prev
      from content.connectors where id = p_id;
    v_fails := case when p_status = 'ok' then 0 else coalesce(v_fails,0) + 1 end;
    v_health := content.classify_health(p_http, p_error, v_fails);
    update content.connectors
    set last_run_at = now(), last_status = p_status, last_records = p_records,
        last_layout = p_layout, last_error = p_error, last_http = p_http,
        observed_rate = coalesce(p_observed_rate, observed_rate),
        consecutive_failures = v_fails,
        health = v_health,
        -- health_since only moves when health CHANGES, so it answers "how long
        -- has this been broken" rather than "when did we last look".
        health_since = case when v_health is distinct from v_prev then now() else health_since end
    where id = p_id;
end;
$$;

-- A readable operational view -- what PostgREST callers actually want.
create or replace view content.v_connectors as
select id, category, url,
       auth->>'type'   as auth_type,
       paging->>'type' as paging_type,
       credentials, rate_limit, quota,
       tier, licence, clock_field,
       coalesce(score_clock,0)+coalesce(score_exclusivity,0)+coalesce(score_resolvability,0)
         +coalesce(score_licence,0)+coalesce(score_beat,0) as score,
       noise_tax,
       max_pages, enabled, health, health_since, consecutive_failures,
       last_run_at, last_status, last_http, last_records, last_layout,
       observed_rate, gotcha
from content.connectors;

-- What needs a human, and why. The operational surface that matters: a source
-- that is `gone` or `needs_credential` is not going to recover on its own, and
-- without this it is invisible among sources that are merely between polls.
create or replace view content.v_connectors_attention as
select id, category, health, consecutive_failures,
       now() - health_since as broken_for,
       last_http, last_error,
       case health
         when 'gone'             then 'endpoint retired or moved -- update url or disable'
         when 'needs_credential' then 'declare and supply: ' || array_to_string(credentials, ', ')
         when 'blocked'          then 'bot challenge -- needs a different access route'
         when 'degraded'         then 'transient; backing off'
       end as action
from content.connectors
where enabled and health in ('gone','needs_credential','blocked','degraded')
order by (health in ('gone','needs_credential','blocked')) desc, consecutive_failures desc;

-- What this deployment needs before it can run everything registered.
-- Build order: score first, noise tax as the tie-break, per §19.1's
-- "priority is not the score column, it's score + noise tax".
create or replace view content.v_build_order as
select id, category, tier,
       coalesce(score_clock,0)+coalesce(score_exclusivity,0)+coalesce(score_resolvability,0)
         +coalesce(score_licence,0)+coalesce(score_beat,0) as score,
       noise_tax,
       (clock_field is not null) as clock_is_a_field,
       health, licence
from content.connectors
where enabled and tier is not null
order by score desc, noise_tax asc;

create or replace view content.v_required_credentials as
select unnest(credentials) as credential_ref,
       count(*) as sources,
       array_agg(id order by id) as used_by
from content.connectors where enabled group by 1 order by 2 desc;

grant usage on schema content to authenticated, web_anon;
grant select, insert, update, delete on content.connectors to authenticated;
grant select on content.v_connectors, content.v_connectors_attention,
                content.v_required_credentials, content.v_build_order
             to authenticated, web_anon;
grant select on content.connectors to web_anon;
grant execute on function content.due_connectors(int) to authenticated, web_anon;
grant execute on function content.report_connector_run(text,text,int,text,text,int,jsonb) to authenticated;
grant execute on function content.classify_health(int,text,int) to authenticated, web_anon;
