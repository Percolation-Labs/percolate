-- =====================================================================
-- Stigmergic orchestration -- the engine-tier additions.
--
-- STATUS: SPEC, NOT BUILT. Never loaded, not in extension/percolate's build
-- order, not declared in surface.sql.
--
-- READ brief.md §2 FIRST. Most of what makes this engine stigmergic already
-- shipped -- SKIP LOCKED claiming, pg_notify recruitment, exponential backoff
-- as evaporation, lease reaping, the rate-limit refill, KEDA on queue depth.
-- None of that is here, because none of it needs writing.
--
-- What IS here is the deposit side, which the engine does not have (§3):
--
--   1. workflow.intensity()          -- decay, one implementation
--   2. workflow.deposits             -- what raises a locus. Append-only
--   3. workflow.anchors              -- a person's standing judgement. The one
--                                       relation with genuinely nowhere to live
--   4. workflow.v_gradient           -- the read-time perspective, for views
--   5. workflow.settle_priority()    -- the settled form, for the claim index
--   6. workflow.promote_due_gradients() -- activation, beside promote_due_timers
--
-- Everything lands in the `workflow` schema, because this is the workflow
-- engine gaining a deposit side rather than a new subsystem appearing beside
-- it.
-- =====================================================================

do $$
begin
    if (select rolsuper from pg_roles where rolname = current_user) then
        raise exception
            'REFUSING TO LOAD: current_user (%) is a cluster superuser. The '
            'views below would return every organisation''s field to every '
            'caller. Load this as app_owner.', current_user;
    end if;
end $$;

-- ------------------------------------------------------------
-- 1. Decay. ONE implementation, two consumers.
--
-- Read-time for the views (§4), settled for the claim index (§5). brief.md §7
-- lists "the settled/read-time split drifts" as a failure mode, and two copies
-- of this function is exactly how it would happen -- so there is one, and
-- settle_priority() calls it rather than reimplementing the arithmetic.
--
-- IMMUTABLE, taking the evaluation instant as an ARGUMENT rather than calling
-- now(). Safe to inline and parallelise, and it makes the gradient evaluable
-- AS OF ANY PAST INSTANT for free -- which is what turns brief.md §8's
-- counterfactual replay from a feature into a generate_series.
-- ------------------------------------------------------------
create or replace function workflow.intensity(
    amplitude numeric, half_life interval,
    deposited_at timestamptz, at timestamptz)
returns numeric language sql immutable parallel safe as $$
    select case
        when half_life = 'infinity'::interval then amplitude
        else amplitude * power(
            0.5,
            extract(epoch from (at - deposited_at)) / extract(epoch from half_life))
    end;
$$;

-- ------------------------------------------------------------
-- 2. Deposits.
--
-- WHY THIS IS A TABLE AND task_events IS NOT ENOUGH. task_events is the
-- engine's sematectonic trace and it is already append-only -- but it records
-- that a STATUS CHANGED and nothing about what the transition means for future
-- work. Reinforcement (brief.md §4.3) is a fold over it; this table is where
-- the fold LANDS, so the claim path reads a small hot table rather than
-- re-aggregating an unbounded event log every tick.
--
-- It is deliberately NOT a general marks table. Three kinds go in it and they
-- are the three brief.md §4 names: age is computed, not deposited; everything
-- else is either reinforcement from the engine's own history or a human anchor
-- projected in from §3.
-- ------------------------------------------------------------
create table workflow.deposits (
    deposit_id   bigint generated always as identity primary key,

    -- WHERE. A locus in this tier is an ENGINE OBJECT -- brief.md §10 leaves
    -- the granularity question open and this is the shape it has to answer in.
    -- 'domain' exists so a task that declares a subject can deposit at it, and
    -- is the seam the domain tier plugs into.
    locus_kind   text not null
                     check (locus_kind in ('queue','step_key','definition','run','domain')),
    locus        text not null,

    kind         text not null
                     check (kind in ('success','failure','question','anchor')),
    amplitude    numeric  not null check (amplitude > 0),
    polarity     smallint not null default 1 check (polarity in (-1, 1)),

    -- LAMBDA LIVES ON THE ROW rather than in a constant, so retuning is an
    -- UPDATE and a deposit made under an old half-life keeps the one it was
    -- made under. brief.md §7 says not to pick lambda up front; this is what
    -- makes that survivable.
    half_life    interval not null check (half_life > interval '0'),

    -- THE INDEPENDENCE UNIT (invariant 5). Compounding counts distinct
    -- origins, never deposits -- otherwise a loop reinforces itself into
    -- certainty and the system cannot tell its own output from evidence.
    -- No default: an origin nobody thought about compounds with everything.
    origin_key   text not null,

    run_id       uuid,
    task_id      uuid,
    org_id       uuid,
    deposited_at timestamptz not null default now()
);

-- Invariant 3 lives here: a gradient read is always AT A LOCUS, and this is
-- what makes that cheap.
create index idx_deposits_locus
    on workflow.deposits (locus_kind, locus, deposited_at desc);
create index idx_deposits_time on workflow.deposits using brin (deposited_at);
create index idx_deposits_org  on workflow.deposits (org_id) where org_id is not null;

-- APPEND-ONLY (invariant 4), enforced by the grant AND by a trigger. The grant
-- is the rule; the trigger is for the SECURITY DEFINER function written later
-- by someone who has not read this file, which runs as the owner -- and the
-- owner does hold UPDATE.
--
-- Retraction is a counter-deposit with polarity = -1, never a delete. The
-- reason is not bookkeeping: decay is computed from (amplitude, half_life,
-- deposited_at), so mutating any of them rewrites the past and every
-- as-of evaluation returns an answer that was never true.
revoke all on workflow.deposits from public;
grant select, insert on workflow.deposits to worker, authenticated;

create or replace function workflow.refuse_field_mutation() returns trigger as $$
begin
    raise exception
        '% is append-only (trace-field/brief.md invariant 4). Retract with a '
        'counter-deposit: the same locus with polarity = -1. A % here would '
        'rewrite the gradient''s past.', tg_table_name, tg_op;
end;
$$ language plpgsql;

create trigger trg_deposits_append_only
    before update or delete on workflow.deposits
    for each row execute function workflow.refuse_field_mutation();

-- ------------------------------------------------------------
-- 3. Anchors -- the one relation with genuinely nowhere else to live.
--
-- signal_task writes a payload bound to a RUN and only while that run waits.
-- auth_events records what a user did to the auth system. NOTHING anywhere
-- records "stop working here", "I have settled this", or "I care about this
-- before there is any evidence". That is what this is, and it is why it is a
-- table rather than a projection.
--
-- NO half_life COLUMN. An anchor is infinite by construction, not by
-- parameter: a column here is how a process eventually mints a permanent mark,
-- and the entire HITL design rests on human deposits being the ones that do
-- not fade.
--
-- AN ACT IS NOT A DEPOSIT KIND, and conflating them is a bug that reads as
-- correct. brief.md §4.4: a `resolution` settles a question AND anchors what
-- settled it. Stored as one row it lands in a gradient nobody reads. So one
-- act inserts as many deposits as it affects, sharing an act_id -- see §7.
-- ------------------------------------------------------------
create table workflow.anchors (
    anchor_id    uuid primary key default gen_random_uuid(),
    act          text not null
                     check (act in ('veto','interest','endorsement','resolution')),

    locus_kind   text not null
                     check (locus_kind in ('queue','step_key','definition','run','domain')),
    locus        text not null,

    -- From the verified token, never a parameter: claiming to be a person must
    -- not be free. NOT NULL with this default means a call with no verified
    -- user fails on the constraint rather than on politeness, so a direct
    -- INSERT cannot forge identity either.
    user_id      uuid not null default rbac.current_user_id()
                     references rbac.users(id),

    rationale    text,
    org_id       uuid,
    deposited_at timestamptz not null default now()
);

create index idx_anchors_locus on workflow.anchors (locus_kind, locus, deposited_at desc);
create index idx_anchors_user  on workflow.anchors (user_id, deposited_at desc);

revoke all on workflow.anchors from public;
grant select, insert on workflow.anchors to authenticated;
-- SELECT and NOT insert for the worker, deliberately: an anchor is a person's
-- act, and a process that can mint one has broken the only thing that makes
-- anchors mean anything.
grant select on workflow.anchors to worker;

create trigger trg_anchors_append_only
    before update or delete on workflow.anchors
    for each row execute function workflow.refuse_field_mutation();

-- ------------------------------------------------------------
-- 4. The gradient -- read-time, for views and for humans.
--
-- Not what claim_task reads. §5 is what claim_task reads, and the difference is
-- one index (brief.md §4.1): a read-time computed priority cannot be indexed,
-- and the claim path is the hottest in the engine.
--
-- VETO IS A PROPERTY OF THE LOCUS, NOT OF ONE DEPOSIT KIND. The obvious
-- spelling -- bool_or(...) inside this aggregate -- is scoped by the GROUP BY,
-- so a veto would suppress only the kind it landed in while every other
-- gradient at the locus went on recruiting. brief.md §4.4 is explicit that a
-- veto suppresses recruitment ENTIRELY, which is the whole reason it is
-- cheaper than a correction pass. So it is computed per locus and joined.
-- ------------------------------------------------------------
create or replace view workflow.v_gradient as
with vetoes as (
    select distinct locus_kind, locus from workflow.anchors where act = 'veto'
)
select
    d.locus_kind,
    d.locus,
    d.kind,
    sum(d.polarity * workflow.intensity(d.amplitude, d.half_life, d.deposited_at, now()))
                                                              as intensity,
    count(distinct d.origin_key) filter (where d.polarity > 0) as independent_origins,
    count(*)                     filter (where d.polarity > 0) as positive_deposits,
    bool_or(v.locus is not null)                               as vetoed,
    max(d.deposited_at) filter (where d.kind = 'anchor')       as last_anchor_at
from workflow.deposits d
left join vetoes v on v.locus_kind = d.locus_kind and v.locus = d.locus
group by 1, 2, 3;

-- The engine's own health, read as a field. Deliberately built from the
-- observability views that already exist rather than from a second count.
create or replace view workflow.v_field as
select
    'queue'::text                       as locus_kind,
    t.queue                             as locus,
    workflow.queue_depth(t.queue)       as depth,
    count(*) filter (where t.status = 'ready'
                       and t.run_after <= now())               as claimable,
    -- Starvation: ready work nobody has taken, weighted by how long it has
    -- waited. The metric brief.md §4.2's example activates on.
    coalesce(sum(extract(epoch from (now() - t.created_at)) / 3600.0)
             filter (where t.status = 'ready' and t.run_after <= now()), 0)
                                                               as starvation,
    coalesce(g.intensity, 0)                                   as reinforcement,
    coalesce(g.vetoed, false)                                  as vetoed
from workflow.tasks t
left join workflow.v_gradient g
       on g.locus_kind = 'queue' and g.locus = t.queue and g.kind = 'success'
where t.status in ('ready','running')
group by t.queue, g.intensity, g.vetoed;

-- ------------------------------------------------------------
-- 5. The settled form -- what claim_task actually reads.
--
-- THIS IS THE ONE PLACE THIS DESIGN DIVERGES FROM THE OBVIOUS ONE, and the
-- reason is worth stating where it is implemented rather than only in the
-- brief. tasks.priority is in idx_tasks_claimable (queue, priority, run_after)
-- and both claim functions order by it. A priority computed at read time
-- cannot be indexed, so every claim would become a sort over the ready set --
-- once per task per worker, on the hottest path in the engine.
--
-- So intensity is SETTLED periodically: one UPDATE per tick over ready tasks,
-- on the pg_cron minute that already runs tick(), promote_due_timers() and
-- reap_stale_tasks(). The claim path keeps reading a plain indexed integer and
-- nothing about claim_task changes at all.
--
-- The cost, stated: priority is stale by up to one tick. For a claim ORDERING
-- that is fine -- it is a preference, not a guarantee, and three other things
-- on this tick already tolerate a minute.
--
-- Calls workflow.intensity() rather than reimplementing decay, because two
-- implementations silently disagreeing is brief.md §7's named failure mode.
-- ------------------------------------------------------------
create or replace function workflow.settle_priority(
    p_age_weight numeric default 1.0,
    p_age_cap    numeric default 50.0)   -- brief.md §7: uncapped age starves
                                         -- interactive work. The cap is a
                                         -- guess until it has been run.
returns int as $$
declare v_n int;
begin
    with g as (
        select locus_kind, locus,
               sum(polarity * workflow.intensity(amplitude, half_life,
                                                 deposited_at, now())) as intensity,
               bool_or(a.locus is not null)                            as vetoed
        from workflow.deposits d
        left join (select distinct locus_kind, locus from workflow.anchors
                    where act = 'veto') a using (locus_kind, locus)
        group by 1, 2
    ),
    scored as (
        select t.id,
               greatest(0, least(1000, (100
                 -- Age: a task waiting is a strengthening trail. Capped,
                 -- because uncapped it inverts against interactive work.
                 + least(p_age_cap,
                         p_age_weight * extract(epoch from (now() - t.created_at)) / 3600.0)
                 + coalesce(gq.intensity, 0)
                 + coalesce(gs.intensity, 0)
               )::int)) as priority,
               coalesce(gq.vetoed, false) or coalesce(gs.vetoed, false) as vetoed
        from workflow.tasks t
        left join g gq on gq.locus_kind = 'queue'    and gq.locus = t.queue
        left join g gs on gs.locus_kind = 'step_key' and gs.locus = t.step_key
        where t.status = 'ready'
    )
    update workflow.tasks t
       -- A vetoed locus goes to the floor rather than being deleted or held:
       -- suppression is a gradient effect, so the work stays claimable if
       -- nothing else is and stops competing if anything is.
       set priority = case when s.vetoed then 0 else s.priority end
      from scored s
     where s.id = t.id
       and t.priority is distinct from (case when s.vetoed then 0 else s.priority end);

    get diagnostics v_n = row_count;
    return v_n;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- select cron.schedule('settle-priority', '* * * * *',
--                      $$select workflow.settle_priority()$$);

-- ------------------------------------------------------------
-- 6. Gradient activation -- promote_due_timers' sibling.
--
-- The engine already has exactly one activation source that is not a DAG edge:
-- promote_due_timers() moves a `timer` task to ready when a clock passes. A
-- clock is a degenerate gradient, so this is the same shape on the same tick,
-- and it is deliberately the NARROWEST version of brief.md §3.1's gap: one
-- more promotion source, no new execution path, no listener, no process.
--
-- HETEROGENEOUS THRESHOLDS OVER ONE FIELD IS THE POINT, not a side effect. Two
-- definitions with different `above:` on one metric specialise -- one taking
-- strong signals, one sweeping weak ones -- with nobody assigning either a
-- role, and re-tuning the division of labour is an UPDATE.
-- ------------------------------------------------------------
create or replace function workflow.promote_due_gradients()
returns int as $$
declare v_n int := 0;
begin
    update workflow.tasks t
       set status = 'ready'
      from workflow.v_field f
     where t.kind   = 'gradient'
       and t.status = 'pending'
       and f.locus  = t.input->>'locus'
       and not f.vetoed
       -- The metric is named in the task input and read off the field view, so
       -- adding a metric is a column there rather than a change here.
       and case t.input->>'metric'
             when 'starvation'    then f.starvation
             when 'depth'         then f.depth::numeric
             when 'reinforcement' then f.reinforcement
           end >= (t.input->>'above')::numeric;

    get diagnostics v_n = row_count;
    return v_n;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- Requires: alter the tasks kind constraint to admit 'gradient', and teach the
-- compiler a `gradient:` action key. Both are one line; neither is written.
-- workflow-engine/roadmap.md §5 carries the trigger.

-- ------------------------------------------------------------
-- 7. Anchoring, and elicitation.
--
-- SECURITY DEFINER with an explicit org check, for the reason
-- content.register_upload documents: identity comes from the verified token,
-- never from the role, because inside a definer function current_user is the
-- definer and session_user is one shared PostgREST login.
--
-- There is no agent-facing deposit function and there should not be. An
-- agent's deposit is its work: a task completing reinforces its loci through
-- §8's fold. A function letting an agent write the field directly would let it
-- reinforce itself without doing anything, which is invariant 5 defeated at
-- the front door.
-- ------------------------------------------------------------
create or replace function workflow.anchor(p_spec jsonb)
returns uuid as $$
declare
    v_act text := p_spec->>'act';
    v_id  uuid;
begin
    if rbac.current_user_id() is null then
        raise exception
            'an anchor is a person''s judgement and this call has no user '
            'identity. A process cannot anchor (trace-field/brief.md §4.4).';
    end if;
    if not content.may_access_org((p_spec->>'org_id')::uuid) then
        raise exception 'not authorized to anchor for that organization';
    end if;

    insert into workflow.anchors (act, locus_kind, locus, rationale, org_id)
    values (v_act, p_spec->>'locus_kind', p_spec->>'locus',
            p_spec->>'rationale', (p_spec->>'org_id')::uuid)
    returning anchor_id into v_id;

    -- ONE ACT, AS MANY DEPOSITS AS IT AFFECTS, sharing the anchor's origin.
    -- The mapping is brief.md §4.4's table and it lives here rather than in a
    -- caller, because a caller that spells `resolution` as one deposit gets a
    -- permanent mark in a gradient nothing reads.
    --
    -- veto deposits nothing: its effect is the suppression join in §4 and §5,
    -- not an amplitude. A negative deposit would be outweighed by enough
    -- positive ones, and "kills a bad path and it stays killed" is the whole
    -- point of it.
    insert into workflow.deposits (locus_kind, locus, kind, amplitude, polarity,
                                   half_life, origin_key, org_id)
    select p_spec->>'locus_kind', p_spec->>'locus', 'anchor',
           e.amplitude, e.polarity, 'infinity'::interval,
           -- The PERSON is the origin. Two anchors by one reviewer are one
           -- origin, exactly as ten news reports of one filing are
           -- (world-model-ingestion/tradecraft.md §8.2).
           'user:' || rbac.current_user_id()::text,
           (p_spec->>'org_id')::uuid
      from (values
        ('interest',    25.0::numeric,  1::smallint),
        ('endorsement', 25.0::numeric,  1::smallint),
        ('resolution',  50.0::numeric, -1::smallint)   -- settles the question
      ) as e(act, amplitude, polarity)
     where e.act = v_act;

    return v_id;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

revoke execute on function workflow.anchor(jsonb) from public;
grant execute on function workflow.anchor(jsonb) to authenticated;

-- What a stuck agent does INSTEAD of holding a signal step open (brief.md
-- §4.5). The task that calls this completes `succeeded` -- that is the whole
-- claim, and it is one column.
--
-- THE BUDGET IS THE PART THAT MATTERS and it is not enforced here, which is
-- honest rather than deferred: this function is called BY a registered
-- function, so a forager that ignores its budget simply does not call it. Only
-- a step kind can enforce a budget the step itself cannot skip, and that is
-- the real argument for `forager:` -- workflow-engine/roadmap.md §5.
create or replace function workflow.elicit(
    p_locus_kind text, p_locus text, p_question text,
    p_task_id uuid default null, p_org_id uuid default null)
returns bigint as $$
    insert into workflow.deposits (locus_kind, locus, kind, amplitude, polarity,
                                   half_life, origin_key, task_id, org_id)
    values (p_locus_kind, p_locus, 'question', 1.0, 1,
            interval '21 days',   -- a question nobody re-asked in three weeks
                                  -- was not important, and removes itself
            coalesce(p_task_id::text, 'anonymous'), p_task_id, p_org_id)
    returning deposit_id;
$$ language sql security definer set search_path = pg_catalog, public;

grant execute on function workflow.elicit(text, text, text, uuid, uuid) to worker, authenticated;

-- The review queue is not a queue. It is the gradient with a different
-- projection: human attention allocated by the same mechanism as task
-- activation, with the same tuning surface.
create or replace view workflow.v_attention as
select g.locus_kind, g.locus, g.intensity, g.independent_origins,
       g.intensity * log(2 + g.positive_deposits) as priority
from workflow.v_gradient g
where g.kind = 'question'
  and g.intensity > 0
  and not g.vetoed
order by priority desc;

-- ------------------------------------------------------------
-- 8. Reinforcement -- a fold over a log the engine already keeps.
--
-- Deneubourg's binary-bridge result is that path selection emerges from
-- reinforcement plus evaporation and needs nothing else: no comparison and no
-- global view. This engine has evaporation (run_after backoff, lease reaping,
-- rate-limit refill) and no reinforcement at all -- a step kind that has
-- succeeded four hundred times is exactly as attractive as one that has never
-- run.
--
-- Everything needed is already in task_events. This is the fold, on the tick.
--
-- HALF-LIFE IS A PARAMETER AND MUST NOT BE GUESSED UP FRONT. brief.md §7 names
-- thrash-vs-lock-in as the most likely way this goes wrong: too fast and
-- nothing converges, too slow and a queue that failed twice on a bad day
-- starves forever. One tuning axis, empirical.
-- ------------------------------------------------------------
create or replace function workflow.deposit_reinforcement(
    p_since     timestamptz,
    p_half_life interval default interval '4 hours')
returns int as $$
declare v_n int;
begin
    insert into workflow.deposits (locus_kind, locus, kind, amplitude, polarity,
                                   half_life, origin_key, run_id, task_id, org_id)
    select 'step_key', t.step_key,
           case when e.to_status = 'done' then 'success' else 'failure' end,
           1.0,
           case when e.to_status = 'done' then 1 else -1 end,
           p_half_life,
           -- ORIGIN IS THE RUN, NOT THE TASK (invariant 5). A fan-out of five
           -- hundred children is ONE run doing one thing five hundred times;
           -- counting each child as an independent origin is manufactured
           -- coherence with the mitigation removed.
           'run:' || e.run_id::text,
           e.run_id, e.task_id, r.org_id
    from workflow.task_events e
    join workflow.tasks t on t.id = e.task_id
    left join workflow.runs r on r.id = e.run_id
    where e.at > p_since
      and e.to_status in ('done','failed');

    get diagnostics v_n = row_count;
    return v_n;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 9. RLS and the ownership split.
--
-- Shaped like content.resources', including the shared tier: org_id null is
-- readable by everyone, because an engine-tier locus (a queue, a step key)
-- legitimately belongs to no tenant.
--
-- api_viewer owns the views, app_owner owns the tables. An owner-privileged
-- view owned by the TABLE owner bypasses RLS exactly as a superuser does, so
-- this is the line that makes the policies real; §0 asserts the other half.
--
-- THE CONSEQUENCE, left open in brief.md §10: a gradient is a PER-CALLER
-- number. Two tenants at one locus see different intensities, so a gradient
-- step's threshold fires per tenant. settle_priority() deliberately runs as
-- the DEFINER over all rows -- claim ordering is an engine-global property and
-- cannot be per-caller -- which means priority leaks a coarse signal about
-- other tenants' load. That is a real trade and not a technicality.
-- ------------------------------------------------------------
alter table workflow.deposits enable row level security;
alter table workflow.anchors  enable row level security;

create policy deposits_org_scoped on workflow.deposits for select
    using (org_id is null or org_id in (select aiq.current_org_ids()));
create policy deposits_insert_own_org on workflow.deposits for insert
    with check (content.may_access_org(org_id));

create policy anchors_org_scoped on workflow.anchors for select
    using (org_id is null or org_id in (select aiq.current_org_ids()));
create policy anchors_insert_own_org on workflow.anchors for insert
    with check (content.may_access_org(org_id));

alter view workflow.v_gradient  owner to api_viewer;
alter view workflow.v_field     owner to api_viewer;
alter view workflow.v_attention owner to api_viewer;

grant select on workflow.deposits, workflow.anchors to api_viewer;
grant select on workflow.v_gradient, workflow.v_field, workflow.v_attention
    to authenticated;

-- ------------------------------------------------------------
-- 10. What is deliberately absent.
--
--   * NO change to claim_task. It reads a plain indexed integer exactly as it
--     does today, which is the point of §5 and the reason this is cheap.
--   * NO dispatcher, assignment or addressee. brief.md invariant 1. Every
--     addition here is a deposit or a threshold; none of them routes work to
--     anybody.
--   * NO agent-facing deposit function. §7. An agent deposits by working.
--   * NO forager table. A forager is a workflow definition plus a schedule row
--     -- a scheduled `matrix:` over a registered function already is one. A
--     third place to describe one is a third place for them to disagree.
--   * NO elicitation budget table. §7 is honest that this function cannot
--     enforce one; the step kind that could is roadmap.md §5, and its trigger
--     is sequence.md phase 5.
--   * NO replacement for `signal:`. Blocking is right for a named approver on
--     one run. brief.md §3.4 objects to it being the ONLY spelling.
-- ------------------------------------------------------------
