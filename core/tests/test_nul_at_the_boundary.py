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


class TheCallSitesUseIt(unittest.TestCase):
    """Grep-shaped, because the rule is 'at the boundary' and there are two.

    A unit test of the helper proves nothing if a third write appears without
    it. These name the two seams so that moving one is visible here.
    """

    def test_append_messages_sanitises_its_payload(self):
        import inspect

        from percolate_core.agentic.db.repository import PgRepository

        src = inspect.getsource(PgRepository.append_messages)
        self.assertIn("without_nul(", src)
        self.assertIn("agentic.persist_turn", src)

    def test_the_ingest_text_path_sanitises_its_outcome(self):
        import inspect

        from percolate_core.ingest import handler

        src = inspect.getsource(handler)
        self.assertIn("without_nul(", src)
        self.assertIn("content.record_ingest", src)


if __name__ == "__main__":
    unittest.main()
