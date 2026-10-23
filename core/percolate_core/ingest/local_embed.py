"""An embedding model that runs in this process, through fastembed (REM-628).

WHY IN THE WORKER AND NOT BEHIND A URL. Every other provider is somebody
else's service, so the registry describes a request and this package makes it.
A small ONNX model is not a service: it loads once, holds ~214MB and answers a
query in about 3ms. Putting it behind HTTP on the same node would add a hop, a
port, a deployment and a second thing to scale, to a function from text to a
list of floats.

WHY fastembed. It is ONNX Runtime and a tokenizer. No torch, which is ~2GB of
wheel and the reason "run the model yourself" has been expensive to say yes to.

THE MODEL FILE IS IN THE IMAGE, NOT FETCHED AT RUN TIME. fastembed downloads
from Hugging Face on first use and caches it. A worker that did that at startup
would need egress the deployment does not allow (REM-555), would pay it on
every cold start, and would fail a pod's first task rather than its build. The
Dockerfile pre-downloads into P8_EMBED_CACHE and the cache is read-only at run
time; `assert_offline()` is what a test calls to prove that.

ONE MODEL PER PROCESS, KEPT. Loading is 3.7s cold and 0.06s from the cache, and
an ingest worker embeds one resource after another, so the model is a module
singleton rather than a per-task object. A second model id in the same process
replaces the first: a worker embeds into one space at a time, and holding two
sets of weights to avoid a 60ms load is the wrong trade on a 2GiB pod.
"""

from __future__ import annotations

import os
import threading
from typing import Any

from ..worker.templates import TerminalError

__all__ = ["embed_local", "assert_offline", "DEFAULT_LOCAL_BATCH"]

# MEASURED, and smaller than it looks like it should be. A batch is padded to
# its longest member, so a bigger batch is a bigger tensor and no more work per
# second: at 1,800-character chunks on two threads, batch 8 ran 10.6 chunks/s at
# 482MB, batch 16 ran 10.0 at 917MB and batch 32 ran 9.8 at 1,599MB. The ingest
# pod's limit is 2GiB. The hosted default (96) exists to save round trips, and
# there are none here (measured 20 September 2026).
DEFAULT_LOCAL_BATCH = 8

_lock = threading.Lock()
_model: Any = None
_model_id: str | None = None


def _cache_dir() -> str | None:
    return os.environ.get("P8_EMBED_CACHE") or None


def _load(model_id: str) -> Any:
    global _model, _model_id
    with _lock:
        if _model is not None and _model_id == model_id:
            return _model
        try:
            from fastembed import TextEmbedding
        except ModuleNotFoundError as e:
            raise TerminalError(
                f"embedding model {model_id!r} runs in this worker, and fastembed is not "
                "installed here. Install percolate-core[embed], or register a model whose "
                "provider is called over HTTP instead.") from e
        kwargs: dict[str, Any] = {"model_name": model_id}
        if cache := _cache_dir():
            kwargs["cache_dir"] = cache
        if threads := os.environ.get("P8_EMBED_THREADS"):
            kwargs["threads"] = int(threads)
        try:
            _model, _model_id = TextEmbedding(**kwargs), model_id
        except Exception as e:
            # Almost always one of two things: an id fastembed does not know, or
            # a cache that does not hold it on a machine with no egress. Both
            # are permanent for this task, so retrying five times is five times
            # the same wait.
            raise TerminalError(
                f"could not load the embedding model {model_id!r} "
                f"(cache {_cache_dir() or 'default'}): {e}") from e
        return _model


def embed_local(model_id: str, texts: list[str], batch_size: int = DEFAULT_LOCAL_BATCH,
                expected_dim: int | None = None) -> list[list[float]]:
    """The vectors, in input order. Order is positional here for the same reason
    it is in the HTTP path: the caller matches them to chunk ids by index."""
    model = _load(model_id)
    vectors = [v.tolist() for v in model.embed(texts, batch_size=batch_size)]
    if len(vectors) != len(texts):
        raise TerminalError(
            f"{model_id} returned {len(vectors)} vectors for {len(texts)} texts")
    if expected_dim is not None and vectors and len(vectors[0]) != expected_dim:
        # The registry's dim built the vector(n) column, so a mismatch is not a
        # bad row to be rejected later: every insert into the space would fail.
        raise TerminalError(
            f"{model_id} produces {len(vectors[0])}-dimension vectors and the space "
            f"registered for it is vector({expected_dim}). Register a space whose dim "
            "matches the model, or point the model row at the model the space was built for.")
    return vectors


def assert_offline(model_id: str) -> None:
    """Load the model with the network denied, which is what a pod has. Called
    by a test so that a missing model file fails the build rather than a pod's
    first task."""
    import socket

    real = socket.socket

    class Denied(socket.socket):
        def connect(self, *a, **k):  # noqa: ANN002,ANN003
            raise AssertionError(
                f"loading {model_id} opened a network connection: the model is not in "
                f"the image's cache ({_cache_dir() or 'default'}), so a pod would "
                "download it on first use")

    socket.socket = Denied  # type: ignore[misc]
    try:
        _load(model_id)
    finally:
        socket.socket = real  # type: ignore[misc]
