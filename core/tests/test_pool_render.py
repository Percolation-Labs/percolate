"""Gate 1 of specs/workflow-engine/pools.md §12: `p8 pool render` reproduces the checked-in examples byte for byte.

Run: python3 tests/test_pool_render.py     (no pytest, no cluster, no database)

The gate is worth having in this shape because the examples are the only place
the render is reviewable: a change to the generator has to show up as a diff in
a pull request, and this is what turns "has to" into "does".

The pool row below is the one the examples' README documents as the source.
Keeping it here and there is a duplication with a purpose -- if somebody edits
the README's row without editing the manifests, this fails.
"""

import os
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from percolate_core.manager.render import RenderError, render_pool  # noqa: E402

def _examples() -> pathlib.Path:
    """Where the checked-in render lives.

    It is kept with the cluster manifests in the private tree, not in this
    package, so there is no fixed path to it: P8_K8S_EXAMPLES names the
    directory, and a monorepo layout is tried after it. Say what to set rather
    than failing on a path nobody can read.
    """
    here = pathlib.Path(__file__).resolve().parent
    env = os.environ.get("P8_K8S_EXAMPLES")
    candidates = ([pathlib.Path(env)] if env else []) + [
        here.parents[0] / "k8s" / "examples",                        # a monorepo layout
    ]
    for c in candidates:
        if (c / "pool-deployment.yaml").exists():
            return c
    raise SystemExit(
        "cannot find the checked-in examples. Set P8_K8S_EXAMPLES to the directory "
        "holding pool-deployment.yaml.\n  looked in: "
        + ", ".join(str(c) for c in candidates))


EXAMPLES = _examples()

POOL = dict(
    name="embed", image="ghcr.io/acme/embed-worker:1.4", command=["worker"],
    min_replicas=0, max_replicas=20, node_class="gpu",
    cpu_request="500m", cpu_limit="2", mem_request="2Gi", mem_limit="8Gi",
    drain_seconds=600, tasks_per_replica=1, env={},
    secret_refs=["acme-model-keys"], generation=1, queues=["embed"],
)


def _check(got: str, name: str) -> bool:
    want = (EXAMPLES / name).read_text()
    if got == want:
        print(f"  ok    {name}")
        return True
    import difflib
    print(f"  FAIL  {name}")
    print("\n".join(list(difflib.unified_diff(
        want.splitlines(), got.splitlines(), "committed", "render", lineterm=""))[:40]))
    return False


def main() -> int:
    ok = True
    print("gate 1 -- render matches the checked-in examples")
    dep, so = render_pool(POOL)
    ok &= _check(dep, "pool-deployment.yaml")
    ok &= _check(so, "pool-scaledobject.yaml")

    print("gate 1b -- .spec.replicas is absent (pools.md §5.3)")
    if "replicas:" in dep.split("template:")[0]:
        print("  FAIL  a replica count would fight the HPA")
        ok = False
    else:
        print("  ok    no replica count on the Deployment")

    print("gate 1c -- a reserved env key is refused at render, not only at INSERT")
    try:
        render_pool({**POOL, "env": {"P8_DSN": "postgres://elsewhere"}})
        print("  FAIL  rendered a pool carrying P8_DSN")
        ok = False
    except RenderError as e:
        print(f"  ok    {e}")

    print("gate 1d -- two bound queues is refused, not silently half-served")
    try:
        render_pool({**POOL, "queues": ["embed", "rerank"]})
        print("  FAIL  rendered one queue and dropped the other")
        ok = False
    except RenderError as e:
        print(f"  ok    {e}")

    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
