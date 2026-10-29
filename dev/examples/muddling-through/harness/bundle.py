#!/usr/bin/env python3
"""Evaluation harness, not product: build the 'try it first' bundle a reader fetches after installing Percolate (REM-1246).

    python3 harness/bundle.py samples/beam OUT [--text shipped|fetch] [--walks walks.json --dsn DSN]

samples/beam must already hold what harness/beam_fetch.py writes (texts.jsonl, questions.jsonl). OUT/beam-walks/ is
then a directory `percolate sample load` reads:

  manifest.yaml, sources.yaml   the two BEAM conversations' channels
  texts.jsonl                   --text shipped: one exchange per line, each piece with its vector (BEAM's text, CC BY-SA)
  fetch/                        --text fetch: beam_fetch.py and vectors.jsonl instead; the reader downloads BEAM's text
  question-texts.jsonl          each question by its words; no evidence, answer or rubric (REM-1231)
  oracle/<qid>.json, all.json   the answer key, for oracle mode only: {question, labelled, items}. Never loaded: the
                                Walks screen passes a file to aiq.walk_structure beside a run
  walks/                        a second sample: Jev's verdicts for each shipped walk (replays.jsonl, exported with
                                aiq.walk_verdicts) and start.sql, which starts each walk offline from them at $0
  README.md, LICENSE, SHA256SUMS

--walks names the runs to ship, [{"run": uuid, "label": "stack walk"}], read from --dsn read-only. The walks are built
last, on the V0 rules (bill, 29 Oct); without --walks the bundle has no walks/ yet.
"""
import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
KEY = ("gold", "answer", "rubric")  # what a question carries that only evaluation may read
LICENCE_SOURCE = ("BEAM's dataset card, https://huggingface.co/datasets/Mohammadta/BEAM, README.md at revision "
                  "3205395e897e7318c7b094ef4e6047b9b82dbb03, line 73: 'license: cc-by-sa-4.0'")
CREDIT = ('Mohammad Tavakoli et al., "Beyond a Million Tokens: Benchmarking and Enhancing Long-Term Memory in LLMs", '
          "ICLR 2026. arXiv:2510.27246. Dataset: https://huggingface.co/datasets/Mohammadta/BEAM")


def jsonl(path):
    return [json.loads(line) for line in Path(path).open() if line.strip()]


def write_jsonl(path, rows):
    with Path(path).open("w") as f:
        f.writelines(json.dumps(r) + "\n" for r in rows)


def question_texts(questions):
    """Each question by its words, as `percolate sample load` registers it. Nothing of the answer key goes in."""
    out = []
    for q in questions:
        md = dict({k: v for k, v in q.items() if k not in KEY}, id=q["qid"], text=q["question"])
        out.append({"channel": "walk-questions", "external_id": f"question:{q['qid']}", "title": q["question"],
                    "uri": f"question:{q['qid']}", "chunks": [{"content": q["question"]}], "metadata": md})
    return out


def oracle_files(questions, items_by_qid, out):
    """One file per question, and all.json with every one: {question, labelled, items}. Oracle mode only."""
    out.mkdir(parents=True, exist_ok=True)
    entries = []
    for q in questions:
        e = {"qid": q["qid"], "question": q["question"], "labelled": q["gold"],
             "items": items_by_qid.get(q["qid"]) or None,
             "oracle": "BEAM's answer key for this question, never shown to the walk"}
        entries.append(e)
        (out / (q["qid"].replace(":", "_") + ".json")).write_text(json.dumps(e, indent=1))
    (out / "all.json").write_text(json.dumps({"oracle": True, "questions": entries}, indent=1))
    return len(entries)


def psql(dsn, sql):
    r = subprocess.run(["psql", dsn, "-X", "-At", "-v", "ON_ERROR_STOP=1", "-c", sql], capture_output=True, text=True,
                       env={"PGOPTIONS": "-c default_transaction_read_only=on", "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"})
    if r.returncode:
        sys.exit(f"psql: {r.stderr.strip()}")
    return r.stdout.strip()


def export_walks(dsn, walks, out):
    """Jev's verdicts for each run, as replay documents, and the SQL that starts each walk offline from them."""
    out.mkdir(parents=True, exist_ok=True)
    replays, starts, graphs = [], [], set()
    for i, w in enumerate(walks):
        run = w["run"]
        inp = json.loads(psql(dsn, f"select input from workflow.runs where id = '{run}'"))
        doc = json.loads(psql(dsn, f"select aiq.walk_verdicts('{run}'::uuid)"))
        q = inp["question"]["text"]
        uri = f"replay:bundle:{i + 1}"
        replays.append({"channel": "walk-replays", "external_id": uri, "title": f"{w['label']}: {q}", "uri": uri,
                        "chunks": [{"content": json.dumps(doc)}], "metadata": {"label": w["label"], "from_run": run}})
        settings = inp.get("settings") or {}
        graphs.add((inp["channel"], json.dumps(settings, sort_keys=True)))
        starts.append(
            "select workflow.start_workflow('walk', jsonb_build_object(\n"
            "  'question', jsonb_build_object('node_id', n.id, 'text', r.title),\n"
            f"  'channel', {sql_text(inp['channel'])}, 'offline', true,\n"
            f"  'replay', (select id from content.resources where uri = {sql_text(uri)}),\n"
            f"  'settings', {sql_text(json.dumps(settings))}::jsonb))\n"
            "  from content.resources r join aiq.nodes n on n.entity_type = 'document' and n.entity_id = r.id\n"
            f" where r.uri like 'question:%' and r.title = {sql_text(q)};")
    write_jsonl(out / "replays.jsonl", replays)
    # A graph is kept per channel and settings; build each walk's first, as the setup block does, or the walk builds
    # it inside its own step and can hit the statement timeout.
    index = [f"select aiq.walk_index(jsonb_build_object('channel', {sql_text(c)}, 'settings', {sql_text(st)}::jsonb))->>'uri';"
             for c, st in sorted(graphs)]
    (out / "start.sql").write_text(
        "-- Starts each shipped walk offline, from the verdicts Jev gave it (replays.jsonl): no model key, $0.\n"
        "select aiq.install_walk_workflow();\n" + "\n".join(index) + "\n\n" + "\n\n".join(starts) + "\n")
    (out / "manifest.yaml").write_text(
        "name: beam-walks-walks\nversion: 1.0.0\ndescription: The shipped walks, replayed offline from Jev's recorded verdicts.\n"
        "load:\n  - texts: replays.jsonl\n  - sql: start.sql\n")
    return len(replays)


def sql_text(s):
    return "'" + str(s).replace("'", "''") + "'"


def main():
    a = argparse.ArgumentParser()
    a.add_argument("sample"); a.add_argument("out")
    a.add_argument("--text", choices=("shipped", "fetch"), default="shipped")
    a.add_argument("--walks"); a.add_argument("--dsn")
    args = a.parse_args()
    sample, root = Path(args.sample), Path(args.out) / "beam-walks"
    if not (sample / "questions.jsonl").exists() or (args.text == "shipped" and not (sample / "texts.jsonl").exists()):
        sys.exit(f"{sample}: run harness/beam_fetch.py {sample} first")
    if root.exists():
        shutil.rmtree(root)
    root.mkdir(parents=True)
    questions = jsonl(sample / "questions.jsonl")
    shutil.copy(sample / "sources.yaml", root / "sources.yaml")
    load = ["  - sources: sources.yaml"]
    if args.text == "shipped":
        shutil.copy(sample / "texts.jsonl", root / "texts.jsonl")
        load.append("  - texts: texts.jsonl")
    else:
        (root / "fetch").mkdir()
        shutil.copy(HERE / "beam_fetch.py", root / "fetch" / "beam_fetch.py")
        shutil.copy(sample / "vectors.jsonl", root / "fetch" / "vectors.jsonl")
        load.append("  - texts: texts.jsonl   # written by: python3 fetch/beam_fetch.py .")
    write_jsonl(root / "question-texts.jsonl", question_texts(questions))
    load.append("  - texts: question-texts.jsonl")
    (root / "manifest.yaml").write_text(
        "name: beam-walks\nversion: 1.0.0\n"
        "description: |-\n  Two BEAM conversations, 1M:22 (1,101 exchanges) and 1M:35 (1,058), and their 36 questions without their\n"
        f"  answers. Licence CC BY-SA 4.0, as stated in {LICENCE_SOURCE}.\n"
        "load:\n" + "\n".join(load) + "\n")
    items = json.loads((HERE / "answer-items.json").read_text())
    n_oracle = oracle_files(questions, items, root / "oracle")
    n_walks = export_walks(args.dsn, json.loads(Path(args.walks).read_text()), root / "walks") if args.walks else 0
    (root / "LICENSE").write_text(
        "The data in this directory is derived from BEAM and is licensed CC BY-SA 4.0:\n"
        "https://creativecommons.org/licenses/by-sa/4.0/legalcode\n\n"
        f"Where BEAM states it: {LICENCE_SOURCE}.\n\n{CREDIT}\n\n"
        "Changes from the original: the two conversations are cut into exchanges (a user turn and the replies after it),\n"
        "BEAM's '->-> n,m' plan index is removed from every piece, and each question's evidence, reference answer and\n"
        "rubric are kept apart from the question, in oracle/. The vectors and the recorded verdicts are ours.\n")
    (root / "README.md").write_text(README.format(walks=n_walks, oracle=n_oracle,
                                                  text=("shipped" if args.text == "shipped" else "fetched")))
    sums = []
    for p in sorted(root.rglob("*")):
        if p.is_file() and p.name != "SHA256SUMS":
            sums.append(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(root)}")
    (root / "SHA256SUMS").write_text("\n".join(sums) + "\n")
    size = sum(p.stat().st_size for p in root.rglob("*") if p.is_file())
    print(f"{root}: {len(questions)} questions, {n_oracle} oracle files, {n_walks} walks, text {args.text}, "
          f"{size / 1e6:.1f} MB")


README = """# Try it first: two BEAM conversations, and walks across them

After installing Percolate:

    percolate sample load beam-walks                    # the conversations ({text}) and the questions, without answers
    percolate walk index --source beam-1m22             # the walk graph, about a minute each
    percolate walk index --source beam-1m35
    percolate sample load beam-walks/walks              # {walks} walk(s), replayed offline from Jev's verdicts: no key, $0

Then open Percolate's UI, Walks. A walk starts from a question's words alone. Oracle mode is the benchmark's answer
key, which no walk ever sees: in a walk, open 'oracle' and choose oracle/all.json ({oracle} questions), or the file for
that question in oracle/. The screen passes it to aiq.walk_structure beside the run; nothing of it is loaded.

Data: BEAM (CC BY-SA 4.0; see LICENSE for where BEAM states it, the credit and our changes). Check the files against
SHA256SUMS.
"""

if __name__ == "__main__":
    main()
