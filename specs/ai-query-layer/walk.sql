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

-- The decider's wording. A verdict belongs to its wording: a replay made
-- under another one is refused rather than mixed (percolate-core decide.py).
create or replace function aiq.walk_task() returns text
language sql immutable as $$
select 'For each option, a lead into the user''s earlier messages that has not been read yet: a term the messages '
    || 'share, or the messages beside or close in meaning to one already read. Would following it likely reach '
    || 'information needed to answer `question`, or part of it?'
$$;

-- The settings, with the study's test arm as the default (explore10_all
-- without the random draw): 10 waves of 50, 3 travels a step's worth, seeds
-- 10, search 10 a wave, next reaching 2 either side, terms shared by at most
-- 10, the gate at 0.5, every read raising clues.
create or replace function aiq.walk_settings(p_input jsonb) returns jsonb
language sql immutable as $$
select jsonb_build_object('waves', 10, 'wave', 50, 'seeds', 10, 'per_wave', 10, 'span', 2, 'cap', 10,
                          'gate', 0.5, 'expand_all', true, 'near', 3)
       || coalesce(p_input->'settings', '{}'::jsonb)
$$;

-- One documents-and-links load for a run's scope, as the caller, as of p_at.
-- Returned as one jsonb so a walk's state is computed in one pass over it:
--   keys:  {node uuid: key}         text: {key: body}
--   terms: {key: [term, ...]}       post: {term: [key, ...]}
--   beside:{key: [key, ...]} within span either side, by walk_next
--   near:  {key: [key, ...]} the first `near` nearest, and who has it as one
create or replace function aiq.walk_graph(p_input jsonb, p_at timestamptz default null)
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
    if p_input ? 'channel' then
        select jsonb_object_agg(n.id::text, coalesce(r.uri, r.id::text)),
               jsonb_object_agg(coalesce(r.uri, r.id::text),
                   coalesce((select string_agg(c.content, ' ' order by c.ordinal)
                               from content.resource_chunks c where c.resource_id = r.id), ''))
          into docs, terms   -- terms holds the text map for a moment
          from content.resources r
          join content.channels ch on ch.id = r.channel_id
          join aiq.nodes n on n.entity_type = 'document' and n.entity_id = r.id
         where ch.name = p_input->>'channel';
    elsif p_input ? 'nodes' then
        select jsonb_object_agg(n.id::text, k.key), jsonb_object_agg(k.key, coalesce(n.summary, k.key))
          into docs, terms
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
    terms := jsonb_build_object('text', terms, 'terms', coalesce(s, '{}'::jsonb));
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
    return jsonb_build_object('keys', docs, 'text', terms->'text', 'terms', terms->'terms',
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
    rd       jsonb;
    src      text;
    t        text;
    tg       jsonb;
    k        text;
    stop     jsonb;
begin
    select * into r from workflow.runs where id = p_run;
    if not found then
        raise no_data_found using message = format('no run %s that you may read', p_run);
    end if;
    inp := r.input;
    s := aiq.walk_settings(inp);
    q := inp->'question';
    g := aiq.walk_graph(inp, r.created_at);
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
    select pmap || coalesce(jsonb_object_agg(kk.value #>> '{}',
                                             (ch.output->'result'->'answers'->('c' || (kk.ordinality - 1))->>'noul')::real),
                            '{}'::jsonb)
      into pmap
      from workflow.tasks jt
      join workflow.tasks ch on ch.matrix_parent_id = jt.id and ch.status = 'succeeded'
      cross join lateral jsonb_array_elements(ch.input->'item'->'keys') with ordinality kk
     where jt.run_id = p_run and jt.step_key like 'judge\_%'
       and ch.output->'result'->'answers'->('c' || (kk.ordinality - 1)) ? 'noul';
    -- The read steps' records, in wave order; wave 0 is the start step's.
    select jsonb_agg(x.rec order by (x.rec->>'wave')::int) into logs
      from (select tk.output->'result'->0->'state' as rec
              from workflow.tasks tk
             where tk.run_id = p_run and tk.status = 'succeeded'
               and (tk.step_key = 'start' or tk.step_key like 'read\_%')) x
     where x.rec ? 'wave';
    for w in select value from jsonb_array_elements(coalesce(logs, '[]'::jsonb)) loop
        wn := (w->>'wave')::int;
        -- The clues this wave's round judged: raised by the previous wave's expanded reads.
        if wn > 0 then
            for k in select key from jsonb_each(nxt) loop
                clues := clues || jsonb_build_object(k, (nxt->k) - 'text'
                                     || jsonb_build_object('wave', wn, 'p', pmap->k));
                if (pmap->>k)::real >= (s->>'gate')::real then
                    null;  -- accepted; open until travelled or spent
                end if;
            end loop;
        end if;
        -- Apply the wave's reads and travels.
        for rd in select value from jsonb_array_elements(w->'reads') loop
            reached := reached || jsonb_build_object(rd->>'doc', true);
        end loop;
        for rd in select value from jsonb_array_elements(coalesce(w->'travels', '[]'::jsonb)) loop
            travelled := travelled || jsonb_build_object(rd->>'key', wn);
            for t in select value #>> '{}' from jsonb_array_elements(rd->'land') loop
                reached := reached || jsonb_build_object(t, true);
            end loop;
        end loop;
        pending := coalesce(w->'pending', '[]'::jsonb);
        waves := waves || jsonb_build_array(w || jsonb_build_object('raised',
                     (select coalesce(jsonb_agg(key order by key), '[]'::jsonb) from jsonb_each(nxt))));
        -- The next round's clues: out of this wave's expanded reads, never raised before, leading somewhere unread.
        nxt := '{}'::jsonb;
        for rd in select value from jsonb_array_elements(w->'reads') where (value->>'expanded')::boolean loop
            src := rd->>'doc';
            for t in select value #>> '{}' from jsonb_array_elements(coalesce(g->'terms'->src, '[]'::jsonb)) loop
                k := 'term:' || t;
                if jsonb_array_length(coalesce(g->'post'->t, '[]'::jsonb)) <= (s->>'cap')::int
                   and not clues ? k then
                    select coalesce(jsonb_agg(value order by value #>> '{}'), '[]'::jsonb) into tg
                      from jsonb_array_elements(g->'post'->t) where not reached ? (value #>> '{}');
                    if jsonb_array_length(tg) > 0 then
                        if nxt ? k then
                            select jsonb_agg(distinct value) into tg
                              from (select value from jsonb_array_elements(tg)
                                    union select value from jsonb_array_elements(nxt->k->'targets')) u;
                            nxt := jsonb_set(nxt, array[k, 'targets'], tg);
                        else
                            nxt := nxt || jsonb_build_object(k, jsonb_build_object(
                                'kind', 'term', 'x', t, 'source', src, 'targets', tg,
                                'text', format('the term ''%s'', which %s unread message(s) share with this read one: "%s"',
                                               t, jsonb_array_length(tg), aiq.walk_snippet(g->'text'->>src, t))));
                        end if;
                    end if;
                end if;
            end loop;
            foreach t in array array['next', 'near'] loop
                k := t || ':' || src;
                if not clues ? k then
                    select coalesce(jsonb_agg(distinct value), '[]'::jsonb) into tg
                      from jsonb_array_elements(coalesce(g->(case t when 'next' then 'beside' else 'near' end)->src,
                                                         '[]'::jsonb))
                     where not reached ? (value #>> '{}') and value #>> '{}' <> src;
                    if jsonb_array_length(tg) > 0 then
                        nxt := nxt || jsonb_build_object(k, jsonb_build_object(
                            'kind', t, 'x', src, 'source', src, 'targets', tg,
                            'text', format('%s: "%s"',
                                           case t when 'next' then 'the messages just before and after this read one, in the same sitting'
                                                  else 'the messages closest in meaning to this read one' end,
                                           aiq.walk_snippet(g->'text'->>src))));
                    end if;
                end if;
            end loop;
        end loop;
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
                          from aiq.search('chunks', inp->'question'->>'text', p_vector, null, 2000)) h
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
     where ordinality <= (s->>'seeds')::int and g->'text' ? (value #>> '{}');
    return jsonb_build_object('wave', 0, 'order', ord, 'si', (s->>'seeds')::int, 'reads', seeds,
                              'travels', '[]'::jsonb, 'pending', '[]'::jsonb);
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
    reads   jsonb := '[]'::jsonb;
    travels jsonb := '[]'::jsonb;
    pending jsonb := st->'pending';
    best    text;
    bp      real;
    land    jsonb;
    doc     text;
    n       int := 0;
    k       text;
    p       real;
    dry     boolean := false;
begin
    if wn = 0 then
        raise invalid_parameter_value using message = 'the walk has not started: no seeds recorded';
    end if;
    -- Every accepted clue still leading somewhere unread: earlier waves' not
    -- yet travelled, and this round's.
    for k in select key from jsonb_each(st->'clues') loop
        p := (st->'p'->>k)::real;
        if p >= (s->>'gate')::real and not (st->'travelled') ? k then
            open_ := open_ || jsonb_build_object(k, jsonb_build_object('p', p, 'targets', st->'clues'->k->'targets'));
        end if;
    end loop;
    for k in select key from jsonb_each(st->'next') loop
        p := (st->'p'->>k)::real;
        if p >= (s->>'gate')::real then
            open_ := open_ || jsonb_build_object(k, jsonb_build_object('p', p, 'targets', st->'next'->k->'targets'));
        end if;
    end loop;
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
        -- the best accepted clue that still leads somewhere unread, ties by key
        best := null;
        select o.key, (o.value->>'p')::real into best, bp
          from jsonb_each(open_) o
         where exists (select 1 from jsonb_array_elements(o.value->'targets') t where not reached ? (t #>> '{}'))
         order by (o.value->>'p')::real desc, o.key
         limit 1;
        if best is not null then
            select coalesce(jsonb_agg(t order by ord_), '[]'::jsonb) into land
              from jsonb_array_elements(open_->best->'targets') with ordinality x(t, ord_)
             where not reached ? (t #>> '{}');
            open_ := open_ - best;
            for doc in select value #>> '{}' from jsonb_array_elements(land) loop
                reached := reached || jsonb_build_object(doc, true);
            end loop;
            pending := pending || land;
            travels := travels || jsonb_build_array(jsonb_build_object('key', best, 'p', round(bp::numeric, 3),
                                                                       'land', land));
            continue;
        end if;
        -- nothing accepted is left: search fills the wave
        if si >= jsonb_array_length(ord) then
            dry := true;
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
                              'dry', dry or (n = 0),
                              'stop', case when dry or n = 0 then jsonb_build_object('reason', 'dry', 'wave', wn) end);
end;
$$;

-- ---------------------------------------------------------------- what a reader queries
create or replace function aiq.walk_reads(p_run uuid)
returns table (wave int, ord int, doc text, via text, expanded boolean)
language sql stable security invoker set search_path = pg_catalog, public as $$
    with st as materialized (select aiq.walk_state(p_run) as st)
    select (w->>'wave')::int, r.ordinality::int, r.value->>'doc', r.value->>'via', (r.value->>'expanded')::boolean
      from st, jsonb_array_elements(st->'waves') w,
           jsonb_array_elements(w->'reads') with ordinality r
     order by 1, 2
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

create or replace function aiq.walk_clues(p_run uuid)
returns table (key text, kind text, wave int, source text, targets text[], p real, decision text, state text,
               travelled_wave int)
language sql stable security invoker set search_path = pg_catalog, public as $$
    with st as materialized (select aiq.walk_state(p_run) as st)
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

drop function if exists aiq.walk_waves(uuid);
create or replace function aiq.walk_waves(p_run uuid)
returns table (wave int, reads int, expanded int, judged int, accepted int, fresh real, open_leads int,
               total_reads int)
language sql stable security invoker set search_path = pg_catalog, public as $$
    with c as materialized (select * from aiq.walk_clues(p_run)),
    r as materialized (select * from aiq.walk_reads(p_run)),
    -- reached by a wave's end: read, or landed by a travel and queued to read
    reached as materialized (
        select wave, doc from r
        union
        select (w->>'wave')::int, l #>> '{}'
          from jsonb_array_elements(aiq.walk_state(p_run)->'waves') w,
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

create or replace function aiq.walk_summary(p_run uuid)
returns jsonb
language sql stable security invoker set search_path = pg_catalog, public as $$
    select jsonb_build_object(
        'question', st->'question', 'settings', st->'settings',
        'scope', (select input - 'question' - 'settings' - 'search' - 'replay' - 'offline' from workflow.runs where id = p_run),
        'reads', (select count(*) from aiq.walk_reads(p_run)),
        'stop', coalesce(st->'stop', jsonb_build_object('reason', 'waves', 'wave', jsonb_array_length(st->'waves') - 1)),
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
$y$, p_name, d.endpoint, d.credential_ref, p_waves, p_decider, v_q,
      case when v_model is not null then 'needs: [q]' else '' end, v_vec));
    return format('%s: a clue walk of up to %s waves, judged by %s, %s', p_name, p_waves, p_decider,
                  coalesce('questions embedded by ' || v_model, 'with no embed step (graph walks, or a given order)'));
end;
$$;

grant execute on function aiq.walk_task(), aiq.walk_settings(jsonb), aiq.walk_needs_vector(uuid), aiq.walk_graph(jsonb, timestamptz),
                          aiq.walk_snippet(text, text), aiq.walk_state(uuid), aiq.walk_start(uuid, vector),
                          aiq.walk_requests(uuid, text), aiq.walk_read(uuid), aiq.walk_reads(uuid), aiq.walk_search_order(uuid),
                          aiq.walk_clues(uuid), aiq.walk_waves(uuid), aiq.walk_summary(uuid), aiq.walk_verdicts(uuid)
    to authenticated;
revoke all on function aiq.install_walk_workflow(text, text, int, text) from public;
