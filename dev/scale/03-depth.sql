-- What the autoscaler pays, every 30 seconds, per pool -- and the headroom it
-- can exhaust before it exhausts throughput.
--
-- The connection view is here because a cluster run found that connection
-- exhaustion locks out the operator as well as the workers, so it is worth
-- watching before it is gone rather than diagnosing after.
set role app_owner;

select max_connections, reserved, in_use, headroom, workers_seen,
       coalesce(warning, '(within budget)') as status
from workflow.v_capacity;

explain (analyze, buffers, costs off) select workflow.queue_depth('scale');
