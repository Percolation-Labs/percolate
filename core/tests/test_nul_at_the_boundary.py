"""A NUL in text this runtime did not compose does not abort the write (REM-146).

Postgres `text` cannot hold U+0000, and both writes that carry a foreign string
hand Postgres a jsonb argument the SQL side reads back with `->>`. So one NUL
anywhere in the payload aborts the whole statement, and the work is already
done by then: on 2026-09-12 the live petstore demo API served a NUL inside a
pet's name and the turn finished `failed` after twenty-three seconds of model
and tool work, reported to the caller as a bare 502 with a duration on it. A
777-byte markdown upload with one NUL in it did the same to ingestion -- task
terminal, three tasks after it cancelled, zero chunks written.

These assert the substitution rather than the absence of an exception, because
"it did not raise" is also what silently dropping the character looks like, and
a chunk that lost a character without saying so no longer lines up with the
`start_offset` it carries back into its source.
"""
import asyncio
import json
import pathlib
import unittest

from percolate_core.core import without_nul


class WithoutNul(unittest.TestCase):
    def test_a_nul_in_a_string_becomes_the_replacement_character(self):
        self.assertEqual(without_nul("a\x00b"), "a�b")

    def test_the_string_keeps_its_length(self):
        """Deletion would shift every offset after it and say nothing."""
        self.assertEqual(len(without_nul("a\x00b")), 3)

    def test_a_string_with_no_nul_is_returned_unchanged(self):
        for value in ("", "plain", "é中�", "a\\u0000b"):
            self.assertEqual(without_nul(value), value)

    def test_it_reaches_into_a_tool_call_payload(self):
        """The agent path's shape: the NUL is never at the top level."""
        payload = [{
            "role": "assistant",
            "content": "Here they are.",
            "tool_calls": [{"tool_name": "findPetsByStatus",
                            "content": {"pets": [{"name": "doggie\x00"}]}}],
        }]
        cleaned = without_nul(payload)
        self.assertEqual(
            cleaned[0]["tool_calls"][0]["content"]["pets"][0]["name"], "doggie�")
        self.assertEqual(cleaned[0]["content"], "Here they are.")

    def test_it_reaches_into_an_ingest_outcome(self):
        """The ingestion path's shape: document text, one level down a list."""
        outcome = {"mode": "text", "parser": "markdown",
                   "chunks": [{"content": "step two ->\x00<-", "start_offset": 0}]}
        cleaned = without_nul(outcome)
        self.assertEqual(cleaned["chunks"][0]["content"], "step two ->�<-")
        self.assertEqual(cleaned["chunks"][0]["start_offset"], 0)

    def test_non_strings_survive_as_themselves(self):
        """Offsets, counts and nulls are not text and must not become text."""
        self.assertEqual(without_nul({"n": 3, "ok": True, "x": None, "f": 1.5}),
                         {"n": 3, "ok": True, "x": None, "f": 1.5})

    def test_a_key_carrying_a_nul_is_cleaned_too(self):
        self.assertEqual(without_nul({"a\x00": "b"}), {"a�": "b"})


PACKAGE = pathlib.Path(__file__).resolve().parent.parent / "percolate_core"


class EveryJsonbArgumentUsesIt(unittest.TestCase):
    """The rule lives in the pool's jsonb encoder, so it covers every write.

    It was first applied at two call sites -- `append_messages` and the ingest
    text path -- and three more writes carried a foreign string into a jsonb
    argument without it: an http_call response on its way to `complete_task`,
    an API source's page to `commit_api_page`, and a tool server's catalogue to
    `upsert_tool_server`. A rule per call site is a rule the next call site
    does not know about, so the assertions here are about the one place every
    jsonb argument passes, and about the ways a write could avoid it.
    """

    def installed_codecs(self):
        from percolate_core.core.identity import _init_connection

        class Conn:
            codecs = {}

            async def set_type_codec(self, typ, *, encoder, decoder, schema):
                self.codecs[typ] = encoder

        conn = Conn()
        asyncio.run(_init_connection(conn))
        return conn.codecs

    def assertStorable(self, encoded, expected):
        """What Postgres's jsonb input rejects is the escape `\\u0000`, so that
        is what must be absent -- and the replacement present, because a
        dropped character would pass the first check too."""
        self.assertNotIn("\\u0000", encoded)
        self.assertIn(expected, json.dumps(json.loads(encoded), ensure_ascii=False))

    def test_the_pool_encodes_jsonb_through_the_rule(self):
        from percolate_core.core.identity import jsonb_text

        self.assertIs(self.installed_codecs()["jsonb"], jsonb_text)

    def test_an_http_call_response_reaches_complete_task_storable(self):
        """What worker/loop.py binds: `{status, result}` from a third party."""
        encoded = self.installed_codecs()["jsonb"](
            {"status": 200, "result": {"items": [{"title": "Q3\x00report"}]}})
        self.assertStorable(encoded, "Q3�report")

    def test_an_api_source_row_reaches_commit_api_page_storable(self):
        """What ingest/api.py binds: the raw record and its mapped fields."""
        row = {"id": 7, "name": "acme\x00", "tags\x00": ["a"]}
        encoded = self.installed_codecs()["jsonb"](
            [{"external_id": "7", "watermark": None, "raw": row, "data": {"name": row["name"]}}])
        self.assertStorable(encoded, "acme�")
        self.assertStorable(encoded, "tags�")

    def test_a_tool_catalogue_reaches_upsert_tool_server_storable(self):
        encoded = self.installed_codecs()["jsonb"](
            {"name": "petstore", "cached_tools": [{"name": "find", "description": "pets\x00"}]})
        self.assertStorable(encoded, "pets�")

    def test_the_size_check_before_complete_task_uses_the_same_text(self):
        """`$1::text::jsonb` bypasses the codec, so it has to call the rule
        itself -- or a NUL aborts the measurement before completion is tried."""
        from percolate_core.worker.artifacts import stored_size

        class Conn:
            async def fetchval(self, sql, text):
                self.text = text
                return len(text)

        conn = Conn()
        asyncio.run(stored_size(conn, {"status": 200, "result": "a\x00b"}))
        self.assertStorable(conn.text, "a�b")

    def test_nothing_opens_a_connection_the_encoder_is_not_on(self):
        """Full recall for the pooled path: one `create_pool`, with the init.

        The two bare `asyncpg.connect` calls are named, with why each binds no
        foreign jsonb: the NOTIFY listener only listens, and the CLI loads the
        samples and bootstrap this repository wrote.
        """
        pools, connects = [], []
        for path in PACKAGE.rglob("*.py"):
            text = path.read_text()
            rel = path.relative_to(PACKAGE).as_posix()
            pools += [rel] * text.count("create_pool(")
            connects += [rel] * text.count("asyncpg.connect(")
        self.assertEqual(pools, ["core/identity.py"])
        self.assertIn("init=kwargs.pop(\"init\", _init_connection)",
                      (PACKAGE / "core/identity.py").read_text())
        self.assertEqual(sorted(connects), ["agentic/db/client.py", "core/cli.py"])

    def test_every_codec_bypassing_cast_uses_the_rule(self):
        """`::text::jsonb` pins the parameter to text; each one must say
        `jsonb_text(` on the same line or it is a sixth path."""
        found = []
        for path in PACKAGE.rglob("*.py"):
            for line in path.read_text().splitlines():
                if "::text::jsonb" in line and ("fetch" in line or "execute" in line):
                    found.append((path.name, "jsonb_text(" in line))
        self.assertTrue(found)
        self.assertEqual([f for f in found if not f[1]], [])


if __name__ == "__main__":
    unittest.main()
