-- A CHANNEL A PACKAGE DECLARES IS VISIBLE TO THE CODE THAT FILLS IT (REM-83),
-- and the same shape refused at the table so there is not a fourth instance.
--
-- percolate.apply_package inserted a declared channel with neither `owner_id`
-- nor `visibility`, so the columns took their defaults: null and `private`.
-- rbac.may_read(null, shared_org, 'private') is NULL on every arm, so the
-- channel is readable by nobody -- including content.register_fetched, which
-- filters its own lookup through may_read and then reports "no channel named %
-- for this org" about a channel that is right there.
--
-- This is the third file to write that pair. REM-75 fixed it in
-- content.register_fetched, REM-74 in the self-model's content.sql, and this
-- one in apply_package. Each repair was at the call site, which is why there
-- were three; §2 below is the gate a class
-- earns once it arrives a third time.
--
-- NOTHING CAUGHT IT because the may_read arm in register_fetched's lookup is
-- newer than any released tag -- every installed database is old enough to
-- hide it -- and the from-zero path that would show it is the one nobody runs.

\set ON_ERROR_STOP on

begin;

set local role app_owner;

-- ---------------------------------------------------------------------
-- 1. THE JOURNEY. Declare a source in a package, fill it the way a poll does,
--    and read the resource back. Against the insert this issue fixes, the
--    register_fetched call raises and this block fails.
-- ---------------------------------------------------------------------
do $$
declare
    v_pkg  text := 'rem83-' || left(gen_random_uuid()::text, 8);
    v_chan text := 'rem83_feed_' || left(gen_random_uuid()::text, 8);
    v_res  uuid;
    v_vis  text;
    v_own  uuid;
begin
    perform percolate.apply_package(jsonb_build_object(
        'name', v_pkg,
        'version', '0.0.1',
        'sources', jsonb_build_array(jsonb_build_object(
            'name', v_chan,
            'kind', 'feed',
            'config', jsonb_build_object('url', 'https://example.invalid/rss')))));

    select visibility, owner_id into v_vis, v_own
      from content.channels where name = v_chan;

    if v_vis is null then
        raise exception 'apply_package declared no channel named % at all', v_chan;
    end if;

    -- STATED BEFORE THE JOURNEY RUNS, so a failure names the cause rather than
    -- the symptom. The symptom -- "no channel named %" -- is a sentence about
    -- the org, which is what sent the two earlier instances looking in the
    -- wrong place.
    if v_vis = 'private' and v_own is null then
        raise exception
            'apply_package wrote visibility=private with no owner: '
            'rbac.may_read(null, shared_org, ''private'') is NULL, so this '
            'channel is readable by nobody and the fetch path below cannot '
            'find it (REM-83)';
    end if;

    -- The poll path itself. This runs claimless, as content.register_fetched's
    -- only real caller does (a registered step function on the `worker` login),
    -- so the channel has to be resolvable without a request identity -- which
    -- is the case rbac.default_visibility() answers with `public`.
    v_res := content.register_fetched(v_chan, 'rem83-item-1',
                                      'First item', 'https://example.invalid/1');
    if v_res is null then
        raise exception 'register_fetched returned no resource for channel %', v_chan;
    end if;

    -- And it is readable back, which is the capability rather than the write.
    if not exists (select 1 from content.resources r
                    join content.channels c on c.id = r.channel_id
                   where r.id = v_res and c.name = v_chan
                     and rbac.may_read(r.owner_id, r.org_id, r.visibility)) then
        raise exception
            'the resource was written and rbac.may_read cannot see it -- the '
            'channel is reachable and its content is not';
    end if;

    raise notice 'content/10 §1: a package-declared channel accepts fetched content and reads back (visibility=%)', v_vis;
end $$;

-- ---------------------------------------------------------------------
-- 2. AND THE SHAPE IS REFUSED AT THE TABLE, which is what makes §1 the last
--    instance rather than the third. Asserted on both tables, and both
--    directions: the dead pair is refused, and a narrow row with an owner --
--    which is the ordinary private row -- still goes in.
-- ---------------------------------------------------------------------
do $$
declare
    v_user uuid := gen_random_uuid();
    v_name text := 'rem83-dead-' || left(gen_random_uuid()::text, 8);
    v_took boolean := false;
begin
    insert into rbac.users (id, email, status)
        values (v_user, v_name || '@example.test', 'active');

    begin
        insert into content.channels (name, kind, visibility, owner_id)
             values (v_name, 'manual', 'private', null);
        v_took := true;
    exception when check_violation then null;
    end;
    if v_took then
        raise exception
            'content.channels accepted visibility=private with no owner -- a '
            'row no policy grants to anybody (REM-83 §2)';
    end if;

    -- The other direction, and it is the half that makes the constraint worth
    -- having rather than merely strict: an owned private channel is the
    -- ordinary narrow row and must still be insertable.
    insert into content.channels (name, kind, visibility, owner_id)
         values (v_name, 'manual', 'private', v_user);
    if not exists (select 1 from content.channels
                    where name = v_name and visibility = 'private'
                      and owner_id = v_user) then
        raise exception 'an owned private channel did not survive the insert';
    end if;

    raise notice 'content/10 §2: content.channels refuses the dead pair and keeps the owned one';
end $$;

do $$
declare
    v_chan uuid;
    v_took boolean := false;
begin
    insert into content.channels (name, kind, visibility)
         values ('rem83-res-' || left(gen_random_uuid()::text, 8), 'manual', 'public')
        returning id into v_chan;

    begin
        insert into content.resources (channel_id, external_id, uri, visibility, owner_id)
             values (v_chan, 'rem83-dead', 'https://example.invalid/dead',
                     'private', null);
        v_took := true;
    exception when check_violation then null;
    end;
    if v_took then
        raise exception
            'content.resources accepted visibility=private with no owner -- a '
            'row no policy grants to anybody (REM-83 §2)';
    end if;

    raise notice 'content/10 §2: content.resources refuses the dead pair too';
end $$;

rollback;
