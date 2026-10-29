-- ============================================================================
-- THE QUESTION STACK: A WALK'S BOARD (REM-1245, specs/ai-query-layer/walk.md §6-§9)
-- ============================================================================
-- A memoryless walk judges every lead against the user's question alone and fixes each P when the lead is raised.
-- Early on, resembling the question is a good signal; later the evidence that resembles it is already read, and the
-- walk keeps accepting echoes of what it has (Jev's AUC fell to 0.27-0.36 in later waves, REM-1240). Under
-- walk.stack the walk keeps a board instead: the questions it is answering, which reads answered which, and which are
-- still open, and Jev judges each lead against the open ones.
--
-- THE BOARD IS A BIPARTITE GRAPH: questions on one side, reads on the other, an edge where the decider judged a read
-- to answer a question, and parent links between questions. The root is the walk's question; a part is a narrower
-- question under it. In flight the board is the output of each wave's `stack` step, so a walk writes nothing but its
-- own task rows; aiq.walk_keep_stack makes it walk_question nodes and walk_part_of / walk_answers edges when the walk
-- is kept. No new table.
--
-- A WAVE, after the previous wave's reads (wave 0's are search's seeds):
--     assess  matrix  each new read x each open question: does the read answer it, or part of it?   A|<q>|<read>
--     shape   matrix  each candidate part: is it a part its parent's answer needs?                 S|<parent>|<term>
--                     each open question that gained evidence: do its reads answer it?              C|<q>|<n reads>
--     stack   sql     the moves those verdicts decide, recorded: linked, answered, added, open
--     judge   matrix  each live lead x each open question it has not been judged against           L|<q>|<lead>
--     read    sql     a lead's P is its highest against an open question; read as before
-- Every judgement is Jev's. No generative model is in the loop (Sirsh, M-20261029-105852-65d0): a part is its parent
-- narrowed to a term the evidence holds (stack.part_wording), and Jev chooses among those; a part a model wrote
-- comes in the run's input as `parts`, from a client the walk asked (walk.md §6.3), and is recorded `by: client`.
--
-- Every verdict is keyed as above and kept with the run's answers, so a replay replays the board, and a verdict is
-- asked once: a read is assessed once against each question open when it was read, so what a lead's description
-- says of its source never changes after the lead is first judged.
-- ============================================================================

-- The board before any wave: the root, open, and any parts the client gave the run.
create or replace function aiq.walk_stack_initial(p_input jsonb)
returns jsonb
language sql immutable set search_path = pg_catalog, public as $$
    select jsonb_build_object(
        'iteration', 0, 'assessed', -1,
        'questions', jsonb_build_object('root', jsonb_build_object(
                         'parent', null, 'text', p_input->'question'->>'text', 'node', p_input->'question'->'node_id',
                         'by', 'root', 'opened_wave', 0, 'opened_p', null, 'state', 'open',
                         'closed_wave', null, 'close_p', null))
                     || coalesce((select jsonb_object_agg('client:' || (o - 1), jsonb_build_object(
                                     'parent', 'root', 'text', x #>> '{}', 'by', 'client', 'opened_wave', 0,
                                     'opened_p', null, 'state', 'open', 'closed_wave', null, 'close_p', null))
                                    from jsonb_array_elements(coalesce(p_input->'parts', '[]'::jsonb)) with ordinality p(x, o)),
                                 '{}'::jsonb),
        'evidence', '[]'::jsonb,
        'open', jsonb_build_array('root')
                || coalesce((select jsonb_agg('client:' || (o - 1) order by o)
                               from jsonb_array_elements(coalesce(p_input->'parts', '[]'::jsonb)) with ordinality p(x, o)),
                            '[]'::jsonb),
        'asked_terms', '[]'::jsonb,
        'moves', null)
$$;

-- The board after each recorded stack step, in order: the initial board, then each wave's moves applied to it. The
-- moves are the only record; the board is always this fold of them.
create or replace function aiq.walk_stack_boards(p_run uuid)
returns setof jsonb
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    b   jsonb := aiq.walk_stack_initial((select input from workflow.runs where id = p_run));
    rec jsonb;
    m   jsonb;
    x   jsonb;
begin
    for rec in select tk.output->'result'->0->'state'
                 from workflow.tasks tk
                where tk.run_id = p_run and tk.step_key like 'stack\_%' and tk.status = 'succeeded'
                  and jsonb_typeof(tk.output->'result'->0->'state') = 'object'
                order by (tk.output->'result'->0->'state'->>'iteration')::int loop
        m := rec->'moves';
        for x in select value from jsonb_array_elements(m->'added') loop
            b := jsonb_set(b, '{questions}', b->'questions' || jsonb_build_object(x->>'q', jsonb_build_object(
                     'parent', x->'parent', 'text', x->'text', 'by', x->'by', 'term', x->'term', 'opened_wave', m->'wave',
                     'opened_p', x->'p', 'state', 'open', 'closed_wave', null, 'close_p', null)));
        end loop;
        for x in select value from jsonb_array_elements(m->'answered') loop
            b := jsonb_set(b, array['questions', x->>'q'], b->'questions'->(x->>'q')
                           || jsonb_build_object('state', 'answered', 'closed_wave', m->'wave', 'close_p', x->'p'));
        end loop;
        b := b || jsonb_build_object('iteration', rec->'iteration', 'assessed', rec->'assessed',
                                     'evidence', (b->'evidence') || (m->'linked'), 'open', m->'open',
                                     'asked_terms', (b->'asked_terms') || (rec->'asked_terms'), 'moves', m);
        return next b;
    end loop;
    if rec is null then
        return next b;
    end if;
end;
$$;

-- What the user said in each of some documents: a document's stored terms_text (the user's own words) or its text,
-- or a node's summary. The line a read is assessed by and shown with.
create or replace function aiq.walk_lines(p_input jsonb, p_docs text[])
returns jsonb
language sql stable security invoker set search_path = pg_catalog, public as $$
    select coalesce(jsonb_object_agg(d.doc, left(btrim(regexp_replace(d.line, '\s+', ' ', 'g')), 400)), '{}'::jsonb) from (
        select coalesce(r.uri, r.id::text) as doc,
               coalesce(r.metadata->>'terms_text',
                        (select string_agg(c.content, ' ' order by c.ordinal) from content.resource_chunks c
                          where c.resource_id = r.id), '') as line
          from content.resources r join content.channels ch on ch.id = r.channel_id
         where p_input ? 'channel' and ch.name = p_input->>'channel' and coalesce(r.uri, r.id::text) = any(p_docs)
        union all
        select k.key, coalesce(n.summary, k.key)
          from aiq.nodes n join aiq.node_keys k on k.node_id = n.id and k.kind = 'canonical'
         where p_input ? 'nodes' and n.entity_type = p_input->>'nodes' and k.key = any(p_docs)
    ) d
$$;

-- Where each of some documents sits, for laying a walk out: its sitting and place in it (the index's walk_next
-- provenance {sitting, pos}, pos being the edge's source's place, so a sitting's last is one past the edge into it) and
-- when it was said (said_at), each when known.
create or replace function aiq.walk_places(p_input jsonb, p_docs text[])
returns jsonb
language sql stable security invoker set search_path = pg_catalog, public as $$
    select coalesce(jsonb_object_agg(d.doc, jsonb_build_object(
               'sitting', coalesce(o.provenance->>'sitting', i.provenance->>'sitting'),
               'pos', coalesce((o.provenance->>'pos')::int, (i.provenance->>'pos')::int + 1),
               'said_at', d.said_at)), '{}'::jsonb)
      from (select coalesce(r.uri, r.id::text) as doc, n.id as node, r.metadata->>'said_at' as said_at
              from content.resources r join content.channels ch on ch.id = r.channel_id
              join aiq.nodes n on n.entity_type = 'document' and n.entity_id = r.id
             where p_input ? 'channel' and ch.name = p_input->>'channel' and coalesce(r.uri, r.id::text) = any(p_docs)
            union all
            select k.key, n.id, null
              from aiq.nodes n join aiq.node_keys k on k.node_id = n.id and k.kind = 'canonical'
             where p_input ? 'nodes' and n.entity_type = p_input->>'nodes' and k.key = any(p_docs)) d
      left join lateral (select e.provenance from aiq.edges e where e.src_id = d.node and e.relation in ('walk_next')
                            and e.valid_to is null limit 1) o on true
      left join lateral (select e.provenance from aiq.edges e where e.dst_id = d.node and e.relation in ('walk_next')
                            and e.valid_to is null limit 1) i on true
$$;

-- The next wave's stack work, from the board as last recorded and the verdicts the run holds (p_state is
-- aiq.walk_state(run)). Returns what to ask -- assess, candidates, closes, each with its key and text -- and the board
-- those verdicts decide. The requests and the stack step both read it, so what was asked and what was decided cannot
-- disagree. A verdict not yet given (offline, or not yet asked) decides nothing: no link, no part, no close.
create or replace function aiq.walk_stack_next(p_run uuid, p_state jsonb)
returns jsonb
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    inp     jsonb := (select input from workflow.runs where id = p_run);
    s       jsonb := p_state->'settings';
    sp      jsonb := aiq.parameters_of('stack');
    board   jsonb := p_state->'board';
    ans     jsonb := coalesce(p_state->'answers', '{}'::jsonb);
    w       int := (board->>'assessed')::int + 1;
    reads   jsonb;
    lines   jsonb;
    g       jsonb;
    assess  jsonb;
    linked  jsonb;
    ev      jsonb;
    closes  jsonb;
    cands   jsonb;
    qs      jsonb := board->'questions';
    open_   jsonb := board->'open';
    closed  jsonb := '[]'::jsonb;
    added   jsonb := '[]'::jsonb;
    c       record;
    nparts  int;
begin
    -- the reads of the wave after the last one assessed; none yet, and there is nothing to do
    select coalesce(jsonb_agg(r.value->>'doc' order by r.ordinality), '[]'::jsonb) into reads
      from jsonb_array_elements(p_state->'waves') wv, jsonb_array_elements(wv->'reads') with ordinality r
     where (wv->>'wave')::int = w;
    if jsonb_array_length(reads) = 0 then
        return jsonb_build_object('assess', '[]'::jsonb, 'closes', '[]'::jsonb, 'candidates', '[]'::jsonb,
                                  'record', jsonb_build_object('iteration', (board->>'iteration')::int + 1,
                                                               'assessed', board->'assessed', 'asked_terms', '[]'::jsonb,
                                                               'moves', jsonb_build_object('wave', w, 'linked', '[]'::jsonb,
                                                                   'answered', '[]'::jsonb, 'added', '[]'::jsonb, 'open', open_)));
    end if;
    lines := aiq.walk_lines(inp, array(select jsonb_array_elements_text(reads)));
    -- 1. assess: each new read against each open question
    select coalesce(jsonb_agg(jsonb_build_object('key', 'A|' || o.q || '|' || r.doc, 'q', o.q, 'doc', r.doc,
                                                 'text', coalesce(lines->>r.doc, r.doc), 'p', ans->('A|' || o.q || '|' || r.doc))
                              order by o.q, r.o), '[]'::jsonb)
      into assess
      from jsonb_array_elements_text(reads) with ordinality r(doc, o), jsonb_array_elements_text(open_) o(q);
    select coalesce(jsonb_agg(jsonb_build_object('doc', a->>'doc', 'q', a->>'q', 'p', (a->>'p')::real, 'wave', w)
                              order by a->>'q', (a->>'p')::real desc), '[]'::jsonb)
      into linked
      from jsonb_array_elements(assess) a
     where (a->>'p')::real >= (sp->>'answers_gate')::real;
    ev := board->'evidence' || linked;
    -- 2. close: each open question that gained evidence, by its reads' lines; the root by every read linked to it or
    -- to any part. Keyed by how many reads it then has, so a question that gains more is asked again.
    with gained as (
        select distinct x->>'q' as q from jsonb_array_elements(linked) x
        union
        select 'root' where jsonb_array_length(linked) > 0
    ), mine as (
        select gq.q, e->>'doc' as doc, max((e->>'p')::real) as p
          from gained gq, jsonb_array_elements(ev) e
         where e->>'q' = gq.q or (gq.q = 'root')
         group by 1, 2
    ), counted as (
        select q, count(*) as n from mine group by q
    ), shown as (
        select m.q, m.doc, m.p, row_number() over (partition by m.q order by m.p desc, m.doc) as k from mine m
    )
    select coalesce(jsonb_agg(jsonb_build_object('key', 'C|' || ct.q || '|' || ct.n, 'q', ct.q,
                                                 'text', (select string_agg(format('%s) "%s"', sh.k,
                                                                                   aiq.walk_snippet(coalesce(l.v->>sh.doc, sh.doc))),
                                                                            ' ' order by sh.k)
                                                            from shown sh
                                                            cross join (select aiq.walk_lines(inp, array(select doc from shown where q = ct.q)) as v) l
                                                           where sh.q = ct.q and sh.k <= (sp->>'evidence_lines')::int),
                                                 'p', ans->('C|' || ct.q || '|' || ct.n)) order by ct.q), '[]'::jsonb)
      into closes
      from counted ct
     where open_ ? ct.q;
    -- 3. candidate parts: the most specific terms (fewest documents holding them) of the reads linked this wave, not
    -- yet asked about, each under the question its read answered best
    g := aiq.walk_run_graph(p_run);
    with src as (
        select distinct on (x->>'doc') x->>'doc' as doc, x->>'q' as q
          from jsonb_array_elements(linked) x order by x->>'doc', (x->>'p')::real desc, x->>'q'
    ), terms as (
        select distinct on (t) t, src.q, jsonb_array_length(coalesce(g->'post'->t, '[]'::jsonb)) as n
          from src, jsonb_array_elements_text(coalesce(g->'terms'->src.doc, '[]'::jsonb)) t
         where not board->'asked_terms' ? t and not qs ? ('part:' || t)
         order by t, 3, src.q
    ), top as (
        select * from terms order by n, t limit (sp->>'candidates')::int
    )
    select coalesce(jsonb_agg(jsonb_build_object('key', 'S|' || top.q || '|' || top.t, 'parent', top.q, 'term', top.t,
                                                 'text', format(sp->>'part_wording', qs->top.q->>'text', top.t),
                                                 'p', ans->('S|' || top.q || '|' || top.t)) order by top.n, top.t), '[]'::jsonb)
      into cands
      from top;
    -- the moves the verdicts decide: closes first, the root only with no part of it left open, then parts
    for c in select x->>'q' as q, (x->>'p')::real as p from jsonb_array_elements(closes) x
              where x->>'q' <> 'root' and (x->>'p')::real >= (sp->>'close_gate')::real loop
        qs := jsonb_set(qs, array[c.q], qs->c.q || jsonb_build_object('state', 'answered', 'closed_wave', w, 'close_p', c.p));
        closed := closed || jsonb_build_array(jsonb_build_object('q', c.q, 'p', c.p));
        open_ := open_ - c.q;
    end loop;
    for c in select x->>'q' as q, (x->>'p')::real as p from jsonb_array_elements(closes) x
              where x->>'q' = 'root' and (x->>'p')::real >= (sp->>'close_gate')::real loop
        if not exists (select 1 from jsonb_array_elements_text(open_) o where o <> 'root') then
            qs := jsonb_set(qs, '{root}', qs->'root' || jsonb_build_object('state', 'answered', 'closed_wave', w, 'close_p', c.p));
            closed := closed || jsonb_build_array(jsonb_build_object('q', 'root', 'p', c.p));
            open_ := open_ - 'root';
        end if;
    end loop;
    nparts := (select count(*) from jsonb_array_elements_text(open_) o where o <> 'root');
    for c in select x->>'parent' as parent, x->>'term' as term, x->>'text' as text, (x->>'p')::real as p
               from jsonb_array_elements(cands) x
              where (x->>'p')::real >= (sp->>'split_gate')::real and open_ ? (x->>'parent')
              order by (x->>'p')::real desc, x->>'term' loop
        exit when nparts >= (sp->>'max_open')::int;
        qs := qs || jsonb_build_object('part:' || c.term, jsonb_build_object(
                  'parent', c.parent, 'text', c.text, 'by', 'decider', 'term', c.term, 'opened_wave', w, 'opened_p', c.p,
                  'state', 'open', 'closed_wave', null, 'close_p', null));
        open_ := open_ || jsonb_build_array('part:' || c.term);
        added := added || jsonb_build_array(jsonb_build_object('q', 'part:' || c.term, 'parent', c.parent, 'p', c.p,
                                                               'text', c.text, 'term', c.term, 'by', 'decider'));
        nparts := nparts + 1;
    end loop;
    -- the record is the wave's moves only, which is what the stack step keeps: a board grows with every wave and would
    -- outgrow a task's 64 KB, a wave's moves are bounded by its reads and the open questions
    return jsonb_build_object(
        'assess', assess, 'closes', closes, 'candidates', cands,
        'record', jsonb_build_object(
            'iteration', (board->>'iteration')::int + 1, 'assessed', w,
            'asked_terms', coalesce((select jsonb_agg(x->'term') from jsonb_array_elements(cands) x), '[]'::jsonb),
            'moves', jsonb_build_object('wave', w, 'linked', linked, 'answered', closed, 'added', added, 'open', open_)));
end;
$$;

-- The assess and shape steps' rows: one Jev request per question (or parent) and 60 options, for the verdicts the run
-- does not hold. None when the walk keeps no stack, or asks nobody.
create or replace function aiq.walk_stack_requests(p_run uuid, p_phase text, p_decider text default 'jev')
returns table (chunk int, keys jsonb, body jsonb)
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    inp jsonb := (select input from workflow.runs where id = p_run);
    st  jsonb;
    nx  jsonb;
    d   claims.deciders;
begin
    if not coalesce((aiq.walk_settings(inp)->>'stack')::boolean, false) or coalesce((inp->>'offline')::boolean, false) then
        return;
    end if;
    if p_phase not in ('assess', 'shape') then
        raise invalid_parameter_value using message = format('a stack request is for assess or shape, not %s', p_phase);
    end if;
    select * into d from claims.deciders where name = p_decider;
    if not found then
        raise no_data_found using message = format('no decider named %s is configured', p_decider);
    end if;
    st := aiq.walk_state(p_run);
    nx := aiq.walk_stack_next(p_run, st);
    return query
    with todo as (
        select x->>'key' as key, x->>'q' as grp, st->'board'->'questions'->(x->>'q')->>'text' as question,
               (select value #>> '{}' from aiq.parameters where name = 'decider.task_assess') as task, x->>'text' as text
          from jsonb_array_elements(nx->'assess') x where p_phase = 'assess'
        union all
        select x->>'key', 'C|' || (x->>'q'), st->'board'->'questions'->(x->>'q')->>'text',
               (select value #>> '{}' from aiq.parameters where name = 'decider.task_close'), x->>'text'
          from jsonb_array_elements(nx->'closes') x where p_phase = 'shape'
        union all
        select x->>'key', 'S|' || (x->>'parent'), st->'board'->'questions'->(x->>'parent')->>'text',
               (select value #>> '{}' from aiq.parameters where name = 'decider.task_split'), x->>'text'
          from jsonb_array_elements(nx->'candidates') x where p_phase = 'shape'
    ), asked as (
        -- a request holds at most 60 options and decider.request_bytes of their text
        select t.*, row_number() over (partition by t.grp order by t.key) - 1 as j,
               sum(octet_length(t.text) + octet_length(t.key) + 64) over (partition by t.grp order by t.key) as cum
          from todo t where not (st->'answers') ? t.key
    ), cut as (
        select a.*, (a.j / 60) as by_count,
               (a.cum / (select (value #>> '{}')::int from aiq.parameters where name = 'decider.request_bytes'))::int as by_bytes
          from asked a
    ), chunks as (
        select c.*, (dense_rank() over (order by c.grp, c.by_bytes, c.by_count) - 1)::int as ch,
               (row_number() over (partition by c.grp, c.by_bytes, c.by_count order by c.key) - 1)::int as jj
          from cut c
    )
    select c.ch, jsonb_agg(c.key order by c.jj),
           jsonb_build_object('model', d.model,
                              'state', jsonb_build_object('question', min(c.question), 'task', min(c.task)),
                              'questions', jsonb_object_agg('c' || c.jj, jsonb_build_object('type', 'noul', 'instructions', c.text)))
      from chunks c
     group by c.ch
     order by c.ch;
end;
$$;

-- The stack step: the board the wave's verdicts decide, recorded as the step's output. Null when the walk keeps none.
create or replace function aiq.walk_stack_move(p_run uuid)
returns jsonb
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    inp jsonb := (select input from workflow.runs where id = p_run);
begin
    if not coalesce((aiq.walk_settings(inp)->>'stack')::boolean, false) then
        return null;
    end if;
    return aiq.walk_stack_next(p_run, aiq.walk_state(p_run))->'record';
end;
$$;

-- ---------------------------------------------------------------- what a reader queries (walk.md §9)
-- The board after each wave: one row per question per recorded stack step, with its state then and the reads linked
-- to it by then. A walk with no stack has one row: its root, open, with nothing linked.
create or replace function aiq.walk_stack(p_run uuid)
returns table (wave int, question text, parent text, text text, by text, state text, opened_wave int, opened_p real,
               closed_wave int, close_p real, evidence text[], evidence_p real[])
language sql stable security invoker set search_path = pg_catalog, public as $$
    with boards as (select b from aiq.walk_stack_boards(p_run) b)
    select (b->>'assessed')::int, q.key, q.value->>'parent', q.value->>'text', q.value->>'by', q.value->>'state',
           (q.value->>'opened_wave')::int, (q.value->>'opened_p')::real, (q.value->>'closed_wave')::int,
           (q.value->>'close_p')::real,
           array(select e->>'doc' from jsonb_array_elements(b->'evidence') e where e->>'q' = q.key
                  order by (e->>'p')::real desc, e->>'doc'),
           array(select (e->>'p')::real from jsonb_array_elements(b->'evidence') e where e->>'q' = q.key
                  order by (e->>'p')::real desc, e->>'doc')
      from boards, jsonb_each(b->'questions') q
     order by 1, (q.value->>'opened_wave')::int, q.key = 'root' desc, q.key
$$;

-- The graph a run walked, as numbers: documents, links by kind, leads a read raises, term postings against the cap,
-- and how much of the scope lies within 1 and 2 lead hops of the seeds.
create or replace function aiq.walk_graph_stats(p_run uuid)
returns jsonb
language sql stable security invoker set search_path = pg_catalog, public as $$
    with gr as materialized (
        select aiq.walk_run_graph(p_run) as g, (aiq.walk_settings(r.input)->>'cap')::int as cap
          from workflow.runs r where r.id = p_run
    ), hops as materialized (
        -- what one lead out of a document reaches: its terms' postings under the cap, its sitting, its nearest
        select d.key as doc, o #>> '{}' as other
          from gr, jsonb_each(gr.g->'terms') d, jsonb_array_elements_text(d.value) t, jsonb_array_elements(gr.g->'post'->t) o
         where jsonb_array_length(gr.g->'post'->t) <= gr.cap
        union
        select d.key, o #>> '{}' from gr, jsonb_each(gr.g->'beside') d, jsonb_array_elements(d.value) o
        union
        select d.key, o #>> '{}' from gr, jsonb_each(gr.g->'near') d, jsonb_array_elements(d.value) o
    ), seeds as (select doc from aiq.walk_reads(p_run) where wave = 0),
    h1 as (select doc from seeds union select h.other from hops h join seeds s on s.doc = h.doc),
    h2 as (select doc from h1 union select h.other from hops h join h1 on h1.doc = h.doc),
    n as (select count(*) as docs from gr, jsonb_object_keys(gr.g->'keys'))
    select jsonb_build_object(
        'documents', n.docs,
        'links', jsonb_build_object(
            'term', (select count(*) from gr, jsonb_each(gr.g->'post') t where jsonb_array_length(t.value) between 2 and gr.cap),
            'next', (select coalesce(sum(jsonb_array_length(value)), 0) from gr, jsonb_each(gr.g->'beside')),
            'near', (select coalesce(sum(jsonb_array_length(value)), 0) from gr, jsonb_each(gr.g->'near'))),
        'terms', (select jsonb_build_object('held', count(*), 'under_cap', count(*) filter (where jsonb_array_length(t.value) <= gr.cap),
                                            'cap', min(gr.cap),
                                            'median_postings', percentile_disc(0.5) within group (order by jsonb_array_length(t.value)))
                    from gr, jsonb_each(gr.g->'post') t),
        'leads_per_read', (select jsonb_build_object('median', percentile_disc(0.5) within group (order by k), 'max', max(k))
                             from (select doc, count(distinct other) as k from hops group by doc) z),
        'seeds', (select count(*) from seeds),
        'within_1_hop', round((select count(*) from h1)::numeric / greatest(n.docs, 1), 3),
        'within_2_hops', round((select count(*) from h2)::numeric / greatest(n.docs, 1), 3))
      from n
$$;

-- The walk structure (walk.md §9): everything a person, a UI or an LLM sees of a walk, as one object from the run's
-- rows. The question, the stop, the graph's numbers, the board (questions, the reads linked to them, the moves of each
-- wave), the reads with what the user said in them and what brought them, the waves' counts, and the decider's work.
-- A UI renders this and assembles nothing of its own.
--
-- ORACLE MODE (walk.md §11) is p_oracle, the labelled answer set: the same object plus what a walker cannot see, in
-- one part marked "oracle": true -- the labels, which reads were evidence, coverage beside search's order, and why
-- each missed piece was missed (aiq.walk_why). p_items, the labels grouped as the benchmark's answer items
-- [{item, docs}], adds each item with the walk's first read of its evidence: the omniscient reader's own stack, each
-- item closing there. Without p_oracle the object is exactly what the walk knew. The ceiling (the oracle decider's own
-- reads) is not built here yet, and the part says so rather than leaving it out silently.
drop function if exists aiq.walk_structure(uuid, text[]);
create or replace function aiq.walk_structure(p_run uuid, p_oracle text[] default null, p_items jsonb default null)
returns jsonb
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    inp     jsonb := (select input from workflow.runs where id = p_run);
    st      jsonb := aiq.walk_state(p_run);
    board   jsonb;
    lines   jsonb;
    places  jsonb;
    reads   jsonb;
    result  jsonb;
begin
    board := coalesce(st->'board', aiq.walk_stack_initial(inp));
    lines := aiq.walk_lines(inp, array(select doc from aiq.walk_state_reads(st)));
    places := aiq.walk_places(inp, array(select doc from aiq.walk_state_reads(st)));
    select coalesce(jsonb_agg(jsonb_build_object('k', r.k, 'wave', r.wave, 'ord', r.ord, 'doc', r.doc, 'via', r.via,
                                                 'line', lines->>r.doc)
                              || coalesce(places->r.doc, '{}'::jsonb)
                              || jsonb_build_object(
                                                 'answers', (select coalesce(jsonb_agg(e->>'q'), '[]'::jsonb)
                                                               from jsonb_array_elements(board->'evidence') e
                                                              where e->>'doc' = r.doc))
                              order by r.wave, r.ord), '[]'::jsonb)
      into reads
      from (select x.*, row_number() over (order by x.wave, x.ord) as k from aiq.walk_state_reads(st) x) r;
    result := jsonb_build_object(
        'run', p_run,
        'question', inp->'question',
        'settings', st->'settings',
        'stack_kept', coalesce((st->'settings'->>'stack')::boolean, false),
        'summary', aiq.walk_summary(p_run),
        'graph', aiq.walk_graph_stats(p_run),
        'questions', (select coalesce(jsonb_agg(q.value || jsonb_build_object('id', q.key,
                                          'evidence', (select coalesce(jsonb_agg(jsonb_build_object('doc', e->>'doc', 'p', e->'p',
                                                                                                   'wave', e->'wave', 'line', lines->>(e->>'doc'))
                                                                                order by (e->>'p')::real desc), '[]'::jsonb)
                                                         from jsonb_array_elements(board->'evidence') e where e->>'q' = q.key))
                                        order by (q.value->>'opened_wave')::int, q.key = 'root' desc, q.key), '[]'::jsonb)
                        from jsonb_each(board->'questions') q),
        'open', board->'open',
        'evidence', board->'evidence',
        'boards', (select coalesce(jsonb_agg(tk.output->'result'->0->'state'->'moves'
                                             order by (tk.output->'result'->0->'state'->>'iteration')::int), '[]'::jsonb)
                     from workflow.tasks tk
                    where tk.run_id = p_run and tk.step_key like 'stack\_%' and tk.status = 'succeeded'
                      and jsonb_typeof(tk.output->'result'->0->'state') = 'object'),
        'reads', reads,
        'waves', (select coalesce(jsonb_agg(to_jsonb(w) order by w.wave), '[]'::jsonb) from aiq.walk_state_waves(st) w),
        'counts', jsonb_build_object(
            'questions_open', jsonb_array_length(board->'open'),
            'questions_answered', (select count(*) from jsonb_each(board->'questions') q where q.value->>'state' = 'answered'),
            'evidence_edges', jsonb_array_length(board->'evidence'),
            'reads', jsonb_array_length(reads),
            'reads_by', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb)
                           -- a read a travel queued for the next wave records no via of its own
                           from (select case when r->>'via' = 'search' then 'search'
                                             when r->>'via' is null then 'queued'
                                             else split_part(r->>'via', ':', 1) end as k,
                                        count(*) as n
                                   from jsonb_array_elements(reads) r group by 1) z),
            'leads', (select count(*) from jsonb_each(st->'clues')),
            'leads_accepted', (select count(*) from aiq.walk_state_clues(st) c where c.decision = 'accepted'),
            'judgements', (select count(*) from jsonb_object_keys(coalesce(st->'answers', st->'p'))),
            -- what the decider's calls cost, as Jev reported it in each answer
            'jev', (select jsonb_build_object('requests', count(*), 'model', min(t.output->'result'->>'model'),
                                              'input_tokens', coalesce(sum((t.output->'result'->'usage'->>'input_tokens')::bigint), 0),
                                              'output_tokens', coalesce(sum((t.output->'result'->'usage'->>'output_tokens')::bigint), 0))
                      from workflow.tasks t
                     where t.run_id = p_run and t.matrix_parent_id is not null and t.status = 'succeeded'
                       and (t.step_key like 'judge\_%' or t.step_key like 'assess\_%' or t.step_key like 'shape\_%'))));
    if p_oracle is not null then
        result := result || jsonb_build_object('oracle', jsonb_build_object(
            'oracle', true,
            'note', 'oracle-scored: the labelled answer set comes from outside the walk, which never saw it',
            'labelled', to_jsonb(p_oracle),
            'evidence_read', (select coalesce(jsonb_agg(r->'doc'), '[]'::jsonb) from jsonb_array_elements(reads) r
                               where r->>'doc' = any(p_oracle)),
            'linked_evidence', (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(board->'evidence') e
                                 where e->>'doc' = any(p_oracle)),
            'linked_not_evidence', (select count(*) from jsonb_array_elements(board->'evidence') e
                                     where not e->>'doc' = any(p_oracle)),
            'coverage', (select coalesce(jsonb_agg(to_jsonb(c) order by c.k), '[]'::jsonb)
                           from aiq.walk_coverage(p_run, p_oracle, array[50, 100, 500]) c),
            'why', (select coalesce(jsonb_agg(to_jsonb(y)), '[]'::jsonb) from aiq.walk_why(p_run, p_oracle) y),
            'items', (select coalesce(jsonb_agg(jsonb_build_object('item', it->'item', 'docs', it->'docs',
                                         'first_read_wave', fr.wave, 'first_read_k', fr.k, 'first_read_doc', fr.doc)
                                       order by coalesce(fr.k, 1000000), it->>'item'), '[]'::jsonb)
                        from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) it
                        left join lateral (select (r->>'wave')::int as wave, (r->>'k')::int as k, r->>'doc' as doc
                                             from jsonb_array_elements(reads) r
                                            where it->'docs' ? (r->>'doc') order by (r->>'k')::int limit 1) fr on true),
            'ceiling', jsonb_build_object('built', false,
                                          'note', 'the oracle decider of walk.md §11 is not in the query layer yet')));
    end if;
    return result;
end;
$$;

grant execute on function aiq.walk_stack_initial(jsonb), aiq.walk_lines(jsonb, text[]), aiq.walk_stack_next(uuid, jsonb),
                          aiq.walk_stack_requests(uuid, text, text), aiq.walk_stack_move(uuid), aiq.walk_stack(uuid),
                          aiq.walk_stack_boards(uuid),
                          aiq.walk_graph_stats(uuid), aiq.walk_structure(uuid, text[], jsonb), aiq.walk_places(jsonb, text[])
    to authenticated;

-- Keep a walk's board as graph rows (walk.md §6): each question of the board a walk_question node (summary: its text),
-- each part a walk_part_of edge to its parent, each link a walk_answers edge from the read's node to the question's,
-- provenance {run, wave, p}; the run's root a walk_asks edge to the user's question node. A board belongs to one run,
-- so its question nodes do too (an edge is unique on its two ends and relation, and two runs of one question must not
-- share a link). Written once, at the walk's keep step, never during the walk. A walk with no stack keeps nothing.
create or replace function aiq.walk_keep_stack(p_run uuid)
returns jsonb
language plpgsql volatile security invoker set search_path = pg_catalog, public as $$
declare
    inp   jsonb := (select input from workflow.runs where id = p_run);
    st    jsonb;
    board jsonb;
    g     jsonb;
    root  aiq.nodes;
    ids   jsonb := '{}'::jsonb;   -- {question id: node uuid}
    q     record;
    nid   uuid;
    n_ans int;
begin
    if not coalesce((aiq.walk_settings(inp)->>'stack')::boolean, false) then
        return jsonb_build_object('kept', 0, 'why', 'the walk kept no stack');
    end if;
    st := aiq.walk_state(p_run);
    board := st->'board';
    g := aiq.walk_run_graph(p_run);
    select * into root from aiq.nodes where id = (inp->'question'->>'node_id')::uuid;
    for q in select key, value from jsonb_each(board->'questions') loop
        insert into aiq.nodes (entity_type, entity_id, summary, org_id, visibility, owner_id)
        values ('walk_question', md5(p_run::text || ':' || q.key)::uuid, q.value->>'text',
                coalesce(root.org_id, rbac.shared_org_id()), coalesce(root.visibility, 'private'), root.owner_id)
        on conflict (entity_type, entity_id) do update set summary = excluded.summary
        returning id into nid;
        ids := ids || jsonb_build_object(q.key, nid);
    end loop;
    -- the relations, as the index catalogues its own: one row per pair of node types this board links
    insert into aiq.relation_types (src_type, relation, dst_type, description, is_symmetric)
    select distinct x.src, x.rel, x.dst, x.descr, false
      from (select n.entity_type as src, 'walk_answers' as rel, 'walk_question' as dst,
                   'the decider judged the read to answer the walk''s question; provenance {run, wave, p} (REM-1245)' as descr
              from jsonb_array_elements(board->'evidence') e
              join jsonb_each_text(g->'keys') k on k.value = e->>'doc'
              join aiq.nodes n on n.id = k.key::uuid
            union all
            select 'walk_question', 'walk_part_of', 'walk_question',
                   'a part of the walk''s question, opened by the decider or the client; provenance {run, by, opened_wave, opened_p, state, closed_wave, close_p} (REM-1245)'
            union all
            select 'walk_question', 'walk_asks', root.entity_type,
                   'a walk''s root question stands for the user''s question; provenance {run} (REM-1245)'
             where root.id is not null) x
    on conflict do nothing;
    insert into aiq.edges (src_id, dst_id, relation, provenance, org_id)
    select (ids->>q2.key)::uuid, (ids->>(q2.value->>'parent'))::uuid, 'walk_part_of',
           jsonb_build_object('run', p_run) || (q2.value - 'text' - 'parent' - 'node'),
           coalesce(root.org_id, rbac.shared_org_id())
      from jsonb_each(board->'questions') q2 where q2.value->>'parent' is not null
    on conflict (src_id, dst_id, relation) do nothing;
    if root.id is not null then
        insert into aiq.edges (src_id, dst_id, relation, provenance, org_id)
        values ((ids->>'root')::uuid, root.id, 'walk_asks', jsonb_build_object('run', p_run), root.org_id)
        on conflict (src_id, dst_id, relation) do nothing;
    end if;
    insert into aiq.edges (src_id, dst_id, relation, provenance, org_id)
    select k.key::uuid, (ids->>(e->>'q'))::uuid, 'walk_answers',
           jsonb_build_object('run', p_run, 'wave', e->'wave', 'p', e->'p'), coalesce(root.org_id, rbac.shared_org_id())
      from jsonb_array_elements(board->'evidence') e
      join jsonb_each_text(g->'keys') k on k.value = e->>'doc'
    on conflict (src_id, dst_id, relation) do nothing;
    get diagnostics n_ans = row_count;
    return jsonb_build_object('questions', (select count(*) from jsonb_object_keys(ids)), 'walk_answers', n_ans);
end;
$$;
grant execute on function aiq.walk_keep_stack(uuid) to authenticated;

-- Every lead a run raised, with the text the decider reads for it (aiq.walk_describe_clue, the walk's own words), under
-- the run's description or the one named: aiq.walk_clue_text for a whole run at once, the state, the graph and the
-- sources' text each read once rather than once a lead. Under walk.stack the decider was also shown what the lead's
-- source was found to answer; that line is `state_line`.
create or replace function aiq.walk_clue_texts(p_run uuid, p_describe text default null)
returns table (key text, text text, state_line text)
language sql stable security invoker set search_path = pg_catalog, public as $$
    with st as materialized (select aiq.walk_state(p_run) as st),
    inp as materialized (select input from workflow.runs where id = p_run),
    g as materialized (select aiq.walk_run_graph(p_run) as g),
    c as materialized (select x.key, x.value from st, jsonb_each(st.st->'clues') x
                       union all
                       select x.key, x.value from st, jsonb_each(st.st->'next') x),
    src as materialized (select aiq.walk_texts((select input from inp), array(select distinct value->>'source' from c)) as t),
    said as materialized (
        select e->>'doc' as doc, string_agg(format('''%s''', st.st->'board'->'questions'->(e->>'q')->>'text'), ' and '
                                            order by (e->>'p')::real desc) as qs
          from st, jsonb_array_elements(coalesce(st.st->'board'->'evidence', '[]'::jsonb)) e group by 1)
    select c.key,
           aiq.walk_describe_clue((select input from inp), g.g, coalesce(p_describe, st.st->'settings'->>'describe'), c.key,
                                  c.value->>'kind', c.value->>'x', c.value->>'source', c.value->'targets',
                                  src.t->>(c.value->>'source')),
           case when sd.qs is not null then 'It comes out of a message found to answer: ' || sd.qs || '.' end
      from c cross join st cross join g cross join src left join said sd on sd.doc = c.value->>'source'
     order by c.key
$$;
grant execute on function aiq.walk_clue_texts(uuid, text) to authenticated;
