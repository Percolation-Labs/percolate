-- Shared canvas is a core capability. No application catalog is installed.
begin;
insert into rbac.users(id,email,status) values
('13290000-0000-0000-0000-000000000010','canvas-one@test.invalid','active'),
('13290000-0000-0000-0000-000000000011','canvas-two@test.invalid','active');
insert into workflow.definitions(name,version,spec) values('test-canvas-record',1,'{"steps":[{"key":"one","kind":"work","queue":"example"}]}');
insert into workflow.runs(workflow_def_id,owner_id,status)
select id,'13290000-0000-0000-0000-000000000010','succeeded' from workflow.definitions where name='test-canvas-record';
select set_config('request.jwt.claims','{"sub":"13290000-0000-0000-0000-000000000010","role":"authenticated","actor":"person"}',true);
do $$
declare s jsonb; q jsonb; v jsonb; c jsonb; n int; i int;
begin
 s:=workflow.canvas('open');q:=workflow.canvas('query','{"query":"workflow_runs"}');
 if q->'view'->'result'->'rows'  is distinct from  '[{"status":"succeeded","runs":1}]'::jsonb then raise exception 'Report escaped caller ownership';end if;
 perform workflow.canvas('touch',jsonb_build_object('kind','selection','result_set',q->'view'->'result'->>'id','columns',jsonb_build_array('status','runs'),'rows',jsonb_build_array(0)));
 select count(*) into n from workflow.tasks where step_key='query';
 v:=workflow.canvas('view','{"control":"plot"}');
 if v->'view'->'result'  is distinct from  q->'view'->'result' then raise exception 'View queried again';end if;
 perform workflow.canvas('view','{"control":"cards"}');
 if (select count(*) from workflow.tasks where step_key='query') is distinct from n then raise exception 'View made query task';end if;
 c:=workflow.canvas('consume');if jsonb_array_length(c->'since_last_call') is distinct from 1 then raise exception 'Missing touch';end if;
 c:=workflow.canvas('consume');if c->'since_last_call' is distinct from '[]'::jsonb then raise exception 'Replayed touch';end if;
 for i in 1..10 loop
  perform workflow.canvas('touch','{"kind":"mark"}');c:=workflow.canvas('consume');
 end loop;
 if jsonb_array_length(c->'lag_samples') is distinct from 10 or (c->>'window_ms')::int<1000 then raise exception 'Timing calibration missing';end if;
 if (select jsonb_array_length(context->'touches') from workflow.runs where id=(s->>'session')::uuid) is distinct from 11 then raise exception 'Consume removed audit';end if;
 q:=workflow.canvas('present','{"statement":"select visible_edges","columns":["source","target"],"rows":[{"source":"a","target":"b"}]}');
 v:=workflow.canvas('view','{"control":"graph","options":{"source":"source","target":"target"}}');
 if v->'view'->'result' is distinct from q->'view'->'result' then raise exception 'Graph changed result';end if;
 perform workflow.canvas('touch',jsonb_build_object('kind','selection','result_set',q->'view'->'result'->>'id','columns',jsonb_build_array('source','target'),'rows',jsonb_build_array(0),'nodes',jsonb_build_array('a')));
 c:=workflow.canvas('consume');
 if c->'since_last_call'->0->'nodes' is distinct from '["a"]'::jsonb then raise exception 'Node selection lost';end if;
 begin
  perform workflow.canvas('touch',jsonb_build_object('kind','selection','result_set',q->'view'->'result'->>'id','columns','[]'::jsonb,'rows','[]'::jsonb,'nodes',jsonb_build_array('missing')));
  raise exception 'Unknown node admitted';
 exception when raise_exception then if sqlerrm is distinct from 'Unknown selected node' then raise;end if;end;
 perform set_config('request.jwt.claims','{"sub":"13290000-0000-0000-0000-000000000011","role":"authenticated","actor":"person"}',true);
 begin
  perform workflow.canvas('read',jsonb_build_object('session',s->>'session'));
  raise exception 'Another user read session';
 exception when raise_exception then if sqlerrm is distinct from 'Canvas session not found' then raise;end if;end;
 c:=workflow.canvas('open');c:=workflow.canvas('query','{"query":"workflow_runs"}');
 if c->'view'->'result'->'rows' is distinct from '[]'::jsonb then raise exception 'Another user read report rows';end if;
 perform set_config('request.jwt.claims','{}',true);
 begin
  perform workflow.canvas('open');raise exception 'Anonymous caller admitted';
 exception when insufficient_privilege then null;end;
end $$;
rollback;
