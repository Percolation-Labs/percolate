#!/usr/bin/env python3
"""Ship BEAM's vectors with its text, so setup loads them instead of embedding 7,339 chunks (Sirsh, 26 Oct).

    python3 build/vectors.py <dsn of a stack that embedded the sample> samples/beam

Reads every chunk's vector from a stack whose worker embedded samples/beam with bge-small-en-v1.5 -- the model a
reader's stack runs -- and writes them into texts.jsonl as `vector_f32` (base64 little-endian float32), with
`model` on each line. Refuses if any chunk of the file is missing a vector, or if a stored chunk's text is not the
file's: a vector must be of the very text it ships with.
"""
import asyncio
import base64
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
    for t in lines:
        for i, c in enumerate(t["chunks"]):
            r = got.get((t["uri"], i))
            if r is None or r["v"] is None:
                sys.exit(f"{t['uri']} chunk {i}: no vector on that stack")
            if r["content"] != c["content"]:
                sys.exit(f"{t['uri']} chunk {i}: the stored text is not the file's")
            c["vector_f32"] = base64.b64encode(struct.pack(f"<{len(r['v'])}f", *r["v"])).decode()
        t["model"] = MODEL
    with path.open("w") as f:
        for t in lines:
            f.write(json.dumps(t) + "\n")
    print(f"{sum(len(t['chunks']) for t in lines)} vectors written into {path}", file=sys.stderr)


if __name__ == "__main__":
    asyncio.run(main(*sys.argv[1:3]))
