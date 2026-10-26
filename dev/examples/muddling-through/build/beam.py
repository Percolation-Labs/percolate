#!/usr/bin/env python3
"""Build samples/beam from the walk study's BEAM files: two conversations, as `texts` lines, plus their questions.

    python3 build/beam.py <study runs/beam dir> samples/beam

Run once by whoever refreshes the sample; a reader never runs it. It reads the study's docs.jsonl and questions.jsonl
(BEAM, CC BY-SA 4.0, Tavakoli et al., arXiv 2510.27246) and writes:

  texts.jsonl       one line per exchange, for `percolate sample load`'s texts step. The chunks are the study's own
                    (each turn as "role: content", packed to 2,000 characters), so the vectors bge-small gives them are
                    the vectors the study searched. The metadata holds the sitting, the place in the conversation and
                    the date said, and `terms_text`: the user's words with BEAM's '->-> n,m' plan index removed, which
                    is what the study tagged.
  questions.jsonl   every question on the two conversations, its channel, and its evidence as document keys.

1M:22 is the conversation the walkthrough's miss comes from (the ladder question). 1M:35 is where the walk clearly
beats search (1M:35:event_ordering:0).
"""
import json
import re
import sys
from pathlib import Path

RUNS = {"1M:22": "beam-1m22", "1M:35": "beam-1m35"}
CHUNK = 2000
MARK = re.compile(r"\s*->->\s*\d+\s*,\s*\d+\s*$")


def chunks(turns):
    """The study's chunking (embed_pool.chunks), unchanged."""
    out, cur = [], ""
    for t in turns:
        line = f"{t['role']}: {t['content']}\n"
        while len(line) > CHUNK:
            if cur:
                out.append(cur)
                cur = ""
            out.append(line[:CHUNK])
            line = line[CHUNK:]
        if len(cur) + len(line) > CHUNK and cur:
            out.append(cur)
            cur = ""
        cur += line
    if cur:
        out.append(cur)
    return out


def key(run, pair):
    return f"beam:{run}/{pair}"


def main(src, dst):
    src, dst = Path(src), Path(dst)
    lines = []
    for line in (src / "docs.jsonl").open():
        d = json.loads(line)
        if d["run"] not in RUNS:
            continue
        user = "\n".join(MARK.sub("", t["content"]) for t in d["turns"] if t["role"] == "user")
        lines.append((d["run"], d["pair"], {
            "channel": RUNS[d["run"]],
            "external_id": f"{d['run']}/{d['pair']}",
            "title": f"BEAM {d['run']}, exchange {d['pair']}",
            "uri": key(d["run"], d["pair"]),
            "chunks": [{"content": c} for c in chunks(d["turns"])],
            "metadata": {"sitting": d["session"], "position": d["pair"], "said_at": d.get("said_at"),
                         "terms_text": user},
        }))
    lines.sort(key=lambda x: (x[0], x[1]))
    with (dst / "texts.jsonl").open("w") as f:
        for _, _, t in lines:
            f.write(json.dumps(t) + "\n")
    qs = []
    for line in (src / "questions.jsonl").open():
        q = json.loads(line)
        if q["run"] in RUNS:
            qs.append({"qid": q["qid"], "channel": RUNS[q["run"]], "type": q["type"], "question": q["question"],
                       "gold": [key(q["run"], p) for p in q["gold"]]})
    qs.sort(key=lambda q: q["qid"])
    with (dst / "questions.jsonl").open("w") as f:
        for q in qs:
            f.write(json.dumps(q) + "\n")
    print(f"{len(lines)} exchanges, {len(qs)} questions", file=sys.stderr)


if __name__ == "__main__":
    main(*sys.argv[1:3])
