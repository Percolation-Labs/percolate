-- ============================================================
-- A RESEARCH PROGRAMME'S PROTOCOLS, RUNS AND DECISIONS AS DATA (REM-594, core-research-programme.md §R1)
-- ============================================================
--
-- A small registry on records core already keeps. A protocol's document is a research revision and its corpus is a
-- list of revision ids; a run may name the workflow run that executed it. What is added is only what nothing else
-- holds: which protocol was frozen and when, which run used which inputs, what it produced, how it was judged and
-- what was decided. Not a scheduler, an agent framework or a second research store.
--
-- EVERYTHING IS HISTORY. Each table is insert-only under research.refuse_rewrite. A freeze and a result are rows of
-- their own rather than updates, so a frozen protocol cannot change and a scored result cannot be rewritten: an
-- amendment is a new protocol that names the one it amends, and a new run. The lifecycle is read from the rows:
-- draft -> frozen -> running -> completed | failed | stopped -> reviewed. A stopped run keeps its partial outputs,
-- failures and usage. The execution state says nothing about scientific validity; a decision does, and only a person
-- makes one (research:endorse, which is human-only).
--
-- REVISIONS ARE REFERENCED, NOT OWNED. document_revision and corpus hold ids without foreign keys: a frozen
-- protocol cannot change, and an erased or no longer readable revision must not rewrite it. The export asks
-- research.revision_readable of each at the time of the export and says "unavailable" when the caller may not read
-- it, so a complete export never leaks a protected input.
--
-- ACCESS. A programme is its owner's. Every table carries programme_id, and row security asks
-- research.programme_owned of it; the write functions ask it too, and refuse what the caller cannot see as not found.

create table if not exists research.programmes (
    id         uuid primary key default uuidv7(),
    owner_id   uuid not null references rbac.users(id),
    question   text not null check (length(btrim(question)) > 0),
    objective  text not null default '',
    -- allowed sources and tools, time and spend limits, stop conditions: the owner's statement, kept as written
    bounds     jsonb not null default '{}'::jsonb check (jsonb_typeof(bounds) = 'object'),
    created_at timestamptz not null default now()
);

create table if not exists research.protocols (
    id                uuid primary key default uuidv7(),
    programme_id      uuid not null references research.programmes(id),
    number            int not null check (number > 0),
    amends            uuid references research.protocols(id),
    document_revision uuid,
    corpus            uuid[] not null default '{}',
    -- hypotheses, comparators, exclusions, metrics and thresholds, code and method versions
    manifest          jsonb not null check (jsonb_typeof(manifest) = 'object'),
    manifest_hash     text not null,
    created_at        timestamptz not null default now(),
    unique (programme_id, number)
);

create table if not exists research.protocol_freezes (
    id           uuid primary key default uuidv7(),
    programme_id uuid not null references research.programmes(id),
    protocol_id  uuid not null unique references research.protocols(id),
    frozen_by    uuid references rbac.users(id),
    frozen_at    timestamptz not null default now()
);

create table if not exists research.programme_runs (
    id           uuid primary key default uuidv7(),
    programme_id uuid not null references research.programmes(id),
    protocol_id  uuid not null references research.protocols(id),
    -- the caller's name for this run: a retry sends the same key and the same inputs and gets the same run
    run_key      text not null check (length(btrim(run_key)) > 0),
    inputs       jsonb not null default '{}'::jsonb check (jsonb_typeof(inputs) = 'object'),
    inputs_hash  text not null,
    workflow_run uuid,
    started_by   uuid references rbac.users(id),
    started_at   timestamptz not null default now(),
    unique (protocol_id, run_key)
);

create table if not exists research.run_results (
    id           uuid primary key default uuidv7(),
    programme_id uuid not null references research.programmes(id),
    run_id       uuid not null unique references research.programme_runs(id),
    state        text not null check (state in ('completed', 'failed', 'stopped')),
    outputs      jsonb not null default '{}'::jsonb,
    failures     jsonb not null default '[]'::jsonb,
    usage        jsonb not null default '{}'::jsonb,
    result_hash  text not null,
    recorded_by  uuid references rbac.users(id),
    recorded_at  timestamptz not null default now()
);

create table if not exists research.run_evaluations (
    id            uuid primary key default uuidv7(),
    programme_id  uuid not null references research.programmes(id),
    run_id        uuid not null references research.programme_runs(id),
    evaluator     text not null,
    method        text not null,
    items         jsonb not null default '[]'::jsonb,
    disagreements jsonb not null default '[]'::jsonb,
    uncertainty   jsonb not null default '{}'::jsonb,
    recorded_by   uuid references rbac.users(id),
    recorded_at   timestamptz not null default now()
);

create table if not exists research.run_decisions (
    id           uuid primary key default uuidv7(),
    programme_id uuid not null references research.programmes(id),
    run_id       uuid not null references research.programme_runs(id),
    verdict      text not null check (verdict in ('supported', 'rejected', 'inconclusive')),
    cited        jsonb not null default '{}'::jsonb,
    reviewer_id  uuid not null references rbac.users(id),
    next_check   text,
    reopen_when  text,
    decided_at   timestamptz not null default now()
);

create index if not exists protocols_by_programme on research.protocols (programme_id, number);
create index if not exists runs_by_programme on research.programme_runs (programme_id);
create index if not exists evaluations_by_run on research.run_evaluations (run_id);
create index if not exists decisions_by_run on research.run_decisions (run_id, decided_at);

do $$
declare t text;
begin
    foreach t in array array['research.programmes', 'research.protocols', 'research.protocol_freezes',
                             'research.programme_runs', 'research.run_results', 'research.run_evaluations',
                             'research.run_decisions'] loop
        execute format('create or replace trigger trg_refuse_rewrite before update or delete on %s '
                       'for each row execute function research.refuse_rewrite()', t);
        execute format('create or replace trigger trg_refuse_truncate before truncate on %s '
                       'for each statement execute function research.refuse_rewrite()', t);
    end loop;
end $$;

-- The one access question, asked by every policy and every write below.
create or replace function research.programme_owned(p_programme uuid) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
    select exists (select 1 from research.programmes p
                    where p.id = p_programme and p.owner_id = rbac.current_user_id());
$$;

do $$
declare t text;
begin
    foreach t in array array['protocols', 'protocol_freezes', 'programme_runs', 'run_results', 'run_evaluations',
                             'run_decisions'] loop
        execute format('alter table research.%I enable row level security', t);
        execute format('drop policy if exists owner_reads on research.%I', t);
        execute format('create policy owner_reads on research.%I for select using (research.programme_owned(programme_id))', t);
    end loop;
end $$;
alter table research.programmes enable row level security;
drop policy if exists owner_reads on research.programmes;
create policy owner_reads on research.programmes for select using (owner_id = rbac.current_user_id());

grant select on research.programmes, research.protocols, research.protocol_freezes, research.programme_runs,
                research.run_results, research.run_evaluations, research.run_decisions to authenticated;

create or replace function research.programme_hash(p jsonb) returns text
language sql immutable set search_path = pg_catalog, public as $$
    select encode(sha256(convert_to(p::text, 'UTF8')), 'hex');
$$;

-- Not found, to anybody who does not own it: the same answer for another person's programme and for none.
create or replace function research.require_programme(p_programme uuid) returns void
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
    if p_programme is null or not research.programme_owned(p_programme) then
        raise no_data_found using message = 'Programme not found';
    end if;
end;
$$;

create or replace function research.programme_create(p_question text, p_objective text default '',
                                                      p_bounds jsonb default '{}'::jsonb) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_user uuid := rbac.require('research', 'insert'); v_id uuid;
begin
    insert into research.programmes (owner_id, question, objective, bounds)
    values (v_user, p_question, coalesce(p_objective, ''), coalesce(p_bounds, '{}'::jsonb))
    returning id into v_id;
    return v_id;
end;
$$;

-- A protocol is a draft until it is frozen. A draft cannot change either: a new draft names the one it amends.
-- Every revision it cites must be readable to its owner when it is written.
create or replace function research.protocol_draft(p_programme uuid, p_manifest jsonb,
                                                   p_document_revision uuid default null,
                                                   p_corpus uuid[] default '{}', p_amends uuid default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid; v_bad uuid;
begin
    perform research.require_programme(p_programme);
    if p_amends is not null and not exists (select 1 from research.protocols
                                             where id = p_amends and programme_id = p_programme) then
        raise invalid_parameter_value using message = 'A protocol amends another protocol of the same programme';
    end if;
    select r into v_bad from unnest(array_append(coalesce(p_corpus, '{}'), p_document_revision)) r
     where r is not null and not research.revision_readable(r) limit 1;
    if v_bad is not null then
        raise no_data_found using message = format('Revision %s not found', v_bad);
    end if;
    insert into research.protocols (programme_id, number, amends, document_revision, corpus, manifest, manifest_hash)
    select p_programme, coalesce(max(number), 0) + 1, p_amends, p_document_revision, coalesce(p_corpus, '{}'),
           p_manifest, research.programme_hash(p_manifest)
      from research.protocols where programme_id = p_programme
    returning id into v_id;
    return v_id;
end;
$$;

-- Freezing is once. Freezing again answers the same hash.
create or replace function research.protocol_freeze(p_protocol uuid) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare p research.protocols;
begin
    select * into p from research.protocols where id = p_protocol;
    perform research.require_programme(p.programme_id);
    insert into research.protocol_freezes (programme_id, protocol_id, frozen_by)
    values (p.programme_id, p.id, rbac.current_user_id())
    on conflict (protocol_id) do nothing;
    return p.manifest_hash;
end;
$$;

-- A run starts only on a frozen protocol. The same key with the same inputs is a retry and answers the same run;
-- the same key with other inputs is refused, because a key names one run.
create or replace function research.run_start(p_protocol uuid, p_key text, p_inputs jsonb default '{}'::jsonb,
                                              p_workflow_run uuid default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare p research.protocols; r research.programme_runs; v_hash text := research.programme_hash(coalesce(p_inputs, '{}'));
begin
    select * into p from research.protocols where id = p_protocol;
    perform research.require_programme(p.programme_id);
    if not exists (select 1 from research.protocol_freezes where protocol_id = p.id) then
        raise object_not_in_prerequisite_state using message = 'Freeze the protocol before a run starts',
            hint = 'research.protocol_freeze(protocol); an amendment is a new protocol';
    end if;
    select * into r from research.programme_runs where protocol_id = p.id and run_key = p_key;
    if found then
        if r.inputs_hash <> v_hash then
            raise unique_violation using message = format('Run %s already started with other inputs', p_key),
                hint = 'A retry sends the same inputs; different inputs are a new key';
        end if;
        return r.id;
    end if;
    insert into research.programme_runs (programme_id, protocol_id, run_key, inputs, inputs_hash, workflow_run, started_by)
    values (p.programme_id, p.id, p_key, coalesce(p_inputs, '{}'), v_hash, p_workflow_run, rbac.current_user_id())
    returning id into r.id;
    return r.id;
end;
$$;

-- A run ends once: completed, failed or stopped, with what it produced, what failed and what it cost. Sending the
-- same result again answers its state; a different one is refused, since a scored result cannot be rewritten.
create or replace function research.run_finish(p_run uuid, p_state text, p_outputs jsonb default '{}'::jsonb,
                                               p_failures jsonb default '[]'::jsonb, p_usage jsonb default '{}'::jsonb)
returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r research.programme_runs; v_hash text; v_have text;
begin
    select * into r from research.programme_runs where id = p_run;
    perform research.require_programme(r.programme_id);
    v_hash := research.programme_hash(jsonb_build_object('state', p_state, 'outputs', coalesce(p_outputs, '{}'),
                                                         'failures', coalesce(p_failures, '[]'),
                                                         'usage', coalesce(p_usage, '{}')));
    select result_hash into v_have from research.run_results where run_id = r.id;
    if found then
        if v_have <> v_hash then
            raise restrict_violation using message = 'This run already has a result, and a result is not rewritten',
                hint = 'Amend the protocol and start a new run';
        end if;
        return p_state;
    end if;
    insert into research.run_results (programme_id, run_id, state, outputs, failures, usage, result_hash, recorded_by)
    values (r.programme_id, r.id, p_state, coalesce(p_outputs, '{}'), coalesce(p_failures, '[]'),
            coalesce(p_usage, '{}'), v_hash, rbac.current_user_id());
    return p_state;
end;
$$;

create or replace function research.run_evaluate(p_run uuid, p_evaluator text, p_method text,
                                                 p_items jsonb default '[]'::jsonb,
                                                 p_disagreements jsonb default '[]'::jsonb,
                                                 p_uncertainty jsonb default '{}'::jsonb) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r research.programme_runs; v_id uuid;
begin
    select * into r from research.programme_runs where id = p_run;
    perform research.require_programme(r.programme_id);
    if not exists (select 1 from research.run_results where run_id = r.id) then
        raise object_not_in_prerequisite_state using message = 'Evaluate a run once it has a result';
    end if;
    insert into research.run_evaluations (programme_id, run_id, evaluator, method, items, disagreements, uncertainty,
                                          recorded_by)
    values (r.programme_id, r.id, p_evaluator, p_method, coalesce(p_items, '[]'), coalesce(p_disagreements, '[]'),
            coalesce(p_uncertainty, '{}'), rbac.current_user_id())
    returning id into v_id;
    return v_id;
end;
$$;

-- A decision is a person's: research:endorse is human-only, so an agent's credential is refused whatever it holds.
-- A later decision on the same run is a new row; the latest is current, and the earlier ones stay.
create or replace function research.run_review(p_run uuid, p_verdict text, p_cited jsonb default '{}'::jsonb,
                                               p_next_check text default null, p_reopen_when text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_user uuid := rbac.require('research', 'endorse'); r research.programme_runs; v_id uuid;
begin
    select * into r from research.programme_runs where id = p_run;
    perform research.require_programme(r.programme_id);
    if not exists (select 1 from research.run_results where run_id = r.id) then
        raise object_not_in_prerequisite_state using message = 'Review a run once it has a result';
    end if;
    insert into research.run_decisions (programme_id, run_id, verdict, cited, reviewer_id, next_check, reopen_when)
    values (r.programme_id, r.id, p_verdict, coalesce(p_cited, '{}'), v_user, p_next_check, p_reopen_when)
    returning id into v_id;
    return v_id;
end;
$$;

-- The lifecycle, read from the rows. Null for a run the caller may not read.
create or replace function research.run_state(p_run uuid) returns text
language sql stable security invoker set search_path = pg_catalog, public as $$
    select case when exists (select 1 from research.run_decisions d where d.run_id = r.id) then 'reviewed'
                else coalesce((select x.state from research.run_results x where x.run_id = r.id), 'running') end
      from research.programme_runs r where r.id = p_run;
$$;

create or replace function research.protocol_state(p_protocol uuid) returns text
language sql stable security invoker set search_path = pg_catalog, public as $$
    select case when exists (select 1 from research.protocol_freezes f where f.protocol_id = p.id) then 'frozen'
                else 'draft' end
      from research.protocols p where p.id = p_protocol;
$$;

-- A revision a protocol cites, as the caller may see it now: its work and label, or unavailable.
create or replace function research.programme_revision_ref(p_revision uuid) returns jsonb
language sql stable security invoker set search_path = pg_catalog, public as $$
    select case when p_revision is null then null
                when research.revision_readable(p_revision) then
                     (select jsonb_build_object('revision_id', v.id, 'work', w.public_id, 'label', v.label)
                        from research.revisions v join research.works w on w.id = v.work_id where v.id = p_revision)
                else jsonb_build_object('revision_id', p_revision, 'unavailable', true) end;
$$;

-- The complete record of a programme: every protocol with its manifest and hash, every run with its inputs, result,
-- evaluations and decisions. Row security scopes it, so it is null to anybody but the owner; a cited revision the
-- owner can no longer read is "unavailable", never its content.
create or replace function research.programme_export(p_programme uuid) returns jsonb
language sql stable security invoker set search_path = pg_catalog, public as $$
    select jsonb_build_object(
        'programme', jsonb_build_object('id', g.id, 'question', g.question, 'objective', g.objective,
                                        'bounds', g.bounds, 'created_at', g.created_at),
        'protocols', coalesce((select jsonb_agg(jsonb_build_object(
                'number', p.number, 'id', p.id,
                'amends', (select a.number from research.protocols a where a.id = p.amends),
                'state', research.protocol_state(p.id),
                'frozen_at', (select f.frozen_at from research.protocol_freezes f where f.protocol_id = p.id),
                'manifest', p.manifest, 'manifest_hash', p.manifest_hash,
                'document', research.programme_revision_ref(p.document_revision),
                'corpus', coalesce((select jsonb_agg(research.programme_revision_ref(c) order by o)
                                      from unnest(p.corpus) with ordinality u(c, o)), '[]'::jsonb))
                order by p.number) from research.protocols p where p.programme_id = g.id), '[]'::jsonb),
        'runs', coalesce((select jsonb_agg(jsonb_build_object(
                'id', r.id, 'key', r.run_key,
                'protocol', (select p.number from research.protocols p where p.id = r.protocol_id),
                'inputs', r.inputs, 'inputs_hash', r.inputs_hash, 'workflow_run', r.workflow_run,
                'started_at', r.started_at, 'state', research.run_state(r.id),
                'result', (select jsonb_build_object('state', x.state, 'outputs', x.outputs, 'failures', x.failures,
                                                     'usage', x.usage, 'result_hash', x.result_hash,
                                                     'recorded_at', x.recorded_at)
                             from research.run_results x where x.run_id = r.id),
                'evaluations', coalesce((select jsonb_agg(jsonb_build_object(
                        'evaluator', e.evaluator, 'method', e.method, 'items', e.items,
                        'disagreements', e.disagreements, 'uncertainty', e.uncertainty, 'recorded_at', e.recorded_at)
                        order by e.recorded_at, e.id) from research.run_evaluations e where e.run_id = r.id), '[]'::jsonb),
                'decisions', coalesce((select jsonb_agg(jsonb_build_object(
                        'verdict', d.verdict, 'cited', d.cited, 'next_check', d.next_check,
                        'reopen_when', d.reopen_when, 'decided_at', d.decided_at)
                        order by d.decided_at, d.id) from research.run_decisions d where d.run_id = r.id), '[]'::jsonb))
                order by r.started_at, r.id) from research.programme_runs r where r.programme_id = g.id), '[]'::jsonb))
      from research.programmes g where g.id = p_programme;
$$;

grant execute on function
    research.programme_create(text, text, jsonb), research.protocol_draft(uuid, jsonb, uuid, uuid[], uuid),
    research.protocol_freeze(uuid), research.run_start(uuid, text, jsonb, uuid),
    research.run_finish(uuid, text, jsonb, jsonb, jsonb),
    research.run_evaluate(uuid, text, text, jsonb, jsonb, jsonb),
    research.run_review(uuid, text, jsonb, text, text), research.run_state(uuid), research.protocol_state(uuid),
    research.programme_export(uuid), research.programme_owned(uuid), research.programme_revision_ref(uuid)
to authenticated;
