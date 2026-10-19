-- ============================================================
-- Resolving a loose mention to a node.
--
-- Prose names things the way people say them. A postmortem writes "the roles
-- table", a commit message writes `claim_task`, a spec writes
-- `workflow.claim_task`, and the registry holds exactly one of those. Every
-- package that lands writing against `aiq.nodes` needs the same cascade, and
-- until now each would have written its own — this shipped for weeks inside one
-- application, which is the definition of a thing that belongs in core.
--
-- THE SHAPE, adapted from graphiti's dedup_helpers.py, which is the
-- best-engineered version of it we read:
--
--   1. EXACT on a normalised key, always attempted, at any length
--   2. the ENTROPY GATE, which guards the two guessing steps below it
--   3. the DROPPED QUALIFICATION, one key ending in the mention
--   4. FUZZY, pg_trgm above a floor
--   5. anything left escalates, and says why
--
-- WHAT WE CHANGED FROM GRAPHITI. It computes MinHash signatures over 3-gram
-- shingles and bands them into an LSH index to get candidates in linear time.
-- Postgres has that already: pg_trgm's GIN index is the blocking step and the
-- similarity in one operator, so eighty lines of MinHash become `%` and
-- `similarity()`. Take the algorithm, not the implementation.
--
-- AMBIGUITY IS NOT ABSENCE, and the distinction earns its own return value.
-- Two nodes sharing a name is a question a similarity score cannot answer; a
-- name matching nothing is a different question. A caller that cannot tell them
-- apart asks a model the wrong one.
--
-- WHAT `score` MEANS DEPENDS ON `method`, and that is stated rather than
-- inferred: 1.0 for `exact` and `suffix` (both are identities, not
-- estimates), the trigram similarity for `fuzzy`, the character entropy for
-- `escalate:low-entropy`, and THE NUMBER OF CANDIDATES for
-- `escalate:ambiguous`. A caller that reads `score` without reading `method`
-- is reading five different quantities as one, which is why every branch here
-- returns the method first.
--
-- WHY AMBIGUITY REPORTS ITS SIZE. The escalation returns at most five
-- exemplars, and a caller handed five of them cannot otherwise tell five from
-- five-of-forty-four. Measured over 2,501 backticked tokens taken from this
-- repository's own prose against the dogfood registry: 163 resolved to
-- `escalate:ambiguous`, and 22 of those had more than five candidates -- one
-- with 44. A model handed an arbitrary five of forty-four and no indication
-- that it was a sample will choose one of them and sound certain, which is
-- this file's characteristic failure: a wrong answer rather than an error.
--
-- AND THE EXEMPLARS ARE ORDERED, so that the same mention resolves the same
-- way twice. `limit` without `order by` is not a bug that shows up in a test
-- run; it is a bug that shows up when the plan changes.
--
-- TENANCY COMES FROM RLS AND MUST. Every function here is SECURITY INVOKER --
-- the default, stated because it is load-bearing rather than incidental. It
-- reads `aiq.nodes` and `aiq.node_keys`, both of which carry row-level
-- security, so a caller sees the nodes their org can see and no others. A
-- SECURITY DEFINER spelling of this would resolve a mention against every
-- tenant's registry and hand back an id the caller may not read, which is the
-- worst failure available here: it looks like an answer.
-- ============================================================

-- Shannon entropy over characters. A measure of whether a string carries enough
-- evidence for similarity to mean anything: `aaa` and `Bob` cannot be
-- fuzzy-matched because there is nothing in them to be similar about.
create or replace function aiq.name_entropy(p_name text)
returns real language sql immutable as $$
    with c as (select ch, count(*)::real n
                 from regexp_split_to_table(lower(replace(p_name,' ','')), '') ch
                group by ch),
         t as (select sum(n) total from c)
    select coalesce(-sum((c.n/t.total) * ln(c.n/t.total) / ln(2)), 0)::real
      from c, t;
$$;

-- THE THRESHOLDS ARE PARAMETERS BECAUSE THEY WERE TUNED SOMEWHERE ELSE.
-- 1.5 and 6 are graphiti's, carried over rather than re-derived against a
-- corpus of ours. A default that came from another project's data is a fine
-- default and a poor constant: a registry of hex digests or of Chinese
-- identifiers has different entropy per character, and a caller who knows that
-- should be able to say so without forking the function.
create or replace function aiq.has_high_entropy(
    p_name text, p_min_entropy real default 1.5, p_min_length int default 6)
returns boolean language sql immutable as $$
    select case
        when length(p_name) < p_min_length
             and array_length(string_to_array(p_name,' '),1) < 2
            then false
        else aiq.name_entropy(p_name) >= p_min_entropy end;
$$;

create or replace function aiq.resolve_mention(
    p_text        text,
    p_entity_type text default null,
    p_min_sim     real default 0.62,
    -- THE SEPARATORS ARE A PARAMETER FOR THE SAME REASON. A dot qualifies a
    -- symbol and a slash qualifies a path, which covers every key this
    -- extension writes today. It does not cover `::`, or `#`, or a package
    -- that qualifies with a space, and hardcoding two characters as though
    -- they were the general rule is how a general mechanism becomes an
    -- overfit one.
    p_separators  text[] default array['.','/'])
returns table (node_id uuid, matched_key text, method text, score real)
language plpgsql stable as $$
declare v_norm text := lower(btrim(p_text));
        v_hits int;
        -- How many exemplars an escalation carries. Five is a sample size, not
        -- a ranking: there is nothing to rank exact matches by, and inventing
        -- an order here (shortest key, most edges) would dress a sample up as
        -- a recommendation. `score` carries the TOTAL so the sample cannot be
        -- mistaken for the set.
        v_max  constant int := 5;
        v_sfx  text[] := array(select '%' || s || v_norm from unnest(p_separators) s);
begin
    -- 1. EXACT, always, regardless of how short or repetitive the name is.
    --    An exact match is an IDENTITY and is safe at any length, which is why
    --    the entropy gate below it does not apply here.
    select count(*) into v_hits from aiq.node_keys k
      join aiq.nodes n on n.id = k.node_id
     where lower(k.key) = v_norm
       and (p_entity_type is null or n.entity_type = p_entity_type);

    if v_hits = 1 then
        return query
        select k.node_id, k.key, 'exact'::text, 1.0::real from aiq.node_keys k
          join aiq.nodes n on n.id = k.node_id
         where lower(k.key) = v_norm
           and (p_entity_type is null or n.entity_type = p_entity_type);
        return;
    elsif v_hits > 1 then
        return query
        select k.node_id, k.key, 'escalate:ambiguous'::text, v_hits::real
          from aiq.node_keys k join aiq.nodes n on n.id = k.node_id
         where lower(k.key) = v_norm
           and (p_entity_type is null or n.entity_type = p_entity_type)
         order by k.key, k.node_id
         limit v_max;
        return;
    end if;

    -- 2. THE ENTROPY GATE, guarding both guessing steps below.
    if not aiq.has_high_entropy(v_norm) then
        return query select null::uuid, null::text, 'escalate:low-entropy'::text,
                            aiq.name_entropy(v_norm);
        return;
    end if;

    -- 3. THE DROPPED QUALIFICATION. `claim_task` for `workflow.claim_task`,
    --    `check.sh` for `dev/check.sh`.
    --
    --    Measured on 300 backticked mentions taken from one repository's
    --    postmortems: of the 159 that reached `no-match` without this step, 21
    --    were a bare name whose qualified form was registered and 21 a bare
    --    filename whose path was. Trigram cannot stand in for it -- the
    --    qualifier is usually long relative to the name, and `recall_count`
    --    against `aiq.edges.recall_count` scores 0.48, under any usable floor.
    --
    --    BEHIND THE ENTROPY GATE, unlike exact matching, because this is a
    --    GUESS that a qualification was dropped rather than an identity. In
    --    front of the gate it resolved the word `done` to a column named
    --    `done` -- one match, so it looked confident, and the prose meant no
    --    such thing.
    select count(*) into v_hits from aiq.node_keys k
      join aiq.nodes n on n.id = k.node_id
     where lower(k.key) like any (v_sfx)
       and (p_entity_type is null or n.entity_type = p_entity_type);

    if v_hits = 1 then
        return query
        select k.node_id, k.key, 'suffix'::text, 1.0::real from aiq.node_keys k
          join aiq.nodes n on n.id = k.node_id
         where lower(k.key) like any (v_sfx)
           and (p_entity_type is null or n.entity_type = p_entity_type);
        return;
    elsif v_hits > 1 then
        return query
        select k.node_id, k.key, 'escalate:ambiguous'::text, v_hits::real
          from aiq.node_keys k join aiq.nodes n on n.id = k.node_id
         where lower(k.key) like any (v_sfx)
           and (p_entity_type is null or n.entity_type = p_entity_type)
         order by k.key, k.node_id
         limit v_max;
        return;
    end if;

    -- 4. FUZZY, via pg_trgm. The GIN index is the blocking step.
    --
    --    0.62 IS MEASURED, not chosen. The test needs no judgement: a fuzzy
    --    match is almost certainly right when the mention is a suffix of the
    --    key it matched. Scored that way over every backticked token in one
    --    postmortem corpus, 0.40-0.59 was 20-42% correct and 0.61-1.00 was
    --    85-100%. The cliff is at 0.60. A threshold picked from that is a
    --    different object from one picked because it felt about right -- and
    --    it is a default rather than a constant, because the corpus it was
    --    measured on is not every corpus.
    return query
    select k.node_id, k.key, 'fuzzy'::text, similarity(lower(k.key), v_norm)
      from aiq.node_keys k join aiq.nodes n on n.id = k.node_id
     where lower(k.key) % v_norm
       and (p_entity_type is null or n.entity_type = p_entity_type)
       and similarity(lower(k.key), v_norm) >= p_min_sim
     order by similarity(lower(k.key), v_norm) desc
     limit 3;

    -- 5. Nothing survived the floor.
    if not found then
        return query select null::uuid, null::text, 'escalate:no-match'::text, 0::real;
    end if;
end $$;

comment on function aiq.resolve_mention(text, text, real, text[]) is
    'Resolve a loose textual mention to a node: exact, then an entropy gate, '
    'then a dropped qualification, then trigram. Returns the method so a '
    'caller can tell an answer from an escalation, and ambiguity from absence. '
    'score is read through method: 1.0 for exact and suffix, similarity for '
    'fuzzy, entropy for escalate:low-entropy, and the total candidate count '
    'for escalate:ambiguous, which returns at most five ordered exemplars.';

-- ------------------------------------------------------------
-- An iterated semantic join: a walk whose relation is a wildcard (REM-997).
--
-- The study is Percolate writing ld-436bceb0b31c, "Graph queries as iterated
-- semantic joins". This is its first runnable slice, and it keeps the study's
-- decisions that make the walk well defined:
--
--   * THE RELATION IS A WILDCARD, resolved hop by hop. From each frontier node
--     the walk may follow a stored current edge of ANY type, in either
--     direction (link `edge`); move to another node holding the identical key
--     (`key`: two records of one thing that nobody merged); move to a node
--     whose key is at least p_similarity alike by trigram (`similarity`); or
--     follow a link a judge proposes under a criterion stated in words
--     (`judged`). Each hop says which kind of link it was.
--   * SEMI-NAIVE. Each round joins only the rows new in the round before, and
--     a node is reached once, by its first path. The walk ends when the
--     target is reached, when a round finds nothing new (the wildcard does not
--     resolve), or at the bound.
--   * THE BOUND IS EXPLICIT AND ENFORCED. p_max_rounds is required to be 1..5,
--     the dialect's DEPTH ceiling, and p_budget caps the frontier read in one
--     round. The budget DEFERS, never drops: the rows past it wait, first in
--     first out, for the next round, so a smaller budget changes how many
--     rounds a walk takes, not where it is heading.
--   * CANDIDATES BY THRESHOLD, NEVER TOP-K. A top-k list is not monotone: a new
--     row can push a true candidate out of it.
--   * A JUDGE IS AN INTERFACE THAT RAISES WHEN UNCONFIGURED. A judged link is a
--     model call, and REM-948's spike measured one Jev request at 0.2-0.4 s, too
--     slow to hold inside a statement. So the walk calls the function named by
--     the setting `percolate.link_judge` -- (criterion text, frontier uuid[])
--     returning (src uuid, dst uuid, p real) -- and refuses, by name, when none
--     is configured. Jev plugs in there, behind describe-then-call; a test plugs
--     in a stub. The study's "every judgement is kept as an edge" is not built:
--     this walk stores nothing, so it stays STABLE.
--
-- SECURITY INVOKER, like every read in this layer: the walk sees only the
-- nodes, keys and edges the caller's row security admits.
-- ------------------------------------------------------------
create or replace function aiq.iterated_join(
    p_seed text, p_target_type text, p_max_rounds int, p_budget int default 50,
    p_similarity real default 0.6, p_criterion text default null,
    p_links text[] default array['edge', 'key', 'similarity', 'judged'])
returns table(round int, node_id uuid, key text, entity_type text, path jsonb, resolved boolean)
as $$
declare
    v_seed     uuid;
    v_seen     uuid[];
    v_frontier jsonb := '[]';   -- [{node, path}], the queue, oldest first
    v_read     jsonb;
    v_new      jsonb;
    v_judge    text := nullif(current_setting('percolate.link_judge', true), '');
    v_round    int := 0;
    v_n        int;
begin
    if p_max_rounds is null or p_max_rounds < 1 or p_max_rounds > 5 then
        raise exception 'iterated_join needs p_max_rounds between 1 and 5 (got %): the bound is stated, never assumed', p_max_rounds;
    end if;
    if p_budget is null or p_budget < 1 then
        raise exception 'iterated_join needs p_budget of at least 1 (got %)', p_budget;
    end if;
    if p_criterion is not null and v_judge is null then
        raise exception 'iterated_join: a judged link was asked for (criterion %), and no judge is configured', quote_literal(p_criterion)
            using errcode = 'feature_not_supported',
                  hint = 'set percolate.link_judge to a function (criterion text, frontier uuid[]) returning (src uuid, dst uuid, p real). A model call runs behind describe-then-call, outside the statement (REM-948).';
    end if;

    if p_links is null or cardinality(p_links) = 0
       or not p_links <@ array['edge', 'key', 'similarity', 'judged'] then
        raise exception 'iterated_join: p_links must name some of edge, key, similarity, judged (got %)', p_links;
    end if;

    -- The seed is exact, as GRAPH's is: a typo must not walk a different node,
    -- and a key two nodes hold must not quietly pick one of them.
    select min(k.node_id::text)::uuid, count(distinct k.node_id) into v_seed, v_n
      from aiq.node_keys k where k.key = lower(p_seed);
    if v_n = 0 then
        raise exception 'iterated_join: no node has the key %', quote_literal(p_seed);
    elsif v_n > 1 then
        raise exception 'iterated_join: the key % names % nodes; seed with a key only one holds', quote_literal(p_seed), v_n;
    end if;
    v_seen := array[v_seed];
    v_frontier := jsonb_build_array(jsonb_build_object('node', v_seed, 'path', '[]'::jsonb));

    while v_round < p_max_rounds and jsonb_array_length(v_frontier) > 0 loop
        v_round := v_round + 1;
        -- Read at most p_budget rows of the queue; the rest wait their turn.
        select coalesce(jsonb_agg(f.value order by f.ord) filter (where f.ord <= p_budget), '[]'),
               coalesce(jsonb_agg(f.value order by f.ord) filter (where f.ord > p_budget), '[]')
          into v_read, v_frontier
          from jsonb_array_elements(v_frontier) with ordinality f(value, ord);

        with fr as (
            select (r.value->>'node')::uuid as node, r.value->'path' as path
              from jsonb_array_elements(v_read) r
        ), hop as (
            select fr.node as src, e.dst_id as dst, 'edge' as link, e.relation as via, 1.0::real as score, fr.path
              from fr join aiq.edges_current e on e.src_id = fr.node
             where 'edge' = any (p_links)
            union all
            select fr.node, e.src_id, 'edge', e.relation || ' (inverse)', 1.0::real, fr.path
              from fr join aiq.edges_current e on e.dst_id = fr.node
             where 'edge' = any (p_links)
            union all
            select fr.node, k2.node_id, 'key', k1.key, 1.0::real, fr.path
              from fr join aiq.node_keys k1 on k1.node_id = fr.node
                      join aiq.node_keys k2 on k2.key = k1.key and k2.node_id <> fr.node
             where 'key' = any (p_links)
            union all
            select fr.node, k2.node_id, 'similarity', k1.key || ' ~ ' || k2.key,
                   similarity(k1.key, k2.key), fr.path
              from fr join aiq.node_keys k1 on k1.node_id = fr.node
                      join aiq.node_keys k2 on k2.key % k1.key and k2.key <> k1.key
                                           and k2.node_id <> fr.node
             where 'similarity' = any (p_links) and similarity(k1.key, k2.key) >= p_similarity
        ), firsts as (
            -- One path per newly reached node: the strongest link, then the
            -- lowest-numbered kind (edge, key, similarity, judged) on a tie.
            select distinct on (h.dst) h.*
              from hop h
             where not (h.dst = any (v_seen))
             order by h.dst, h.score desc,
                      array_position(array['edge','key','similarity','judged'], h.link)
        )
        select coalesce(jsonb_agg(jsonb_build_object(
                   'node', f.dst,
                   'path', f.path || jsonb_build_object(
                       'from', (select min(k.key) || ' (' || min(k.entity_type) || ')' from aiq.node_keys k where k.node_id = f.src),
                       'to',   (select min(k.key) || ' (' || min(k.entity_type) || ')' from aiq.node_keys k where k.node_id = f.dst),
                       'link', f.link, 'via', f.via, 'score', round(f.score::numeric, 3)))
                   order by f.dst), '[]')
          into v_new
          from firsts f;

        if v_judge is not null and p_criterion is not null and 'judged' = any (p_links) then
            execute format('select coalesce(jsonb_agg(jsonb_build_object(''node'', j.dst, ''path'', fr.path || jsonb_build_object(
                    ''from'', (select min(k.key) || '' ('' || min(k.entity_type) || '')'' from aiq.node_keys k where k.node_id = j.src),
                    ''to'', (select min(k.key) || '' ('' || min(k.entity_type) || '')'' from aiq.node_keys k where k.node_id = j.dst),
                    ''link'', ''judged'', ''via'', %L, ''score'', round(j.p::numeric, 3)))), ''[]'')
                  from %s(%L, $1) j
                  join (select (r.value->>''node'')::uuid as node, r.value->''path'' as path
                          from jsonb_array_elements($2) r) fr on fr.node = j.src
                 where not (j.dst = any ($3))
                   and not exists (select 1 from jsonb_array_elements($4) x where (x->>''node'')::uuid = j.dst)',
                   p_criterion, v_judge::regproc, p_criterion)
              into v_read
             using (select array_agg((r.value->>'node')::uuid) from jsonb_array_elements(v_read) r),
                   v_read, v_seen, v_new;
            v_new := v_new || v_read;
        end if;

        v_seen := v_seen || coalesce((select array_agg((n->>'node')::uuid) from jsonb_array_elements(v_new) n), '{}');

        -- A target reached in this round ends the walk: those are the answers.
        if exists (select 1 from jsonb_array_elements(v_new) n join aiq.nodes x on x.id = (n->>'node')::uuid
                    where x.entity_type = p_target_type) then
            return query
                select v_round, x.id, (select min(k.key) from aiq.node_keys k where k.node_id = x.id),
                       x.entity_type, n->'path', true
                  from jsonb_array_elements(v_new) n join aiq.nodes x on x.id = (n->>'node')::uuid
                 where x.entity_type = p_target_type
                 order by 3;
            return;
        end if;
        v_frontier := v_frontier || v_new;
    end loop;

    -- Not resolved: one row saying why, so an empty answer is never silent.
    return query select v_round, null::uuid, null::text, p_target_type, jsonb_build_object(
        'reason', case when jsonb_array_length(v_frontier) = 0 then 'nothing new to join: the wildcard does not resolve'
                       else 'the bound was reached before the target' end,
        'rounds', v_round, 'reached', cardinality(v_seen) - 1, 'waiting', jsonb_array_length(v_frontier)), false;
end;
$$ language plpgsql stable security invoker;

comment on function aiq.iterated_join(text, text, int, int, real, text, text[]) is
    'A walk whose relation is a wildcard: from the seed key, each round joins the '
    'frontier through stored edges, shared keys, key similarity at a threshold, '
    'or (with a criterion) a configured judge, until a node of p_target_type is '
    'reached; p_links narrows which kinds the wildcard ranges over. Bounded by p_max_rounds (1..5) and p_budget per round, which defers '
    'and never drops. Every hop names its link kind. REM-997; study ld-436bceb0b31c.';

-- The same grant every read in this layer has: the walk runs as the caller.
grant execute on function aiq.iterated_join(text, text, int, int, real, text, text[]) to authenticated;
