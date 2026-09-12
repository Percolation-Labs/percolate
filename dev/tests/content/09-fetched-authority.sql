-- WHOSE AUTHORITY REGISTERS A FETCHED ITEM -- content.register_fetched's gate,
-- measured on both arms (REM-76).
--
-- register_fetched is SECURITY DEFINER, granted to `authenticated`, and asked
-- only content.assert_org_write: may this caller act in the org. Its sibling
-- register_upload asks content.may_upload as well -- may_access_org PLUS the
-- `resources:create` permission -- so a signed-in member of an org without that
-- permission was refused an upload and allowed the identical write through the
-- fetch path. Two entry points onto one table, differing only in whether bytes
-- came with it, disagreeing about who may use them.
--
-- WHY THE GATE IS A DISJUNCTION, and why bare may_upload would be an outage.
-- The only caller of register_fetched in the tree is a REGISTERED STEP FUNCTION
-- (selfmodel.ingest_prose, via workflow.call_step_function), which sets no
-- claims and runs on the `worker` login. may_upload's own operator arm reads
-- has_table_privilege(SESSION_USER, 'content.resources', 'insert') -- the
-- login, not the definer -- and `worker` holds no table privileges by design.
-- Measured in that exact shape before choosing the predicate:
--
--     session_user=worker | is_operator=t | login_can_insert=f | may_upload=f
--
-- So the gate is `rbac.is_operator() or content.may_upload(org)`, and §3 below
-- is the assertion that tests the first arm rather than taking it on trust:
-- a claimless writer must still be able to write.
--
-- sources.md §21 states the rule and records what is still owed --
-- call_step_function does not set the run owner's claims, so a scheduled fetch
-- carries an operator's authority rather than its source owner's. When that
-- changes, §2 here starts covering the scheduled path too with no edit.

\set ON_ERROR_STOP on

begin;

set local role app_owner;

-- TWO USERS IN ONE ORG, which is what the defect is about: it is not about
-- tenancy. Both callers are members of the same org and would both pass
-- may_access_org; they differ only in whether they hold `resources:create`.
-- A fixture that put them in different orgs would pass on the org check and
-- measure nothing about the permission.
create temp table t_fa (org uuid, may uuid, maynot uuid, chan text);
insert into t_fa values (gen_random_uuid(),
                         gen_random_uuid(), gen_random_uuid(),
                         't-fa-feed-' || left(gen_random_uuid()::text, 8));

do $$
declare o uuid; u_may uuid; u_not uuid; c text;
begin
    select org, may, maynot, chan into o, u_may, u_not, c from t_fa;
    insert into rbac.orgs (id, slug, name)
        values (o, 't-fa-org-' || left(o::text, 8), 'Fetched Authority Org');
    -- THE USERS ARE ROWS, for the reason content/01's header gives about orgs:
    -- rbac.org_members.user_id references rbac.users, and membership is what
    -- rbac.current_org_ids() reads -- a claim naming a user who does not exist
    -- is an anonymous caller, which would make §1 below pass on the org check.
    insert into rbac.users (id, email, status) values
        (u_may, 't-fa-may-'    || left(u_may::text, 8) || '@example.test', 'active'),
        (u_not, 't-fa-maynot-' || left(u_not::text, 8) || '@example.test', 'active');
    insert into rbac.org_members (org_id, user_id) values (o, u_may), (o, u_not);

    -- `org` visibility and an explicit owner, for the reason content/01 gives:
    -- channels default to private with no owner, and rbac.may_read(null, org,
    -- 'private') is NULL, so the lookup inside register_fetched drops the row
    -- and reports "no channel named %" about a channel that is right there --
    -- which would make every refusal below pass for the wrong reason.
    insert into content.channels (name, kind, org_id, visibility, owner_id)
        values (c, 'feed', o, 'org', u_may);

    -- A PUBLIC CHANNEL AS WELL, and the reason is a real constraint rather
    -- than fixture convenience. §3 runs as a CLAIMLESS operator, and the
    -- channel lookup inside register_fetched gates on
    -- rbac.may_read(owner_id, org_id, visibility) -- which has no operator arm
    -- (user-rbac/schema.sql: may_write and may_access_org have one, may_read
    -- does not). So a claimless caller can resolve ONLY a `public` channel; an
    -- `org` one raises "no channel named %" at it. That is pre-existing
    -- behaviour, not something this file's change introduced, and it is why
    -- content.channels takes add_scope_columns(..., 'public') as its default.
    --
    -- Measured here rather than assumed: §3 against the `org` channel above
    -- failed with exactly that message. Using a public channel keeps §3
    -- measuring the gate this file is about instead of the channel lookup.
    insert into content.channels (name, kind, org_id, visibility, owner_id)
        values (c || '-pub', 'feed', o, 'public', u_may);
end $$;

-- THE PERMISSION ITSELF, granted to one of the two users.
--
-- Read from rbac's own tables rather than assumed: the grant has to be the one
-- rbac.has_permission() reads, or §1 and §2 below both pass without the gate
-- doing anything. If the role or permission rows are not shaped as this block
-- expects it raises here, rather than leaving a green run behind.
do $$
declare o uuid; u_may uuid; u_not uuid; r_may text; r_not text;
begin
    select org, may, maynot into o, u_may, u_not from t_fa;
    r_may := 't-fa-creator-'    || left(o::text, 8);
    r_not := 't-fa-noncreator-' || left(o::text, 8);

    if not exists (select 1 from rbac.permission_kinds
                    where resource = 'resources' and action = 'create') then
        raise exception
            'there is no resources:create permission kind -- the premise of this '
            'file (that register_upload gates on one) has changed';
    end if;

    -- TWO PURPOSE-MADE ROLES rather than the shipped `member`, which happens
    -- to carry resources:create today. Depending on that would make this file
    -- go red for a reason that has nothing to do with register_fetched the day
    -- somebody re-cuts the default roles; the premise assertion below is what
    -- makes the purpose-made pair safe to rely on instead.
    insert into rbac.roles (name, description) values
        (r_may, 'holds resources:create, for content/09'),
        (r_not, 'holds no resources:create, for content/09');
    insert into rbac.role_permissions (role, resource, action) values
        (r_may, 'resources', 'create'),
        -- a real permission that is NOT the one under test, so the refused
        -- caller is a user with roles rather than a user with none -- the
        -- latter would also fail a has_permission written any other way
        (r_not, 'orgs', 'select');
    insert into rbac.user_roles (user_id, role) values
        (u_may, r_may), (u_not, r_not);

    -- and the premise, asserted rather than assumed: one user holds it and the
    -- other does not. `is distinct from` so a NULL from a missing row fires
    -- this instead of silencing it (dev/assertion-audit.py's class).
    if rbac.has_permission(u_may, 'resources', 'create') is distinct from true then
        raise exception 'the fixture user that should hold resources:create does not';
    end if;
    if rbac.has_permission(u_not, 'resources', 'create') is distinct from false then
        raise exception 'the fixture user that should NOT hold resources:create does';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. A signed-in member of the org WITHOUT resources:create is refused.
--
-- This is the defect, stated as behaviour. Before the gate this call returned
-- a resource id.
--
-- THE MESSAGE IS CHECKED, NOT ONLY THE SQLSTATE, for the reason content/01 §5
-- records: assert_org_write also raises 42501, and so does a missing GRANT, so
-- `when insufficient_privilege` alone would let the org check -- or a plain
-- permission denial -- pass itself off as this one. The refusal must be the
-- designed one, naming the permission.
-- ---------------------------------------------------------------------
do $$
declare
    o uuid; u_not uuid; c text; v_sqlstate text; v_msg text; v_hint text; v_res uuid;
begin
    select org, maynot, chan into o, u_not, c from t_fa;

    set local role authenticated;
    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', u_not, 'orgs', array[o])::text);

    -- the caller can genuinely act in this org, so §1 is measuring the
    -- permission and not the org check standing in for it
    if rbac.may_access_org(o) is distinct from true then
        raise exception
            'the refused caller cannot act in the org at all -- this block would '
            'pass on assert_org_write and say nothing about resources:create';
    end if;

    begin
        v_res := content.register_fetched(c, 't-fa-refused', 'refused', null, o);
        raise exception
            'A SIGNED-IN CALLER WITHOUT resources:create REGISTERED FETCHED '
            'CONTENT: % -- register_fetched is not asking may_upload', v_res;
    exception when others then
        v_sqlstate := sqlstate; v_msg := sqlerrm;
        get stacked diagnostics v_hint = pg_exception_hint;
        if v_msg like 'A SIGNED-IN CALLER%' then raise; end if;
    end;

    if v_sqlstate is distinct from '42501' then
        raise exception
            'register_fetched refused with % rather than 42501, so PostgREST '
            'will not answer 403: %', v_sqlstate, v_msg;
    end if;
    if v_hint is distinct from 'needs resources:create' then
        raise exception
            'the refusal is not the permission check -- hint was %, message %',
            coalesce(v_hint, '(none)'), v_msg;
    end if;

    -- and nothing landed
    if exists (select 1 from content.resources where external_id = 't-fa-refused') then
        raise exception 'the refusal still wrote the row';
    end if;

    reset role;
    raise notice 'content/09: a signed-in member without resources:create cannot register fetched content';
end $$;

-- ---------------------------------------------------------------------
-- 2. The same caller, now HOLDING resources:create, succeeds.
--
-- A check that refuses everyone is not a check, it is an outage -- content/01
-- §5's words. This is also the "a poll for a source whose owner holds it still
-- succeeds" half of REM-76, in the only shape the code can currently express
-- it: claims carrying the owner's `sub`. That is exactly what
-- workflow.execute_for sets for an inline sql step, and what
-- workflow.call_step_function does NOT yet set for a registered step function
-- (sources.md §21.3).
-- ---------------------------------------------------------------------
do $$
declare o uuid; u_may uuid; c text; v_res uuid; v_owner uuid;
begin
    select org, may, chan into o, u_may, c from t_fa;

    set local role authenticated;
    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', u_may, 'orgs', array[o])::text);

    v_res := content.register_fetched(c, 't-fa-allowed', 'allowed', null, o);
    if v_res is null then
        raise exception
            'register_fetched returned nothing for a caller who holds '
            'resources:create -- the gate refuses the people it is meant to admit';
    end if;

    -- and the row is the caller's own, readable by them: the write must not be
    -- one the writer is locked out of (the REM-75 defect this function already
    -- carries a comment about)
    select owner_id into v_owner from content.resources where id = v_res;
    if v_owner is distinct from u_may then
        raise exception 'the registered row is owned by % rather than the caller', v_owner;
    end if;
    if not exists (select 1 from content.resources where id = v_res) then
        raise exception 'the caller cannot read back the row they just registered';
    end if;

    reset role;
    raise notice 'content/09: a signed-in member holding resources:create still registers fetched content, and owns what it wrote';
end $$;

-- ---------------------------------------------------------------------
-- 3. A CLAIMLESS WRITER IS UNTOUCHED, which is the arm that would have turned
--    this fix into an outage.
--
-- The one caller of register_fetched in the tree is a registered step function
-- with no claims on the `worker` login, and content.may_upload returns FALSE
-- for exactly that shape (measured in this file's header). So the gate leads
-- with rbac.is_operator(), and this block is what stops that arm from being a
-- claim rather than a check.
--
-- Run as app_owner with claims explicitly EMPTIED, which is the operator the
-- install and the seed are. `set local role` is not enough on its own: the
-- blocks above set claims, and a leftover `sub` would make is_operator() false
-- and this block measure the wrong arm.
-- ---------------------------------------------------------------------
do $$
declare o uuid; c text; v_res uuid;
begin
    select org, chan into o, c from t_fa;

    set local role app_owner;
    set local request.jwt.claims = '';

    if rbac.is_operator() is distinct from true then
        raise exception
            'app_owner with no claims is not an operator, so block 3 is not '
            'measuring the arm it says it is';
    end if;
    -- the premise: may_upload alone would NOT admit this caller on the worker
    -- login. app_owner does hold the INSERT, so state the weaker fact that is
    -- true here -- the operator arm is what carries a login without it.
    if content.may_upload(o) is distinct from true then
        raise exception 'may_upload refuses app_owner, which the install depends on';
    end if;

    -- the PUBLIC channel, for the may_read reason the fixture block records
    v_res := content.register_fetched(c || '-pub', 't-fa-operator', 'operator', null, o);
    if v_res is null then
        raise exception
            'A CLAIMLESS OPERATOR CANNOT REGISTER FETCHED CONTENT -- the install, '
            'the seed and selfmodel.ingest_prose''s step all go through here';
    end if;

    raise notice 'content/09: a claimless operator still registers fetched content -- the step-function caller is not refused';
end $$;

-- ---------------------------------------------------------------------
-- 4. The two entry points now refuse the SAME caller.
--
-- The defect was not that either function was wrong on its own; it was that
-- they disagreed. Asserting the agreement is what keeps a later change to one
-- of them from reopening this, and it is the property sources.md §21 promises
-- an operator: nobody can use the fetch path by hand to write content into a
-- channel they could not upload to.
-- ---------------------------------------------------------------------
do $$
declare
    o uuid; u_not uuid; c text; v_up boolean := false; v_fe boolean := false;
begin
    select org, maynot, chan into o, u_not, c from t_fa;

    -- an upload channel for the same org, so the two calls differ in the
    -- function under test and not in what they are pointed at
    insert into content.channels (name, kind, org_id, visibility, owner_id)
        values (c || '-up', 'file_upload', o, 'org', (select may from t_fa));

    set local role authenticated;
    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', u_not, 'orgs', array[o])::text);

    begin
        perform content.register_upload(c || '-up', 't-fa-cmp-1', 'b', 'k/1',
                                        1, null, 'cmp', null, o);
    exception when others then v_up := true;
    end;
    begin
        perform content.register_fetched(c, 't-fa-cmp-2', 'cmp', null, o);
    exception when others then v_fe := true;
    end;

    if v_up is distinct from v_fe then
        raise exception
            'the upload path and the fetch path disagree about the same caller: '
            'register_upload refused=%, register_fetched refused=% -- one of them '
            'is a way around the other', v_up, v_fe;
    end if;
    if not v_up then
        raise exception
            'neither path refused a caller without resources:create, so this '
            'block agrees about nothing';
    end if;

    reset role;
    raise notice 'content/09: register_upload and register_fetched refuse the same caller -- neither is a way around the other';
end $$;

rollback;
