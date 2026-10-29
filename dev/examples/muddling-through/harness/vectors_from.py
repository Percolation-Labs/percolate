#!/usr/bin/env python3
"""Evaluation harness, not product: export the vectors a stack already made for some BEAM conversations, in the form
beam_fetch.py matches pieces against (vectors.jsonl), so loading them elsewhere needs no embedding (REM-1245).

    python3 harness/vectors_from.py postgres://p8:p8@localhost:5841/percolate beam-1m2 beam-1m4 > cal-vectors.jsonl

One line per piece: its document's uri, its place among the document's pieces, the sha256 of the exact text the stack
embedded, and the vector as little-endian float32 in base64. beam_fetch.py uses a vector only where its sha256 is the
sha256 of the piece it cuts, so a piece whose text differs is never given another text's vector. Read in one read-only
transaction: nothing is written to the source.
"""
import base64
import hashlib
import json
import struct
import subprocess
import sys

QUERY = """
begin read only;
copy (
  select r.uri, c.ordinal, c.content, e.embedding::text
    from content.resources r
    join content.channels ch on ch.id = r.channel_id
    join content.resource_chunks c on c.resource_id = r.id
    join aiq."emb_bge_small_en_v1.5" e on e.chunk_id = c.id
   where ch.name = any(string_to_array(:'channels', ','))
   order by r.uri, c.ordinal
) to stdout with (format csv);
commit;
"""


def main(dsn, channels):
    import csv
    import io
    out = subprocess.run(["psql", dsn, "-q", "-v", f"channels={','.join(channels)}"], input=QUERY,
                         capture_output=True, text=True, check=True).stdout
    n = 0
    for uri, ordinal, content, emb in csv.reader(io.StringIO(out)):
        floats = [float(x) for x in emb.strip("[]").split(",")]
        print(json.dumps({"uri": uri, "piece": int(ordinal),
                          "sha256": hashlib.sha256(content.encode()).hexdigest(),
                          "vector_f32": base64.b64encode(struct.pack(f"<{len(floats)}f", *floats)).decode()}))
        n += 1
    print(f"{n} pieces from {len(channels)} channel(s)", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2:])
