"""A user's handle on the query tool: what an agent runtime would send, from a shell.

    ASK_URL=http://127.0.0.1:5701 ASK_SESSION=u1 ASK_TOKEN=<jwt> python ask.py describe
    ... python ask.py query '<p8ql>' [--question "what I am trying to find out"]

`describe` prints the tool's description and arguments as the model would read
them. `query` calls it with the session header a runtime sends to a bound
origin (X-P8-Session-Id), so the server's query log can pair each query with the
next one. It prints exactly what came back -- the envelope and, when the server
shows them, the exceptions -- with each row's text cut to `--chars` (4,000 by
default: run 2's 500 hid date headings in every arm), the same cut in every arm.
"""
from __future__ import annotations

import argparse
import json
import os
import urllib.request


def call(method: str, params: dict) -> dict:
    headers = {"Content-Type": "application/json",
               "X-P8-Session-Id": os.environ.get("ASK_SESSION", "anon"),
               "X-P8-Run-Id": os.environ.get("ASK_SESSION", "anon")}
    if os.environ.get("ASK_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['ASK_TOKEN']}"
    req = urllib.request.Request(os.environ["ASK_URL"], method="POST", headers=headers,
                                 data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                                                  "params": params}).encode())
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())


def main() -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("describe")
    q = sub.add_parser("query")
    q.add_argument("query")
    q.add_argument("--question")
    q.add_argument("--chars", type=int, default=4000)
    a = ap.parse_args()
    if a.cmd == "describe":
        [tool] = call("tools/list", {})["result"]["tools"]
        print(tool["description"])
        print("\nARGUMENTS:", json.dumps(tool["inputSchema"]["properties"], indent=1))
        return
    args = {"query": a.query}
    if a.question:
        args["question"] = a.question
    res = call("tools/call", {"name": "query", "arguments": args})
    if "error" in res:
        print("ERROR", json.dumps(res["error"]))
        return
    out = res["result"]
    texts = [c.get("text", "") for c in out.get("content", [])]
    if out.get("isError"):
        print("TOOL ERROR")
        print("\n".join(texts))
        return
    doc = json.loads(texts[0])
    for row in doc.get("rows") or []:
        if isinstance(row, dict) and isinstance(row.get("content"), str) and len(row["content"]) > a.chars:
            row["content"] = row["content"][:a.chars] + " [...]"
    doc.pop("semantic_exceptions", None)   # shown below as the prompt the model reads
    print(json.dumps(doc, indent=1, ensure_ascii=False))
    for t in texts[1:]:
        print("\n" + t)


if __name__ == "__main__":
    main()
