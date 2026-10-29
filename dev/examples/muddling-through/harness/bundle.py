#!/usr/bin/env python3
"""Evaluation harness, not product: build the 'try it first' bundle a reader fetches after installing Percolate (REM-1246).

    python3 harness/bundle.py SAMPLE OUT --name walks-starter [--text shipped|fetch]
        [--runs runs.jsonl --dsn DSN [--questions q1,q2,...] [--rule "how the questions were chosen"]]

SAMPLE must already hold what harness/beam_fetch.py writes for the conversations the walks need (texts.jsonl,
questions.jsonl, sources.yaml, manifest.yaml). OUT/NAME/ is then a directory `percolate sample load` reads:

  manifest.yaml, sources.yaml   one channel per BEAM conversation the walks need
  texts.jsonl                   --text shipped: one exchange per line, each piece with its vector (BEAM's text, CC BY-SA)
  fetch/                        --text fetch: beam_fetch.py and vectors.jsonl instead; the reader downloads BEAM's text
  question-texts.jsonl          each question by its words; no evidence, answer or rubric (REM-1231)
  oracle/<qid>.json, all.json   the answer key, for oracle mode only: {question, labelled, items}. Never loaded: the
                                Walks screen passes a file to aiq.walk_structure beside a run
  walks/                        a second sample: Jev's verdicts for each shipped walk (replays.jsonl, exported with
                                aiq.walk_verdicts) and start.sql, which starts each walk offline from them at $0
  README.md, LICENSE, SHA256SUMS

--runs is a walk list as the pilot writes it, one {qid, arm, run} a line (arm P: V0's walk, the question stack off,
as V0 ships; arm S: the same walk with the question stack on, measured in the pilot and not V0's default), read from
--dsn read-only; --questions keeps only those qids, and --rule says in CONTENTS.json how they
were chosen. The walks are built last, on the V0 rules (bill, 29 Oct); without --runs the bundle has no walks/.
"""
import argparse
import hashlib
import json
import re
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
    (out / "README.md").write_text(
        "# The answer keys\n\n"
        "Each file here is a benchmark question's answer key: the messages BEAM cites as its evidence, and where BEAM's\n"
        "rubric lists them, the items its answer needs. No walk ever sees them. Nothing in this bundle loads them into\n"
        "the database: `percolate sample load` and the walks' start script leave this directory alone, so a default load\n"
        "is keyless. They are read only when you ask for oracle mode on a walk in the Walks screen and choose a file here\n"
        "(all.json holds every question; the screen takes the entry for the walk's question). The screen passes it to\n"
        "aiq.walk_structure beside the run, and marks everything it adds as oracle-scored.\n")
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
    # The replays live in their own channel, which the conversations' sources do not declare.
    (out / "sources.yaml").write_text(
        "channels:\n  - name: walk-replays\n    kind: manual\n    visibility: public\n"
        "    config: {description: \"Jev's recorded verdicts for each shipped walk, one document a walk\"}\n")
    (out / "manifest.yaml").write_text(
        "name: beam-walks-walks\nversion: 1.0.0\ndescription: The shipped walks, replayed offline from Jev's recorded verdicts.\n"
        "load:\n  - sources: sources.yaml\n  - texts: replays.jsonl\n  - sql: start.sql\n")
    return len(replays)


def sql_text(s):
    return "'" + str(s).replace("'", "''") + "'"


def main():
    a = argparse.ArgumentParser()
    a.add_argument("sample"); a.add_argument("out")
    a.add_argument("--text", choices=("shipped", "fetch"), default="shipped")
    a.add_argument("--name", required=True)
    a.add_argument("--runs"); a.add_argument("--dsn"); a.add_argument("--questions"); a.add_argument("--rule", default="")
    args = a.parse_args()
    sample, root = Path(args.sample), Path(args.out) / args.name
    if not (sample / "questions.jsonl").exists() or (args.text == "shipped" and not (sample / "texts.jsonl").exists()):
        sys.exit(f"{sample}: run harness/beam_fetch.py {sample} first")
    if root.exists():
        shutil.rmtree(root)
    root.mkdir(parents=True)
    questions = jsonl(sample / "questions.jsonl")
    # With --questions, the bundle carries only the conversations those questions are about, and only their questions:
    # a starter is a few conversations, not the whole sample.
    keep_q = set(q.strip() for q in args.questions.split(",")) if args.questions else None
    keep_ch = {q["channel"] for q in questions if q["qid"] in keep_q} if keep_q else None
    if keep_ch is not None:
        questions = [q for q in questions if q["channel"] in keep_ch]
        src = (sample / "sources.yaml").read_text()
        blocks = re.split(r"(?m)^(?=  - name: )", src)
        (root / "sources.yaml").write_text("".join(b for b in blocks
            if not b.startswith("  - name: beam-") or b.split("\n", 1)[0].split("name:", 1)[1].strip() in keep_ch))
    else:
        shutil.copy(sample / "sources.yaml", root / "sources.yaml")
    load = ["  - sources: sources.yaml"]
    if args.text == "shipped":
        if keep_ch is None:
            shutil.copy(sample / "texts.jsonl", root / "texts.jsonl")
        else:
            with (sample / "texts.jsonl").open() as fin, (root / "texts.jsonl").open("w") as fout:
                fout.writelines(l for l in fin if json.loads(l)["channel"] in keep_ch)
        load.append("  - texts: texts.jsonl")
    else:
        (root / "fetch").mkdir()
        shutil.copy(HERE / "beam_fetch.py", root / "fetch" / "beam_fetch.py")
        shutil.copy(sample / "vectors.jsonl", root / "fetch" / "vectors.jsonl")
        load.append("  - texts: texts.jsonl   # written by: python3 fetch/beam_fetch.py .")
    write_jsonl(root / "question-texts.jsonl", question_texts(questions))
    load.append("  - texts: question-texts.jsonl")
    channels = [l.split("name:", 1)[1].strip() for l in (root / "sources.yaml").read_text().splitlines()
                if l.strip().startswith("- name: beam-")]
    convs = ", ".join(c.replace("beam-", "").upper().replace("M", "M:", 1) for c in channels)
    (root / "manifest.yaml").write_text(
        f"name: {args.name}\nversion: 1.0.0\n"
        f"description: |-\n  BEAM conversations {convs}, and their {len(questions)} questions without their answers.\n"
        f"  Licence CC BY-SA 4.0, as stated in {LICENCE_SOURCE}.\n"
        "load:\n" + "\n".join(load) + "\n")
    items = json.loads((HERE / "answer-items.json").read_text())
    n_oracle = oracle_files(questions, items, root / "oracle")
    # V0 ships with the question stack off: the pilot's registered rule found S-P at 100 reads of -1.1 [-3.1, +0.2],
    # wholly below its +5 bar (bill, 29 Oct 17:33Z). The stack walk ships beside it as measured, not as the default.
    ARMS = {"P": "V0 walk (question stack off, V0's default)", "S": "walk with the question stack on (measured; not V0's default)"}
    keep = keep_q
    walks = [{"run": r["run"], "label": ARMS.get(r.get("arm"), r.get("arm") or "walk"), "qid": r["qid"], "arm": r.get("arm")}
             for r in jsonl(args.runs) if keep is None or r["qid"] in keep] if args.runs else []
    if keep is not None and args.runs and {w["qid"] for w in walks} != keep:
        sys.exit(f"--questions names qids with no run: {sorted(keep - {w['qid'] for w in walks})}")
    n_walks = export_walks(args.dsn, walks, root / "walks") if walks else 0
    (root / "CONTENTS.json").write_text(json.dumps({
        "name": args.name, "conversations": channels, "questions": len(questions),
        "rule": args.rule or None, "text": args.text,
        "rerun": {
            "replay": "percolate sample load NAME/walks starts every listed walk offline from the verdicts Jev gave it, "
                      "recorded in walks/replays.jsonl: no model key, no cost, and the same reads, the same stack and the "
                      "same result as the original run. In the Walks screen, Start a walk with 'Replay' does the same for one "
                      "question.",
            "live": "With your own Jev key bound to the deployment, Start a walk with 'Live' (aiq.walk_launch(question, "
                    "'live')) walks any question afresh: new verdicts, so the reads can differ from the original, and its "
                    "spend is in the walk's Spend panel (walk_structure's cost part)."},
        "walks": [{"qid": w["qid"], "arm": w["arm"], "what": w["label"], "from_run": w["run"]} for w in walks],
        "arms": ARMS, "oracle": "oracle/ holds each question's answer key; it is never loaded"}, indent=1))
    (root / "LICENSE").write_text(
        "The data in this directory is derived from BEAM and is licensed CC BY-SA 4.0:\n"
        "https://creativecommons.org/licenses/by-sa/4.0/legalcode\n\n"
        f"Where BEAM states it: {LICENCE_SOURCE}.\n\n{CREDIT}\n\n"
        "Changes from the original: the conversations are cut into exchanges (a user turn and the replies after it),\n"
        "BEAM's '->-> n,m' plan index is removed from every piece, and each question's evidence, reference answer and\n"
        "rubric are kept apart from the question, in oracle/. The vectors and the recorded verdicts are ours.\n")
    (root / "README.md").write_text(README.format(name=args.name, walks=n_walks, oracle=n_oracle,
                                                  text=("shipped" if args.text == "shipped" else "fetched"),
                                                  index="\n".join(f"    percolate walk index --source {c}" for c in channels)))
    sums = []
    for p in sorted(root.rglob("*")):
        if p.is_file() and p.name != "SHA256SUMS":
            sums.append(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(root)}")
    (root / "SHA256SUMS").write_text("\n".join(sums) + "\n")
    size = sum(p.stat().st_size for p in root.rglob("*") if p.is_file())
    print(f"{root}: {len(channels)} conversations, {len(questions)} questions, {n_oracle} oracle files, {n_walks} walks, text {args.text}, "
          f"{size / 1e6:.1f} MB")


README = """# {name}: BEAM conversations, and walks across them

After installing Percolate:

    percolate sample load {name}                        # the conversations ({text}) and the questions, without answers
{index}
    percolate sample load {name}/walks                  # {walks} walk(s), replayed offline from Jev's verdicts: no key, $0

The walk index builds each conversation's walk graph, about a minute each. CONTENTS.json lists the walks: for each
question, V0's walk (the question stack off, as V0 ships) and the same walk with the question stack on beside it, which
the pilot measured and V0 did not adopt, and how the questions were chosen.

Rerunning a walk means one of two things, and they differ:
- Replay (the walks step above, or 'Replay' under Start a walk): from Jev's recorded verdicts, offline, no key, no
  cost. It reproduces the original run: the same reads, stack and result.
- Live ('Live' under Start a walk, with your own Jev key bound to the deployment): new verdicts, so the reads can
  differ. Its spend is in the walk's Spend panel.

Then open Percolate's UI, Walks. A walk starts from a question's words alone. Oracle mode is the benchmark's answer
key, which no walk ever sees: in a walk, open 'oracle' and choose oracle/all.json ({oracle} questions), or the file for
that question in oracle/. The screen passes it to aiq.walk_structure beside the run; nothing of it is loaded.

Data: BEAM (CC BY-SA 4.0; see LICENSE for where BEAM states it, the credit and our changes). Check the files against
SHA256SUMS.
"""

if __name__ == "__main__":
    main()
