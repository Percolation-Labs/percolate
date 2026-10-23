# The kind probes — what a cluster tests that compose cannot

Compose measures the database. This measures the things that only exist once
workers are on other machines: a real network between claimer and database, pods
dying while holding work, and the connection budget.

```bash
kind create cluster --config cluster.yaml
docker pull percolationlabs/percolate-postgres:19
kind load docker-image percolationlabs/percolate-postgres:19 --name p8-scale
kubectl apply -f stack.yaml
kubectl scale -n p8 deployment/claimer --replicas=2
```

The database is pinned to the control plane and the claimers are barred from it
by node affinity, so **every claim crosses a node boundary**. That is the whole
point of running this here rather than in compose.

## Bound the run by transaction count, not by time

`claimbench-job.yaml` uses `pgbench -t`, and the reason is a measurement error
this harness made first and caught second.

A time-boxed run against a queue that drains mid-run measures the **empty-queue
no-op path** for the remainder and reports it as throughput. It looks like a
spectacular result: the first kind run reported 22,839 claims/s per pod, and the
queue turned out to be empty — 200,000 tasks had all moved to `running` inside
the first few seconds and every subsequent "claim" was returning null.

So a run is bounded by transaction count, and **the check is arithmetic**: the
ready count must fall by exactly `pods × clients × transactions`. If it fell by
less, the queue drained and the number is inflated.

```
started: ready=200000
ran:     2 pods x 4 clients x 5000 transactions = 40000
ended:   ready=160000, running=40000        <- exactly 40000. Trust the number.
```

## Resetting between runs

Scale claimers to **0 and wait for the pods to actually be gone** before
resetting. A terminating pod keeps claiming, and a reset that races it produces a
run contaminated by load you are not counting — which also happened here before
it was noticed.

```bash
kubectl scale -n p8 deployment/claimer --replicas=0
until [ "$(kubectl get pods -n p8 -l app=claimer --no-headers | wc -l)" = "0" ]; do sleep 3; done
```

Note that `kubectl apply -f stack.yaml` resets `replicas` to 0, because the
manifest declares it. Scale after applying, never before.
