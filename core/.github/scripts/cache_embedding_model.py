"""Download the in-process embedding model into the image, then prove it is complete (REM-628).

Run in the `embedmodel` build stage, on the BUILD platform: the files are an
ONNX graph and a tokenizer, identical for both architectures, and running the
model under QEMU is what killed the 0.2.1 release (REM-619).

The second half is the point. Downloading leaves a cache that looks right; what
a pod needs is a cache that LOADS with no network, because it has no egress to
Hugging Face (REM-555). So the model is loaded again with sockets denied, and
one text embedded. A missing file fails this build rather than a pod's first
task, months later, in somebody else's upload.
"""
import os
import socket
import sys

CACHE = os.environ.get("P8_EMBED_CACHE", "/embed-cache")
MODEL = os.environ["P8_EMBED_MODEL"]

from fastembed import TextEmbedding  # noqa: E402

TextEmbedding(model_name=MODEL, cache_dir=CACHE)
print(f"cached {MODEL} into {CACHE}", flush=True)


class Denied(socket.socket):
    def connect(self, *a, **k):
        raise AssertionError(
            f"{MODEL} is not fully cached in {CACHE}: loading it opened a connection, "
            "so a pod with no egress would fail its first embed task")


socket.socket = Denied
model = TextEmbedding(model_name=MODEL, cache_dir=CACHE)
dim = len(list(model.embed(["a sentence to prove the session runs"]))[0])
print(f"loaded offline, dim={dim}", flush=True)
if dim <= 0:
    sys.exit(1)
