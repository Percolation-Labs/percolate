-- THE READER FOR `channels.poll_interval`, which has had none since the column
-- was added.
--
-- `brief.md` §3.5 states the gap and names the design: "the worker, as a
-- scheduled workflow whose steps are ordinary `rest` calls followed by a `sql`
-- step calling `register_fetched`. That keeps the 'get bytes, register, start
-- ingestion' logic in one place -- the database function both paths already
-- call -- rather than duplicating it into a poller." This file is that
-- paragraph, executed. `RELEASE-0.1.md` §6 names it as one of two things
-- remaining for 0.1.
--
-- WHAT WAS ALREADY HERE, because almost all of it was, and this file is small
-- for that reason:
--
--   * `content.channels.poll_interval` and `idx_channels_pollable` -- the
--     column and the index, with nothing reading either.
--   * `workflow.schedules`, `workflow.tick()` and one `pg_cron` entry -- a
--     working scheduler with a cron expression per row.
--   * `overlap_policy = 'skip'`, which is `brief.md` §5's overlapping-poll
--     problem already solved: a channel polled every minute whose fetch takes
--     ninety seconds must not accumulate runs. Not re-solved here.
--   * `content.register_fetched()` -- register a fetched thing and start its
--     ingestion, the function the upload path already goes through.
--
-- So the missing piece is exactly one hop: **an enabled channel with an
-- interval on it should have a schedule, and nothing made one.** A person had
-- to write the workflow, write the schedule, and then keep the two in step
-- with the channel by hand -- which is why the corpus holds what somebody
-- remembered to fetch rather than what the sources published.

-- ---------------------------------------------------------------------------
-- 1. AN INTERVAL IS NOT A CRON EXPRESSION, AND MOST INTERVALS ARE NOT ONE.
--
-- `poll_interval` is an `interval`; `workflow.schedules.cron_expr` is a
-- five-field cron string evaluated once a minute. The conversion is lossy in
-- one direction and this function refuses rather than rounding.
--
-- `*/7 * * * *` IS NOT "EVERY SEVEN MINUTES", and that is the trap this exists
-- to avoid. Cron's step syntax selects matching values inside the field's
-- range, so `*/7` fires at minutes 0,7,...,56 and then again at 0 -- a
-- four-minute gap once an hour. A caller who wrote `interval '7 minutes'` and
-- got that would have a poller that is wrong twenty-four times a day and looks
-- right in every individual firing. So an interval is accepted only when it
-- divides its containing unit evenly, and refused with the nearest values that
-- work when it does not.
--
-- The floor is one minute because the ticker's resolution is one minute.
-- Accepting `30 seconds` would be a promise the engine cannot keep, and the
-- honest failure is at the write rather than a schedule that quietly fires at
-- half the requested rate forever.
create or replace function content.cron_for_interval(p_every interval)
returns text language plpgsql immutable set search_path = pg_catalog, public as $$
declare
    v_secs numeric := extract(epoch from p_every);
    v_mins int;
    v_hours int;
begin
    if p_every is null then
        raise exception 'a poll cadence is required';
    end if;
    if v_secs < 60 then
        raise exception
            'a poll cadence of % is shorter than the scheduler''s one-minute '
            'resolution, so it could not be honoured', p_every
            using hint = 'the shortest supported cadence is 1 minute';
    end if;
    if v_secs::bigint % 60 <> 0 then
        raise exception
            'a poll cadence of % is not a whole number of minutes', p_every
            using hint = 'the scheduler evaluates once a minute';
    end if;

    v_mins := (v_secs / 60)::int;

    -- Sub-hourly: must divide 60, or the step wraps unevenly at the hour.
    if v_mins < 60 then
        if 60 % v_mins <> 0 then
            raise exception
                'a poll cadence of % minutes would not fire evenly: cron steps '
                'restart every hour, so it would skip at the hour boundary',
                v_mins
                using hint = 'use 1, 2, 3, 4, 5, 6, 10, 12, 15, 20 or 30 minutes, or a whole number of hours';
        end if;
        return format('*/%s * * * *', v_mins);
    end if;

    if v_mins = 60 then
        return '0 * * * *';
    end if;

    -- Hourly and above: must be whole hours, and must divide 24 for the same
    -- reason -- cron's hour step restarts at midnight.
    if v_mins % 60 <> 0 then
        raise exception
            'a poll cadence of % minutes is between one hour and one day and is '
            'not a whole number of hours', v_mins
            using hint = 'use a whole number of hours that divides 24';
    end if;
    v_hours := v_mins / 60;
    if v_hours < 24 then
        if 24 % v_hours <> 0 then
            raise exception
                'a poll cadence of % hours would not fire evenly: cron steps '
                'restart every day, so it would skip at midnight', v_hours
                using hint = 'use 1, 2, 3, 4, 6, 8 or 12 hours, or 1 day';
        end if;
        return format('0 */%s * * *', v_hours);
    end if;
    if v_hours = 24 then
        return '0 0 * * *';
    end if;

    raise exception
        'a poll cadence of % is longer than a day', p_every
        using hint = 'schedule it with workflow.schedule_workflow() and a cron expression that says which days';
end $$;

-- NOT GRANTED TO ANYBODY. It is reached only from sync_channel_schedule
-- below, which is SECURITY DEFINER, so a caller never needs it -- and
-- `surface.sql` refused the grant when it was there, which is the audit doing
-- exactly its job: an external surface nobody wrote a sentence for. The
-- validate-before-you-save case a grant would serve is already covered, because
-- writing the channel raises the same message.
revoke all on function content.cron_for_interval(interval) from public;

-- ---------------------------------------------------------------------------
-- 2. THE SCHEDULE IS DERIVED FROM THE CHANNEL, NOT KEPT BESIDE IT.
--
-- One name, `channel_<id>`, computed from the row rather than stored on it --
-- so there is no second place for the link to be wrong, and a channel deleted
-- by any path leaves no schedule behind. This is the collection's own rule
-- about one home for a fact, applied to the join between two tables that both
-- already existed.
--
-- SECURITY DEFINER because it is reached from a trigger on `content.channels`,
-- and `workflow.schedule_workflow` asks `assert_schedule_access`. The caller
-- has already been authorised to write the channel; a poll cadence is a
-- property of that channel rather than a separate grant, and requiring a
-- second permission to make the interval mean anything would be a column that
-- silently does nothing for most of the people allowed to set it -- which is
-- the state this file is fixing.
create or replace function content.sync_channel_schedule(p_channel_id uuid)
returns text language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    c        content.channels;
    v_sched  text;
    v_flow   text;
begin
    select * into c from content.channels where id = p_channel_id;
    v_sched := 'channel_' || replace(p_channel_id::text, '-', '');

    -- Gone, disabled, or no cadence: no schedule. Unconditional rather than
    -- conditional on having created one, because the reason a schedule should
    -- not exist is the same in all three cases and a missing one is not an
    -- error to unschedule.
    if c.id is null or not c.enabled or c.poll_interval is null then
        perform workflow.unschedule_workflow(v_sched);
        return null;
    end if;

    v_flow := c.config->>'ingest_workflow';
    if v_flow is null then
        raise exception
            'channel "%" has a poll cadence but names no workflow to run', c.name
            using hint = 'set config.ingest_workflow, or clear poll_interval';
    end if;

    -- `input` carries the channel id and nothing else. The workflow reads the
    -- row for everything else, so a channel edited after the schedule was made
    -- takes effect on the next tick rather than needing the schedule rewritten
    -- -- the same reason `schedules.workflow_name` stores a name and not an id.
    perform workflow.schedule_workflow(
        v_sched, v_flow, content.cron_for_interval(c.poll_interval),
        jsonb_build_object('channel_id', c.id),
        'UTC',
        -- brief.md §5's overlapping-poll problem. Named explicitly rather than
        -- left to the column default, because it is the property this feature
        -- depends on and a default can be changed by somebody who does not
        -- know that.
        'skip');
    return v_sched;
end $$;

revoke all on function content.sync_channel_schedule(uuid) from public;

-- The trigger. AFTER, so the row is visible to schedule_workflow's own reads,
-- and on the three columns that decide whether a schedule should exist or what
-- it should say -- an update to `last_polled_at` (which the tick itself writes)
-- must not re-derive the schedule on every fire.
create or replace function content.channel_schedule_trigger() returns trigger as $$
begin
    perform content.sync_channel_schedule(coalesce(new.id, old.id));
    return null;
end $$ language plpgsql security definer set search_path = pg_catalog, public;

create or replace trigger channels_sync_schedule
    after insert or update of enabled, poll_interval, config on content.channels
    for each row execute function content.channel_schedule_trigger();

-- DELETE is its own trigger because the row is gone by AFTER and `new` is null;
-- the schedule still has to go with it.
create or replace trigger channels_drop_schedule
    after delete on content.channels
    for each row execute function content.channel_schedule_trigger();
