#!/usr/bin/env python3
"""Each question as a stored text, so SQL can find a question by uri.

    python3 build/questions.py <sample dir>

Reads <sample dir>/questions.jsonl and writes <sample dir>/question-texts.jsonl for the sample's texts step: one
document per question in the channel walk-questions, uri question:<qid>, whose metadata holds {qid, question,
channel, ...}. The answer key is not stored: build/labels.py reads it from questions.jsonl and a block passes it to
aiq.walk_coverage or aiq.walk_why. A walk starts with the question's {id, text} and nothing else (REM-1231).
"""
import json
import sys
from pathlib import Path


def main(sample):
    sample = Path(sample)
    with (sample / "question-texts.jsonl").open("w") as f:
        for q in map(json.loads, open(sample / "questions.jsonl")):
            md = {k: q[k] for k in ("qid", "question", "channel", "phrasing", "type", "named") if k in q}
            # The walk's contract names a question {id, text}; walk-0's questions have no words, so their text is the id.
            md.update(id=q["qid"], text=q.get("question") or q["qid"])
            f.write(json.dumps({"channel": "walk-questions", "external_id": f"question:{q['qid']}",
                                "title": q.get("question") or q["qid"], "uri": f"question:{q['qid']}",
                                "chunks": [{"content": q.get("question") or q["qid"]}], "metadata": md}) + "\n")


if __name__ == "__main__":
    main(sys.argv[1])
