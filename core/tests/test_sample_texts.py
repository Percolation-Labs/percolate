"""A sample can register text that is already in pieces, on a channel whose workflow embeds it (REM-1203).

`percolate sample load`'s `texts` step hands each JSON line to content.register_text with its chunks and metadata,
because a conversation whose unit is the exchange cannot go through POST /files: the chunker packs text to a token
budget and does not know where an exchange ends. These pin what reaches the database and what is refused before it.

WHAT WOULD MAKE IT FAIL. Drop `texts` from the step kinds, pass the chunks or metadata as a string of a string, lose
the metadata, or let a malformed line through to the database.
"""
import asyncio
import json
import tempfile
import unittest
from pathlib import Path

from percolate_core.core import samples


class Conn:
    def __init__(self, status="queued", embeds=True, dim=4, model=True):
        self.calls, self.status, self.embeds, self.dim, self.model = [], status, embeds, dim, model
        self.writes = []

    async def fetchval(self, sql, *args):
        if "content.channels" in sql:
            return self.embeds
        self.calls.append((sql, args))
        return json.dumps({"resource_id": "r", "status": self.status})

    async def fetchrow(self, sql, *args):
        return {"space": 'aiq."emb_m"', "dim": self.dim} if self.model else None

    async def execute(self, sql, *args):
        self.writes.append((sql, args))


def lines(*objs):
    d = Path(tempfile.mkdtemp())
    (d / "texts.jsonl").write_text("".join(json.dumps(o) + "\n" for o in objs))
    return d / "texts.jsonl"


LINE = {"channel": "beam-1m22", "external_id": "1M:22/73", "title": "exchange 73", "uri": "beam:1M:22/73",
        "chunks": [{"content": "user: a ladder"}], "metadata": {"sitting": 3, "position": 73}}


class Texts(unittest.TestCase):
    def test_texts_is_a_step_kind(self):
        d = Path(tempfile.mkdtemp())
        (d / "t.jsonl").write_text("")
        (d / "manifest.yaml").write_text("name: x\nload:\n  - texts: t.jsonl\n")
        self.assertEqual(samples.read_manifest(d)["load"], [{"texts": "t.jsonl"}])

    def test_each_line_reaches_register_text_with_its_pieces_and_metadata(self):
        conn = Conn()
        done, started = asyncio.run(samples.apply_texts(conn, lines(LINE)))
        sql, args = conn.calls[0]
        self.assertIn("content.register_text", sql)
        self.assertEqual(args[:2], ("beam-1m22", "1M:22/73"))
        self.assertEqual(json.loads(args[2]), LINE["chunks"])
        self.assertEqual(json.loads(args[6]), LINE["metadata"])
        self.assertEqual((started, done), (1, ["texts texts.jsonl: 1 queued"]))

    def test_an_unchanged_text_starts_nothing(self):
        done, started = asyncio.run(samples.apply_texts(Conn("unchanged"), lines(LINE, LINE)))
        self.assertEqual((started, done), (0, ["texts texts.jsonl: 2 unchanged"]))

    def test_text_on_a_channel_with_no_workflow_is_not_reported_as_embedding(self):
        done, started = asyncio.run(samples.apply_texts(Conn(embeds=False), lines(LINE)))
        self.assertEqual((started, done), (0, ["texts texts.jsonl: 1 queued"]))

    def test_a_shipped_vector_lands_in_its_models_space_by_ordinal(self):
        import base64, struct
        v = base64.b64encode(struct.pack("<4f", 0.5, -1.0, 0.25, 2.0)).decode()
        line = dict(LINE, model="m", chunks=[{"content": "a", "vector_f32": v}, {"content": "b"}])
        conn = Conn()
        asyncio.run(samples.apply_texts(conn, lines(line)))
        self.assertNotIn("vector_f32", conn.calls[0][1][2])  # the text goes in without it
        self.assertEqual(len(conn.writes), 1)
        sql, args = conn.writes[0]
        self.assertIn('aiq."emb_m"', sql)
        self.assertEqual(args, ("r", 0, "[0.5,-1.0,0.25,2.0]"))

    def test_a_vector_of_another_dimension_is_refused(self):
        import base64, struct
        v = base64.b64encode(struct.pack("<3f", 1, 2, 3)).decode()
        line = dict(LINE, model="m", chunks=[{"content": "a", "vector_f32": v}])
        with self.assertRaises(samples.SampleError):
            asyncio.run(samples.apply_texts(Conn(), lines(line)))

    def test_a_vector_from_an_unregistered_model_is_refused(self):
        import base64, struct
        v = base64.b64encode(struct.pack("<4f", 1, 2, 3, 4)).decode()
        line = dict(LINE, model="m", chunks=[{"content": "a", "vector_f32": v}])
        with self.assertRaises(samples.SampleError):
            asyncio.run(samples.apply_texts(Conn(model=False), lines(line)))

    def test_a_line_without_chunks_is_refused_before_the_database(self):
        conn = Conn()
        bad = {k: v for k, v in LINE.items() if k != "chunks"}
        with self.assertRaises(samples.SampleError):
            asyncio.run(samples.apply_texts(conn, lines(bad)))
        self.assertEqual(conn.calls, [])


if __name__ == "__main__":
    unittest.main()
