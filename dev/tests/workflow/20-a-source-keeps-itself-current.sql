-- A SOURCE KEEPS ITSELF CURRENT ONCE YOU SWITCH IT ON.
--
-- `content.channels.poll_interval` and `idx_channels_pollable` existed with
-- nothing reading either, so "polled every fifteen minutes" was a value in a
-- column and a person's memory. `RELEASE-0.1.md` §6 named it as one of two
-- things remaining for 0.1.
--
-- WHAT IS UNDER TEST IS THE DERIVATION, not the scheduler. `workflow.tick()`,
-- cron matching and `overlap_policy = 'skip'` are all covered by
-- `02-schedules.sql` and `03-cron-tick.sql` and are not re-proved here. What is
-- new is that a channel row and a schedule row cannot disagree: the schedule is
-- derived from the channel on every write, so there is no second place for the
-- cadence to be wrong and no way to leave a schedule behind.
--
-- Every assertion is a state transition, because a derivation that only works
-- in the create direction is the failure that matters -- a disabled channel
-- that keeps polling looks exactly like a working one from the channel table.

\set ON_ERROR_STOP on

begin;
set local role app_owner;

select workflow.define_yaml($y$
name: poll_test_flow
steps:
  - id: fetch
    work: true
    queue: http
    input:
      op: noop
$y$);

do $$
declare
    v_ch   uuid := '5e7c0000-0000-4000-8000-00000000f00d';
    v_name text := 'channel_5e7c000000004000800000000000f00d';
    v_cron text;
    v_n    int;
begin
    -- ------------------------------------------------------------------
    -- 1. AN ENABLED CHANNEL WITH A CADENCE HAS A SCHEDULE, AUTHORED BY NOBODY.
    -- ------------------------------------------------------------------
    insert into content.channels (id, name, kind, poll_interval, enabled, config, owner_id)
    values (v_ch, 'poll_test_feed', 'http_pull', interval '15 minutes', true,
            '{"ingest_workflow":"poll_test_flow"}'::jsonb,
            '11111111-1111-1111-1111-111111111111');

    select cron_expr into v_cron from workflow.schedules where name = v_name;
    if v_cron is null then
        raise exception
            'a channel with poll_interval = 15 minutes produced no schedule, so '
            'the column still has no reader and the source polls only when '
            'somebody remembers';
    end if;
    if v_cron <> '*/15 * * * *' then
        raise exception 'expected */15 * * * * from a 15-minute cadence, got %', v_cron;
    end if;

    -- The overlap policy is the property brief.md §5 depends on: a channel
    -- polled every minute whose fetch takes ninety seconds must not accumulate
    -- runs. Asserted rather than left to the column default, because a default
    -- can be changed by somebody who does not know this rests on it.
    if (select overlap_policy from workflow.schedules where name = v_name)
       is distinct from 'skip' then
        raise exception 'a poll schedule must skip while its previous run is still going';
    end if;

    -- The input carries the channel and nothing else, so a channel edited
    -- later takes effect on the next tick rather than needing the schedule
    -- rewritten.
    if (select input from workflow.schedules where name = v_name)
       is distinct from jsonb_build_object('channel_id', v_ch) then
        raise exception 'the schedule does not name its channel';
    end if;

    -- ------------------------------------------------------------------
    -- 2. EVERY TRANSITION, because create-only derivation is the real bug.
    -- ------------------------------------------------------------------
    update content.channels set poll_interval = interval '1 hour' where id = v_ch;
    if (select cron_expr from workflow.schedules where name = v_name)
       is distinct from '0 * * * *' then
        raise exception 'changing the cadence did not change the schedule';
    end if;

    update content.channels set enabled = false where id = v_ch;
    select count(*) into v_n from workflow.schedules where name = v_name;
    if v_n <> 0 then
        raise exception
            'a disabled channel kept its schedule, so switching a source off '
            'leaves it polling and the channel table says it is off';
    end if;

    update content.channels set enabled = true where id = v_ch;
    if (select count(*) from workflow.schedules where name = v_name) <> 1 then
        raise exception 're-enabling a channel did not restore its schedule';
    end if;

    update content.channels set poll_interval = null where id = v_ch;
    if (select count(*) from workflow.schedules where name = v_name) <> 0 then
        raise exception 'clearing the cadence left the schedule behind';
    end if;

    -- ...and a deleted channel takes its schedule with it. DELETE is a separate
    -- trigger because `new` is null by then, so it is worth its own assertion.
    update content.channels set poll_interval = interval '5 minutes' where id = v_ch;
    delete from content.channels where id = v_ch;
    if (select count(*) from workflow.schedules where name = v_name) <> 0 then
        raise exception
            'a deleted channel left an orphan schedule, which fires a workflow '
            'for a source that no longer exists once every five minutes';
    end if;

    raise notice 'workflow/20: a channel''s cadence derives its schedule, in every direction';
end $$;

-- ------------------------------------------------------------------
-- 3. A CADENCE CRON CANNOT EXPRESS EVENLY IS REFUSED AT THE WRITE.
--
-- `*/7 * * * *` is not "every seven minutes" -- cron's step restarts each hour,
-- so it fires at 0,7,…,56 and then 0, a four-minute gap once an hour. Accepting
-- it would give a poller that is wrong twenty-four times a day and looks right
-- at every individual firing. The refusal has to land on the person setting the
-- interval, not in `schedules.last_error` where nobody is looking.
-- ------------------------------------------------------------------
do $$
declare
    v_ch uuid := '5e7c0000-0000-4000-8000-00000000beef';
    r    record;
begin
    for r in
        select * from (values
            (interval '7 minutes',  'does not divide an hour'),
            (interval '30 seconds', 'is faster than the ticker'),
            (interval '5 hours',    'does not divide a day'),
            (interval '90 seconds', 'is not a whole number of minutes')
        ) as t(i, w)
    loop
        begin
            insert into content.channels (id, name, kind, poll_interval, enabled, config, owner_id)
            values (v_ch, 'poll_bad_feed', 'http_pull', r.i, true,
                    '{"ingest_workflow":"poll_test_flow"}'::jsonb,
                    '11111111-1111-1111-1111-111111111111');
            raise exception
                'a cadence that % was accepted (%), so it will fire unevenly '
                'forever and every single firing will look correct', r.w, r.i;
        exception when raise_exception then
            if sqlerrm like 'a cadence that %' then raise; end if;
        end;
    end loop;
    raise notice 'workflow/20: a cadence the scheduler cannot honour is refused when it is set';
end $$;

rollback;
