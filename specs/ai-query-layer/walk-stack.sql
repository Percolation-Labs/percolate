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
--     shape   matrix  each candidate part: is it a part the root's answer needs?                   S|root|<term>
--                     once: could one message answer the root (if not, DECOMPOSITION_REQUIRED)     N|root
--                     each candidate line of a leaf with links: does this line answer it?          T|<q>|<read>
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
    b   jsonb := aiq.walk_stack_initial((select input from aiq.walk_run(p_run)));
    rec jsonb;
    m   jsonb;
    x   jsonb;
begin
    for rec in select tk.output->'result'->0->'state'
                 from aiq.walk_tasks(p_run) tk
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
                           || jsonb_build_object('state', 'answered', 'closed_wave', m->'wave', 'close_p', x->'p',
                                                 'by', x->'by', 'answer', x->'answer',
                                                 'answered_by', coalesce(x->'lines', x->'parts')));
        end loop;
        for x in select value from jsonb_array_elements(coalesce(m->'stale', '[]'::jsonb)) loop
            b := jsonb_set(b, array['questions', x->>'q'], b->'questions'->(x->>'q')
                           || jsonb_build_object('state', 'stale', 'closed_wave', m->'wave'));
        end loop;
        for x in select value from jsonb_array_elements(coalesce(m->'displaced', '[]'::jsonb)) loop
            b := jsonb_set(b, array['questions', x->>'q'], b->'questions'->(x->>'q')
                           || jsonb_build_object('state', 'displaced', 'closed_wave', m->'wave', 'displaced_by', x->'by'));
        end loop;
        -- a semantic exception raised to the client stays on the board, so it is raised once
        if jsonb_array_length(coalesce(m->'raised', '[]'::jsonb)) > 0 then
            b := b || jsonb_build_object('raised', coalesce(b->'raised', '[]'::jsonb) || (m->'raised'));
        end if;
        -- when each question last gained a link, which is what makes a part stale
        for x in select distinct on (value->>'q') value from jsonb_array_elements(m->'linked') loop
            b := jsonb_set(b, array['questions', x->>'q', 'last_linked_wave'], m->'wave');
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
    inp     jsonb := (select input from aiq.walk_run(p_run));
    s       jsonb := p_state->'settings';
    sp      jsonb := aiq.parameters_need('stack', array['link_floor', 'link_share', 'close_min_links', 'close_gate',
                                                         'stale_waves', 'max_open', 'max_displace', 'candidates',
                                                         'evidence_lines', 'part_wording', 'split_gate']);
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
    stale   jsonb := '[]'::jsonb;
    gone    jsonb := '[]'::jsonb;   -- parts displaced by a candidate with higher P
    c       record;
    weak    record;
    nparts  int;
    swaps   int := 0;
    narrow  boolean;                 -- whether one message could answer the root (N|root against narrow_gate)
    raised  jsonb := '[]'::jsonb;    -- semantic exceptions this wave raises to the client
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
                                                                   'answered', '[]'::jsonb, 'added', '[]'::jsonb,
                                                                   'stale', '[]'::jsonb, 'displaced', '[]'::jsonb, 'open', open_)));
    end if;
    lines := aiq.walk_lines(inp, array(select jsonb_array_elements_text(reads)));
    -- 1. assess: each new read against each open question
    select coalesce(jsonb_agg(jsonb_build_object('key', 'A|' || o.q || '|' || r.doc, 'q', o.q, 'doc', r.doc,
                                                 -- worded as REM-1240's recognition test showed a read, so the wording
                                                 -- that ships is the one measured
                                                 'text', format('the user wrote: "%s"', coalesce(lines->>r.doc, r.doc)),
                                                 'p', ans->('A|' || o.q || '|' || r.doc))
                              order by o.q, r.o), '[]'::jsonb)
      into assess
      from jsonb_array_elements_text(reads) with ordinality r(doc, o), jsonb_array_elements_text(open_) o(q);
    -- A read links to a question when its P clears stack.link_floor AND ranks in the top stack.link_share of the reads
    -- assessed against that question so far (walk.md §6 move 1, F10). Rank, because at a fixed gate the links were
    -- mostly noise (6% evidence at 0.5 against a 3.9% base; the top 2% by rank were 19%, REM-1240). It is relative, so
    -- a walk with no evidence still links its best reads; the close step is what must say no. "So far" is the reads of
    -- waves up to this one, never later ones a replay may also hold.
    with pool as (
        select split_part(x.key, '|', 2) as q, split_part(x.key, '|', 3) as doc, (x.value #>> '{}')::real as p
          from jsonb_each(ans) x
         where x.key like 'A|%'
           and split_part(x.key, '|', 3) in (select r.value->>'doc' from jsonb_array_elements(p_state->'waves') wv,
                                                    jsonb_array_elements(wv->'reads') r where (wv->>'wave')::int <= w)
    ), ranked as (
        select q, doc, p, rank() over (partition by q order by p desc) as rk, count(*) over (partition by q) as n from pool
    )
    select coalesce(jsonb_agg(jsonb_build_object('doc', a->>'doc', 'q', a->>'q', 'p', (a->>'p')::real, 'wave', w,
                                                 'rank', rk.rk, 'of', rk.n)
                              order by a->>'q', (a->>'p')::real desc), '[]'::jsonb)
      into linked
      from jsonb_array_elements(assess) a
      join ranked rk on rk.q = a->>'q' and rk.doc = a->>'doc'
     where (a->>'p')::real >= (sp->>'link_floor')::real
       -- at least close_min_links, so a question can be judged for closing before 100 reads are assessed: under
       -- 100, the top 2% is one read, and close needs two (walk spec 4cf59f55; three of REM-1245's five test walks
       -- linked exactly one read and so never asked)
       and rk.rk <= greatest((sp->>'close_min_links')::int, ceil((sp->>'link_share')::real * rk.n));
    ev := board->'evidence' || linked;
    -- 2. close, by structure, never by a holistic judgement (walk.md §6 move 4, spec 1d5f38d8, Sirsh 13:15Z). Jev is
    -- never asked whether a set of messages answers a question. A LEAF (a part; or the root while it has no parts and
    -- is narrow enough that one message could answer it) closes on ONE line: once it has close_min_links links, its
    -- candidate lines (its links plus every line assessed against it above link_floor, either direction of time, the
    -- evidence_lines highest by P, F13) are judged one at a time, with their dates: does this line answer this
    -- question (decider.task_state, T|<q>|<read>), each asked once. A PARENT closes by structure below, with no call.
    -- Why not the holistic ask: on the ten walks it separated asks holding evidence at AUC 0.622 and closed once in
    -- ten, wrongly; Jev judges one line well and a pile of mixed lines badly (spec §6, postmortem).
    narrow := case when ans ? 'N|root' then (ans->>'N|root')::real >= (sp->>'narrow_gate')::real end;
    with gained as (
        select distinct x->>'q' as q from jsonb_array_elements(linked) x
        union
        select 'root' where jsonb_array_length(linked) > 0
    ), leaves as (
        select o.q from jsonb_array_elements_text(open_) o(q)
         where o.q <> 'root'
            or (not exists (select 1 from jsonb_each(qs) x where x.key <> 'root') and coalesce(narrow, false))
    ), links as (
        select lv.q, e->>'doc' as doc, (e->>'p')::real as p
          from leaves lv, jsonb_array_elements(ev) e
         where e->>'q' = lv.q or lv.q = 'root'
    ), enough as (
        select q from links group by q having count(distinct doc) >= (sp->>'close_min_links')::int
    ), assessed as (
        select split_part(x.key, '|', 2) as q, split_part(x.key, '|', 3) as doc, (x.value #>> '{}')::real as p
          from jsonb_each(ans) x
         where x.key like 'A|%' and (x.value #>> '{}')::real >= (sp->>'link_floor')::real
           and split_part(x.key, '|', 3) in (select r.value->>'doc' from jsonb_array_elements(p_state->'waves') wv,
                                                    jsonb_array_elements(wv->'reads') r where (wv->>'wave')::int <= w)
    ), cand as (
        select q, doc, max(p) as p from (select * from links union all select * from assessed) u
         where q in (select q from enough) and q in (select q from gained)
         group by q, doc
    ), cut as (
        select q, doc, p from (select cd.*, row_number() over (partition by cd.q order by cd.p desc, cd.doc) as rk from cand cd) z
         where rk <= (sp->>'evidence_lines')::int
    ), pl as (
        select aiq.walk_places(inp, array(select distinct doc from cut)) as places,
               aiq.walk_lines(inp, array(select distinct doc from cut)) as lines
    )
    select coalesce(jsonb_agg(jsonb_build_object(
               'key', 'T|' || cu.q || '|' || cu.doc, 'q', cu.q, 'doc', cu.doc,
               'said_at', pl.places->cu.doc->>'said_at',
               'text', format('[%s] the user wrote: "%s"',
                              coalesce(to_char((pl.places->cu.doc->>'said_at')::timestamptz, 'YYYY-MM-DD'), 'undated'),
                              coalesce(pl.lines->>cu.doc, cu.doc)),
               'p', ans->('T|' || cu.q || '|' || cu.doc)) order by cu.q, cu.doc), '[]'::jsonb)
      into closes
      from cut cu, pl;
    -- 3. candidate parts (walk.md §6 move 2): parts open only under the root, so they never nest. The candidates are
    -- the terms the most reads linked to the root share (at least two), ties by specificity (fewest documents holding
    -- them), not yet asked about. The rarest term of each linked read is not used: on REM-1245's live ladder walk it
    -- filled every slot with variants of one aspect by wave 3, and the question's other aspects never got one.
    g := aiq.walk_run_graph(p_run);
    with linked_root as (
        select distinct x->>'doc' as doc from jsonb_array_elements(ev) x where x->>'q' = 'root'
    ), shared as (
        select t, count(*) as holders, jsonb_array_length(coalesce(g->'post'->t, '[]'::jsonb)) as n
          from linked_root lr, jsonb_array_elements_text(coalesce(g->'terms'->lr.doc, '[]'::jsonb)) t
         where not board->'asked_terms' ? t and not qs ? ('part:' || t)
         group by t
        having count(*) >= 2
    ), top as (
        select * from shared order by holders desc, n, t limit (sp->>'candidates')::int
    )
    select coalesce(jsonb_agg(jsonb_build_object('key', 'S|root|' || top.t, 'parent', 'root', 'term', top.t,
                                                 'holders', top.holders,
                                                 'text', format(sp->>'part_wording', qs->'root'->>'text', top.t),
                                                 'p', ans->('S|root|' || top.t)) order by top.holders desc, top.n, top.t), '[]'::jsonb)
      into cands
      from top
     where jsonb_array_length(linked) > 0;
    -- leaves the verdicts close: one line at or above state_gate answers the leaf; among the lines that clear, the
    -- newest is the answer and the older ones its history, so a contradiction keeps both sides. Unset, the gate closes
    -- nothing and the walk records the verdicts (the calibration's input).
    if jsonb_typeof(sp->'state_gate') = 'number' then
        for c in select x->>'q' as q, max((x->>'p')::real) as p,
                        jsonb_agg(x->>'doc' order by (x->>'said_at')::timestamptz desc nulls last, x->>'doc')
                            filter (where (x->>'p')::real >= (sp->>'state_gate')::real) as by_lines
                   from jsonb_array_elements(closes) x
                  group by x->>'q'
                 having max((x->>'p')::real) >= (sp->>'state_gate')::real
                  order by x->>'q' loop
            qs := jsonb_set(qs, array[c.q], qs->c.q || jsonb_build_object(
                      'state', 'answered', 'closed_wave', w, 'close_p', c.p, 'by', 'line',
                      'answer', c.by_lines->0, 'answered_by', c.by_lines));
            closed := closed || jsonb_build_array(jsonb_build_object('q', c.q, 'p', c.p, 'by', 'line',
                                                                     'answer', c.by_lines->0, 'lines', c.by_lines));
            open_ := open_ - c.q;
        end loop;
    end if;
    -- stale (F9): a part that has gained no link for stack.stale_waves waves leaves the open list as 'stale'. It is
    -- not answered, and its leads keep their P (aiq.walk_state), so a stale part never hides evidence behind it.
    for c in select o as q from jsonb_array_elements_text(open_) o
              where o <> 'root' and not exists (select 1 from jsonb_array_elements(linked) x where x->>'q' = o)
                and w - coalesce((qs->o->>'last_linked_wave')::int, (qs->o->>'opened_wave')::int)
                    >= (sp->>'stale_waves')::int loop
        qs := jsonb_set(qs, array[c.q], qs->c.q || jsonb_build_object('state', 'stale', 'closed_wave', w));
        stale := stale || jsonb_build_array(jsonb_build_object('q', c.q));
        open_ := open_ - c.q;
    end loop;
    -- a parent closes by structure, with no Jev call: every child it still has closed, at least one answered, the rest
    -- answered or stale (a displaced part was replaced, not a child any more). The root is a parent once it has parts.
    if open_ ? 'root' and exists (select 1 from jsonb_each(qs) x where x.value->>'parent' = 'root'
                                     and x.value->>'state' <> 'displaced')
       and not exists (select 1 from jsonb_each(qs) x where x.value->>'parent' = 'root' and x.value->>'state' = 'open')
       and exists (select 1 from jsonb_each(qs) x where x.value->>'parent' = 'root' and x.value->>'state' = 'answered') then
        qs := jsonb_set(qs, '{root}', qs->'root' || jsonb_build_object(
                  'state', 'answered', 'closed_wave', w, 'by', 'structure',
                  'answered_by', (select jsonb_agg(x.key order by x.key) from jsonb_each(qs) x
                                   where x.value->>'parent' = 'root' and x.value->>'state' = 'answered')));
        closed := closed || jsonb_build_array(jsonb_build_object('q', 'root', 'by', 'structure',
                      'parts', (select jsonb_agg(x.key order by x.key) from jsonb_each(qs) x
                                 where x.value->>'parent' = 'root' and x.value->>'state' = 'answered')));
        open_ := open_ - 'root';
    end if;
    -- a broad root with no parts is closed by no line: the walk raises DECOMPOSITION_REQUIRED to the client for a split
    -- (walk.md §12), once, and splits in the loop from the aspects its reads name meanwhile
    if narrow is false and not (board ? 'raised') then
        raised := jsonb_build_array(jsonb_build_object('code', 'DECOMPOSITION_REQUIRED', 'question', 'root',
                      'prompt', 'split your question up: it asks about more than one message can answer',
                      'p', ans->'N|root'));
    end if;
    nparts := (select count(*) from jsonb_array_elements_text(open_) o where o <> 'root');
    for c in select x->>'parent' as parent, x->>'term' as term, x->>'text' as text, (x->>'p')::real as p
               from jsonb_array_elements(cands) x
              where (x->>'p')::real >= (sp->>'split_gate')::real and open_ ? (x->>'parent')
              order by (x->>'p')::real desc, x->>'term' loop
        if nparts >= (sp->>'max_open')::int then
            -- the slot rule (F11): a candidate with higher P displaces the weakest open part that has no link of its
            -- own, at most stack.max_displace a wave; the displaced part keeps its leads and its record
            exit when swaps >= (sp->>'max_displace')::int;
            select o as q, (qs->o->>'opened_p')::real as p into weak
              from jsonb_array_elements_text(open_) o
             where o <> 'root' and not exists (select 1 from jsonb_array_elements(ev) e where e->>'q' = o)
             order by (qs->o->>'opened_p')::real, o
             limit 1;
            exit when weak.q is null or coalesce(weak.p, 0) >= c.p;
            qs := jsonb_set(qs, array[weak.q], qs->weak.q || jsonb_build_object('state', 'displaced', 'closed_wave', w,
                                                                                 'displaced_by', 'part:' || c.term));
            gone := gone || jsonb_build_array(jsonb_build_object('q', weak.q, 'p', weak.p, 'by', 'part:' || c.term));
            open_ := open_ - weak.q;
            nparts := nparts - 1;
            swaps := swaps + 1;
        end if;
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
        -- is the root narrow enough that one message could answer it (asked once, with the first shape step)
        'narrow', case when not ans ? 'N|root' then jsonb_build_array(jsonb_build_object(
                      'key', 'N|root', 'q', 'root', 'text', qs->'root'->>'text')) else '[]'::jsonb end,
        'record', jsonb_build_object(
            'iteration', (board->>'iteration')::int + 1, 'assessed', w,
            'asked_terms', coalesce((select jsonb_agg(x->'term') from jsonb_array_elements(cands) x), '[]'::jsonb),
            'moves', jsonb_build_object('wave', w, 'linked', linked, 'answered', closed, 'added', added,
                                        'stale', stale, 'displaced', gone, 'raised', raised, 'open', open_)));
end;
$$;

-- The assess and shape steps' rows: one Jev request per question (or parent) and 60 options, for the verdicts the run
-- does not hold. None when the walk keeps no stack, or asks nobody.
create or replace function aiq.walk_stack_requests(p_run uuid, p_phase text, p_decider text default 'jev')
returns table (chunk int, keys jsonb, body jsonb)
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    inp jsonb := (select input from aiq.walk_run(p_run));
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
    perform aiq.parameters_need('decider', array['task_assess', 'task_state', 'task_narrow', 'task_split', 'request_bytes']);
    st := aiq.walk_state(p_run);
    nx := aiq.walk_stack_next(p_run, st);
    return query
    with todo as (
        select x->>'key' as key, x->>'q' as grp, st->'board'->'questions'->(x->>'q')->>'text' as question,
               (select value #>> '{}' from aiq.parameters where name = 'decider.task_assess') as task, x->>'text' as text
          from jsonb_array_elements(nx->'assess') x where p_phase = 'assess'
        union all
        select x->>'key', 'T|' || (x->>'q'), st->'board'->'questions'->(x->>'q')->>'text',
               (select value #>> '{}' from aiq.parameters where name = 'decider.task_state'), x->>'text'
          from jsonb_array_elements(nx->'closes') x where p_phase = 'shape'
        union all
        select x->>'key', 'N|root', st->'board'->'questions'->'root'->>'text',
               (select value #>> '{}' from aiq.parameters where name = 'decider.task_narrow'), x->>'text'
          from jsonb_array_elements(nx->'narrow') x where p_phase = 'shape'
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
    inp jsonb := (select input from aiq.walk_run(p_run));
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
          from aiq.walk_run(p_run) r
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
    inp     jsonb := (select input from aiq.walk_run(p_run));
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
        -- the run's real state, from its rows (bill, Sirsh's Walks test): initializing until the start step has
        -- recorded its seeds, running with the wave in flight, failed with the first error, or stopped with its reason
        'state', (select jsonb_build_object(
                     'phase', case when r.status = 'failed' then 'failed'
                                   when r.status in ('completed', 'succeeded', 'cancelled') then 'stopped'
                                   when jsonb_array_length(st->'waves') = 0 then 'initializing'
                                   else 'running' end,
                     'run_status', r.status,
                     'wave', case when jsonb_array_length(st->'waves') > 0 then jsonb_array_length(st->'waves') - 1 end,
                     'step', (select t.step_key from aiq.walk_tasks(p_run) t
                               where t.status in ('running', 'ready') and t.matrix_parent_id is null
                               order by t.updated_at desc limit 1),
                     'stop', aiq.walk_summary(p_run)->'stop',
                     'error', (select t.error->>'error' from aiq.walk_tasks(p_run) t where t.status = 'failed'
                                order by t.updated_at limit 1),
                     'started_at', r.created_at, 'completed_at', r.completed_at)
                    from aiq.walk_run(p_run) r),
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
                     from aiq.walk_tasks(p_run) tk
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
                      from aiq.walk_tasks(p_run) t
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
            -- per labelled piece, when a lead toward it was first offered and first accepted, and when the walk read
            -- it (cory and Sirsh, M-20261029-122922-d364): a late read after an early offer is a judging miss, a late
            -- offer is distance. A lead's targets are as it was raised, so 'offered' means it led there unread.
            'timeline', (select coalesce(jsonb_agg(jsonb_build_object(
                                 'doc', d.doc,
                                 'first_offered_wave', fo.wave, 'first_offered_lead', fo.key,
                                 'first_accepted_wave', fa.wave, 'first_accepted_lead', fa.key, 'first_accepted_p', fa.p,
                                 'read_wave', rd.wave, 'read_ord', rd.ord, 'read_via', rd.via,
                                 'wait', rd.wave - fo.wave) order by d.doc), '[]'::jsonb)
                           from unnest(p_oracle) d(doc)
                           left join lateral (select c.wave, c.key from aiq.walk_state_clues(st) c
                                               where d.doc = any(c.targets) order by c.wave, c.key limit 1) fo on true
                           left join lateral (select c.wave, c.key, c.p from aiq.walk_state_clues(st) c
                                               where d.doc = any(c.targets) and c.decision = 'accepted'
                                               order by c.wave, c.p desc, c.key limit 1) fa on true
                           left join lateral (select r.wave, r.ord, r.via from aiq.walk_state_reads(st) r
                                               where r.doc = d.doc order by r.wave, r.ord limit 1) rd on true),
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
    inp   jsonb := (select input from aiq.walk_run(p_run));
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
    inp as materialized (select input from aiq.walk_run(p_run)),
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

-- A walk's readers, executable by whoever may read the run (walk.md §9: everything a person or UI sees comes through
-- these, signed in as themselves). Each reads the run through aiq.walk_run / aiq.walk_tasks, so the grant gives no
-- run the caller could not already read. Named here, after walk.sql and walk-why.sql, because some had no grant and
-- worked only while PUBLIC kept execute, which the build revokes at the end: cory's UI, signed in on 5801, was
-- refused walk_state_reads, walk_state_waves and parameters_of. walk_coverage, walk_why and walk_audit serve oracle
-- mode, whose labels the caller passes in.
grant execute on function aiq.walk_state_reads(jsonb), aiq.walk_state_clues(jsonb), aiq.walk_state_waves(jsonb),
                          aiq.walk_describe_clue(jsonb, jsonb, text, text, text, text, text, jsonb, text),
                          aiq.walk_clue_text(uuid, text, text), aiq.walk_audit(uuid), aiq.walk_why(uuid, text[]),
                          aiq.walk_coverage(uuid, text[], integer[])
    to authenticated;

-- The oracle decider (walk.md §11): the ceiling a walk is measured against, and the line between a data failure and an
-- implementation one (§10). Same graph as the run (aiq.walk_run_graph), same seeds (the run's wave 0), same budget (the
-- run's reads, unless given), the same leads a read raises (its terms under walk.cap, the exchanges beside it, its
-- nearest). It knows the labelled set and nothing else, and opens, from the live leads, the one with the most unread
-- evidence per unread target; when no live lead reaches unread evidence, the one whose targets lie fewest lead hops from
-- it; with no live lead at all, search's next document. Opening a lead reads all its unread targets, as the walk does.
-- Oracle-scored by construction: it is never inside a walk, and every figure it colours says so.
create or replace function aiq.walk_oracle(p_run uuid, p_labelled text[], p_budget int default null)
returns table (k int, doc text, via text)
language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
    st      jsonb := aiq.walk_state(p_run);
    s       jsonb := st->'settings';
    g       jsonb := aiq.walk_run_graph(p_run);
    budget  int := coalesce(p_budget, (select count(*) from aiq.walk_state_reads(st))::int);
    leads   jsonb := '{}'::jsonb;   -- {lead key: [targets]} for every lead any document raises
    raised  jsonb := '{}'::jsonb;   -- {doc: [lead keys it raises]}
    ev      text[];
    dist    jsonb := '{}'::jsonb;   -- {doc: {evidence: hops from doc to it}}
    readset jsonb := '{}'::jsonb;
    opened  jsonb := '{}'::jsonb;
    live    jsonb := '{}'::jsonb;   -- {lead key: true}
    out     jsonb := '[]'::jsonb;
    ord     jsonb := st->'order';
    si      int := 0;
    best    text;
    d       text;
    n       int := 0;
    e       text;
    frontier text[];
    nextf   text[];
    hop     int;
begin
    -- the labelled pieces in the run's scope
    ev := array(select x from unnest(p_labelled) x
                 where exists (select 1 from jsonb_each_text(g->'keys') kv where kv.value = x));
    -- the leads each document raises, as the walk raises them
    select coalesce(jsonb_object_agg(key, tg), '{}'::jsonb) into leads from (
        select 'term:' || t.key as key, t.value as tg from jsonb_each(g->'post') t
         where jsonb_array_length(t.value) <= (s->>'cap')::int
        union all
        select 'next:' || b.key, b.value from jsonb_each(g->'beside') b
        union all
        select 'near:' || nr.key, nr.value from jsonb_each(g->'near') nr) z;
    select coalesce(jsonb_object_agg(doc, ks), '{}'::jsonb) into raised from (
        select doc, jsonb_agg(key) as ks from (
            select dt.key as doc, 'term:' || t as key from jsonb_each(g->'terms') dt, jsonb_array_elements_text(dt.value) t
             where leads ? ('term:' || t)
            union all select b.key, 'next:' || b.key from jsonb_each(g->'beside') b
            union all select nr.key, 'near:' || nr.key from jsonb_each(g->'near') nr) y group by doc) z;
    -- hops from every document to each piece of evidence, over the reversed lead edges (breadth first from each piece)
    foreach e in array ev loop
        dist := jsonb_set(dist, array[e], jsonb_build_object(e, 0), true);
        frontier := array[e];
        hop := 0;
        while cardinality(frontier) > 0 and hop < 6 loop
            hop := hop + 1;
            select array_agg(distinct src) into nextf from (
                select r.key as src from jsonb_each(raised) r, jsonb_array_elements_text(r.value) lk,
                       jsonb_array_elements_text(leads->lk) tgt
                 where tgt = any(frontier) and r.key <> tgt) z
             where not (coalesce(dist->src, '{}'::jsonb) ? e);
            exit when nextf is null;
            for d in select unnest(nextf) loop
                dist := jsonb_set(dist, array[d], coalesce(dist->d, '{}'::jsonb) || jsonb_build_object(e, hop), true);
            end loop;
            frontier := nextf;
        end loop;
    end loop;
    -- the seeds, as the run read them
    for d in select r.doc from aiq.walk_state_reads(st) r where r.wave = 0 order by r.ord loop
        exit when n >= budget;
        if not readset ? d then
            readset := readset || jsonb_build_object(d, true); n := n + 1;
            out := out || jsonb_build_array(jsonb_build_array(n, d, 'search'));
            live := live || coalesce((select jsonb_object_agg(lk, true) from jsonb_array_elements_text(raised->d) lk
                                       where not opened ? lk), '{}'::jsonb);
        end if;
    end loop;
    while n < budget loop
        -- the best live lead: most unread evidence per unread target, else nearest unread evidence
        select x.key into best from (
            select l.key,
                   count(*) filter (where t = any(ev)) ::real / count(*) as share,
                   min((select min((dist->t->>u)::int) from unnest(ev) u where not readset ? u and dist->t ? u)) as near
              from jsonb_each(live) l, jsonb_array_elements_text(leads->l.key) t
             where not readset ? t
             group by l.key) x
         order by x.share desc, x.near nulls last, x.key
         limit 1;
        if best is null then
            -- no live lead: search's next unread document
            loop
                exit when si >= jsonb_array_length(ord);
                d := ord->>si; si := si + 1;
                exit when not readset ? d;
                d := null;
            end loop;
            exit when d is null;
            readset := readset || jsonb_build_object(d, true); n := n + 1;
            out := out || jsonb_build_array(jsonb_build_array(n, d, 'search'));
            live := live || coalesce((select jsonb_object_agg(lk, true) from jsonb_array_elements_text(raised->d) lk
                                       where not opened ? lk), '{}'::jsonb);
            continue;
        end if;
        opened := opened || jsonb_build_object(best, true);
        live := live - best;
        for d in select t from jsonb_array_elements_text(leads->best) t where not readset ? t loop
            exit when n >= budget;
            readset := readset || jsonb_build_object(d, true); n := n + 1;
            out := out || jsonb_build_array(jsonb_build_array(n, d, best));
            live := live || coalesce((select jsonb_object_agg(lk, true) from jsonb_array_elements_text(raised->d) lk
                                       where not opened ? lk), '{}'::jsonb);
        end loop;
        best := null;
    end loop;
    return query select (x->>0)::int, x->>1, x->>2 from jsonb_array_elements(out) x;
end;
$$;
grant execute on function aiq.walk_oracle(uuid, text[], int) to authenticated;
