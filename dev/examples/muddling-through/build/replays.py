#!/usr/bin/env python3
"""Replay documents as `texts` lines, one per question, in a channel of their own that nothing embeds.

    python3 build/replays.py <sample dir> <channel>

Reads <sample dir>/replay/*.json (one verdict document per question) and writes <sample dir>/replays.jsonl. A run
started with {"replay": "<uri>"} reads the document back as its chunks joined in order (REM-1199 §2.4). The uri is
replay:<qid>. The text is cut into pieces of at most 200,000 characters, at any character, because a piece is
storage here and is never embedded or searched.
"""
import json
import sys
from pathlib import Path

PIECE = 200_000


def main(sample, channel):
    sample = Path(sample)
    with (sample / "replays.jsonl").open("w") as f:
        for p in sorted((sample / "replay").glob("*.json")):
            text = p.read_text()
            qid = next(iter(json.loads(text)["verdicts"]))
            f.write(json.dumps({
                "channel": channel, "external_id": f"replay:{qid}", "title": f"verdicts for {qid}",
                "uri": f"replay:{qid}",
                "chunks": [{"content": text[i:i + PIECE]} for i in range(0, len(text), PIECE)],
                "metadata": {"replay_of": qid}}) + "\n")


if __name__ == "__main__":
    main(*sys.argv[1:3])
