-- ============================================================================
-- THE CLUE WALK AS A WORKFLOW (REM-1210)
-- ============================================================================
--
-- A walk answers one question by reading in waves. Search supplies the first
-- reads. Every read raises CLUES: a term it shares with a few unread
-- documents, the documents beside it in its sitting, the documents nearest it
-- in meaning. A decider (Jev) gives each clue a P; P >= 0.5 accepts it; and
-- the wave then travels the accepted clues, best first, reading what they
-- reach until it holds its share of reads. The decider acts BEFORE the read:
-- a judgement after a row is read has already paid for the row.
--
-- WHY A WORKFLOW AND NOT A CLIENT LOOP. The same walk existed as Python
-- around the database (percolate-core `percolate walk run`). A reader could
-- not see which part was Percolate. Here every step is a task row, and every
-- read, clue, P, gate decision, open lead and the stop can be queried with
-- SQL: aiq.walk_reads, aiq.walk_clues, aiq.walk_waves, aiq.walk_summary.
--
--     start   sql    the seeds: search's first reads (wave 0)
--     wave    repeat, at most 20 waves, until a wave finds nothing to read
--       judge   matrix of rest: one Jev request per 60 clues the replay lacks
--       read    sql    gate the wave's clues, travel the best, read to the wave's size
--
-- NO NEW TABLE. A walk's record is its run's own task rows. The 64KB task cap
-- decides the split: a read step records only its reads and travels (a few
-- kilobytes), each judge child records one Jev request and its answers, and
-- everything else -- which clues a wave raised, their targets, which stayed
-- open -- is recomputed by aiq.walk_state from those rows and from the links
-- as they stood when the run started. The links are by construction
-- (REM-1201: walk_term, walk_tagged, walk_next, walk_nearest), so the
-- recomputation is exact, not a model's second opinion.
--
-- A WAVE IS ONE JUDGING ROUND. The study judged after every travel step,
-- about ten rounds a wave; a workflow judges once a wave, which is what the
-- article's figure shows (read, pause, prune) and what fits in repeat's
-- bound. Clues raised by a wave's reads are judged at the start of the next.
--
-- REPLAY. Run input {"replay": "<resource uri>"} names a verdict document,
-- {"model", "task", "verdicts": {qid: {clue key: P}}}; its P values are used
-- and Jev is asked only for the rest. {"offline": true} asks nobody, and a
-- clue with no stored P is unjudged, never accepted. aiq.walk_verdicts(run)
-- writes a finished run's verdicts in the same shape, so the first run of a
-- walk costs cents and every rerun nothing.
--
-- WHAT A RUN READS. Input {"channel": "<name>"} walks the `document` nodes of
-- that channel's resources, named by resource uri; {"nodes": "<entity_type>",
-- "prefix": "<key prefix>"} walks graph nodes, named by canonical key. The
-- question is {"question": {"id", "text"}}. Search is aiq.search over the
-- channel's chunks with the question embedded (the `q` step), or the order a
-- question node holds as walk_seed edges (provenance rank), or input
-- "search": [keys] for a short list.
-- ============================================================================

-- THE PARAMETERS (Sirsh, M-20261027-213302-a399): every number and wording the walk, its index, its decider, its
-- explanations and dreaming read is a row here, never a literal in code, and each row says what it controls, where
-- it is read and why it has the value it has, so the table also explains the algorithm:
--     select name, value, controls, why from aiq.parameters order by part, name;
-- The spec seeds the rows, set_by 'spec'. A later spec refreshes only rows still set by the spec, so a value tuned on
-- a deployment (set_by naming who, why saying on what evidence) survives an upgrade. One table for all of them,
-- rather than one per part, because they are one algorithm and are tuned against each other.
create table if not exists aiq.parameters (
    name       text primary key check (name ~ '^[a-z]+\.[a-z_]+$'),
    part       text not null check (part in ('index', 'search', 'walk', 'decider', 'explain', 'dream')),
    value      jsonb not null,
    controls   text not null check (btrim(controls) <> ''),
    read_by    text not null check (btrim(read_by) <> ''),
    why        text not null check (btrim(why) <> ''),
    set_by     text not null default 'spec',
    updated_at timestamptz not null default now(),
    check (split_part(name, '.', 1) = part)
);
comment on table aiq.parameters is
    'The walk''s, its index''s, its decider''s, its explanations'' and dreaming''s parameters: value, what it controls, where it is read and why.';
alter table aiq.parameters enable row level security;
drop policy if exists parameters_readable on aiq.parameters;
create policy parameters_readable on aiq.parameters for select using (true);
grant select on aiq.parameters to authenticated;

insert into aiq.parameters as p (name, part, value, controls, read_by, why) values
 ('walk.waves', 'walk', '10', 'How many waves a walk runs before it stops.', 'aiq.walk_settings',
  'Ten waves of 50 is 500 reads, the budget the BEAM study and REM-1204''s crossover curves were measured at.'),
 ('walk.wave', 'walk', '50', 'Reads per wave; Jev judges the clues a wave raised before the next wave reads.', 'aiq.walk_settings',
  'The study''s waves2 arm: 50 reads keep a judge round near 48k tokens and let the walk change course ten times.'),
 ('walk.seeds', 'walk', '10', 'Search''s first reads, the ones that raise the first clues.', 'aiq.walk_settings',
  'The study''s explore10_all arm, chosen on 40 dev questions before the 150 test questions were walked.'),
 ('walk.per_wave', 'walk', '10', 'Search reads taken at the start of every later wave, before any clue is travelled.', 'aiq.walk_settings',
  'explore10_all: search keeps feeding the walk, so a walk is never worse off than search for long.'),
 ('walk.span', 'walk', '5', 'How far a next-message clue reaches either side of a read, within its sitting.', 'aiq.walk_settings, aiq.walk_graph_build',
  'Sirsh approved 5 (M-20261027-223456-e71c) on REM-1219''s test: 122 BEAM questions with stored verdicts, span 5 against 2 at 500 reads raised evidence share 0.897 to 0.931 (95% CI +0.008 to +0.066; 19 questions up, 8 down, sign p 0.052) and all-evidence questions 90 to 93; instruction following went 0.846 to 1.000 and no narrow type dropped. Missed evidence sat a few exchanges past evidence already read.'),
 ('walk.cap', 'walk', '100', 'A term is offered as a clue only when at most this many documents share it.', 'aiq.walk_settings, aiq.walk_state',
  'Set wide on Sirsh''s direction (M-20261028-074522-1623) until a sweep plots the walk across caps. At the old cap of 10 (REM-1208), on BEAM, 161 of 544 never-read evidence documents were reachable only through a wider tag, 153 of them in event-ordering or summarization questions. On REM-1204''s 156 buried test questions (deep order, span 2, 500 reads) the walk led search by +0.058 (95% CI +0.035 to +0.082) at cap 10, +0.049 at 30 and +0.050 at 100: no gain from widening, and a cost of about 0.01, inside the noise. Above the index''s fit cap (index.df_floor, index.df_share) the walk cap does nothing, because no wider term exists: on BEAM 1M that is 20 to 30 messages, so 100 acts as about 30 there and binds only on longer histories. query/38 pins the cap''s behaviour.'),
 ('walk.gate', 'walk', '0.5', 'The P at or above which a judged clue is accepted and may be travelled.', 'aiq.walk_settings, aiq.walk_why',
  'Jev''s P read as a probability: accept what is more likely than not to lead to the answer.'),
 ('walk.expand_all', 'walk', 'true', 'Whether every read raises clues, or only search''s seeds and what clues reach.', 'aiq.walk_settings',
  'The study''s _all arms beat seeds-only on BEAM test reach.'),
 ('walk.near', 'walk', '3', 'Nearest-in-meaning clues a read raises, from the index''s nearest neighbours.', 'aiq.walk_settings, aiq.walk_graph_build',
  'The study''s 3 nearest both ways; the index keeps index.nearest so this can be raised without re-indexing.'),
 ('walk.memory', 'walk', '0', 'How far a walk leans on stored verdicts: 0 asks afresh, 1 takes past verdicts whole.', 'aiq.walk_state',
  'Sirsh, M-20261027-115632-55e8: verdicts are stored, and reads are memoryless by default.'),
 ('walk.memory_as_of', 'walk', 'null', 'Which stored verdicts a walk with memory reads: those given before this run started (null), before a past run started (its id), or before a time.', 'aiq.walk_state',
  'Sirsh, M-20261028-134903-f73c: a rerun with memory read 86 verdicts its original never saw and differed in 451 of 500 reads; pinning the store to the original''s start keeps the memory it read.'),
 ('walk.order', 'walk', '"p"', 'Which accepted clue is travelled next: by P, or by how many open accepted clues agree on its target (votes, wvotes).', 'aiq.walk_read',
  'REM-1219: votes gained 3 questions of 122 and lost none, sign p 0.25; not enough to change the default.'),
 ('walk.near_miss', 'walk', 'null', 'Off, or {band, every}: every every-th travel takes the best rejected clue with P in [band, gate).', 'aiq.walk_read',
  'Off because no measurement shows it helps across questions: its only evidence is the walkthrough''s q19 (0 of 2 under the gate without it, 2 of 2 with {band 0.35, every 2}), REM-1207.'),
 ('search.hits', 'search', '2000', 'How many search hits a channel walk takes as its search order.', 'aiq.walk_start',
  'Enough to rank every document of a 1M BEAM conversation (about 1,100) by its best chunk.'),
 ('decider.task', 'decider', to_jsonb(text 'For each option, a lead into the user''s earlier messages that has not been read yet: a term the messages share, or the messages beside or close in meaning to one already read. Would following it likely reach information needed to answer `question`, or part of it?'),
  'The question Jev answers for every clue. A verdict is kept with this wording and is never mixed with another''s.', 'aiq.walk_task',
  'Ported from the BEAM study with REM-1200, where the generic wording beat one naming BEAM''s question types on 7 of 9 types.'),
 ('index.nearest', 'index', '10', 'Nearest-in-meaning documents the index links from each document.', 'percolate walk index (core walk/index.py)',
  'Ten keeps room above walk.near for a walk that asks for more, at about 10 edges a document.'),
 ('index.df_floor', 'index', '20', 'The term fit keeps a term only when at most max(df_floor, df_share x documents) documents hold it.', 'percolate walk index (core walk/index.py, walk/terms.py)',
  'Came in with the term fitter (REM-1201), not measured. It caps every walk_term posting, and so caps walk.cap from above. REM-1204 found the cost: a name in 40 of a 1M history''s messages, 20 of them evidence (the trainer in BEAM''s buried questions), has no term at all; refit with a floor of 100, terms from search''s top 10 enter 5.6 of 8.2 evidence islands against 4.0.'),
 ('index.df_share', 'index', '0.02', 'With index.df_floor, the share of documents above which a term is too common to keep.', 'percolate walk index (core walk/index.py, walk/terms.py)',
  'Came in with the term fitter (REM-1201), not measured. It binds above 1,000 documents: about 30 on BEAM''s longer 1M histories and about 200 on 10M.'),
 ('explain.cold', 'explain', '0.05', 'A wave is cold when under this share of its expanded reads raised a new accepted clue.', 'aiq.walk_why, aiq.walk_audit (core walk/why.py)',
  'Not measured. Core walk/why.py credits REM-1194''s BEAM calibration, but that calibration binned cold at under 0.2; 0.05 is a stricter choice nobody tested.'),
 ('explain.near_miss', 'explain', '0.35', 'A rejected clue with P from this up to the gate is reported as a near miss.', 'aiq.walk_why (core walk/why.py)',
  'Not measured: a reporting band 0.15 under the gate, equal to the band REM-1207''s walkthrough travelled (0.35), so the audit and the walk agree on what a near miss is.')
on conflict (name) do update
   set value = excluded.value, controls = excluded.controls, read_by = excluded.read_by, why = excluded.why,
       updated_at = now()
 where p.set_by = 'spec';

-- One part's parameters as {name without the part: value}.
create or replace function aiq.parameters_of(p_part text) returns jsonb
language sql stable set search_path = pg_catalog, public as $$
select coalesce(jsonb_object_agg(split_part(name, '.', 2), value), '{}'::jsonb) from aiq.parameters where part = p_part
$$;

-- The wording a verdict is kept under (aiq.parameters decider.task). Verdicts given under another wording are
-- refused rather than mixed (percolate-core decide.py).
create or replace function aiq.walk_task() returns text
language sql stable set search_path = pg_catalog, public as $$
select value #>> '{}' from aiq.parameters where name = 'decider.task'
$$;

-- The settings: the walk's parameters, under what a run's input asks for.
create or replace function aiq.walk_settings(p_input jsonb) returns jsonb
language sql stable set search_path = pg_catalog, public as $$
select aiq.parameters_of('walk') || jsonb_build_object('hits', aiq.parameters_of('search')->'hits')
       || coalesce(p_input->'settings', '{}'::jsonb)
$$;

-- A run's scope, {node uuid: key}: the `document` nodes of a channel's resources by uri, or the nodes of an entity
-- type by canonical key.
create or replace function aiq.walk_keys(p_input jsonb)
returns jsonb
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    docs jsonb;
begin
    if p_input ? 'channel' then
        select jsonb_object_agg(n.id::text, coalesce(r.uri, r.id::text)) into docs
          from content.resources r
          join content.channels ch on ch.id = r.channel_id
          join aiq.nodes n on n.entity_type = 'document' and n.entity_id = r.id
         where ch.name = p_input->>'channel';
    elsif p_input ? 'nodes' then
        select jsonb_object_agg(n.id::text, k.key) into docs
          from aiq.nodes n
          join aiq.node_keys k on k.node_id = n.id and k.kind = 'canonical'
         where n.entity_type = p_input->>'nodes'
           and k.key like coalesce(p_input->>'prefix', '') || '%';
    else
        raise invalid_parameter_value using message = 'a walk reads a channel or a set of nodes',
            hint = 'start it with {"channel": "<name>"} or {"nodes": "<entity_type>", "prefix": "<key prefix>"}';
    end if;
    if docs is null then
        raise no_data_found using message = format('nothing to walk in %s', p_input - 'question' - 'settings'),
            hint = 'load the sample first; a channel walks its document nodes';
    end if;
    return docs;
end;
$$;

-- The text of some of a scope's documents, for the snippets a judge reads: a document's chunks in order, or a
-- node's summary. Fetched for the few a round needs rather than carried in the graph (4.4 MB on a BEAM channel).
create or replace function aiq.walk_texts(p_input jsonb, p_docs text[])
returns jsonb
language sql stable security invoker set search_path = pg_catalog, public as $$
    select coalesce(jsonb_object_agg(d.doc, d.body), '{}'::jsonb) from (
        select coalesce(r.uri, r.id::text) as doc,
               coalesce((select string_agg(c.content, ' ' order by c.ordinal)
                           from content.resource_chunks c where c.resource_id = r.id), '') as body
          from content.resources r join content.channels ch on ch.id = r.channel_id
         where p_input ? 'channel' and ch.name = p_input->>'channel' and coalesce(r.uri, r.id::text) = any(p_docs)
        union all
        select k.key, coalesce(n.summary, k.key)
          from aiq.nodes n join aiq.node_keys k on k.node_id = n.id and k.kind = 'canonical'
         where p_input ? 'nodes' and n.entity_type = p_input->>'nodes' and k.key = any(p_docs)
    ) d
$$;

-- What a scope's graph is built from: its documents and the walk links out of them, each link by its ends, relation,
-- provenance and validity. Any change to one, a close backdated or a new row, moves a sum; as_of is the time after
-- which the graph no longer depends on the moment it is read. (48 ms on a BEAM channel, against 200 ms to build.)
create or replace function aiq.walk_graph_version(p_keys jsonb)
returns jsonb
language sql stable security invoker set search_path = pg_catalog, public as $$
    select jsonb_build_object(
               'docs', (select count(*) from jsonb_object_keys(p_keys)), 'edges', count(*), 'closed', count(e.valid_to),
               'links', sum(hashtext(e.src_id::text || e.dst_id::text || e.relation || e.provenance::text)::bigint),
               'from', sum(extract(epoch from e.valid_from)), 'to', sum(extract(epoch from e.valid_to)),
               'newest', max(e.created_at),
               'as_of', max(greatest(e.created_at, e.valid_from, coalesce(e.valid_to, e.valid_from))))
      from aiq.edges e
     where e.src_id = any (array(select k::uuid from jsonb_object_keys(p_keys) k))
       and e.relation in ('walk_term', 'walk_tagged', 'walk_next', 'walk_nearest')
$$;

-- Where a scope's graph is kept: one document per scope, the two settings the graph depends on, and the version of
-- its links. Links that change name a new document rather than rewrite one, because a resource's metadata is kept
-- from its first registration.
create or replace function aiq.walk_graph_uri(p_input jsonb, p_version jsonb)
returns text
language sql stable set search_path = pg_catalog, public as $$
    select 'walk-graph:' || md5(((p_input - 'question' - 'settings' - 'search' - 'replay' - 'offline')
                                 || jsonb_build_object('span', aiq.walk_settings(p_input)->'span',
                                                       'near', aiq.walk_settings(p_input)->'near'))::text)
           || ':' || md5(p_version::text)
$$;

-- A scope's graph, read from its document when that was built from the links as they are, and built otherwise.
-- The graph is the same on every step of every run over the scope, and building it was most of a walk's cost
-- (76% of a BEAM walk's database time); a run as of a time before the links last changed builds its own.
create or replace function aiq.walk_graph(p_input jsonb, p_at timestamptz default null)
returns jsonb
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    v_at timestamptz := coalesce(p_at, now());
    v    jsonb := aiq.walk_graph_version(aiq.walk_keys(p_input));
    kept jsonb;
begin
    select res.metadata->'walk_graph' into kept
      from content.resources res
     where res.uri = aiq.walk_graph_uri(p_input, v)
     order by res.updated_at desc
     limit 1;
    if kept is not null and v_at >= (v->>'as_of')::timestamptz then
        return kept;
    end if;
    return aiq.walk_graph_build(p_input, v_at);
end;
$$;

-- Keep a scope's graph as a document in p_channel, so every walk over the scope reads it rather than building it.
-- Run it after loading the links, and again after changing them: a graph kept for links that have since changed
-- is never read, so a stale one costs a rebuild per step and is never wrong. The graph is the document's metadata;
-- its one chunk is '-', which indexes to no words, so search never finds it (as chunk text, a graph's terms put it
-- in the keyword ranking and moved the walk's own search order).
create or replace function aiq.walk_index(p_input jsonb, p_channel text default 'walk-graphs')
returns jsonb
language plpgsql volatile security invoker set search_path = pg_catalog, public as $$
declare
    v   jsonb := aiq.walk_graph_version(aiq.walk_keys(p_input));
    uri text := aiq.walk_graph_uri(p_input, v);
    g   jsonb;
begin
    -- the channel is made on first use, in the shared org where register_text looks for a channel a caller with no
    -- org names, so the first index on a fresh stack (percolate walk index keeps its graph) does not fail on it
    if not exists (select 1 from content.channels where name = p_channel) then
        insert into content.channels (name, kind, org_id, visibility)
        values (p_channel, 'manual', rbac.shared_org_id(), 'public');
    end if;
    g := aiq.walk_graph_build(p_input, greatest(now(), (v->>'as_of')::timestamptz));
    return content.register_text(p_channel, uri, '[{"content": "-"}]'::jsonb,
               'walk graph: ' || (p_input - 'question' - 'settings' - 'search' - 'replay' - 'offline')::text, uri,
               null, jsonb_build_object('walk_graph', g, 'version', v))
           || jsonb_build_object('uri', uri, 'version', v);
end;
$$;

-- The graph a run walked (Sirsh, M-20261028-200720-890b). A walk's leads are read back from its graph, and an edge's
-- identity has no time in it: a re-index rewrites a walk_term's terms in place, and a tag renamed renames its leads.
-- So the start step records the kept graph document (aiq.walk_index) that holds the scope's links as they are when it
-- starts, and every later reading of the run (walk_state, so walk_clues, walk_why and the rest) takes the graph from
-- that document. Documents are never rewritten (changed links name a new one), so a pinned run reads what it walked.
-- A step is read-only and cannot write the document itself: a scope is pinned when it was indexed after its links
-- last changed, and a run started otherwise records no document and is read as of its start, as before.
create or replace function aiq.walk_run_graph(p_run uuid)
returns jsonb
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    r    workflow.runs;
    kept jsonb;
begin
    select * into r from workflow.runs where id = p_run;
    select res.metadata->'walk_graph' into kept
      from workflow.tasks tk
      join content.resources res on res.uri = tk.output->'result'->0->'state'->>'graph'
     where tk.run_id = p_run and tk.step_key = 'start' and tk.status = 'succeeded'
     order by res.updated_at desc
     limit 1;
    return coalesce(kept, aiq.walk_graph(r.input, r.created_at));
end;
$$;

-- One documents-and-links load for a run's scope, as the caller, as of p_at.
-- Returned as one jsonb so a walk's state is computed in one pass over it:
--   keys:  {node uuid: key}
--   terms: {key: [term, ...]}       post: {term: [key, ...]}
--   beside:{key: [key, ...]} within span either side, by walk_next
--   near:  {key: [key, ...]} the first `near` nearest, and who has it as one
-- A document's text is not in it: aiq.walk_texts fetches the few a round's snippets need.
create or replace function aiq.walk_graph_build(p_input jsonb, p_at timestamptz default null)
returns jsonb
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    s      jsonb := aiq.walk_settings(p_input);
    v_at   timestamptz := coalesce(p_at, now());
    docs   jsonb;
    terms  jsonb;
    post   jsonb;
    beside jsonb;
    near   jsonb;
begin
    docs := aiq.walk_keys(p_input);
    -- Terms: walk_term between two documents (provenance terms[]), and
    -- walk_tagged from a node to a tag node (the tag's summary is the term).
    with t as (
        select docs->>e.src_id::text as doc, x->>'term' as term, (x->>'rank')::int as rank,
               docs->>e.dst_id::text as other
          from aiq.edges e, jsonb_array_elements(e.provenance->'terms') x
         where e.relation = 'walk_term' and docs ? e.src_id::text
           and e.valid_from <= v_at and (e.valid_to is null or e.valid_to > v_at)
        union all
        select docs->>e.src_id::text, tn.summary, 0, null
          from aiq.edges e join aiq.nodes tn on tn.id = e.dst_id
         where e.relation = 'walk_tagged' and docs ? e.src_id::text
           and e.valid_from <= v_at and (e.valid_to is null or e.valid_to > v_at)
    ), own as (
        select doc, term, min(rank) as rank from t group by doc, term
    ), holders as (
        select term, doc from t union select term, other from t where other is not null
        union
        -- a walk_tagged term's postings are every node tagged with it
        select tn.summary, docs->>e.src_id::text
          from aiq.edges e join aiq.nodes tn on tn.id = e.dst_id
         where e.relation = 'walk_tagged' and docs ? e.src_id::text
           and e.valid_from <= v_at and (e.valid_to is null or e.valid_to > v_at)
    )
    select (select jsonb_object_agg(doc, ts) from (
                select doc, jsonb_agg(term order by rank, term) as ts from own group by doc) a),
           (select jsonb_object_agg(term, ds) from (
                select term, jsonb_agg(doc order by doc) as ds from holders where doc is not null group by term) b)
      into s, post;
    -- (s now holds the term lists; the settings are re-read below)
    terms := coalesce(s, '{}'::jsonb);
    s := aiq.walk_settings(p_input);
    -- Beside: the next chain, both ways, within span.
    with recursive nx as (
        select docs->>e.src_id::text as a, docs->>e.dst_id::text as b
          from aiq.edges e
         where e.relation = 'walk_next' and docs ? e.src_id::text and docs ? e.dst_id::text
           and e.valid_from <= v_at and (e.valid_to is null or e.valid_to > v_at)
    ), both_ways as (
        select a, b from nx union select b, a from nx
    ), reach (origin, at, d) as (
        select a, b, 1 from both_ways
        union
        select r.origin, w.b, r.d + 1 from reach r join both_ways w on w.a = r.at
         where r.d < (s->>'span')::int and w.b <> r.origin
    )
    select jsonb_object_agg(origin, ks) into beside
      from (select origin, jsonb_agg(distinct at) as ks from reach group by origin) z;
    -- Nearest: the first `near` by rank, and the reverse lists.
    with nn as (
        select docs->>e.src_id::text as a, docs->>e.dst_id::text as b, (e.provenance->>'rank')::int as rank
          from aiq.edges e
         where e.relation = 'walk_nearest' and docs ? e.src_id::text and docs ? e.dst_id::text
           and (e.provenance->>'rank')::int < (s->>'near')::int
           and e.valid_from <= v_at and (e.valid_to is null or e.valid_to > v_at)
    ), lists as (
        select a as doc, b as other, 0 as dir, rank from nn
        union all
        select b, a, 1, rank from nn
    )
    select jsonb_object_agg(doc, ks) into near
      from (select doc, jsonb_agg(other order by dir, rank, other) as ks from lists group by doc) z;
    return jsonb_build_object('keys', docs, 'terms', terms,
                              'post', coalesce(post, '{}'::jsonb), 'beside', coalesce(beside, '{}'::jsonb),
                              'near', coalesce(near, '{}'::jsonb));
end;
$$;

-- A clue's one-line description: what Jev reads instead of the documents.
create or replace function aiq.walk_snippet(p_text text, p_around text default null) returns text
language plpgsql immutable as $$
declare
    t text := regexp_replace(coalesce(p_text, ''), '\s+', ' ', 'g');
    i int;
begin
    t := btrim(t);
    if p_around is not null then
        i := strpos(lower(t), lower(p_around));
        if i > 81 then
            t := '…' || substr(t, i - 80);
        end if;
    end if;
    return left(t, 160);
end;
$$;

-- The verdicts the decider gave this run, one row a clue: the clue's key, its P, when it was answered and the model
-- that answered. Read from the judge step's tasks, which workflow retention prunes: aiq.walk_keep keeps them.
create or replace function aiq.walk_answers(p_run uuid)
returns table (key text, p real, at timestamptz, model text)
language sql stable security invoker set search_path = pg_catalog, public as $$
    select kk.value #>> '{}', (ch.output->'result'->'answers'->('c' || (kk.ordinality - 1))->>'noul')::real,
           ch.completed_at, ch.input->'item'->'body'->>'model'
      from workflow.tasks jt
      join workflow.tasks ch on ch.matrix_parent_id = jt.id and ch.status = 'succeeded'
      cross join lateral jsonb_array_elements(ch.input->'item'->'keys') with ordinality kk
     where jt.run_id = p_run and jt.step_key like 'judge\_%'
       and ch.output->'result'->'answers'->('c' || (kk.ordinality - 1)) ? 'noul'
$$;

-- The walk so far, recomputed from the run's rows. Everything the reader's
-- functions return comes from here, so they cannot disagree with each other.
--
-- Returns {settings, question, order (search's order), waves: [{wave, reads:
-- [{doc, via, expanded}], travels, raised: [clue keys]}], clues: {key: {kind,
-- x, wave, source, targets, p}}, travelled: {key: wave}, reached, pending,
-- next: the clues the next wave would judge, with their descriptions, stop}.
create or replace function aiq.walk_state(p_run uuid)
returns jsonb
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    r        workflow.runs;
    inp      jsonb;
    s        jsonb;
    g        jsonb;
    q        jsonb;
    ord      jsonb;
    pmap     jsonb := '{}'::jsonb;
    rep      jsonb;
    logs     jsonb;
    w        jsonb;
    wn       int;
    clues    jsonb := '{}'::jsonb;
    reached  jsonb := '{}'::jsonb;   -- {key: true}
    travelled jsonb := '{}'::jsonb;  -- {clue key: wave}
    pending  jsonb := '[]'::jsonb;
    sources  jsonb := '[]'::jsonb;   -- the reads whose clues the next round judges
    nxt      jsonb := '{}'::jsonb;   -- clues the next round raises: {key: {kind, x, source, targets, text}}
    waves    jsonb := '[]'::jsonb;
    stop     jsonb;
    last     boolean;
    txt      jsonb;
    mem      real;
    asof     timestamptz;
begin
    select * into r from workflow.runs where id = p_run;
    if not found then
        raise no_data_found using message = format('no run %s that you may read', p_run);
    end if;
    inp := r.input;
    s := aiq.walk_settings(inp);
    q := inp->'question';
    g := aiq.walk_run_graph(p_run);
    -- Search's order: the start step's record of it.
    select tk.output->'result'->0->'state'->'order' into ord
      from workflow.tasks tk where tk.run_id = p_run and tk.step_key = 'start' and tk.status = 'succeeded';
    -- P: the replay document, then every answer Jev gave this run.
    if inp ? 'replay' then
        select (string_agg(c.content, '' order by c.ordinal))::jsonb into rep
          from content.resources res join content.resource_chunks c on c.resource_id = res.id
         where res.uri = inp->>'replay'
         group by res.id limit 1;
        if rep is null then
            raise no_data_found using message = format('no replay document %s', inp->>'replay');
        end if;
        if rep->>'task' is distinct from aiq.walk_task() then
            raise invalid_parameter_value using message = 'the replay was judged under another task wording',
                hint = 'a verdict belongs to its wording; walk again live, or replay a document made under this one';
        end if;
        pmap := coalesce(rep->'verdicts'->(q->>'id'), '{}'::jsonb);
    end if;
    select pmap || coalesce(jsonb_object_agg(a.key, a.p), '{}'::jsonb) into pmap from aiq.walk_answers(p_run) a;
    -- Memory (settings.memory, 0 to 1, default 0): how far this run leans on the verdicts earlier runs kept for the
    -- same question under the same wording. At 0 they are not read. Above it, a clue judged before and now takes
    -- (1 - memory) * now + memory * the mean of before, and one judged only before takes the mean and is not asked.
    -- settings.memory_as_of moves the store's cutoff back: to a past run's start, given its id, or to a time. It never
    -- moves it past this run's own start, so the state of a finished run does not change as later runs keep verdicts.
    mem := coalesce((s->>'memory')::real, 0);
    asof := r.created_at;
    if mem > 0 and jsonb_typeof(s->'memory_as_of') = 'string' then
        if s->>'memory_as_of' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
            select least(asof, x.created_at) into asof from workflow.runs x where x.id = (s->>'memory_as_of')::uuid;
            if not found then
                raise no_data_found using message = format('memory_as_of names no run %s that you may read', s->>'memory_as_of');
            end if;
        else
            asof := least(asof, (s->>'memory_as_of')::timestamptz);
        end if;
    end if;
    if mem > 0 then
        select coalesce(jsonb_object_agg(z.k, case when z.now_p is null then z.past
                                                   else (1 - mem) * z.now_p + mem * z.past end), '{}'::jsonb)
               || (select coalesce(jsonb_object_agg(n.key, n.value), '{}'::jsonb) from jsonb_each(pmap) n
                    where not exists (select 1 from aiq.walk_kept(q->>'id', asof) k where k.key = n.key))
          into pmap
          from (select k.key as k, avg(k.p)::real as past, (pmap->>k.key)::real as now_p
                  from aiq.walk_kept(q->>'id', asof) k
                 group by k.key) z;
    end if;
    -- The read steps' records, in wave order; wave 0 is the start step's.
    select jsonb_agg(x.rec order by (x.rec->>'wave')::int) into logs
      from (select tk.output->'result'->0->'state' as rec
              from workflow.tasks tk
             where tk.run_id = p_run and tk.status = 'succeeded'
               and (tk.step_key = 'start' or tk.step_key like 'read\_%')) x
     where x.rec ? 'wave';
    -- Each wave is applied as a whole: one jsonb merge per accumulator per wave. A merge per key copied the
    -- growing object every time, so a walk's state cost the square of its reads (1.3 s of 1.6 s at 500 reads).
    for w in select value from jsonb_array_elements(coalesce(logs, '[]'::jsonb)) loop
        wn := (w->>'wave')::int;
        -- Only the last wave's clues are still to be judged, and a clue's text is only read by its judge.
        last := wn = (logs->-1->>'wave')::int;
        txt := case when last then aiq.walk_texts(inp, array(select value->>'doc' from jsonb_array_elements(w->'reads')
                                                              where (value->>'expanded')::boolean)) end;
        -- The clues this wave's round judged: raised by the previous wave's expanded reads.
        if wn > 0 then
            clues := clues || coalesce((select jsonb_object_agg(key, (value - 'text')
                                                 || jsonb_build_object('wave', wn, 'p', pmap->key))
                                          from jsonb_each(nxt)), '{}'::jsonb);
        end if;
        -- Apply the wave's reads and travels.
        reached := reached || coalesce((select jsonb_object_agg(d, true) from (
                       select value->>'doc' as d from jsonb_array_elements(w->'reads')
                       union
                       select l #>> '{}' from jsonb_array_elements(coalesce(w->'travels', '[]'::jsonb)) tr,
                                              jsonb_array_elements(tr->'land') l) x), '{}'::jsonb);
        travelled := travelled || coalesce((select jsonb_object_agg(value->>'key', wn)
                                              from jsonb_array_elements(coalesce(w->'travels', '[]'::jsonb))),
                                           '{}'::jsonb);
        pending := coalesce(w->'pending', '[]'::jsonb);
        waves := waves || jsonb_build_array(w || jsonb_build_object('raised',
                     (select coalesce(jsonb_agg(key order by key), '[]'::jsonb) from jsonb_each(nxt))));
        -- The next round's clues: out of this wave's expanded reads, never raised before, leading somewhere unread.
        -- A term's source is the first expanded read that carries it; its targets are the term's unread postings.
        with ex as (
            select value->>'doc' as src, o from jsonb_array_elements(w->'reads') with ordinality r(value, o)
             where (value->>'expanded')::boolean
        ), term as (
            select t, min(o) as o, count(*) as n
              from ex, jsonb_array_elements_text(coalesce(g->'terms'->src, '[]'::jsonb)) t
             where jsonb_array_length(coalesce(g->'post'->t, '[]'::jsonb)) <= (s->>'cap')::int
               and not clues ? ('term:' || t)
             group by t
        ), term_clue as (
            select 'term:' || term.t as k, term.t, ex.src,
                   -- a term raised by two reads had its targets re-aggregated distinct; kept so the record is unchanged
                   case when term.n > 1 then (select jsonb_agg(distinct value) from jsonb_array_elements(g->'post'->term.t)
                                               where not reached ? (value #>> '{}'))
                        else (select jsonb_agg(value order by value #>> '{}') from jsonb_array_elements(g->'post'->term.t)
                               where not reached ? (value #>> '{}')) end as tg
              from term join ex on ex.o = term.o
        ), side_clue as (
            select kind || ':' || ex.src as k, kind, ex.src,
                   (select jsonb_agg(distinct value)
                      from jsonb_array_elements(coalesce(g->(case kind when 'next' then 'beside' else 'near' end)->ex.src,
                                                         '[]'::jsonb))
                     where not reached ? (value #>> '{}') and value #>> '{}' <> ex.src) as tg
              from ex, unnest(array['next', 'near']) kind
             where not clues ? (kind || ':' || ex.src)
        )
        select coalesce(jsonb_object_agg(k, c), '{}'::jsonb) into nxt from (
            select k, jsonb_build_object(
                       'kind', 'term', 'x', t, 'source', src, 'targets', tg,
                       'text', case when last then
                                   format('the term ''%s'', which %s unread message(s) share with this read one: "%s"',
                                          t, jsonb_array_length(tg), aiq.walk_snippet(txt->>src, t)) end) as c
              from term_clue where tg is not null
            union all
            select distinct on (k) k, jsonb_build_object(
                       'kind', kind, 'x', src, 'source', src, 'targets', tg,
                       'text', case when last then
                                   format('%s: "%s"',
                                          case kind when 'next' then 'the messages just before and after this read one, in the same sitting'
                                                    else 'the messages closest in meaning to this read one' end,
                                          aiq.walk_snippet(txt->>src)) end)
              from side_clue where tg is not null
        ) z;
        stop := w->'stop';
    end loop;
    return jsonb_build_object('settings', s, 'question', q, 'order', coalesce(ord, '[]'::jsonb),
                              'waves', waves, 'clues', clues, 'travelled', travelled, 'reached', reached,
                              'pending', pending, 'next', nxt, 'pmap_size', (select count(*) from jsonb_object_keys(pmap)),
                              'p', pmap, 'stop', stop, 'replay', inp->'replay', 'offline', coalesce(inp->'offline', 'false'));
end;
$$;

-- Whether the question needs embedding: only a channel walk with no stored
-- order searches by meaning. A graph walk, or one given its order, skips the
-- embed step, so a walk over a graph runs with no worker at all.
create or replace function aiq.walk_needs_vector(p_run uuid) returns boolean
language sql stable security invoker set search_path = pg_catalog, public as $$
    select coalesce((select input ? 'channel' and not input ? 'search' from workflow.runs where id = p_run), false)
$$;

-- The start step: search's order, and its first `seeds` reads as wave 0.
create or replace function aiq.walk_start(p_run uuid, p_vector vector default null)
returns jsonb
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    r     workflow.runs;
    inp   jsonb;
    s     jsonb;
    g     jsonb;
    ord   jsonb;
    seeds jsonb;
begin
    select * into r from workflow.runs where id = p_run;
    inp := r.input;
    s := aiq.walk_settings(inp);
    g := aiq.walk_graph(inp, r.created_at);
    -- A replay is checked here, at the first step, so a wrong one fails the walk once rather than every retry of a
    -- matrix expansion: walk_state raises if it is missing or was judged under another wording.
    if inp ? 'replay' then
        perform aiq.walk_state(p_run);
    end if;
    if inp ? 'search' then
        ord := inp->'search';
    elsif p_vector is not null and inp ? 'channel' then
        -- a hit stands for its document, at the rank of its best chunk
        select jsonb_agg(doc order by first_rank) into ord
          from (select coalesce(res.uri, res.id::text) as doc, min(h.rn) as first_rank
                  from (select chunk_id, row_number() over () as rn
                          from aiq.search('chunks', inp->'question'->>'text', p_vector, null, (s->>'hits')::int, 60,
                                          jsonb_build_object('channel', inp->>'channel'))) h
                  join content.resource_chunks c on c.id = h.chunk_id
                  join content.resources res on res.id = c.resource_id
                  join content.channels ch on ch.id = res.channel_id and ch.name = inp->>'channel'
                 group by 1) z;
    else
        -- a question node's stored order: walk_seed edges with provenance rank
        select jsonb_agg(k2.key order by (e.provenance->>'rank')::int) into ord
          from aiq.node_keys k1
          join aiq.edges e on e.src_id = k1.node_id and e.relation = 'walk_seed'
          join aiq.node_keys k2 on k2.node_id = e.dst_id and k2.kind = 'canonical'
         where k1.kind = 'canonical' and k1.key = inp->'question'->>'id';
    end if;
    if ord is null or jsonb_array_length(ord) = 0 then
        raise no_data_found using message = format('search returned nothing for %s', inp->'question'->>'id'),
            hint = 'a channel walk needs the question embedded (the q step); a graph walk needs walk_seed edges or "search"';
    end if;
    select jsonb_agg(jsonb_build_object('doc', value #>> '{}', 'via', 'search', 'expanded', true) order by ordinality)
      into seeds
      from jsonb_array_elements(ord) with ordinality
     where ordinality <= (s->>'seeds')::int
       and (value #>> '{}') in (select k.v from jsonb_each_text(g->'keys') k(n, v));
    return jsonb_build_object('wave', 0, 'order', ord, 'si', (s->>'seeds')::int, 'reads', seeds,
                              'travels', '[]'::jsonb, 'pending', '[]'::jsonb,
                              'graph', (select res.uri from content.resources res
                                         where res.uri = aiq.walk_graph_uri(inp, aiq.walk_graph_version(aiq.walk_keys(inp)))
                                         limit 1));
end;
$$;

-- The judge step's rows: one Jev request for each 60 clues this round raises
-- that the replay lacks. None when offline, or when the replay holds them all.
create or replace function aiq.walk_requests(p_run uuid, p_decider text default 'jev')
returns table (chunk int, keys jsonb, body jsonb)
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    st  jsonb := aiq.walk_state(p_run);
    d   claims.deciders;
begin
    if (st->>'offline')::boolean then
        return;
    end if;
    select * into d from claims.deciders where name = p_decider;
    if not found then
        raise no_data_found using message = format('no decider named %s is configured', p_decider);
    end if;
    return query
    with todo as (
        select key, value->>'text' as text, row_number() over (order by key) - 1 as i
          from jsonb_each(st->'next')
         where not (st->'p') ? key
    ), chunks as (
        select (i / 60)::int as chunk, key, text, (i % 60)::int as j from todo
    )
    select c.chunk,
           jsonb_agg(c.key order by c.j),
           jsonb_build_object('model', d.model,
                              'state', jsonb_build_object('question', st->'question'->>'text', 'task', aiq.walk_task()),
                              'questions', jsonb_object_agg('c' || c.j,
                                  jsonb_build_object('type', 'noul', 'instructions', c.text)))
      from chunks c
     group by c.chunk
     order by c.chunk;
end;
$$;

-- The read step: gate this round's clues, then travel accepted clues best
-- first, reading what they reach, until the wave holds its share of reads.
-- Search fills in when no accepted clue is left; with nothing left at all the
-- wave is dry and the walk stops.
create or replace function aiq.walk_read(p_run uuid)
returns jsonb
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    st      jsonb := aiq.walk_state(p_run);
    s       jsonb := st->'settings';
    wn      int := jsonb_array_length(st->'waves');   -- waves so far, counting wave 0
    target  int;
    ord     jsonb := st->'order';
    si      int := coalesce((st->'waves'->-1->>'si')::int, 0);
    reached jsonb := st->'reached';
    open_   jsonb := '{}'::jsonb;   -- {key: {p, targets}}
    -- Near misses (REM-1207), off unless settings.near_miss = {band, every}: rejected clues with P in [band, gate),
    -- of which every `every`-th travel takes the best. A fixed rotation rather than the study's coin, so a replay
    -- reads the same documents in the same order on any engine.
    nm      jsonb := s->'near_miss';
    misses  jsonb := '{}'::jsonb;   -- {key: {p, targets}}
    travel  int := (select count(*) from jsonb_array_elements(st->'waves') w,
                           jsonb_array_elements(coalesce(w->'travels', '[]'::jsonb)))::int;
    miss    boolean;
    reads   jsonb := '[]'::jsonb;
    travels jsonb := '[]'::jsonb;
    pending jsonb := st->'pending';
    best    text;
    bp      real;
    land    jsonb;
    doc     text;
    n       int := 0;
    failed  int;
    asked   int;
    why     text;
begin
    if wn = 0 then
        raise invalid_parameter_value using message = 'the walk has not started: no seeds recorded';
    end if;
    -- A Jev request that failed leaves its clues unjudged, and a walk that read on without them would end succeeded
    -- with a result it does not have (REM-1225: an empty account cost 244 walks 4,579 of 10,112 requests, and all
    -- 244 ended succeeded). So a failed request stops the walk, here, before it reads past the gap.
    -- A request is failed only once its retries are spent, or at once when the provider says retrying will not help
    -- (workflow.fail_task puts a retryable failure back to ready), so one timeout does not stop a walk.
    select count(*) filter (where t.status = 'failed'), count(*),
           (array_agg(t.error->>'error' order by t.updated_at) filter (where t.status = 'failed'))[1]
      into failed, asked, why
      from workflow.tasks t
     where t.run_id = p_run and t.step_key like 'judge\_%' and t.matrix_parent_id is not null;
    if failed > 0 then
        raise exception '% of the % Jev requests in this walk failed, so their clues were never judged', failed, asked
            using hint = 'the walk stops rather than read on without them; the first error: ' || coalesce(why, 'none recorded');
    end if;
    -- Every accepted clue still leading somewhere unread: earlier waves' not
    -- yet travelled, and this round's.
    -- (each built in one aggregate: a merge per key copies the growing object every time)
    select coalesce(jsonb_object_agg(c.key, jsonb_build_object('p', (st->'p'->>c.key)::real, 'targets', c.value->'targets')),
                    '{}'::jsonb) into open_
      from (select key, value from jsonb_each(st->'clues') where not (st->'travelled') ? key
            union all
            select key, value from jsonb_each(st->'next')) c
     where (st->'p'->>c.key)::real >= (s->>'gate')::real;
    if jsonb_typeof(nm) = 'object' then
        select coalesce(jsonb_object_agg(c.key, jsonb_build_object('p', (st->'p'->>c.key)::real,
                                                                  'targets', coalesce(st->'clues'->c.key->'targets',
                                                                                      st->'next'->c.key->'targets'))),
                        '{}'::jsonb) into misses
          from (select key from jsonb_each(st->'clues') union select key from jsonb_each(st->'next')) c
         where (st->'p'->>c.key)::real >= (nm->>'band')::real and (st->'p'->>c.key)::real < (s->>'gate')::real
           and not (st->'travelled') ? c.key;
    end if;
    -- The wave's size: cumulative reads reach wave * size (wave 0's seeds count toward wave 1).
    target := wn * (s->>'wave')::int
              - (select count(*) from jsonb_array_elements(st->'waves') w, jsonb_array_elements(w->'reads'))::int;
    -- Search first, per_wave of it, from the second wave on.
    if wn > 1 then
        while n < least((s->>'per_wave')::int, target) and si < jsonb_array_length(ord) loop
            doc := ord->>si;
            si := si + 1;
            if not reached ? doc then
                reached := reached || jsonb_build_object(doc, true);
                reads := reads || jsonb_build_array(jsonb_build_object('doc', doc, 'via', 'search',
                                                    'expanded', (s->>'expand_all')::boolean));
                n := n + 1;
            end if;
        end loop;
    end if;
    while n < target loop
        if jsonb_array_length(pending) > 0 then
            doc := pending->>0;
            pending := pending - 0;
            reads := reads || jsonb_build_array(jsonb_build_object('doc', doc, 'via', best, 'expanded', true));
            n := n + 1;
            continue;
        end if;
        -- the best accepted clue that still leads somewhere unread, ties by key; on every `every`-th travel the
        -- best near miss instead, when one leads somewhere unread
        best := null;
        miss := false;
        if jsonb_typeof(nm) = 'object' and travel % (nm->>'every')::int = (nm->>'every')::int - 1 then
            select o.key, (o.value->>'p')::real into best, bp
              from jsonb_each(misses) o
             where exists (select 1 from jsonb_array_elements(o.value->'targets') t where not reached ? (t #>> '{}'))
             order by (o.value->>'p')::real desc, o.key
             limit 1;
            miss := best is not null;
        end if;
        if not miss then
            select o.key, (o.value->>'p')::real into best, bp
              from jsonb_each(open_) o
             where exists (select 1 from jsonb_array_elements(o.value->'targets') t where not reached ? (t #>> '{}'))
             order by (o.value->>'p')::real desc, o.key
             limit 1;
        end if;
        if best is not null then
            select coalesce(jsonb_agg(t order by ord_), '[]'::jsonb) into land
              from jsonb_array_elements(case when miss then misses else open_ end->best->'targets')
                   with ordinality x(t, ord_)
             where not reached ? (t #>> '{}');
            open_ := open_ - best;
            misses := misses - best;
            travel := travel + 1;
            for doc in select value #>> '{}' from jsonb_array_elements(land) loop
                reached := reached || jsonb_build_object(doc, true);
            end loop;
            pending := pending || land;
            travels := travels || jsonb_build_array(jsonb_build_object('key', best, 'p', round(bp::numeric, 3),
                                                                       'land', land)
                                                    || case when miss then '{"near_miss": true}'::jsonb
                                                            else '{}'::jsonb end);
            continue;
        end if;
        -- nothing accepted is left: search fills the wave. With search spent too the wave ends here, but it is
        -- not dry while it read anything: those reads' clues are raised and judged at the next wave's start, and
        -- only a wave that reads nothing at all has nothing left to judge (james, REM-1205: a stop declared before
        -- the last reads were judged looked like a certificate and was not one).
        if si >= jsonb_array_length(ord) then
            exit;
        end if;
        doc := ord->>si;
        si := si + 1;
        if not reached ? doc then
            reached := reached || jsonb_build_object(doc, true);
            reads := reads || jsonb_build_array(jsonb_build_object('doc', doc, 'via', 'search',
                                                'expanded', (s->>'expand_all')::boolean));
            n := n + 1;
        end if;
    end loop;
    return jsonb_build_object('wave', wn, 'si', si, 'reads', reads, 'travels', travels, 'pending', pending,
                              'judged', (select count(*) from jsonb_each(st->'next') x where (st->'p') ? x.key),
                              'unjudged', (select count(*) from jsonb_each(st->'next') x where not (st->'p') ? x.key),
                              'dry', n = 0,
                              'stop', case when n = 0 then jsonb_build_object('reason', 'dry', 'wave', wn) end);
end;
$$;

-- ---------------------------------------------------------------- what a reader queries
-- Each view comes in two forms: one over a run, and one over a state already built (aiq.walk_state_*), so a
-- query that reads several views of one run builds its state once rather than once per view.
create or replace function aiq.walk_state_reads(p_state jsonb)
returns table (wave int, ord int, doc text, via text, expanded boolean)
language sql immutable security invoker set search_path = pg_catalog, public as $$
    select (w->>'wave')::int, r.ordinality::int, r.value->>'doc', r.value->>'via', (r.value->>'expanded')::boolean
      from jsonb_array_elements(p_state->'waves') w,
           jsonb_array_elements(w->'reads') with ordinality r
     order by 1, 2
$$;

create or replace function aiq.walk_reads(p_run uuid)
returns table (wave int, ord int, doc text, via text, expanded boolean)
language sql stable security invoker set search_path = pg_catalog, public as $$
    select * from aiq.walk_state_reads(aiq.walk_state(p_run))
$$;

-- Search's own order for the run's question: what plain search would have
-- read, rank by rank, for setting a walk beside it read for read.
create or replace function aiq.walk_search_order(p_run uuid)
returns table (rank int, doc text)
language sql stable security invoker set search_path = pg_catalog, public as $$
    select o.ordinality::int, o.value #>> '{}'
      from workflow.tasks tk, jsonb_array_elements(tk.output->'result'->0->'state'->'order') with ordinality o
     where tk.run_id = p_run and tk.step_key = 'start' and tk.status = 'succeeded'
     order by 1
$$;

create or replace function aiq.walk_state_clues(p_state jsonb)
returns table (key text, kind text, wave int, source text, targets text[], p real, decision text, state text,
               travelled_wave int)
language sql immutable security invoker set search_path = pg_catalog, public as $$
    with st as (select p_state as st)
    select c.key, c.value->>'kind', (c.value->>'wave')::int, c.value->>'source',
           array(select jsonb_array_elements_text(c.value->'targets')),
           (st->'p'->>c.key)::real,
           case when st->'p'->>c.key is null then 'unjudged'
                when (st->'p'->>c.key)::real >= (st->'settings'->>'gate')::real then 'accepted' else 'rejected' end,
           case when st->'p'->>c.key is null then 'unjudged'
                when (st->'travelled') ? c.key then 'travelled'
                when (st->'p'->>c.key)::real < (st->'settings'->>'gate')::real then 'rejected'
                when exists (select 1 from jsonb_array_elements_text(c.value->'targets') t
                              where not (st->'reached') ? t) then 'open'
                else 'spent' end,
           (st->'travelled'->>c.key)::int
      from st, jsonb_each(st->'clues') c
     order by 3, 1
$$;

create or replace function aiq.walk_clues(p_run uuid)
returns table (key text, kind text, wave int, source text, targets text[], p real, decision text, state text,
               travelled_wave int)
language sql stable security invoker set search_path = pg_catalog, public as $$
    select * from aiq.walk_state_clues(aiq.walk_state(p_run))
$$;

drop function if exists aiq.walk_waves(uuid);
create or replace function aiq.walk_state_waves(p_state jsonb)
returns table (wave int, reads int, expanded int, judged int, accepted int, fresh real, open_leads int,
               total_reads int)
language sql immutable security invoker set search_path = pg_catalog, public as $$
    with c as materialized (select * from aiq.walk_state_clues(p_state)),
    r as materialized (select * from aiq.walk_state_reads(p_state)),
    -- reached by a wave's end: read, or landed by a travel and queued to read
    reached as materialized (
        select wave, doc from r
        union
        select (w->>'wave')::int, l #>> '{}'
          from jsonb_array_elements(p_state->'waves') w,
               jsonb_array_elements(coalesce(w->'travels', '[]'::jsonb)) t,
               jsonb_array_elements(t->'land') l),
    w as (select distinct wave from r)
    select w.wave,
           (select count(*) from r where r.wave = w.wave)::int,
           (select count(*) from r where r.wave = w.wave - 1 and r.expanded)::int,
           (select count(*) from c where c.wave = w.wave and c.p is not null)::int,
           (select count(*) from c where c.wave = w.wave and c.decision = 'accepted')::int,
           (select case when count(*) = 0 then null
                        else (count(*) filter (where exists (
                                 select 1 from c where c.wave = w.wave and c.decision = 'accepted'
                                                   and c.source = r.doc)))::real / count(*) end
              from r where r.wave = w.wave - 1 and r.expanded),
           -- open: accepted, not travelled by the wave's end, and still leading somewhere not yet reached, so
           -- the last wave's count is walk_clues' state 'open'
           (select count(*) from c where c.decision = 'accepted' and c.wave <= w.wave
                                     and (c.travelled_wave is null or c.travelled_wave > w.wave)
                                     and exists (select 1 from unnest(c.targets) t
                                                  where not exists (select 1 from reached x where x.doc = t
                                                                                             and x.wave <= w.wave)))::int,
           (select count(*) from r where r.wave <= w.wave)::int
      from w where w.wave > 0
     order by 1
$$;

create or replace function aiq.walk_waves(p_run uuid)
returns table (wave int, reads int, expanded int, judged int, accepted int, fresh real, open_leads int,
               total_reads int)
language sql stable security invoker set search_path = pg_catalog, public as $$
    select * from aiq.walk_state_waves(aiq.walk_state(p_run))
$$;

create or replace function aiq.walk_summary(p_run uuid)
returns jsonb
language sql stable security invoker set search_path = pg_catalog, public as $$
    select jsonb_build_object(
        'question', st->'question', 'settings', st->'settings',
        'scope', (select input - 'question' - 'settings' - 'search' - 'replay' - 'offline' from workflow.runs where id = p_run),
        'reads', (select count(*) from aiq.walk_state_reads(st)),
        -- a read step that did not stop the walk records "stop": null, which is JSON, not SQL NULL
        'stop', case when jsonb_typeof(st->'stop') = 'object' then st->'stop'
                     else jsonb_build_object('reason', 'waves', 'wave', jsonb_array_length(st->'waves') - 1) end,
        'pending', st->'pending',
        'decider', jsonb_build_object('mode', case when (st->>'offline')::boolean then 'offline'
                                                   when jsonb_typeof(st->'replay') = 'string' then 'replay, then jev'
                                                   else 'jev' end,
                                      'replay', st->'replay', 'verdicts_held', st->'pmap_size'))
      from (select aiq.walk_state(p_run) as st offset 0) x
$$;

-- A finished run's verdicts, as a replay document a later run reads.
create or replace function aiq.walk_verdicts(p_run uuid)
returns jsonb
language sql stable security invoker set search_path = pg_catalog, public as $$
    select jsonb_build_object('model', (select model from claims.deciders where name = 'jev'), 'task', aiq.walk_task(),
                              'verdicts', jsonb_build_object(st->'question'->>'id',
                                  (select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
                                     from jsonb_each(st->'p') where (st->'clues') ? key)))
      from (select aiq.walk_state(p_run) as st offset 0) x
$$;

-- The verdicts earlier runs kept for a question under this wording, each answered before p_before.
create or replace function aiq.walk_kept(p_question text, p_before timestamptz default null)
returns table (key text, p real, at timestamptz, model text, run uuid)
language sql stable security invoker set search_path = pg_catalog, public as $$
    select v.key, (v.value->>'p')::real, (v.value->>'at')::timestamptz, v.value->>'model', (res.metadata->>'run')::uuid
      from content.resources res, jsonb_each(res.metadata->'verdicts') v
     where left(res.uri, length('verdicts:' || p_question || ':')) = 'verdicts:' || p_question || ':'
       and res.metadata->>'question' = p_question
       and res.metadata->>'task' = aiq.walk_task()
       and (p_before is null or (v.value->>'at')::timestamptz < p_before)
$$;

-- Keep a run's verdicts: one document a run, verdicts:<question>:<run>, written once and never changed, each verdict
-- with its P, when it was answered and the model. The log is append-only because a run is: a later run keeps its own
-- document beside this one. The verdicts are the document's metadata and its one chunk is '-', so search never
-- finds them. A run that asked nobody keeps nothing.
create or replace function aiq.walk_keep(p_run uuid, p_channel text default 'walk-replays')
returns jsonb
language plpgsql volatile security invoker set search_path = pg_catalog, public as $$
declare
    q   jsonb := (select input->'question' from workflow.runs where id = p_run);
    v   jsonb;
    uri text := 'verdicts:' || (q->>'id') || ':' || p_run;
begin
    select jsonb_object_agg(a.key, jsonb_build_object('p', a.p, 'at', a.at, 'model', a.model)) into v
      from aiq.walk_answers(p_run) a;
    if v is null then
        return jsonb_build_object('kept', 0);
    end if;
    perform content.register_text(p_channel, uri, '[{"content": "-"}]'::jsonb,
                format('verdicts for %s, run %s', q->>'id', p_run), uri, null,
                jsonb_build_object('question', q->>'id', 'run', p_run, 'task', aiq.walk_task(), 'verdicts', v));
    return jsonb_build_object('kept', (select count(*) from jsonb_object_keys(v)), 'uri', uri);
end;
$$;

-- ---------------------------------------------------------------- the workflow
drop function if exists aiq.install_walk_workflow(text, text, int);
-- p_model embeds the question for a channel walk: the deployment's default
-- model when it has a provider. With none (a database whose vectors are
-- written directly, as dev/init's demo space is), the workflow has no embed
-- step, and walks a graph or a channel given its order.
create or replace function aiq.install_walk_workflow(p_name text default 'walk', p_decider text default 'jev',
                                                     p_waves int default 10, p_model text default null)
returns text
language plpgsql set search_path = pg_catalog, public as $$
declare
    d       claims.deciders;
    v_model text := coalesce(p_model, (select name from aiq.embedding_models
                                        where is_default and provider is not null limit 1));
    v_q     text := '';
    v_vec   text := 'null';
begin
    if v_model is not null then
        v_q := format($q$
  - id: q
    when: "aiq.walk_needs_vector({{run.$id}}::uuid)"
    embed:
      text: '{{run.question.text}}'
      model: %s
$q$, v_model);
        v_vec := '{{steps.q.result}}';
    end if;
    select * into d from claims.deciders where name = p_decider;
    if not found then
        raise no_data_found using message = format('no decider named %s is configured', p_decider),
            hint = 'insert a row into claims.deciders: its endpoint, model and the worker credential it calls with';
    end if;
    if p_waves not between 1 and 20 then
        raise invalid_parameter_value using message = 'a walk has 1 to 20 waves (repeat''s bound)';
    end if;
    perform workflow.define_yaml(format($y$
name: %1$s
steps:%6$s
  - id: start
    %7$s
    sql: "select aiq.walk_start({{run.$id}}::uuid, %8$s::vector) as state"
  - id: wave
    needs: [start]
    repeat:
      max: %4$s
      until: "({{steps.read.result.0.state.dry}})::boolean"
      steps:
        - id: judge
          matrix:
            rows: "select chunk, keys, body from aiq.walk_requests({{run.$id}}::uuid, '%5$s')"
            max_fanout: 200
            continue_on: failed
            template:
              rest:
                url: %2$s
                method: POST
                credential_ref: %3$s
                body: '{{item.body}}'
        - id: read
          needs: [judge]
          sql: "select aiq.walk_read({{run.$id}}::uuid) as state"
  - id: keep
    needs: [wave]
    sql: {statement: "select aiq.walk_keep({{run.$id}}::uuid) as kept", write: true}
$y$, p_name, d.endpoint, d.credential_ref, p_waves, p_decider, v_q,
      case when v_model is not null then 'needs: [q]' else '' end, v_vec));
    return format('%s: a clue walk of up to %s waves, judged by %s, %s', p_name, p_waves, p_decider,
                  coalesce('questions embedded by ' || v_model, 'with no embed step (graph walks, or a given order)'));
end;
$$;

grant execute on function aiq.walk_task(), aiq.walk_settings(jsonb), aiq.walk_needs_vector(uuid), aiq.walk_graph(jsonb, timestamptz),
                          aiq.walk_keys(jsonb), aiq.walk_texts(jsonb, text[]), aiq.walk_graph_version(jsonb),
                          aiq.walk_graph_uri(jsonb, jsonb), aiq.walk_graph_build(jsonb, timestamptz), aiq.walk_index(jsonb, text),
                          aiq.walk_answers(uuid), aiq.walk_kept(text, timestamptz), aiq.walk_keep(uuid, text),
                          aiq.walk_snippet(text, text), aiq.walk_state(uuid), aiq.walk_start(uuid, vector),
                          aiq.walk_run_graph(uuid),
                          aiq.walk_requests(uuid, text), aiq.walk_read(uuid), aiq.walk_reads(uuid), aiq.walk_search_order(uuid),
                          aiq.walk_clues(uuid), aiq.walk_waves(uuid), aiq.walk_summary(uuid), aiq.walk_verdicts(uuid)
    to authenticated;
revoke all on function aiq.install_walk_workflow(text, text, int, text) from public;
