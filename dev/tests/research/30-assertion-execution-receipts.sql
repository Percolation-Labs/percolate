-- REM-590: real SQL execution boundary, manual write, forged provenance, retry and operational pruning.
\set ON_ERROR_STOP on
begin;
insert into rbac.users(id,email,status) values
 ('00000000-0000-4000-8000-000000059001','receipt-owner@example.test','active'),
 ('00000000-0000-4000-8000-000000059002','receipt-reader@example.test','active');
insert into rbac.roles(name,description) values ('receipt-author','receipt workflow fixture');
insert into rbac.role_permissions(role,resource,action) values ('receipt-author','workflows','update'),('receipt-author','research','list');
insert into rbac.user_roles(user_id,role) values ('00000000-0000-4000-8000-000000059001','receipt-author');
create temporary table ids(k text primary key,v text) on commit drop;
grant all on ids to authenticated;
set local request.jwt.claims='{"sub":"00000000-0000-4000-8000-000000059001"}';
set local role authenticated;
insert into ids select 'rev',(research.submit_package('{"schema_version":"0.1","title":"Receipts","visibility":"listed","sources":[],"edges":[],
 "claims":[{"id":"C1","kind":"Inference","text":"One."},{"id":"C2","kind":"Inference","text":"Two."}]}',null,'rp-receipts')->>'revision_id');
insert into ids select 'manual',claims.assert_relation('C1','supports','C2',(select v::uuid from ids where k='rev'))::text;
do $$ declare j jsonb; begin
 select claims.execution_receipt(tx) into j from claims.relations where id=(select v::bigint from ids where k='manual');
 assert j->>'kind'='manual' and j->>'run_id' is null, 'manual assertion names no invented run';
 assert j->'inputs'->0->>'status'='available' and j->'inputs'->0->>'content_hash' is not null, 'receipt captures immutable input hash';
 assert j->'execution'->>'status'='unavailable', 'no invented usage or model';
 begin
   perform set_config('workflow.current_task_id','00000000-0000-4000-8000-000000059099',true);
   raise exception 'caller forged task provenance';
 exception when insufficient_privilege then null; end;
end $$;
reset role;
-- Run a registered function through execute_sql_step, rather than hand-setting its trusted context.
create function public.rem590_assert() returns jsonb language sql as $$
 select to_jsonb(claims.assert_relation('C2','supports','C1',(select id from research.revisions where work_id=
   (select id from research.works where public_id='rp-receipts') limit 1)));
$$;
select workflow.register_step_function('rem590_assert','public.rem590_assert');
select workflow.define_yaml($y$
name: rem590_receipt
steps:
  - id: assert
    sql: {function: rem590_assert, args: []}
$y$);
insert into ids select 'run',workflow.start_workflow('rem590_receipt','{}')::text;
insert into ids select 'task',id::text from workflow.tasks where run_id=(select v::uuid from ids where k='run');
insert into ids select 'generated_tx',tx::text from claims.relations where id=(
 select (output->>'result')::bigint from workflow.tasks where id=(select v::uuid from ids where k='task'));
do $$ begin
 assert (select status='succeeded' from workflow.tasks where id=(select v::uuid from ids where k='task')), 'SQL step completed';
 assert coalesce(current_setting('workflow.current_task_id',true),'')='', 'task context restored after step';
end $$;
set local role authenticated;
do $$ declare j jsonb := claims.execution_receipt((select v::bigint from ids where k='generated_tx')); begin
 assert j->>'kind'='workflow' and j->>'task_id'=(select v from ids where k='task'), 'actual engine task captured';
 assert j->>'run_id'=(select v from ids where k='run') and j->>'step_key'='assert', 'run and step captured';
end $$;
reset role;
-- Completion retry writes no new assertion/receipt. Operational retention cannot cascade into receipts.
do $$ declare n bigint := (select count(*) from claims.execution_receipts); begin
 assert not workflow.execute_sql_step((select v::uuid from ids where k='task')), 'completed task is not replayed';
 assert n=(select count(*) from claims.execution_receipts), 'retry creates no receipt';
end $$;
delete from workflow.runs where id=(select v::uuid from ids where k='run');
set local role authenticated;
do $$ begin
 assert claims.execution_receipt((select v::bigint from ids where k='generated_tx'))->>'task_id'=(select v from ids where k='task'), 'pruned workflow retains execution identity';
end $$;
reset role;
-- The runtime carries a signed task lease, and its usage producer writes through a worker-only function.
with x as (insert into workflow.runs(workflow_def_id,owner_id)
 values ((select id from workflow.definitions where name='rem590_receipt' limit 1),'00000000-0000-4000-8000-000000059001') returning id)
insert into ids select 'runtime_run',id::text from x;
with x as (insert into workflow.tasks(run_id,step_key,kind,status,attempts,claimed_by)
 values ((select v::uuid from ids where k='runtime_run'),'model','http_call','running',1,'receipt-worker') returning id)
insert into ids select 'runtime_task',id::text from x;
-- Even otherwise well-formed task context cannot move another actor's assertions into this run.
select set_config('request.jwt.claims',jsonb_build_object('sub','00000000-0000-4000-8000-000000059002',
 'workflow_task_id',(select v from ids where k='runtime_task'),'workflow_worker_id','receipt-worker','workflow_attempt',1)::text,true);
set local role authenticated;
do $$ begin
 begin
   perform research.submit_package('{"schema_version":"0.1","title":"Forged foreign run","visibility":"private","sources":[],"edges":[],
      "claims":[{"id":"C1","kind":"Inference","text":"A forged provenance claim."}]}',null,'rp-foreign-receipt');
   raise exception 'an actor attached an assertion to another owner run';
 exception when check_violation then
   if sqlerrm <> 'An assertion workflow run belongs to its actor' then raise; end if;
 end;
 assert not exists(select 1 from research.works where public_id='rp-foreign-receipt'), 'refused provenance leaves no work';
end $$;
reset role;
-- A model-only task must not turn the receipt store into another execution log.
grant select on ids to worker;
set local role worker;
select claims.record_execution_result((select v::uuid from ids where k='runtime_task'),'receipt-worker',1,
 '00000000-0000-4000-8000-000000059003','core/test','test-model',null,'{"input_tokens":12}');
reset role;
do $$ begin
 assert not exists(select 1 from claims.execution_results where task_id=(select v::uuid from ids where k='runtime_task')),
   'no assertion means no durable model-result copy';
end $$;
select set_config('request.jwt.claims',jsonb_build_object('sub','00000000-0000-4000-8000-000000059001',
 'workflow_task_id',(select v from ids where k='runtime_task'),'workflow_worker_id','receipt-worker','workflow_attempt',1)::text,true);
set local role authenticated;
insert into ids select 'runtime_relation',claims.assert_relation('C1','challenges','C2',(select v::uuid from ids where k='rev'))::text;
insert into ids select 'runtime_tx',tx::text from claims.relations where id=(select v::bigint from ids where k='runtime_relation');
do $$ begin
 begin
   perform claims.record_execution_result((select v::uuid from ids where k='runtime_task'),'receipt-worker',1,
     '00000000-0000-4000-8000-000000059003','core/test','test-model',null,'{}');
   raise exception 'caller forged provider metadata';
 exception when insufficient_privilege then null; end;
end $$;
reset role;
grant select on ids to worker;
set local role worker;
do $$ declare task uuid := (select v::uuid from ids where k='runtime_task'); begin
 begin
   perform claims.record_execution_result(task,'stale-worker',1,'00000000-0000-4000-8000-000000059003','core/test','test-model',null,'{}');
   raise exception 'stale worker attached a result';
 exception when insufficient_privilege then null; end;
 perform claims.record_execution_result(task,'receipt-worker',1,'00000000-0000-4000-8000-000000059003',
   'core/test','test-model',null,'{"input_tokens":12,"output_tokens":3,"prompt":"secret text"}',
   '00000000-0000-4000-8000-000000059099');
 perform claims.record_execution_result(task,'receipt-worker',1,'00000000-0000-4000-8000-000000059003',
   'core/test','test-model',null,'{"input_tokens":12,"output_tokens":3}',
   '00000000-0000-4000-8000-000000059099');
 begin
   perform claims.record_execution_result(task,'receipt-worker',1,'00000000-0000-4000-8000-000000059003','core/test','forged-model',null,'{}');
   raise exception 'retry rewrote a receipt';
 exception when check_violation then null; end;
end $$;
reset role;
update workflow.tasks set attempts=2,claimed_by='new-worker' where id=(select v::uuid from ids where k='runtime_task');
set local role authenticated;
do $$ begin
 begin
   perform claims.assert_relation('C1','supports','C2',(select v::uuid from ids where k='rev'));
   raise exception 'stale token adopted a later task attempt';
 exception when check_violation then null; end;
end $$;
reset role;
delete from workflow.runs where id=(select v::uuid from ids where k='runtime_run');
set local request.jwt.claims='{"sub":"00000000-0000-4000-8000-000000059001"}';
set local role authenticated;
do $$ declare j jsonb:=claims.execution_receipt((select v::bigint from ids where k='runtime_tx')); begin
 assert j->'execution'->>'status'='available', 'result survives task pruning';
 assert jsonb_array_length(j->'execution'->'runs')=1, 'retry is idempotent';
 assert j->'execution'->'runs'->0->'usage'='{"input_tokens":12,"output_tokens":3}'::jsonb, 'only measured counters, no prompt';
 assert j->'execution'->'runs'->0->>'model_version' is null, 'unknown provider version stays unknown';
 assert j->'evaluation_artifacts'->0='{"status":"unavailable"}'::jsonb, 'missing content has no leaked locator';
end $$;
reset role;
-- A signed caller with a made-up task still cannot bind an assertion to a non-executing task.
select set_config('request.jwt.claims',jsonb_build_object('sub','00000000-0000-4000-8000-000000059001','workflow_task_id',(select v from ids where k='task'))::text,true);
set local role authenticated;
do $$ begin
 begin
   perform claims.assert_relation('C1','supports','C2',(select v::uuid from ids where k='rev'));
   raise exception 'assertion accepted a pruned task';
 exception when check_violation then null; end;
end $$;
reset role;
-- An erased comparison input is retained only as unavailable, without its id or content hash.
set local request.jwt.claims='{"sub":"00000000-0000-4000-8000-000000059001"}';
set local role authenticated;
insert into ids select 'secondary',research.submit_package('{"schema_version":"0.1","title":"Private input","visibility":"private","sources":[],"edges":[],
 "claims":[{"id":"C1","kind":"Inference","text":"Private input text."}]}',null,'rp-receipt-input')->>'revision_id';
insert into ids select 'comparison',claims.assert_relation('C1','supports','C1',(select v::uuid from ids where k='rev'),(select v::uuid from ids where k='secondary'))::text;
insert into ids select 'comparison_tx',tx::text from claims.relations where id=(select v::bigint from ids where k='comparison');
reset role;
select research.erase_work('rp-receipt-input','receipt missing-input fixture');
set local role authenticated;
do $$ declare j jsonb:=claims.execution_receipt((select v::bigint from ids where k='comparison_tx')); begin
 assert jsonb_array_length(j->'inputs')=2, 'receipt preserves input completeness after erasure';
 assert (select count(*) from jsonb_array_elements(j->'inputs') i where i='{"status":"unavailable"}'::jsonb)=1,
   'erased input reveals neither id nor hash';
end $$;
reset role;
set local request.jwt.claims='{"sub":"00000000-0000-4000-8000-000000059002"}';
set local role authenticated;
do $$ begin
 assert claims.execution_receipt((select v::bigint from ids where k='generated_tx'))->>'kind'='workflow', 'public reader can inspect generated receipt';
 assert claims.execution_receipt(-1) is null, 'missing and denied receipts indistinguishable';
 begin
   perform * from claims.execution_receipts;
   raise exception 'caller can read raw private receipt rows';
 exception when insufficient_privilege then null; end;
end $$;
reset role;
set local request.jwt.claims='{"sub":"00000000-0000-4000-8000-000000059001"}';
set local role authenticated;
select research.revise_package('rp-receipts','{"schema_version":"0.1","title":"Now private","visibility":"private","claims":[],"sources":[],"edges":[]}','draft-1');
reset role;
set local request.jwt.claims='{"sub":"00000000-0000-4000-8000-000000059002"}';
set local role authenticated;
do $$ begin
 assert claims.execution_receipt((select v::bigint from ids where k='generated_tx')) is null, 'revoked evidence revokes receipt access';
end $$;
reset role;
rollback;
