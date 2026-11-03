"""QASPER's text, fetched and checked, written into the sample as one document per paragraph.

    python3 harness/qasper_fetch.py samples/qasper              # text and vectors (needs: pip install fastembed)
    python3 harness/qasper_fetch.py samples/qasper --no-vectors # text only; the stack then embeds it, slowly

QASPER (Dasigi et al. 2021, CC BY 4.0) is questions that NLP practitioners asked having read only a paper's title
and abstract, answered by other practitioners from the full text, who marked the paragraphs that hold the answer.
The sample carries none of its text. This downloads the train-dev release from AllenAI's bucket, checks its sha256,
and writes into the sample directory:

    texts.jsonl           every paragraph of the 281 development papers, abstract included, one document each, in
                          channel `qasper` (uri qasper:<paper>:<section>:<paragraph>, 'a' for the abstract);
    question-texts.jsonl  the sample's questions by their words alone, in channel `walk-questions`.

The whole development set is the corpus, though only 17 questions are asked of it: a paper's paragraphs compete
with 13,546 others, which is what buries an answer past search's first hundred. Fewer papers, and search finds it.

VECTORS. 13,547 paragraphs through the stack's embedding queue take hours by design (the queue is rate-limited so a
burst does not take every core). So by default this embeds them here, with the model the stack's worker runs
(BAAI/bge-small-en-v1.5 through fastembed, one chunk per paragraph: its title line and its text, unit length), and writes each vector beside its
text, so `percolate sample load` stores them in seconds. Pass --no-vectors to leave embedding to the stack.
"""
import base64
import hashlib
import io
import json
import struct
import sys
import tarfile
import urllib.request
from pathlib import Path

URL = "https://qasper-dataset.s3.us-west-2.amazonaws.com/qasper-train-dev-v0.3.tgz"
SHA256 = "a28fdf966db827bcee3d873107d6b6669864fb7ca8fbf73a192f5e39191bdb5a"
DEV = "qasper-dev-v0.3.json"
MODEL, DIM = "BAAI/bge-small-en-v1.5", 384


def fetch() -> dict:
    data = urllib.request.urlopen(URL, timeout=120).read()
    if hashlib.sha256(data).hexdigest() != SHA256:
        sys.exit(f"{URL}: sha256 is not {SHA256}; the release changed")
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as t:
        member = next(m for m in t.getmembers() if m.name.endswith(DEV))
        return json.load(t.extractfile(member))


def paragraphs(papers: dict) -> list[dict]:
    out = []
    for pid in sorted(papers):
        p = papers[pid]
        rows = [(f"qasper:{pid}:a", "Abstract", p["abstract"])]
        for si, sec in enumerate(p["full_text"]):
            for pi, para in enumerate(sec["paragraphs"]):
                rows.append((f"qasper:{pid}:{si}:{pi}", sec["section_name"] or "", para))
        for uri, section, text in rows:
            if text.strip():
                # the chunk is the title line, a blank line, then the paragraph: the text the lab's search ranks
                # (and so 'buried past 100') were measured on, so a reader's search ranks the same way
                title = f"{p['title']} | {section}"
                out.append({"channel": "qasper", "external_id": uri, "uri": uri,
                            "title": title, "chunks": [{"content": f"{title}\n\n{text}"}],
                            "metadata": {"paper": pid, "section": section}})
    return out


def embed(texts: list[dict]) -> None:
    from fastembed import TextEmbedding
    import numpy as np
    model = TextEmbedding(MODEL)
    vecs = model.embed([t["chunks"][0]["content"] for t in texts], batch_size=64)
    for t, v in zip(texts, vecs):
        v = np.asarray(v, dtype="float32")
        v = v / np.linalg.norm(v)
        assert v.shape == (DIM,)
        t["chunks"][0]["vector_f32"] = base64.b64encode(struct.pack(f"<{DIM}f", *v)).decode()
        t["model"] = "bge-small-en-v1.5"


def main(sample: str, *flags: str) -> int:
    sample = Path(sample)
    papers = fetch()
    texts = paragraphs(papers)
    have = {t["uri"] for t in texts}
    qs = [json.loads(l) for l in (sample / "questions.jsonl").open()]
    missing = [g for q in qs for g in q["gold"] if g not in have]
    if missing:
        sys.exit(f"{len(missing)} gold paragraphs are not in the release: {missing[:3]}")
    if "--no-vectors" not in flags:
        embed(texts)
    with (sample / "texts.jsonl").open("w") as f:
        f.writelines(json.dumps(t) + "\n" for t in texts)
    with (sample / "question-texts.jsonl").open("w") as f:
        for q in qs:
            # by its words alone: the gold paragraphs are the answer key and stay in questions.jsonl
            f.write(json.dumps({"channel": "walk-questions", "external_id": f"question:{q['qid']}",
                                "title": q["question"], "uri": f"question:{q['qid']}",
                                "chunks": [{"content": q["question"]}],
                                "metadata": {"id": q["qid"], "text": q["question"], "type": q["type"]}}) + "\n")
    print(f"QASPER dev, sha256 checked: {len(papers)} papers, {len(texts)} paragraphs"
          f"{'' if '--no-vectors' in flags else ', embedded here'}; {len(qs)} questions")
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
