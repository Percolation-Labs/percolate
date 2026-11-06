"""What Mem0 2.2.1's open-source SDK does when asked when a memory held, for "Percolate for Mem0 folks".

Maya's two homes go in as the tutorial's do, with no LLM (infer=False) and the same fastembed model. Then the three
ways to say when: add(timestamp=), search(reference_date=), and history(), which is what is left.
"""
import os, shutil, tempfile

os.environ.setdefault("OPENAI_API_KEY", "unused")
os.environ["MEM0_TELEMETRY"] = "False"
from mem0 import Memory

path = tempfile.mkdtemp(prefix="mem0-time-")
m = Memory.from_config({
    "embedder": {"provider": "fastembed", "config": {"model": "BAAI/bge-small-en-v1.5", "embedding_dims": 384}},
    "vector_store": {"provider": "qdrant", "config": {"path": path, "collection_name": "maya",
                                                      "embedding_model_dims": 384, "on_disk": True}},
    "history_db_path": os.path.join(path, "history.db"),
})
home = m.add([{"role": "user", "content": "Maya lives in Leeds."}], user_id="maya", infer=False)["results"][0]["id"]
try:
    m.add([{"role": "user", "content": "Maya lives in Leeds."}], user_id="maya", infer=False,
          timestamp="2026-01-05T09:00:00Z")
except ValueError as e:
    print("add(timestamp=):", e)
try:
    m.search("where does Maya live", filters={"user_id": "maya"}, reference_date="2026-03-01")
except ValueError as e:
    print("search(reference_date=):", e)
m.update(home, text="Maya moved to Lisbon for a job at Harbour Health.")
for h in m.history(home):
    print("history:", h["event"], h["created_at"][:19], "->", h["updated_at"][:19], h["new_memory"])
shutil.rmtree(path)
