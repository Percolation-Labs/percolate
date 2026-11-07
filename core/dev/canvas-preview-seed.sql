insert into rbac.users(id,email,status,fixture) values ('13290000-0000-0000-0000-000000000001','canvas-preview@example.test','active',true) on conflict(id) do nothing;
insert into workflow.definitions(name,version,spec) values ('Example: workspace report',1,'{"steps":[{"key":"example","kind":"work","queue":"example"}]}') on conflict(name,version) do nothing;
insert into workflow.runs(workflow_def_id,owner_id,status,input,completed_at)
select id,'13290000-0000-0000-0000-000000000001',s.status,'{"example":true}',now() from workflow.definitions cross join (values('succeeded'),('succeeded'),('failed')) s(status) where name='Example: workspace report';
insert into workflow.tasks(run_id,step_key,queue,status,output,completed_at)
select r.id, step, 'example', 'succeeded','{}',now() from workflow.runs r cross join (values('retrieve'),('judge'),('answer')) s(step) where r.owner_id='13290000-0000-0000-0000-000000000001';
