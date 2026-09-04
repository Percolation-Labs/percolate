-- ============================================================
-- Development convenience helpers.
--
-- NOT PART OF A PRODUCTION DEPLOY. This file is deliberately excluded from
-- the normal load order (roles -> workflow -> rbac -> integrations -> aiq);
-- a deployment that applies it has made a choice, not inherited one.
--
-- WHAT THESE DO AND DO NOT DO -- the distinction is the whole safety argument:
--
--   They set an IDENTITY. They do not disable RLS.
--
-- After calling dev_assume() you see exactly what that identity is entitled to
-- see -- no more. So the worst case if this ever escaped into an environment
-- it shouldn't be in is "a caller can claim to be someone else", which is
-- serious but is precisely what possession of the JWT signing secret already
-- grants in any environment. It is NOT a way to read across tenants, and it is
-- NOT a permissive RLS policy. A helper that disabled RLS "just for testing"
-- would be a different and much worse thing, and is deliberately absent:
-- testing against relaxed rules tells you nothing about the rules you ship.
--
-- Two independent guards, because one is a single edit away from being gone:
--   1. This file is not in the production load order.
--   2. Every function here refuses to run unless `app.dev_mode` is 'on', which
--      must be set deliberately at the database or role level. Loading the
--      file is not enough to make it work.
-- ============================================================

-- Enable with:
--   alter database <db> set app.dev_mode = 'on';
-- and disable by resetting it. Deliberately NOT a table flag: a GUC set at the
-- database/role level is visible in \drds and pg_settings, so "is dev mode on
-- here?" is answerable by inspection rather than by remembering.
create or replace function aiq.assert_dev_mode() returns void as $$
begin
    if coalesce(current_setting('app.dev_mode', true), 'off') <> 'on' then
        raise exception
            'dev helpers are disabled: app.dev_mode is not ''on''. '
            'These exist for local testing only -- enable with '
            '"alter database <db> set app.dev_mode = ''on''" if that is really '
            'what you want.';
    end if;
end;
$$ language plpgsql stable;

-- Assume an identity for the rest of the SESSION (not just the transaction),
-- which is the actual convenience: set it once in a pgAdmin tab and every
-- subsequent query is scoped, with no BEGIN/COMMIT wrapper.
--
-- set_config's third argument is `false` = session-scoped. The production path
-- uses `true` (transaction-local) via PostgREST, because a pooled connection
-- that kept one request's claims into the next request's transaction is
-- exactly the bug rbac.current_user_id() was hardened against. That hazard is
-- real here too -- which is why this is a dev-only file, and why the session
-- scope is stated rather than assumed.
create or replace function aiq.dev_assume(
    p_sub uuid,
    p_orgs uuid[] default '{}'::uuid[]
) returns text as $$
declare v_claims jsonb;
begin
    perform aiq.assert_dev_mode();
    v_claims := jsonb_build_object('sub', p_sub, 'role', 'authenticated');
    if array_length(p_orgs, 1) is not null then
        v_claims := v_claims || jsonb_build_object('orgs', to_jsonb(p_orgs));
    end if;
    perform set_config('request.jwt.claims', v_claims::text, false);
    return v_claims::text;
end;
$$ language plpgsql volatile;

-- Convenience for the most common dev case: "be somebody in this org".
--
-- IT NOW MAKES THE USER AND THE MEMBERSHIP ROW, and the comment it replaces is
-- the reason it had to. That comment said: "generates a throwaway subject
-- rather than requiring a real users row, since most query-layer testing cares
-- about ORG scoping, not which user." That was true while `orgs` was an array
-- on the token and the token was the membership. It is now false in the way
-- that matters: rbac.current_org_ids() intersects the claim with
-- rbac.org_members, so a throwaway subject belongs to nothing, and this helper
-- would hand back a token that reads exactly what an anonymous caller reads --
-- silently, and while appearing to be scoped to the org you asked for.
--
-- Making the rows rather than requiring them is the point. Fifteen fixtures and
-- test files across this repository set an `orgs` claim with no `sub` at all,
-- because that was sufficient for years; every one of them had to be corrected
-- by hand. A helper whose whole job is "be somebody in this org" is where that
-- correctness belongs, so the sixteenth fixture cannot get it wrong.
--
-- Deterministic in the org, not random: calling it twice for one org gives the
-- same identity, so a fixture that assumes an org, writes a row, and assumes it
-- again still owns what it wrote. A fresh uuid each time made that fail in a
-- way that looks like an RLS bug.
--
-- dev-mode guarded like everything else here, and it INSERTS -- which is why it
-- is in this file and not in rbac. A production helper that creates users on
-- demand is a different and much worse thing.
create or replace function aiq.dev_assume_org(p_org uuid)
returns text as $$
declare v_sub uuid;
begin
    perform aiq.assert_dev_mode();

    -- uuid v5-style determinism without the extension: hash the org, take the
    -- first 32 hex digits. Stable per org, and visibly synthetic in a table.
    v_sub := (substr(md5('dev_assume_org:' || p_org::text), 1, 32))::uuid;

    insert into rbac.orgs (id, slug, name)
    values (p_org, 'dev-' || left(p_org::text, 8), 'dev org ' || left(p_org::text, 8))
    on conflict (id) do nothing;
    insert into rbac.users (id, email, status)
    values (v_sub, 'dev-' || left(v_sub::text, 8) || '@example.invalid', 'active')
    on conflict (id) do nothing;
    insert into rbac.org_members (org_id, user_id)
    values (p_org, v_sub)
    on conflict (org_id, user_id) do nothing;

    return aiq.dev_assume(v_sub, array[p_org]);
end;
$$ language plpgsql volatile;

-- Drop back to anonymous, to check what an unauthenticated caller sees --
-- the case most easily forgotten, and the one where a missing policy shows up.
create or replace function aiq.dev_anon() returns text as $$
begin
    perform aiq.assert_dev_mode();
    perform set_config('request.jwt.claims', '', false);
    return 'anonymous';
end;
$$ language plpgsql volatile;

-- Show the identity currently in effect. Worth having because the commonest
-- confusion in a SQL client is not "the query is wrong" but "I am not who I
-- think I am" -- an empty result from a superuser session and an empty result
-- from a wrong-org session look identical.
create or replace function aiq.whoami()
returns table(db_role text, is_superuser boolean, rls_applies boolean,
              user_id uuid, orgs uuid[], claims text) as $$
    select current_user::text,
           (select rolsuper from pg_roles where rolname = current_user),
           -- superusers bypass RLS unconditionally, so "am I actually being
           -- filtered?" is a different question from "is RLS enabled?"
           not (select rolsuper from pg_roles where rolname = current_user),
           rbac.current_user_id(),
           coalesce(array(select rbac.current_org_ids()), '{}'::uuid[]),
           coalesce(nullif(current_setting('request.jwt.claims', true), ''), '(none)');
$$ language sql stable;

-- whoami() is safe in any environment -- it reveals only who the caller
-- already is -- so it is granted broadly and needs no dev_mode guard.
grant execute on function aiq.whoami() to authenticated, web_anon;

-- The impersonation helpers are NOT granted to web_anon or authenticated.
-- In dev you call them as app_owner (or as the superuser), which is who is
-- driving a SQL client anyway. Granting them to `authenticated` would let any
-- API caller reassign their own identity -- the exact escalation shape this
-- collection keeps finding and fixing.
revoke execute on function aiq.dev_assume(uuid, uuid[]) from public;
revoke execute on function aiq.dev_assume_org(uuid) from public;
revoke execute on function aiq.dev_anon() from public;
