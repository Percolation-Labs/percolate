-- Work nobody can claim, which is the failure with no error in it.
--
-- A rate_key naming a bucket that does not exist means claim_task never hands
-- the task out -- to anybody, forever -- with no error, no attempt recorded and
-- no retry. v_stuck_tasks cannot see it either, because it reports tasks that
-- are OLD and a freshly unclaimable task is not old yet.
set role app_owner;

-- Manufacture the condition rather than wait for it.
update workflow.tasks set rate_key = 'a-bucket-that-does-not-exist'
where id in (select id from workflow.tasks where status = 'ready' limit 5);

select reason, count(*), min(waiting)::interval(0) as waiting
from workflow.v_unclaimable group by 1;

select 'remedy: ' || min(remedy) as remedy from workflow.v_unclaimable;

-- Put it back so the harness is re-runnable.
update workflow.tasks set rate_key = null where rate_key = 'a-bucket-that-does-not-exist';
