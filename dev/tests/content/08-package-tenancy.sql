-- A package cannot add a door the core would refuse (REM-47).
--
-- packages/apply.py piped a package's storage through psql and nothing looked
-- at what it added. percolate-dev and incident-review created tables with a
-- nullable org_id and no RLS; their manifests named no `org:`, so
-- apply_package projected every row onto the shared tier as a public node; and
-- every pgw definer function on the tour database had a NULL ACL, which is
-- PUBLIC's EXECUTE. percolate.check_package_schema() now refuses all three,
-- apply.py runs it in the transaction that applies storage, and apply_package
-- runs it on every schema an entity type names.
--
-- Each refusal is asserted by the text naming the object, so a check that
-- raised for some other reason, or for a different table, fails here.
\set ON_ERROR_STOP on
begin;
set local role app_owner;
create schema t_pkgten;
create table t_pkgten.widgets (id uuid not null default gen_random_uuid() unique,
                               key text primary key, org_id uuid);
set local request.jwt.claims = '{}';

-- 1. A nullable org_id with no RLS is refused, and the error names the table,
--    both rules and the core call that fixes it.
do $$ declare v_hint text; begin
    begin
        perform percolate.check_package_schema('t_pkgten');
        raise exception 'check_package_schema accepted a nullable org_id with no RLS';
    exception when raise_exception then
        get stacked diagnostics v_hint = pg_exception_hint;
        if sqlerrm not like '%t_pkgten.widgets.org_id is nullable%'
           or sqlerrm not like '%t_pkgten.widgets has org_id and row-level security is off%' then
            raise;
        end if;
        if v_hint not like '%rbac.add_scope_columns%' or v_hint not like '%rbac.add_scope_policy%' then
            raise exception 'the refusal does not point at the core primitives: %', v_hint;
        end if;
    end;
    raise notice 'content/08: a nullable, unpoliced org_id is refused by name';
end $$;

-- 2. apply_package refuses it too, for a client that applied storage some
--    other way, and registers nothing.
do $$ begin
    begin
        perform percolate.apply_package($m${"name": "t-pkg-tenancy", "version": "0.1.0",
          "entity_types": [{"name": "t_ten_widget", "table": "t_pkgten.widgets", "key": "n.key"}]}$m$::jsonb);
        raise exception 'apply_package registered an entity type over an unscoped table';
    exception when raise_exception then
        if sqlerrm not like '%t_pkgten.widgets.org_id is nullable%' then raise; end if;
    end;
    if exists (select 1 from aiq.entity_registry where entity_type = 't_ten_widget') then
        raise exception 'the refused package left its entity type registered';
    end if;
    raise notice 'content/08: apply_package refuses the same table';
end $$;

-- 3. The core's two calls make the same table pass.
select rbac.add_scope_columns('t_pkgten.widgets');
select rbac.add_scope_policy('t_pkgten.widgets');
do $$ begin
    perform percolate.check_package_schema('t_pkgten');
    raise notice 'content/08: rbac.add_scope_columns + add_scope_policy pass';
end $$;

-- 4. A definer function PUBLIC can execute is refused, by an explicit grant and
--    by a NULL ACL. The second is created by a role whose default privileges
--    were never changed, which is how the tour's pgw functions got theirs.
create function t_pkgten.door() returns int language sql security definer as 'select 1';
grant execute on function t_pkgten.door() to public;
reset role;
create function t_pkgten.door_null_acl() returns int language sql security definer as 'select 1';
set local role app_owner;
do $$ begin
    if (select proacl from pg_proc where oid = 't_pkgten.door_null_acl()'::regprocedure) is not null then
        raise exception 'fixture: door_null_acl was meant to have a NULL ACL';
    end if;
    begin
        perform percolate.check_package_schema('t_pkgten');
        raise exception 'check_package_schema accepted definer functions PUBLIC can execute';
    exception when raise_exception then
        if sqlerrm not like '%t_pkgten.door() is SECURITY DEFINER and PUBLIC can execute it%'
           or sqlerrm not like '%t_pkgten.door_null_acl() is SECURITY DEFINER and PUBLIC can execute it%' then
            raise;
        end if;
    end;
    revoke execute on function t_pkgten.door() from public;
    raise notice 'content/08: a definer function PUBLIC can execute is refused, NULL ACL included';
end $$;
reset role;
revoke execute on function t_pkgten.door_null_acl() from public;
set local role app_owner;
do $$ begin
    perform percolate.check_package_schema('t_pkgten');
end $$;

-- 5. A schema that does not exist is refused rather than passing empty.
do $$ begin
    begin
        perform percolate.check_package_schema('t_pkgten_absent');
        raise exception 'check_package_schema passed a schema that does not exist';
    exception when raise_exception then
        if sqlerrm not like '%t_pkgten_absent does not exist%' then raise; end if;
    end;
end $$;

-- 6. With no `org:` in the manifest, a row's org and visibility are the node's.
--    apply_package passed 'null', which projected every row onto the shared
--    tier as a public node whatever org it carried.
do $$ declare v_org uuid; n aiq.nodes; begin
    insert into rbac.orgs (slug, name) values ('t-pkgten', 'pkg tenancy') returning id into v_org;
    perform percolate.apply_package($m${"name": "t-pkg-tenancy", "version": "0.1.0",
      "entity_types": [{"name": "t_ten_widget", "table": "t_pkgten.widgets", "key": "n.key"}]}$m$::jsonb);
    insert into t_pkgten.widgets (key, org_id, visibility) values ('w-org', v_org, 'org');
    select * into n from aiq.nodes
     where entity_type = 't_ten_widget'
       and entity_id = (select id from t_pkgten.widgets where key = 'w-org');
    if n.id is null then
        raise exception 'the widget row projected no node';
    end if;
    if n.org_id is distinct from v_org or n.visibility is distinct from 'org' then
        raise exception 'the widget projected into org % as %, where the row is org % as org',
            n.org_id, n.visibility, v_org;
    end if;
    raise notice 'content/08: with no org: in the manifest, the node takes the row''s org and visibility';
end $$;
rollback;
