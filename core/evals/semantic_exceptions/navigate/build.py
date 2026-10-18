"""Build the Dracula store the navigation test searches.

    python build.py --entries <path to entries.jsonl>

`entries.jsonl` is the iterative-query spike's segmentation of Gutenberg #345
(p8-subsystems meta/spikes/2026-10-17-iterative-query/segment.py): 241 dated
entries, each with its document and narrator. The text is not committed here,
as it is not there. This splits each entry into passages of about 200 words at
paragraph breaks, embeds them with bge-small-en-v1.5 (fastembed, local), and
writes store/passages.jsonl and store/vectors.npy.

A passage's `time` is its entry's date in 1893. An entry with no date of its
own (a heading, a cutting reprinted inside another) takes the date of the
entry before it, and says so in `dated`.
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
STORE = HERE / "store"
MODEL = "BAAI/bge-small-en-v1.5"
MONTHS = {m: i for i, m in enumerate(
    "January February March April May June July August September October November December".split(), 1)}


def date_of(recorded: str | None) -> str | None:
    if not recorded:
        return None
    m = re.match(r"([A-Z][a-z]+)\s+(\d{1,2})", recorded)
    if not m or m.group(1) not in MONTHS:
        return None
    return f"1893-{MONTHS[m.group(1)]:02d}-{int(m.group(2)):02d}"


def split(text: str, target: int = 200) -> list[str]:
    paras = [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]
    out, cur = [], []
    for p in paras:
        cur.append(p)
        if sum(len(x.split()) for x in cur) >= target:
            out.append("\n\n".join(cur))
            cur = []
    if cur:
        if out and sum(len(x.split()) for x in cur) < target // 3:
            out[-1] += "\n\n" + "\n\n".join(cur)
        else:
            out.append("\n\n".join(cur))
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--entries", required=True)
    a = ap.parse_args()
    entries = [json.loads(l) for l in open(a.entries)]
    passages, last = [], None
    for e in entries:
        d = date_of(e.get("recorded"))
        dated = "own" if d else "inherited"
        d = d or last
        last = d
        # A heading alone ("JONATHAN HARKER'S JOURNAL") is not a passage: in
        # use it outranked the entries it heads, with nothing to read.
        if len(e["text"].split()) < 15:
            continue
        parts = split(e["text"])
        for i, t in enumerate(parts):
            passages.append({
                "id": f"{e['id']}.{i + 1}", "entry": e["id"], "part": i + 1, "parts": len(parts),
                "chapter": e["chapter"], "document": e["document"], "source": e["narrator"],
                "time": d, "dated": dated, "heading": e.get("heading"), "content": t})
    from fastembed import TextEmbedding
    model = TextEmbedding(MODEL)
    vecs = np.array(list(model.embed([p["content"] for p in passages], batch_size=64)),
                    dtype=np.float32)
    vecs /= np.linalg.norm(vecs, axis=1, keepdims=True)
    STORE.mkdir(exist_ok=True)
    with open(STORE / "passages.jsonl", "w") as f:
        for p in passages:
            f.write(json.dumps(p, ensure_ascii=False) + "\n")
    np.save(STORE / "vectors.npy", vecs)
    print(f"{len(entries)} entries -> {len(passages)} passages, {vecs.shape[1]}-d")


if __name__ == "__main__":
    main()
