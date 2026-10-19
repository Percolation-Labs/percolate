"""Pool rows in, Kubernetes manifests out. No cluster, no database, no I/O.

This is the half of the manager that can be reviewed without running anything,
which is why it is its own module: `k8s/examples/` holds a checked-in render, and
`pools.md` §12 Gate 1 is that this reproduces it byte for byte. A change to the
generator then shows up as a diff in a pull request rather than as a surprise in
a cluster.

**Why the emitter carries comments.** The obvious implementation renders a dict
and serialises it, and that is what `k8s/kind/manager.py` does — but the checked-in
examples are annotated, and their annotations are the review value. A render
without them reproduces the bytes Kubernetes needs and loses the reason anybody
would look. So the manifest stays one dict (the same object the apply path sends,
so there is no second representation to drift), and the comments hang off it by
path in `NOTES` below. The emitter walks the dict and prints a note before the key
it belongs to.

Two details the naive serialiser gets wrong and this one does not:

  * `command: ["worker"]` is flow style in the examples and block style out of a
    generic emitter. Both are valid YAML and only one of them is byte-identical,
    so the paths that render inline are named in `FLOW`.
  * `image: ghcr.io/acme/embed-worker:1.4` must NOT be quoted, even though it
    contains a colon: a colon inside a scalar is only a mapping separator when
    followed by a space. Quoting it is valid and is a diff.
"""

from __future__ import annotations

import os

from . import notes as _notes
from .emit import dump

PREFIX = "p8-pool-"
MANAGED_BY = "app.percolate/managed-by"
POOL_LABEL = "app.percolate/pool"
GEN_LABEL = "app.percolate/generation"

# The uid every rendered pool runs as (pools.md §5.1), verified against
# percolationlabs/percolate-core: `percolate worker` starts clean as 65532 on a
# read-only root filesystem, which is what Pod Security `restricted` plus this
# securityContext produce together.
RUN_AS_UID = 65532

# Rejected here as well as by the trigger in pools.sql §5a. A filter that exists
# in one place is a filter that gets bypassed the first time somebody adds a
# second write path -- and the second write path here would be a manager reading
# rows some other tool wrote.
RESERVED_ENV = ("P8_DSN", "P8_ROLE", "P8_SERVICE_ROLE", "P8_WORKER_ID")


class RenderError(RuntimeError):
    """A pool row that cannot become a manifest. Raised, never rendered around."""


def deployment(pool: dict, *, namespace: str, service_account: str,
               dsn_secret: str) -> dict:
    """One Deployment per pool. Note the absence of `.spec.replicas` — §5.3."""
    queues = pool.get("queues") or []
    if len(queues) != 1:
        # pools.sql leaves one-pool-many-queues open in the schema; the shipped
        # worker takes a single --queue, so rendering it is not yet possible.
        # Refusing loudly beats rendering the first queue and silently never
        # serving the rest (pools.md §3.2).
        raise RenderError(
            f"pool {pool['name']}: bound to {len(queues)} queues {queues}. "
            "The worker takes one --queue; pools.md §3.2.")
    queue = queues[0]
    name = PREFIX + pool["name"]

    env = [
        {"name": "P8_DSN",
         "valueFrom": {"secretKeyRef": {"name": dsn_secret, "key": "dsn"}}},
        {"name": "P8_WORKER_ID",
         "valueFrom": {"fieldRef": {"fieldPath": "metadata.name"}}},
    ]
    for k, v in sorted((pool.get("env") or {}).items()):
        if k in RESERVED_ENV or (k.startswith("P8_") and k.endswith("_SECRET")):
            raise RenderError(f"pool {pool['name']}: reserved env key {k}")
        env.append({"name": k, "value": str(v)})

    container = {
        "name": "worker",
        "image": pool["image"],
        # The consumer image's own entrypoint. Kubernetes `command` REPLACES the
        # image ENTRYPOINT rather than extending it, so this is the whole of it.
        "command": list(pool.get("command") or ["worker"]),
        "args": ["--queue", queue],
        "securityContext": {
            "allowPrivilegeEscalation": False,
            "readOnlyRootFilesystem": True,
            "capabilities": {"drop": ["ALL"]},
        },
        "resources": {
            "requests": {"cpu": pool["cpu_request"], "memory": pool["mem_request"]},
            "limits": {"cpu": pool["cpu_limit"], "memory": pool["mem_limit"]},
        },
        "env": env,
    }
    if pool.get("secret_refs"):
        container["envFrom"] = [{"secretRef": {"name": s}} for s in pool["secret_refs"]]

    return {
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {
            "name": name,
            "namespace": namespace,
            "labels": {
                MANAGED_BY: "manager",
                POOL_LABEL: pool["name"],
                GEN_LABEL: str(pool["generation"]),
            },
        },
        "spec": {
            "selector": {"matchLabels": {POOL_LABEL: pool["name"]}},
            "template": {
                "metadata": {"labels": {MANAGED_BY: "manager", POOL_LABEL: pool["name"]}},
                "spec": {
                    "serviceAccountName": service_account,
                    "automountServiceAccountToken": False,
                    "terminationGracePeriodSeconds": pool["drain_seconds"],
                    "securityContext": {
                        "runAsNonRoot": True,
                        "runAsUser": RUN_AS_UID,
                        "seccompProfile": {"type": "RuntimeDefault"},
                    },
                    "nodeSelector": {"percolate.io/node-class": pool["node_class"]},
                    "tolerations": [{
                        "key": "percolate.io/node-class",
                        "operator": "Equal",
                        "value": pool["node_class"],
                        "effect": "NoSchedule",
                    }],
                    "topologySpreadConstraints": [{
                        "maxSkew": 1,
                        "topologyKey": "kubernetes.io/hostname",
                        "whenUnsatisfiable": "ScheduleAnyway",
                        "labelSelector": {"matchLabels": {POOL_LABEL: pool["name"]}},
                    }],
                    "containers": [container],
                },
            },
        },
    }


def scaledobject(pool: dict, *, namespace: str, polling_seconds: int,
                 auth_name: str = "p8-keda-postgres") -> dict:
    """One ScaledObject per pool, one trigger per bound queue."""
    queue = (pool.get("queues") or [None])[0]
    if queue is None:
        raise RenderError(f"pool {pool['name']}: no queue bound")
    name = PREFIX + pool["name"]
    return {
        "apiVersion": "keda.sh/v1alpha1",
        "kind": "ScaledObject",
        "metadata": {
            "name": name,
            "namespace": namespace,
            "labels": {MANAGED_BY: "manager", POOL_LABEL: pool["name"]},
        },
        "spec": {
            "scaleTargetRef": {"name": name},
            "minReplicaCount": pool["min_replicas"],
            "maxReplicaCount": pool["max_replicas"],
            "pollingInterval": polling_seconds,
            "cooldownPeriod": pool["drain_seconds"],
            "fallback": {"failureThreshold": 3, "replicas": 1},
            "triggers": [{
                "type": "postgresql",
                "metadata": {
                    "query": f"select workflow.queue_depth('{queue}')",
                    "targetQueryValue": str(pool["tasks_per_replica"]),
                    "activationTargetQueryValue": "0",
                },
                "authenticationRef": {
                    "name": auth_name,
                    "kind": "ClusterTriggerAuthentication",
                },
            }],
        },
    }


class Config:
    """Manager configuration — and every one of these is deliberately NOT a
    column on `workflow.pools` (pools.md §3.1). A consumer-supplied namespace is
    a direct route to scheduling a pod into kube-system, and this is the seam
    where that is prevented rather than validated."""

    namespace = os.environ.get("P8_POOL_NAMESPACE", "percolate")
    service_account = os.environ.get("P8_POOL_SERVICE_ACCOUNT", "percolate-pool")
    dsn_secret = os.environ.get("P8_POOL_DSN_SECRET", "p8-worker-dsn")
    polling_seconds = int(os.environ.get("P8_KEDA_POLLING_SECONDS", "15"))
    resync_seconds = int(os.environ.get("P8_MANAGER_RESYNC_SECONDS", "30"))


def render_pool(pool: dict, cfg: type[Config] = Config) -> tuple[str, str]:
    """The two manifests for one pool row, as annotated YAML.

    Lives here rather than in `cli.py` so that rendering — the half that is
    Gate 1, and the half anybody reviewing a change needs — costs no import
    beyond the standard library. A gate that needs Typer installed to run is a
    gate that gets skipped on the machine where it matters.

    Returns (deployment, scaledobject) separately because that is what
    `k8s/examples/` is: two files, two reviews.
    """
    src = f"workflow.pools where name = '{pool['name']}'"
    dep = deployment(pool, namespace=cfg.namespace, service_account=cfg.service_account,
                     dsn_secret=cfg.dsn_secret)
    so = scaledobject(pool, namespace=cfg.namespace, polling_seconds=cfg.polling_seconds)

    dep_notes = dict(_notes.DEPLOYMENT_NOTES)
    dep_notes[("apiVersion",)] = _notes.header(
        src + "  (see README.md in this directory)",
        "NOTE THE ABSENCE OF .spec.replicas. That is not an omission. pools.md §5.3.")
    so_notes = dict(_notes.SCALEDOBJECT_NOTES)
    so_notes[("apiVersion",)] = _notes.header(src)

    return (dump(dep, dep_notes, _notes.DEPLOYMENT_FLOW) + "\n",
            dump(so, so_notes, _notes.SCALEDOBJECT_FLOW, _notes.SCALEDOBJECT_QUOTE) + "\n")
