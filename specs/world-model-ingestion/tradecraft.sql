-- ============================================================================
-- tradecraft -- the grading, corroboration and track-record layer.
--
-- Companion DDL for tradecraft.md. Nothing here is invented: the grading model
-- is NATO AJP-2.1 (the Admiralty Code, in use since 1939), the likelihood
-- lexicon is ICD 203 (2007, rev. 2015), and the corroboration rule is
-- Bellingcat's Yemen collection protocol. The contribution is turning three
-- prose standards into constraints a database enforces.
--
-- Load order: after sources.sql / connectors.sql (references content.connectors).
-- ============================================================================
create schema if not exists tradecraft;

-- ----------------------------------------------------------------------------
-- 1. The likelihood lexicon -- ICD 203, as data
--
-- Seven terms with numeric bands. The point of loading it as a TABLE rather
-- than documenting it is that a foreign key then makes an unlisted term
-- impossible, and "likely" cannot drift to mean 90% in one product and 60% in
-- the next. Without a fixed lexicon there is nothing to score a forecaster
-- against, which is why this table and the resolution ledger (§6) are the same
-- project.
-- ----------------------------------------------------------------------------
create table if not exists tradecraft.likelihood (
    term      text primary key,
    alt_term  text not null,
    lo        numeric not null check (lo between 0 and 1),
    hi        numeric not null check (hi between 0 and 1),
    midpoint  numeric generated always as ((lo + hi) / 2) stored,
    check (hi > lo)
);

insert into tradecraft.likelihood (term, alt_term, lo, hi) values
    ('almost no chance',    'remote',            0.01, 0.05),
    ('very unlikely',       'highly improbable', 0.05, 0.20),
    ('unlikely',            'improbable',        0.20, 0.45),
    ('roughly even chance', 'roughly even odds', 0.45, 0.55),
    ('likely',              'probable',          0.55, 0.80),
    ('very likely',         'highly probable',   0.80, 0.95),
    ('almost certain',      'nearly certain',    0.95, 0.99)
on conflict (term) do nothing;

-- ----------------------------------------------------------------------------
-- 2. Evidence classes -- the corroboration primitive
--
-- Bellingcat's Yemen protocol requires three independent sources FROM DIFFERENT
-- CHANNELS, and treats satellite imagery as able to authenticate with fewer
-- sources because it is a different KIND of evidence rather than another
-- instance of the same kind.
--
-- `derives_from` is the load-bearing column. Three media reports quoting one
-- filing are ONE source, and the only way a database can know that is if the
-- news class declares that it derives from registry and filing classes.
-- Counting classes without modelling derivation just moves the error.
-- ----------------------------------------------------------------------------
create table if not exists tradecraft.evidence_classes (
    class        text primary key,
    description  text not null,
    -- classes this one commonly restates rather than independently observes
    derives_from text[] not null default '{}',
    -- a class that can carry an assessment with fewer corroborating sources
    -- (satellite imagery in the Bellingcat rule); deterministic, hard to fake
    standalone   boolean not null default false
);

insert into tradecraft.evidence_classes (class, description, derives_from, standalone) values
    ('registry',    'statutory register or official filing',            '{}',                        true),
    ('court',       'court docket, judgment or listing',                '{}',                        true),
    ('sensor',      'instrument reading -- satellite, seismic, AIS, ADS-B', '{}',                    true),
    ('filing',      'regulated disclosure by the subject itself',       '{}',                        false),
    ('igo_report',  'IGO or NGO field reporting',                       '{}',                        false),
    ('forecast',    'prediction market or forecaster question',         '{}',                        false),
    ('news',        'journalism',                    '{registry,court,filing,igo_report}',           false),
    ('social',      'user-generated content',        '{news,registry,filing}',                       false),
    ('attention',   'traffic or search interest',    '{news,social}',                                false),
    ('leak',        'leaked or contributed document collection',        '{}',                        false)
on conflict (class) do nothing;

-- ----------------------------------------------------------------------------
-- 3. Source reliability -- the Admiralty LETTER, on the source
--
-- A property of the source's history, not of any one report. Deliberately
-- separate from content.connectors.health: health is "is it responding", this
-- is "has it been right". A connector can be perfectly healthy and grade E.
--
-- Every source starts at F. That is not a placeholder -- F means "no basis
-- exists for evaluating reliability", which is the honest grade for a source
-- with no track record, and it stays F until outcomes are observed (§6).
-- ----------------------------------------------------------------------------
create table if not exists tradecraft.source_reliability (
    connector_id text primary key references content.connectors(id) on delete cascade,
    grade        char(1) not null default 'F' check (grade in ('A','B','C','D','E','F')),
    basis        text,                 -- what the grade rests on
    n_resolved   int not null default 0,
    graded_at    timestamptz not null default now()
);

comment on column tradecraft.source_reliability.grade is
 'A completely reliable / B usually / C fairly / D not usually / E unreliable / '
 'F cannot be judged (no basis). NATO AJP-2.1.';

-- ----------------------------------------------------------------------------
-- 4. Assessments -- what we are willing to say, and ICD 203 Standard 7
--
-- Append-only, and the append-only-ness IS the feature. Standard 7 requires a
-- product to state consistency with, or change from, previously published
-- analysis. Every newsroom and every dashboard fails this, and it is the
-- easiest of the nine to automate because it needs no judgement -- only a
-- stable key and a history nobody deletes.
--
-- Two consequences fall out for free: a score that MOVES is itself a lead even
-- when neither endpoint is, and Standard 8 (accuracy) is unmeasurable without
-- this history, so a track record is impossible without it.
-- ----------------------------------------------------------------------------
create table if not exists tradecraft.assessments (
    id             uuid primary key default gen_random_uuid(),
    -- the stable thing being assessed across time; changes to the STATEMENT
    -- make a new row, changes of MIND make a new row with the same subject_key
    subject_key    text not null,
    statement      text not null,
    -- ICD 203 §2: likelihood is about the world
    likelihood     text references tradecraft.likelihood(term),
    -- ICD 203 §2: confidence is about the evidence. NEVER the same sentence.
    confidence     text check (confidence in ('low','moderate','high')),
    -- the Admiralty NUMBER: credibility of this specific report
    credibility    int check (credibility between 1 and 6),
    -- ICD 203 §3: what is observed vs what is inferred, kept apart
    evidence       jsonb not null default '[]',   -- [{class, connector_id, ref}]
    assumptions    text[] not null default '{}',
    -- ICD 203 §4: alternatives considered
    alternatives   text[] not null default '{}',
    -- Standard 7: the row this supersedes, and why
    supersedes     uuid references tradecraft.assessments(id),
    change_reason  text,
    author         text not null,
    published_at   timestamptz not null default now(),
    -- a forward date makes an assessment RESOLVABLE; without one it can never
    -- be scored, which is a property worth making visible rather than implicit
    resolves_by    timestamptz,
    check (supersedes is null or change_reason is not null)
);

create index if not exists assessments_subject_key_published_at_idx on tradecraft.assessments (subject_key, published_at desc);
create index if not exists assessments_resolves_by_idx on tradecraft.assessments (resolves_by) where resolves_by is not null;

-- ICD 203's explicit prohibition, enforced rather than documented: a product
-- must not combine a confidence level and a degree of likelihood in one
-- statement. "High confidence that it is likely" is meaningless -- one is about
-- the evidence, the other about the world.
create or replace function tradecraft.assessments_check() returns trigger as $$
begin
    if new.statement ~* '\y(low|moderate|high)\s+confidence\y'
       and new.statement ~* '\y(likely|unlikely|probable|improbable|almost certain|even chance)\y'
    then
        raise exception 'ICD 203: do not combine a confidence level and a likelihood in one statement'
            using errcode = 'check_violation';
    end if;
    -- An unresolvable assessment is allowed but must not claim a likelihood:
    -- a probability nobody can ever score is decoration.
    if new.likelihood is not null and new.resolves_by is null then
        raise exception 'an assessment carrying a likelihood needs resolves_by, or it can never be scored'
            using errcode = 'check_violation';
    end if;
    return new;
end;
$$ language plpgsql;

create or replace trigger trg_assessments_check before insert or update on tradecraft.assessments
    for each row execute function tradecraft.assessments_check();

-- ----------------------------------------------------------------------------
-- 5. Corroboration -- classes, not counts
--
-- The Bellingcat rule, mechanised: count DISTINCT evidence classes, discount a
-- class that derives from another class already present, and let a `standalone`
-- class carry the assessment on fewer sources.
-- ----------------------------------------------------------------------------
create or replace function tradecraft.corroboration(p_assessment uuid)
returns table (n_records int, n_classes int, n_independent int, classes text[], standalone boolean)
language sql stable as $$
    with ev as (
        select distinct e->>'class' as class
        from tradecraft.assessments a, jsonb_array_elements(a.evidence) e
        where a.id = p_assessment
    ),
    all_ev as (
        select count(*)::int as n_records
        from tradecraft.assessments a, jsonb_array_elements(a.evidence) e
        where a.id = p_assessment
    ),
    -- a class is discounted when something it derives from is also present
    indep as (
        select ev.class from ev
        join tradecraft.evidence_classes ec on ec.class = ev.class
        where not exists (
            select 1 from ev o where o.class = any(ec.derives_from)
        )
    )
    select (select n_records from all_ev),
           (select count(*)::int from ev),
           (select count(*)::int from indep),
           (select array_agg(class order by class) from ev),
           (select bool_or(ec.standalone) from indep i
              join tradecraft.evidence_classes ec on ec.class = i.class);
$$;

-- The publish gate. Three independent classes, or one standalone class plus a
-- second. Deliberately a FUNCTION returning a reason rather than a boolean:
-- "not yet corroborated" is information, and a gate that only says no teaches
-- nobody anything.
create or replace function tradecraft.publishable(p_assessment uuid)
returns table (ok boolean, reason text)
language sql stable as $$
    select case
             when c.n_independent >= 3 then true
             when c.standalone and c.n_independent >= 2 then true
             else false
           end,
           case
             when c.n_independent >= 3 then 'three independent evidence classes'
             when c.standalone and c.n_independent >= 2
               then 'standalone class (' || array_to_string(c.classes,',') || ') plus corroboration'
             when c.n_records > c.n_classes
               then 'only ' || c.n_independent || ' independent class(es) across '
                    || c.n_records || ' records -- instances are not sources'
             else 'only ' || c.n_independent || ' independent evidence class(es)'
           end
    from tradecraft.corroboration(p_assessment) c;
$$;

-- ----------------------------------------------------------------------------
-- 6. The resolution ledger -- ICD 203 Standard 8, and the only honest reputation
--
-- Brier score, because it is a PROPER scoring rule (Gneiting & Raftery 2007):
-- the expected score is optimised by reporting your true belief, so hedging
-- toward 0.5 is penalised rather than rewarded. An improper rule would make
-- "roughly even chance" the rational answer to everything.
-- ----------------------------------------------------------------------------
create table if not exists tradecraft.resolutions (
    assessment_id uuid primary key references tradecraft.assessments(id) on delete cascade,
    outcome       boolean not null,
    resolved_at   timestamptz not null default now(),
    resolver      text not null,
    evidence_ref  text,                 -- what settled it
    note          text
);

create or replace view tradecraft.v_track_record as
select a.author,
       count(*)                                          as n_resolved,
       round(avg(power(l.midpoint - (r.outcome)::int::numeric, 2)), 4) as brier,
       -- calibration: when they said X, how often were they right?
       round(avg(l.midpoint), 3)                         as mean_stated,
       round(avg((r.outcome)::int::numeric), 3)          as mean_actual
from tradecraft.assessments a
join tradecraft.resolutions r on r.assessment_id = a.id
join tradecraft.likelihood  l on l.term = a.likelihood
group by a.author;

-- Standard 7 made queryable: where has our published line CHANGED?
create or replace view tradecraft.v_line_changes as
select cur.subject_key,
       prev.likelihood as was, cur.likelihood as now,
       prev.published_at as said_at, cur.published_at as changed_at,
       cur.change_reason, cur.author
from tradecraft.assessments cur
join tradecraft.assessments prev on prev.id = cur.supersedes
where cur.likelihood is distinct from prev.likelihood;

-- Assessments whose forward date has passed and which nobody has scored.
-- This is the queue that makes a track record possible; left unworked it is
-- the reason most reputation systems have none.
create or replace view tradecraft.v_awaiting_resolution as
select a.id, a.subject_key, a.statement, a.likelihood, a.author, a.resolves_by,
       now() - a.resolves_by as overdue
from tradecraft.assessments a
left join tradecraft.resolutions r on r.assessment_id = a.id
where a.resolves_by is not null and a.resolves_by < now() and r.assessment_id is null
order by a.resolves_by;
