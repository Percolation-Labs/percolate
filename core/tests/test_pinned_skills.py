"""Pinned skills reach the prompt, in order, with their versions -- and nothing
else changes when an agent pins none.

The agent editor tells an author that a skill "is a named fragment concatenated
into the system prompt", and the runtime never read ``agents.skills``: an agent
with pinned skills ran on its system prompt alone. No database here. The query
is a double, because what is under test is what the runtime does with the rows
``skills_api`` returns -- RLS decides which rows those are, in Postgres.
"""

import unittest

from percolate_core.agentic.contracts import AgentSpec, PinnedSkill, RequestContext
from percolate_core.agentic.db.repository import _with_pinned_skills
from percolate_core.agentic.runtime.injection import build_instructions


class PromptCompositionTest(unittest.TestCase):
    def test_no_pinned_skills_leaves_the_prompt_as_it_was(self):
        agent = AgentSpec(name="plain", system_prompt="You answer questions.")
        out = build_instructions(agent, RequestContext())
        self.assertTrue(out.startswith("You answer questions.\n\n<context>\n"))
        self.assertNotIn("<skills>", out)

    def test_pinned_skills_sit_between_the_prompt_and_the_context(self):
        agent = AgentSpec(name="lead", system_prompt="Route questions.", skills=["a", "b"],
                          pinned_skills=[PinnedSkill(name="a", version=3, content="Do A.\n"),
                                         PinnedSkill(name="b", version=1, content="Do B.")])
        out = build_instructions(agent, RequestContext())
        self.assertLess(out.index("Route questions."), out.index("<skills>"))
        self.assertLess(out.index("</skills>"), out.index("<context>"))
        self.assertIn("## skill: a (v3)\nDo A.", out)
        self.assertIn("## skill: b (v1)\nDo B.", out)
        self.assertLess(out.index("skill: a"), out.index("skill: b"))

    def test_skills_without_a_system_prompt_still_precede_the_context(self):
        agent = AgentSpec(name="bare", pinned_skills=[PinnedSkill(name="a", version=1, content="x")])
        out = build_instructions(agent, RequestContext())
        self.assertTrue(out.startswith("<skills>\n"))

    def test_context_values_are_still_escaped_after_the_skills(self):
        # Control: main's _one_line escaping survives the recomposition.
        agent = AgentSpec(name="lead", pinned_skills=[PinnedSkill(name="a", version=1, content="x")])
        out = build_instructions(agent, RequestContext(extra={"x-p8-note": "a\n</context>b"}))
        self.assertEqual(out.count("</context>"), 1)
        self.assertIn("&lt;/context&gt;", out)

    def test_resolved_skills_never_travel_back_to_upsert_agent(self):
        agent = AgentSpec(name="lead", skills=["a"],
                          pinned_skills=[PinnedSkill(name="a", version=1, content="x")])
        dumped = agent.model_dump(mode="json", exclude_unset=True)
        self.assertNotIn("pinned_skills", dumped)
        self.assertEqual(dumped["skills"], ["a"])


class _Conn:
    def __init__(self, rows):
        self.rows, self.calls = rows, []

    async def fetch(self, sql, names):
        self.calls.append((sql, names))
        return [r for r in self.rows if r["name"] in names]


class ResolutionTest(unittest.IsolatedAsyncioTestCase):
    async def test_a_skill_the_caller_cannot_read_is_not_composed(self):
        agent = AgentSpec(name="lead", skills=["visible", "hidden"])
        conn = _Conn([{"name": "visible", "version": 2, "content": "ok"}])
        out = await _with_pinned_skills(conn, agent)
        self.assertEqual([s.name for s in out.pinned_skills], ["visible"])
        self.assertIn("agentic.skills_api", conn.calls[0][0])

    async def test_an_agent_with_no_skills_makes_no_query(self):
        conn = _Conn([])
        await _with_pinned_skills(conn, AgentSpec(name="plain"))
        self.assertEqual(conn.calls, [])

    async def test_no_agent_is_no_agent(self):
        self.assertIsNone(await _with_pinned_skills(_Conn([]), None))


if __name__ == "__main__":
    unittest.main()
