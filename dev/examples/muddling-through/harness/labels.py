#!/usr/bin/env python3
"""The benchmark's answer key, for the evaluation functions: harness, not product (REM-1231).

    python3 harness/labels.py <questions.jsonl>... <qid>                one question's evidence, as a Postgres text[]
    python3 harness/labels.py <questions.jsonl>... [--where field=value] {qid: [evidence]} as JSON

A walk never carries its answer key and the database never holds it: a block reads it from the sample's own
questions file and passes it to aiq.walk_coverage(run, nodes, budgets) or aiq.walk_why(run, nodes) as a psql
variable, e.g.

    psql -v labelled="$(python3 harness/labels.py samples/beam/questions.jsonl 1M:35:event_ordering:0)" \\
         -c "select * from aiq.walk_coverage(:'run', :'labelled', array[50, 100, 500])"
"""
import json
import sys


def main(*args):
    files = [a for a in args if a.endswith(".jsonl")]
    args = args[len(files):]
    qs = [json.loads(line) for path in files for line in open(path) if line.strip()]
    if args and not args[0].startswith("--"):
        (q,) = [q for q in qs if q["qid"] == args[0]]
        # every key is a plain document key (beam:1M:35/12, walk-0/d12501), so no element needs quoting
        print("{" + ",".join(q["gold"]) + "}")
        return
    if args:
        field, value = args[1].split("=", 1)
        qs = [q for q in qs if str(q.get(field)) == value]
    print(json.dumps({q["qid"]: q["gold"] for q in qs}))


if __name__ == "__main__":
    main(*sys.argv[1:])
