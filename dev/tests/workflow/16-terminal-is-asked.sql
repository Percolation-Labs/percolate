-- "Has it finished" is asked of the vocabulary, and stays asked (REM-52).
--
-- workflow.lifecycle_states has carried is_terminal and is_success since
-- efebac2 and nothing read them: every caller wrote `status in ('succeeded',
-- 'failed','cancelled')` again instead. Each copy was correct, and each was a
-- place a ninth state would have to be remembered into -- which is how
-- `quota_exceeded` reached the browser as an unstyled chip and a cancelled run
-- reached dev/e2e-lake.py as a wait that ran out its deadline.
--
-- Two assertions. The functions agree with the table, and no function body in
-- the extension writes the set out again.
\set ON_ERROR_STOP on
begin;
set local role app_owner;

do $$ declare v_bad text; begin
    -- 1. The functions ARE the table, for every state and for a word that is
    --    not one. An unknown status is not terminal: it is a typo, and
    --    treating it as finished would end a run that never ran.
    select string_agg(format('%s: is_terminal=%s/%s is_success=%s/%s', s.state,
                             workflow.is_terminal(s.state), s.is_terminal,
                             workflow.is_success(s.state), s.is_success), '; ')
      into v_bad
      from workflow.lifecycle_states s
     where workflow.is_terminal(s.state) is distinct from s.is_terminal
        or workflow.is_success(s.state) is distinct from s.is_success;
    if v_bad is not null then raise exception 'the functions disagree with the table: %', v_bad; end if;

    if workflow.is_terminal('done') or workflow.is_success('done')
       or workflow.is_terminal(null) or workflow.is_success(null) then
        raise exception 'a status the vocabulary does not admit reads as finished';
    end if;

    -- A state added to the table is terminal to every reader immediately,
    -- which is the whole claim. Rolled back with this transaction.
    insert into workflow.lifecycle_states (state, is_terminal, is_success, note)
    values ('t_abandoned', true, false, 'test-only, rolled back');
    if not workflow.is_terminal('t_abandoned') or workflow.is_success('t_abandoned') then
        raise exception 'a state added to the vocabulary is not read from it';
    end if;
    delete from workflow.lifecycle_states where state = 't_abandoned';

    -- 2. Nothing writes the terminal set out again. The pattern is the triple
    --    in any order inside a function body; the two functions above are the
    --    one place it is allowed to appear, and they do not contain it either
    --    -- they read rows. A CHECK constraint may still list states, because
    --    which SUBSET a table admits genuinely differs per table and is
    --    enforced where a violation can be refused.
    select string_agg(p.oid::regprocedure::text, ', ' order by p.oid::regprocedure::text)
      into v_bad
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('workflow', 'content', 'aiq', 'agentic', 'rbac', 'percolate')
       and p.prokind = 'f'
       -- Both spellings: written in a body, and written inside dynamic SQL,
       -- where the quotes are doubled. workflow.purge_completed had two of the
       -- second kind, which is where retention decides what may be deleted.
       and pg_get_functiondef(p.oid) ~
           '''{1,2}succeeded''{1,2}\s*,\s*''{1,2}failed''{1,2}\s*,\s*''{1,2}cancelled'''
       and p.proname not in ('is_terminal', 'is_success');
    if v_bad is not null then
        raise exception 'these function bodies write the terminal set out instead of asking for it: %', v_bad
        using hint = 'workflow.is_terminal(status) / workflow.is_success(status). '
                     'A list here is correct today and is a place the ninth state has to be remembered into.';
    end if;

    raise notice 'workflow/16: is_terminal and is_success are the table, and no function body restates the terminal set';
end $$;
rollback;
