"""The walk's clue links are derived from the text alone, the same way every time (REM-1201).

`percolate walk index` writes what these functions return. The postings were
checked equal to the walk study's TermTagger(max_zipf=99) on BEAM 1M:22 (1,742
terms over 1,101 documents); these pin the rules that equality rests on, so a
change to one of them fails here rather than in a walk that quietly reads
different clues.

WHAT WOULD MAKE IT FAIL. Let a stopword into a run, drop the recurrence or
width cap, keep a nested term, iterate a set unsorted, or link a document to
itself; ignore a strategy's limits, run a strategy nobody named, or lose which
strategy made a tag.
"""
import asyncio
import unittest
from unittest import mock

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
        texts = ["ladder"] * (T.DF_FLOOR + 1) + ["drill"] * 2
        self.assertEqual(T.fit(texts), {"drill": [T.DF_FLOOR + 1, T.DF_FLOOR + 2]})

    def test_the_cap_is_a_parameter(self):
        texts = ["ladder"] * 21 + ["drill"] * 2
        self.assertEqual(T.fit(texts, df_floor=20), {"drill": [21, 22]})
        self.assertIn("ladder", T.fit(texts, df_floor=21))

    def test_a_shorter_term_inside_a_longer_one_gives_way(self):
        self.assertEqual(T.fit(["step ladder", "step ladder"]), {"step ladder": [0, 1]})

    def test_the_order_does_not_depend_on_the_hash_seed(self):
        out = T.fit(["zebra apple", "zebra", "apple"])
        self.assertEqual(list(out), ["apple", "zebra"])


class Layers(unittest.TestCase):
    """The tagger is layered: strategies by name, each under its own limits, and every tag says who made it."""

    def test_frequency_alone_is_fit(self):
        texts = ["step ladder", "step ladder", "drill"]
        self.assertEqual(T.tag(texts), {"step ladder": {"docs": [0, 1], "by": ["frequency"]}})

    def test_an_unknown_strategy_is_refused(self):
        with self.assertRaises(ValueError):
            T.tag(["a"], ("frequency", "guess"))

    def test_one_strategy_may_be_a_string(self):
        self.assertEqual(T.strategies_from("frequency"), ("frequency",))
        self.assertEqual(T.strategies_from(["frequency", "entities"]), ("frequency", "entities"))
        self.assertEqual(T.strategies_from(None), ("frequency",))

    def test_frequency_alone_names_no_spacy(self):
        self.assertIsNone(T.provenance(("frequency",)))

    def test_a_tag_two_strategies_find_names_both(self):
        saved = dict(T.STRATEGIES)
        try:
            T.STRATEGIES["other"] = lambda texts, **kw: {"step ladder": [1, 2], "rope": [0, 2]}
            out = T.tag(["step ladder", "step ladder", "rope step ladder"], ("frequency", "other"))
        finally:
            T.STRATEGIES.clear()
            T.STRATEGIES.update(saved)
        self.assertEqual(out["step ladder"], {"docs": [0, 1, 2], "by": ["frequency", "other"]})
        self.assertEqual(out["rope"], {"docs": [0, 2], "by": ["other"]})

    def test_a_union_is_held_to_the_widest_cap_that_found_it(self):
        saved = dict(T.STRATEGIES)
        try:
            T.STRATEGIES["a"] = lambda texts, **kw: {"x": [0, 1]}
            T.STRATEGIES["b"] = lambda texts, **kw: {"x": [2, 3]}
            lim = {"a": {"df_floor": 3, "df_share": 0.0}, "b": {"df_floor": 3, "df_share": 0.0}}
            self.assertEqual(T.tag(["t"] * 4, ("a", "b"), lim), {})
            lim["b"]["df_floor"] = 4
            self.assertEqual(T.tag(["t"] * 4, ("a", "b"), lim)["x"]["docs"], [0, 1, 2, 3])
        finally:
            T.STRATEGIES.clear()
            T.STRATEGIES.update(saved)

    def test_each_strategy_reads_its_own_limits(self):
        lim = T.limits_from({"min_df": 3, "df_floor": 50, "entity_df_floor": 100, "phrase_df_share": 0.05,
                             "entity_labels": ["PERSON"], "spacy_model": "m"})
        self.assertEqual(lim["frequency"], {"min_df": 3, "df_floor": 50})
        self.assertEqual(lim["entities"], {"min_df": 3, "df_floor": 100, "labels": ["PERSON"], "model": "m"})
        self.assertEqual(T.limits_from({"spacy_chars": 10})["phrases"], {"chars": 10})
        self.assertEqual(lim["phrases"], {"min_df": 3, "df_share": 0.05, "model": "m"})

    def test_the_limits_reach_the_strategy(self):
        texts = ["ladder"] * 21
        self.assertEqual(T.tag(texts, limits=T.limits_from({"df_floor": 20})), {})
        self.assertIn("ladder", T.tag(texts, limits=T.limits_from({"df_floor": 21})))


class Spacy(unittest.TestCase):
    """The spaCy strategies, where spaCy and its model are installed (percolate-core[tags])."""

    def setUp(self):
        try:
            T._nlp(T.SPACY_MODEL)
        except (RuntimeError, OSError) as e:
            self.skipTest(f"spaCy or {T.SPACY_MODEL} is not installed: {e}")

    def test_the_report_names_spacy_and_the_model(self):
        made = T.provenance(("frequency", "entities"))
        self.assertTrue(made["spacy"])
        self.assertTrue(made["models"][T.SPACY_MODEL])

    def test_a_recurring_name_is_an_entity_however_common(self):
        # The label is the model's (the small model calls a lone "Rebecca" a place as often as a person), so the
        # default labels are kept: the strategy promises an entity, not its kind.
        texts = [f"Rebecca checked my form on day {i}." for i in range(30)] + ["I rested."]
        self.assertIn("rebecca", T.entities(texts, df_floor=100))
        self.assertNotIn("rebecca", T.fit(texts, df_floor=20))

    def test_a_phrase_loses_its_stopwords(self):
        out = T.phrases(["My vertical jump got better.", "The vertical jump is 20 inches now."])
        self.assertIn("vertical jump", out)


class Edges(unittest.TestCase):
    def test_two_documents_sharing_terms_get_one_edge_each_way(self):
        e = I.term_edges(docs("ladder budget", "ladder budget", "drill"))
        self.assertEqual(set(e), {("n0", "n1"), ("n1", "n0")})
        self.assertEqual([t["term"] for t in e[("n0", "n1")]["terms"]], ["ladder budget"])
        self.assertEqual(e[("n0", "n1")]["terms"][0]["n"], 2)
        self.assertEqual(e[("n0", "n1")]["terms"][0]["by"], ["frequency"])

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



class KeepGraph(unittest.TestCase):
    """The index keeps the channel's graph as a document, so a walk can pin it (percolate#316)."""

    class Conn:
        def __init__(self, has_walk_index):
            self.has, self.calls = has_walk_index, []

        async def fetchval(self, sql, *args):
            self.calls.append((sql, args))
            if "to_regprocedure" in sql:
                return self.has
            return "walk-graph:abc:def"

    def test_the_graph_is_kept_after_the_links(self):
        c = self.Conn(True)
        self.assertEqual(asyncio.run(I.keep_graph(c, "beam-1m22")), "walk-graph:abc:def")
        self.assertIn("aiq.walk_index", c.calls[-1][0])
        self.assertEqual(c.calls[-1][1], ("beam-1m22",))

    def test_a_failing_keep_leaves_the_index_written(self):
        class Failing(self.Conn):
            async def fetchval(self, sql, *args):
                if "select aiq.walk_index(" in sql:
                    raise RuntimeError("no channel named walk-graphs")
                return await super().fetchval(sql, *args)
        self.assertIsNone(asyncio.run(I.keep_graph(Failing(True), "beam-1m22")))

    def test_a_database_without_walk_index_keeps_nothing(self):
        c = self.Conn(False)
        self.assertIsNone(asyncio.run(I.keep_graph(c, "beam-1m22")))
        self.assertEqual(len(c.calls), 1)

    def test_index_keeps_the_graph_after_the_links_commit(self):
        events = []

        class Conn(self.Conn):
            def transaction(self):
                class T:
                    async def __aenter__(self_):
                        events.append("begin")

                    async def __aexit__(self_, *exc):
                        events.append("commit")
                return T()

            async def execute(self, sql, *args):
                pass

            async def fetchval(self, sql, *args):
                if "select aiq.walk_index(" in sql:
                    events.append("walk_index")
                return await super().fetchval(sql, *args)

        async def write(conn, relation, edges, nodes):
            events.append(relation)
            return {}

        async def no_params(conn):
            return {}

        async def docs(conn, channel):
            return [{"node": "n0", "resource": "r0", "text": "", "metadata": {}}]

        async def no_nearest(conn, docs, k):
            return {}

        with mock.patch.multiple(I, parameters=no_params, documents=docs, nearest_edges=no_nearest, write=write):
            report = asyncio.run(I.index(Conn(True), "beam-1m22"))
        self.assertEqual(report["graph"], "walk-graph:abc:def")
        self.assertEqual(events, ["begin", "walk_term", "walk_next", "walk_nearest", "commit", "walk_index"])

if __name__ == "__main__":
    unittest.main()
