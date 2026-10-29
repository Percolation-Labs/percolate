#!/usr/bin/env python3
"""Evaluation harness, not product: replay documents as `texts` lines, one per question, in a channel of their own
that nothing embeds.

    python3 harness/replays.py <sample dir> <channel>

Reads <sample dir>/replay/*.json (one verdict document per question, {model, task, verdicts: {qid: {key: P}}}) and
<sample dir>/questions.jsonl, and writes <sample dir>/replays.jsonl. Each document holds one question's verdicts as
a flat map, {model, task, verdicts: {key: P}}, which is what a walk started with {"replay": <the document's id>}
reads back as its chunks joined in order (REM-1199 §2.4, REM-1232). Its title is the question's own words, so a
step finds the recorded verdicts for a question by its text, as it finds the question. The uri replay:<qid> is only
the loader's address. The text is cut into pieces of at most 200,000 characters, at any character, because a piece
is storage here and is never embedded or searched.
"""
import json
import sys
from pathlib import Path

PIECE = 200_000


def main(sample, channel):
    sample = Path(sample)
    words = {q["qid"]: q.get("question") or q["qid"] for q in map(json.loads, open(sample / "questions.jsonl"))}
    with (sample / "replays.jsonl").open("w") as f:
        for p in sorted((sample / "replay").glob("*.json")):
            doc = json.loads(p.read_text())
            (qid, verdicts), = doc["verdicts"].items()
            text = json.dumps({**doc, "verdicts": verdicts})
            f.write(json.dumps({
                "channel": channel, "external_id": f"replay:{qid}", "title": words[qid],
                "uri": f"replay:{qid}",
                "chunks": [{"content": text[i:i + PIECE]} for i in range(0, len(text), PIECE)],
                "metadata": {"replay_of": qid}}) + "\n")


if __name__ == "__main__":
    main(*sys.argv[1:3])
