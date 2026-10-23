-- The claim path, asserted rather than eyeballed.
--
-- This used to be an EXPLAIN whose output a human had to read for the words
-- "Seq Scan" and "external merge Disk". That is a check nobody runs on a
-- Tuesday, so it is now a function in the engine: workflow.check_hot_paths()
-- returns FAIL when the planner has abandoned the claim index, and refuses to
-- return `ok` on a queue too shallow to judge -- which is the exact condition
-- under which the original defect was invisible for its entire life.
set role app_owner;

select path, verdict, detail from workflow.check_hot_paths();

-- The raw plan is still here, because a FAIL is more convincing with the
-- evidence attached than without it.
explain (analyze, buffers, costs off)
select * from workflow.tasks
where queue = 'scale' and status = 'ready' and run_after <= now()
order by priority desc, created_at
for update skip locked limit 20;
