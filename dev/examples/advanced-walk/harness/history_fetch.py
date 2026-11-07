"""A git repository's history as a sample: one document per commit, its message as the text, its date as said_at.

    python3 harness/history_fetch.py ../../.. samples/history 053c8869    # needs: pip install fastembed
    percolate sample load samples/history
    percolate walk index --source history

REPO is any git repository, and REV the commit whose history to take (default HEAD). Tutorial four takes this
repository at 053c8869: 1,236 commits without merges. The
vectors are made here, with the model the stack's worker runs (BAAI/bge-small-en-v1.5 through fastembed, unit
length), so the load takes seconds instead of the stack's paced embedding queue.
"""
import base64
import json
import struct
import subprocess
import sys
from pathlib import Path

MODEL, DIM = "BAAI/bge-small-en-v1.5", 384


def commits(repo: str, rev: str) -> list[dict]:
    log = subprocess.run(["git", "-C", repo, "log", rev, "--no-merges", "--format=%H%x1f%aI%x1f%B%x1e"],
                         check=True, capture_output=True, text=True).stdout
    out = []
    for rec in log.split("\x1e"):
        if not rec.strip():
            continue
        sha, at, msg = rec.strip("\n").split("\x1f", 2)
        msg = msg.strip()
        out.append({"channel": "history", "external_id": sha, "uri": f"commit:{sha}",
                    "title": msg.splitlines()[0][:120], "chunks": [{"content": msg}],
                    "metadata": {"said_at": at}})
    return out


def embed(texts: list[dict]) -> None:
    from fastembed import TextEmbedding
    import numpy as np
    vecs = TextEmbedding(MODEL).embed([t["chunks"][0]["content"] for t in texts], batch_size=64)
    for t, v in zip(texts, vecs):
        v = np.asarray(v, dtype="float32")
        v = v / np.linalg.norm(v)
        t["chunks"][0]["vector_f32"] = base64.b64encode(struct.pack(f"<{DIM}f", *v)).decode()
        t["model"] = "bge-small-en-v1.5"


def main(repo: str, sample: str, rev: str = "HEAD") -> int:
    texts = commits(repo, rev)
    embed(texts)
    with (Path(sample) / "texts.jsonl").open("w") as f:
        f.writelines(json.dumps(t) + "\n" for t in texts)
    print(f"{len(texts)} commits of {repo} at {rev}, embedded here")
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
