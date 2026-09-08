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
