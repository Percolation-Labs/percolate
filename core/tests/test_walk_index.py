"""The walk's clue links are derived from the text alone, the same way every time (REM-1201).

`percolate walk index` writes what these functions return. The postings were
checked equal to the walk study's TermTagger(max_zipf=99) on BEAM 1M:22 (1,742
terms over 1,101 documents); these pin the rules that equality rests on, so a
change to one of them fails here rather than in a walk that quietly reads
different clues.

WHAT WOULD MAKE IT FAIL. Let a stopword into a run, drop the recurrence or
width cap, keep a nested term, iterate a set unsorted, or link a document to
itself.
"""
import unittest

from percolate_core.walk import index as I
from percolate_core.walk import terms as T


def docs(*texts, meta=None):
    return [{"node": f"n{i}", "resource": f"r{i}", "text": t, "metadata": (meta or {}).get(i, {})}
            for i, t in enumerate(texts)]


class Terms(unittest.TestCase):
    def test_a_run_stops_at_a_stopword_and_a_sentence(self):
        self.assertEqual(T.candidates("Ladder rental. The ladder"), {"ladder rental", "ladder", "rental"})

    def test_a_token_keeps_its_dots_and_dashes(self):
        self.assertIn("node.js", T.candidates("I use node.js daily"))
        self.assertIn("gpt-4", T.candidates("gpt-4 is here"))

    def test_a_term_needs_two_documents(self):
        self.assertEqual(T.fit(["ladder", "drill"]), {})

    def test_a_term_wider_than_the_cap_is_dropped(self):
        texts = ["ladder"] * 21 + ["drill"] * 2
        self.assertEqual(T.fit(texts), {"drill": [21, 22]})

    def test_a_shorter_term_inside_a_longer_one_gives_way(self):
        self.assertEqual(T.fit(["step ladder", "step ladder"]), {"step ladder": [0, 1]})

    def test_the_order_does_not_depend_on_the_hash_seed(self):
        out = T.fit(["zebra apple", "zebra", "apple"])
        self.assertEqual(list(out), ["apple", "zebra"])


class Edges(unittest.TestCase):
    def test_two_documents_sharing_terms_get_one_edge_each_way(self):
        e = I.term_edges(docs("ladder budget", "ladder budget", "drill"))
        self.assertEqual(set(e), {("n0", "n1"), ("n1", "n0")})
        self.assertEqual([t["term"] for t in e[("n0", "n1")]["terms"]], ["ladder budget"])
        self.assertEqual(e[("n0", "n1")]["terms"][0]["n"], 2)

    def test_no_document_is_linked_to_itself(self):
        e = I.term_edges(docs("ladder", "ladder", "ladder"))
        self.assertTrue(all(a != b for a, b in e))
        self.assertEqual(len(e), 6)

    def test_the_fit_cap_comes_from_the_caller(self):
        three = docs("ladder", "ladder", "ladder")
        self.assertEqual(I.term_edges(three, df_floor=2, df_share=0.0), {})
        self.assertEqual(len(I.term_edges(three, df_floor=3, df_share=0.0)), 6)

    def test_next_follows_position_within_a_sitting(self):
        meta = {0: {"sitting": 1, "position": 2}, 1: {"sitting": 1, "position": 1},
                2: {"sitting": 2, "position": 1}, 3: {}}
        e = I.next_edges(docs("a", "b", "c", "d", meta=meta))
        self.assertEqual(e, {("n1", "n0"): {"sitting": "1", "pos": 1}})


if __name__ == "__main__":
    unittest.main()
