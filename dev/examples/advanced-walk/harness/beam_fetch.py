"""BEAM for tutorial four: two conversations, two questions, text fetched and checked, vectors made here.

    python3 harness/beam_fetch.py samples/beam      # needs: pip install fastembed pandas pyarrow

The walkthrough's harness (../muddling-through/harness/beam_fetch.py) downloads BEAM's million-token split at a
pinned revision, checks its sha256 and writes one document per exchange; it gives a piece its vector only if the
piece's text is the one the vector was made from. This runs it for conversations 1M:16 and 1M:26, after embedding
their pieces here with the model the stack's worker runs (BAAI/bge-small-en-v1.5 through fastembed, unit length;
cosine .99999 against the stack's own vectors for the walkthrough's pieces). It keeps the two questions the tutorial
uses:
    1M:16:event_ordering:1   the walk's leads crowd out a fact search alone reads
    1M:26:event_ordering:1   travelling the open leads highest first reaches the best one
"""
import base64
import hashlib
import importlib.util
import json
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONVERSATIONS = ("16", "26")
QIDS = {"1M:16:event_ordering:1", "1M:26:event_ordering:1"}


def walkthrough():
    spec = importlib.util.spec_from_file_location("beam_fetch_walkthrough",
                                                  HERE.parent.parent / "muddling-through/harness/beam_fetch.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main(sample: str) -> int:
    import numpy as np
    from fastembed import TextEmbedding
    sample, bf = Path(sample), walkthrough()
    rows = list(bf.fetch("1M"))          # sha256-checked by the walkthrough's harness
    bf.fetch = lambda split: rows        # and handed back to its main, so BEAM downloads once
    pieces = []
    for row in rows:
        conv = str(row["conversation_id"])
        if conv in CONVERSATIONS:
            pairs, _ = bf.exchanges(row["chat"])
            for i, p in enumerate(pairs):
                for n, c in enumerate(bf.chunks(p["turns"])):
                    pieces.append((f"beam:1M:{conv}/{i}", n, bf.MARK_IN_PIECE.sub("", c)))
    model = TextEmbedding("BAAI/bge-small-en-v1.5")
    local = sample / "vectors.local.jsonl"
    with local.open("w") as f:
        for (uri, n, text), v in zip(pieces, model.embed([t for _, _, t in pieces], batch_size=64)):
            v = np.asarray(v, dtype="float32"); v = v / np.linalg.norm(v)
            f.write(json.dumps({"uri": uri, "piece": n, "sha256": hashlib.sha256(text.encode()).hexdigest(),
                                "vector_f32": base64.b64encode(struct.pack("<384f", *v)).decode()}) + "\n")
    bf.main(sample, "1M", CONVERSATIONS, [str(local)])
    for name in ("questions.jsonl", "question-texts.jsonl"):
        path = sample / name
        keep = [l for l in path.open() if (json.loads(l).get("qid") or json.loads(l)["metadata"]["id"]) in QIDS]
        path.write_text("".join(keep))
    print(f"kept {len(QIDS)} questions; {len(pieces)} pieces embedded here")
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
