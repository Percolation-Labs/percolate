-- ============================================================
-- How often has this source been wrong?
--
-- Taken from anda-brain, which keeps `SourceReliability { corrections,
-- last_corrected_at }` per source and lowers the confidence assigned to that
-- source's next assertion. Their comment: "High correction counts mark a source
-- whose facts deserve a lower initial confidence at encode time."
--
-- This extension already had both halves of that number and threw them away.
-- `aiq.edges` is bitemporal: a derivation retracts by setting `valid_to` and
-- never deletes. **A RETRACTION IS A CORRECTION** -- the extractor that wrote
-- that edge was wrong about the world at that time -- and an edge that still
-- holds is a confirmation. The mechanism has been running since edges were
-- written and nothing read it back.
--
-- WHAT IS HERE AND WHAT IS NOT. Two things, both of which are true of any graph
-- this extension stores:
--
--   aiq.reliability()        the estimator, over any two counts
--   aiq.source_reliability   the estimator applied to the edge table
--
-- What is NOT here is the snapshot. An application that derives its weights
-- from this has to materialise it first -- see the warning on the view -- and
-- how a second application would add its own channels to a shared snapshot is
-- a question with no second application to answer it. Inventing that extension
-- point now would be designing for one caller and calling it general.
-- ============================================================

-- LAPLACE-SMOOTHED, and parameter-free at the call site for the reason
-- evidence_weight is: a source with one confirmation and no corrections should
-- not score 1.0, because one observation is not certainty.
--
--     reliability = (confirmations + a) / (confirmations + corrections + a + b)
--
-- which is the posterior mean of a Beta(a, b) prior. The default is a = b = 1,
-- Laplace, a uniform prior: a source nobody has corrected sits just under 1 and
-- approaches it with evidence, and one corrected as often as confirmed sits at
-- 0.5.
--
-- THE PRIOR IS A PARAMETER because it is a choice and not a law. Laplace is the
-- conventional default and Jeffreys (a = b = 0.5) is the conventional
-- alternative for a rate that may be near zero; a caller who has a real prior
-- from somewhere else should be able to say so without reimplementing the
-- arithmetic. Baking in 1 and 2 would be presenting one statistician's
-- convention as the shape of the world.
create or replace function aiq.reliability(
    p_confirmations bigint,
    p_corrections   bigint,
    p_prior_confirmations real default 1.0,
    p_prior_corrections   real default 1.0)
returns numeric language sql immutable as $$
    select round(((p_confirmations + p_prior_confirmations)::numeric
                  / nullif(p_confirmations + p_corrections
                           + p_prior_confirmations + p_prior_corrections, 0)::numeric), 4);
$$;

-- PER SOURCE, over the edge table. `provenance->>'from'` is the extractor that
-- wrote the edge; `provenance->>'kind'` is the fallback for writers that use
-- the older spelling, and 'unknown' for those that record neither -- which is
-- itself worth seeing, because a source that cannot be named cannot be
-- discounted.
--
-- SECURITY INVOKER, so a caller scores the sources behind the edges they can
-- see. Left on the default this view would run as its owner, which owns
-- aiq.edges and bypasses its row-level security.
--
-- DO NOT READ THIS LIVE DURING A DERIVATION THAT USES IT, and the reason is a
-- defect this caused within ten minutes of first being written. A derivation
-- that retires the relations it owns and then revives what still derives will,
-- inside that window, show every managed edge as retracted -- so every source
-- has been wrong every time and the score collapses to 1/(n+2). Weights written
-- during that window came out at 0.001 instead of 0.99 and persisted, because
-- the transaction committed a number measured while its subject was mid-flight.
--
-- Reliability is a PRIOR FROM HISTORY. Materialise it before the sweep and read
-- the snapshot, which is both correct and stable for the length of a load.
create or replace view aiq.source_reliability with (security_invoker = true) as
select coalesce(provenance->>'from', provenance->>'kind', 'unknown') as source,
       'edge'::text                                  as channel,
       count(*) filter (where valid_to is null)      as confirmations,
       count(*) filter (where valid_to is not null)  as corrections,
       aiq.reliability(count(*) filter (where valid_to is null),
                       count(*) filter (where valid_to is not null)) as reliability
  from aiq.edges
 group by 1
having count(*) > 0;

comment on function aiq.reliability(bigint, bigint, real, real) is
    'Posterior mean of a Beta prior over a source''s confirmations and '
    'corrections. Laplace by default; the prior is a parameter because it is a '
    'choice and not a law.';
comment on view aiq.source_reliability is
    'How often each extractor''s edges have been retracted. A retraction is a '
    'correction. Materialise before reading during a derivation that uses it.';
