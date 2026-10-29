#!/usr/bin/env python3
"""Evaluation harness, not product: ship BEAM's vectors without its text, so setup loads them instead of embedding 7,339 pieces (Sirsh, 26 Oct).

    python3 harness/vectors.py <dsn of a stack that embedded the sample> samples/beam

Reads every piece's vector from a stack whose worker embedded samples/beam's texts.jsonl (as harness/beam_fetch.py
writes it) with bge-small-en-v1.5 -- the model a reader's stack runs -- and writes vectors.jsonl: one line per piece,
{uri, piece, sha256 of its text, vector_f32 (base64 little-endian float32)}. beam_fetch.py gives a downloaded piece
its vector only when the sha256 matches. Refuses if any piece is missing a vector, or if a stored piece's text is
not the file's: a vector must be of the very text it ships with.
"""
import asyncio
import base64
import hashlib
import json
import struct
import sys
from pathlib import Path

MODEL = "bge-small-en-v1.5"


async def main(dsn, sample):
    import asyncpg
    path = Path(sample) / "texts.jsonl"
    lines = [json.loads(l) for l in path.open()]
    conn = await asyncpg.connect(dsn)
    space = await conn.fetchval("select format('aiq.%I', aiq.embedding_space_name($1))", MODEL)
    rows = await conn.fetch(
        f"""select r.uri, k.ordinal, k.content, e.embedding::real[] as v
              from content.resources r join content.resource_chunks k on k.resource_id = r.id
              left join {space} e on e.chunk_id = k.id
             where r.uri = any($1::text[])""", [t["uri"] for t in lines])
    got = {(r["uri"], r["ordinal"]): r for r in rows}
    out = []
    for t in lines:
        for i, c in enumerate(t["chunks"]):
            r = got.get((t["uri"], i))
            if r is None or r["v"] is None:
                sys.exit(f"{t['uri']} chunk {i}: no vector on that stack")
            if r["content"] != c["content"]:
                sys.exit(f"{t['uri']} chunk {i}: the stored text is not the file's")
            out.append({"uri": t["uri"], "piece": i, "sha256": hashlib.sha256(c["content"].encode()).hexdigest(),
                        "vector_f32": base64.b64encode(struct.pack(f"<{len(r['v'])}f", *r["v"])).decode()})
    with (Path(sample) / "vectors.jsonl").open("w") as f:
        f.writelines(json.dumps(v) + "\n" for v in out)
    print(f"{len(out)} vectors written into {Path(sample) / 'vectors.jsonl'}", file=sys.stderr)


if __name__ == "__main__":
    asyncio.run(main(*sys.argv[1:3]))
