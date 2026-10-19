"""B1-mem0: Mem0 2.2.1 OSS on the fixture, three ways it can hold a changing fact.

  add     every fact added, nothing superseded (what infer=False gives you)
  expire  a superseded memory gets expiration_date = the day it was replaced;
          current questions search with show_expired=False
  update  memory.update(old, new text) -- Mem0's UPDATE event; the old text
          survives only in history()

No LLM runs: infer=False, and the LLM is replaced by one that raises.
Embeddings: fastembed BAAI/bge-small-en-v1.5, the same model Percolate gets.
Prints one JSON line per (mode, question) with the ranked fact ids.
"""
import json, shutil, sys, tempfile, os

os.environ.setdefault("OPENAI_API_KEY", "unused")
os.environ["MEM0_TELEMETRY"] = "False"
from mem0 import Memory

fixture = json.load(open(sys.argv[1]))
facts = {f["id"]: f for f in fixture["facts"]}
TOP = 10


def build(mode):
    path = tempfile.mkdtemp(prefix=f"mem0-{mode}-")
    m = Memory.from_config({
        "embedder": {"provider": "fastembed",
                     "config": {"model": "BAAI/bge-small-en-v1.5", "embedding_dims": 384}},
        "vector_store": {"provider": "qdrant",
                         "config": {"path": path, "collection_name": f"b1_{mode}",
                                    "embedding_model_dims": 384, "on_disk": True}},
        "history_db_path": os.path.join(path, "history.db"),
    })

    def refuse(*a, **k):
        raise RuntimeError("no LLM in this baseline")
    m.llm.generate_response = refuse

    mem_of, fact_of = {}, {}
    for f in sorted(fixture["facts"], key=lambda f: f["said_at"]):
        old = f["supersedes"]
        if mode == "update" and old:
            m.update(mem_of[old], text=f["text"])
            mem_of[f["id"]] = mem_of[old]
            fact_of[mem_of[old]] = f["id"]
            continue
        r = m.add([{"role": "user", "content": f["text"]}], user_id=f["user"],
                  agent_id=f["agent"], run_id=f["run"], infer=False,
                  # timestamp= raises "not supported by the OSS Memory SDK"
                  metadata={"fact": f["id"], "said_at": f["said_at"]})
        mid = r["results"][0]["id"]
        mem_of[f["id"]], fact_of[mid] = mid, f["id"]
        if mode == "expire" and old:
            m.update(mem_of[old], expiration_date=f["said_at"][:10])
    return m, fact_of, path


for mode in ("add", "expire", "update"):
    m, fact_of, path = build(mode)
    for q in fixture["questions"]:
        filters = {"user_id": q["user"]}
        if q.get("agent"):
            filters["agent_id"] = q["agent"]
        show_expired = mode == "expire" and q["kind"] in ("historical", "change")
        hits = m.search(q["ask"], filters=filters, top_k=TOP, threshold=0.0,
                        show_expired=show_expired)["results"]
        print(json.dumps({"system": f"mem0-{mode}", "q": q["id"],
                          "ranked": [fact_of.get(h["id"], "?") for h in hits]}))
    if mode == "update":
        # the history call, for the article: what Mem0 can say about a change
        mid = next(k for k, v in fact_of.items() if v == "f34")
        print(json.dumps({"history": m.history(mid)}, default=str), file=sys.stderr)
    shutil.rmtree(path, ignore_errors=True)
