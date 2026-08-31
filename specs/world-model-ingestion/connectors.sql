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

    -- observed, written back by the runner
    last_run_at    timestamptz,
    last_status    text,
    last_records   int,
    last_layout    text,
    last_error     text,
    gotcha         text,

    enabled     boolean not null default true,
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
    new.updated_at := now();
    return new;
end;
$$ language plpgsql;

drop trigger if exists trg_connectors_validate on content.connectors;
create trigger trg_connectors_validate before insert or update on content.connectors
    for each row execute function content.connectors_validate();

-- What the runner claims. Ordinary SQL, exposed as an RPC so a worker with no
-- table grant can call it.
create or replace function content.due_connectors(p_limit int default 50)
returns setof content.connectors
language sql stable security definer set search_path = content, pg_catalog as $$
    select * from content.connectors
    where enabled order by coalesce(last_run_at, 'epoch') asc limit p_limit;
$$;

create or replace function content.report_connector_run(
    p_id text, p_status text, p_records int default null,
    p_layout text default null, p_error text default null
) returns void
language sql security definer set search_path = content, pg_catalog as $$
    update content.connectors
    set last_run_at = now(), last_status = p_status, last_records = p_records,
        last_layout = p_layout, last_error = p_error
    where id = p_id;
$$;

-- A readable operational view -- what PostgREST callers actually want.
create or replace view content.v_connectors as
select id, category, url,
       auth->>'type'   as auth_type,
       paging->>'type' as paging_type,
       max_pages, enabled,
       last_run_at, last_status, last_records, last_layout, gotcha
from content.connectors;

grant usage on schema content to authenticated, web_anon;
grant select, insert, update, delete on content.connectors to authenticated;
grant select on content.v_connectors to authenticated, web_anon;
grant select on content.connectors to web_anon;
grant execute on function content.due_connectors(int) to authenticated, web_anon;
grant execute on function content.report_connector_run(text,text,int,text,text) to authenticated;
