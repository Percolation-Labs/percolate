#!/usr/bin/env python3
"""Evaluation harness, not product: download BEAM from its public release and cut the walkthrough's two conversations from it (Sirsh, 28 Oct).

    pip install pyarrow
    python3 harness/beam_fetch.py samples/beam
    python3 harness/beam_fetch.py samples/beam-cal --split 1M --conversations 2,4,5 --vectors exported.jsonl

With no options it cuts the walkthrough's two conversations, 1M:22 and 1M:35. --split picks BEAM's 100K, 500K, 1M or
10M release and --conversations any of its conversations (REM-1245: the calibration walks and the sweep need others);
each file is pinned by revision and sha256 below. --vectors adds files of vectors to match pieces against, as
vectors.jsonl is matched; a piece with no vector made from its exact text stops the fetch, as before.

A reader runs this: the sample ships no BEAM text, only the vectors the stack's own bge-small gave each piece. It
downloads BEAM's million-token split from Hugging Face (Mohammadta/BEAM, CC BY-SA 4.0, Tavakoli et al., arXiv
2510.27246) at a pinned revision, checks its sha256, and writes into the sample directory:

  texts.jsonl           one line per exchange of 1M:22 and 1M:35 for `percolate sample load`: a user turn and the
                        replies after it, in pieces of at most 2,000 characters cut at turn boundaries, with the
                        sitting, the place in the conversation and the date said. BEAM's trailing '->-> n,m' plan
                        index is removed from every piece and from `terms_text`, the user's words the walk tags. Each piece gets its
                        vector from vectors.jsonl only if the piece's sha256 is the one that vector was made from.
  questions.jsonl       the 36 questions on the two conversations, each with its evidence as document keys, and
                        BEAM's reference answer and rubric, which harness/examples.py sets the walk's reads against.
  question-texts.jsonl  each question stored by uri question:<qid>, so SQL finds it. Not its answer key: that stays
                        in questions.jsonl, which harness/labels.py hands to the evaluation functions (REM-1231).

These are the rules the walk study used on the same file, so the documents, keys and pieces are the study's.
"""
import base64
import hashlib
import io
import json
import re
import sys
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

REVISION = "3205395e897e7318c7b094ef4e6047b9b82dbb03"
# Each split's files at a pinned revision, with their sha256 (Hugging Face's LFS oid). 10M is its own dataset.
SPLITS = {
    "100K": ("Mohammadta/BEAM", REVISION, [("100K-00000-of-00001.parquet", "c0519be25907005ba873c927c50877471d550873039d96c041554d0075a78ace")]),
    "500K": ("Mohammadta/BEAM", REVISION, [("500K-00000-of-00001.parquet", "af05921c979355038e1761b7cde3d2dd713200dd3071b278de0200f6c7f30122")]),
    "1M": ("Mohammadta/BEAM", REVISION, [("1M-00000-of-00001.parquet", "41b5acbbb55a586b1305514ef9d9fb03365d9b3331b598a1c2dd7603d93ef533")]),
    "10M": ("Mohammadta/BEAM-10M", "9b2096193fe74e2837e4713e483351e19817773c",
            [("10M-00000-of-00002.parquet", "31d96fd47ec56221d202e68792f26c00e49467dd4b36ee105c36ebd19ef78ad5"),
             ("10M-00001-of-00002.parquet", "a4f13fe25af51d57405ae41008689c31d1421377f3efde56a024b441deb2ee65")]),
}
DEFAULT_SPLIT, DEFAULT_CONVERSATIONS = "1M", ("22", "35")
CHUNK = 2000
MARK = re.compile(r"\s*->->\s*\d+\s*,\s*(?:\d+|N/A)(?:\s*,\s*\d+)*\s*$")  # the same three forms, at a turn's end
# The same mark at the end of any line of a piece: BEAM's generator's (sitting, plan step), which a decider must
# never read, since plan step predicts which exchanges BEAM's questions cite (REM-1240).
# Every form BEAM writes, counted on 1M:22 and 1M:35: "n,m" (1,848), "n,N/A" (9) and "n,m, k" (1), always at a line end.
MARK_IN_PIECE = re.compile(r"[ \t]*->->[ \t]*\d+[ \t]*,[ \t]*(?:\d+|N/A)(?:[ \t]*,[ \t]*\d+)*[ \t]*(?=\n|$)")


SAID = 160  # characters of the user's words a document's title carries
KEY = ("gold", "answer", "rubric")  # what a question carries that only evaluation may read

def ints(x):
    """Every integer in BEAM's source_chat_ids, which nest lists and dicts."""
    if isinstance(x, int):
        return [x]
    if isinstance(x, dict):
        return [i for v in x.values() for i in ints(v)]
    if isinstance(x, (list, tuple)):
        return [i for v in x for i in ints(v)]
    return []


def chunks(turns):
    """Turns as 'role: content' lines, packed into pieces of at most 2,000 characters."""
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


def exchanges(sessions):
    """A user turn and the replies after it, each dated by its sitting's anchor plus a second per exchange."""
    pairs, pair_of = [], {}
    anchor = next((m["time_anchor"] for s in sessions for m in s if m["time_anchor"]), None)
    for si, session in enumerate(sessions):
        for m in session:
            anchor = m["time_anchor"] or anchor
            if m["role"] == "user" or not pairs or pairs[-1]["session"] != si:
                pairs.append({"session": si, "anchor": anchor, "turns": []})
            pairs[-1]["turns"].append({"role": m["role"], "content": m["content"]})
            pair_of[m["id"]] = len(pairs) - 1
    for i, p in enumerate(pairs):
        day = datetime.strptime(p["anchor"], "%B-%d-%Y").replace(tzinfo=timezone.utc) if p["anchor"] else None
        p["said_at"] = (day + timedelta(seconds=i)).isoformat() if day else None
    return pairs, pair_of


def fetch(split):
    """The split's rows, every file checked against its pinned sha256."""
    import pyarrow.parquet as pq
    dataset, revision, files = SPLITS[split]
    rows = []
    for name, sha in files:
        url = f"https://huggingface.co/datasets/{dataset}/resolve/{revision}/data/{name}"
        with urllib.request.urlopen(url) as r:
            data = r.read()
        if hashlib.sha256(data).hexdigest() != sha:
            sys.exit(f"{url}: sha256 is not {sha}; the release changed under this revision")
        rows += pq.read_table(io.BytesIO(data)).to_pylist()
    return rows


def main(sample, split=DEFAULT_SPLIT, conversations=DEFAULT_CONVERSATIONS, extra_vectors=()):
    import ast
    sample = Path(sample)
    if split not in SPLITS:
        sys.exit(f"--split is one of {', '.join(SPLITS)}, not {split}")
    runs = {c: f"beam-{split.lower()}{c}" for c in conversations}
    vectors = {}
    for f in [sample / "vectors.jsonl", *map(Path, extra_vectors)]:
        if f.exists():
            for v in map(json.loads, f.open()):
                vectors[(v["uri"], v["piece"])] = v
    texts, qs, matched, pieces = [], [], 0, 0
    found = set()
    for row in fetch(split):
        conv = str(row["conversation_id"])
        if conv not in runs:
            continue
        found.add(conv)
        run, channel = f"{split}:{conv}", runs[conv]
        pairs, pair_of = exchanges(row["chat"])
        for i, p in enumerate(pairs):
            uri = f"beam:{run}/{i}"
            cs = []
            for n, c in enumerate(chunks(p["turns"])):
                # The piece keeps its boundaries and loses the plan index; its vector is still matched by the text the
                # study embedded, mark included, so the vectors are the study's. Search's keyword half reads the
                # stripped text, so search's order moves a little (james's run from empty, 40dfbed1).
                piece, v = {"content": MARK_IN_PIECE.sub("", c)}, vectors.get((uri, n))
                pieces += 1
                if v and v["sha256"] == hashlib.sha256(c.encode()).hexdigest():
                    piece["vector_f32"] = v["vector_f32"]
                    matched += 1
                cs.append(piece)
            user = "\n".join(MARK.sub("", t["content"]) for t in p["turns"] if t["role"] == "user")
            # The title is the document node's summary, so a step shows what was said by reading the node (REM-1233).
            said = " ".join(user.split())
            said = said if len(said) <= SAID else said[:SAID - 1].rstrip() + "…"
            texts.append({"channel": channel, "external_id": f"{run}/{i}", "title": f"BEAM {run}, exchange {i}: {said}",
                          "uri": uri, "chunks": cs,
                          "metadata": {"sitting": p["session"], "position": i, "said_at": p["said_at"],
                                       "terms_text": user}})
        for qtype, items in ast.literal_eval(row["probing_questions"]).items():
            for n, q in enumerate(items):
                gold = sorted({pair_of[i] for i in ints(q.get("source_chat_ids")) if i in pair_of})
                if gold:
                    # BEAM's reference answer and rubric ride with the answer key, for harness/examples.py: like
                    # the key, they stay in this file and never enter the database (questions.py does not copy them).
                    rubric = q.get("rubric")
                    qs.append({"qid": f"{run}:{qtype}:{n}", "channel": channel, "type": qtype,
                               "question": q["question"], "gold": [f"beam:{run}/{g}" for g in gold],
                               "answer": q.get("answer") or q.get("ideal_response") or q.get("ideal_answer") or "",
                               "rubric": ast.literal_eval(rubric) if isinstance(rubric, str) else rubric or []})
    if found != set(runs):
        sys.exit(f"BEAM {split} has no conversation {', '.join(sorted(set(runs) - found))}")
    if matched == pieces:
        for t in texts:
            t["model"] = "bge-small-en-v1.5"
    else:
        # a piece without its vector is embedded by the stack's worker; the sample's channels name no workflow,
        # so stop here rather than load text nothing will embed
        sys.exit(f"{pieces - matched} of {pieces} pieces differ from the text vectors.jsonl was made from")
    texts.sort(key=lambda t: (t["channel"], t["metadata"]["position"]))
    qs.sort(key=lambda q: q["qid"])
    with (sample / "texts.jsonl").open("w") as f:
        f.writelines(json.dumps(t) + "\n" for t in texts)
    with (sample / "questions.jsonl").open("w") as f:
        f.writelines(json.dumps(q) + "\n" for q in qs)
    with (sample / "question-texts.jsonl").open("w") as f:
        for q in qs:
            # The question goes into the database by its words alone: its evidence, BEAM's reference answer and its
            # rubric are the answer key, which stays in questions.jsonl for the evaluation functions (REM-1231).
            md = dict({k: v for k, v in q.items() if k not in KEY}, id=q["qid"], text=q["question"])
            f.write(json.dumps({"channel": "walk-questions", "external_id": f"question:{q['qid']}",
                                "title": q["question"], "uri": f"question:{q['qid']}",
                                "chunks": [{"content": q["question"]}], "metadata": md}) + "\n")
    if not (sample / "manifest.yaml").exists():
        write_manifest(sample, split, runs, len(texts), len(qs))
    print(f"BEAM {split} at {SPLITS[split][1][:12]}, sha256 checked: {len(texts)} exchanges in {len(runs)} "
          f"conversation(s), {pieces} pieces, {matched} with their vectors, {len(qs)} questions")


def write_manifest(sample, split, runs, exchanges, questions):
    """A sample directory with no manifest gets one, and its sources: one channel per conversation (a person's memory;
    terms are fitted per channel), the walk-questions channel, and the walk study's embedding model. The walkthrough's
    own sample keeps the manifest it ships."""
    dataset, revision, _ = SPLITS[split]
    channels = "".join(f"""  - name: {ch}
    kind: manual
    visibility: public
    config: {{description: "BEAM {split}:{conv}, one document per exchange"}}
""" for conv, ch in sorted(runs.items(), key=lambda kv: int(kv[0])))
    (sample / "sources.yaml").write_text(f"""# Written by harness/beam_fetch.py for BEAM {split}, conversations {", ".join(sorted(runs, key=int))}.
embedding_models:
  - name: bge-small-en-v1.5
    dim: 384
    provider: fastembed
    endpoint: BAAI/bge-small-en-v1.5
    credential_ref: null
    is_default: true
channels:
{channels}  - name: walk-questions
    kind: manual
    visibility: public
    config: {{description: "the walk's questions, one document each, by their words alone"}}
""")
    (sample / "manifest.yaml").write_text(f"""# Written by harness/beam_fetch.py: BEAM {split} at {dataset}@{revision[:12]}, {len(runs)} conversation(s).
name: beam-{split.lower()}-{len(runs)}
version: 1.0.0
description: |-
  BEAM {split} conversations {", ".join(sorted(runs, key=int))} ({exchanges} exchanges), with their {questions} questions.
  CC BY-SA 4.0, from Tavakoli et al., "Beyond a Million Tokens", ICLR 2026 (arXiv 2510.27246).
load:
  - sources: sources.yaml
  - texts: texts.jsonl
  - texts: question-texts.jsonl
""")


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("sample")
    ap.add_argument("--split", default=DEFAULT_SPLIT)
    ap.add_argument("--conversations", default=",".join(DEFAULT_CONVERSATIONS))
    ap.add_argument("--vectors", nargs="*", default=())
    a = ap.parse_args()
    main(a.sample, a.split, tuple(c.strip() for c in a.conversations.split(",") if c.strip()), a.vectors)
