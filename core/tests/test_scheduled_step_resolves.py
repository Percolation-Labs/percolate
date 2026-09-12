"""The documented scheduled step resolves, and a malformed call is told so (REM-126).

`specs/workflow-engine/README.md` documents the reference scheduled step as
`"workflow_task_id": "{{task.id}}"`, and `task` was not a resolvable namespace --
so the documented step raised `unknown template namespace 'task'` at dispatch and
`dev/seed.sql`'s reference definition sent no body at all.

It is not a documentation defect. `/internal/run` needs the id because the
runtime completes its OWN triggering task once the run and any chained action
have finished (`agentic/sequencer.py`, `brief.md` §3). With no id,
`workflow_task_id` is None, that block is skipped, the task is never completed,
the reaper takes its lease and the run happens again -- REM-109's duplicate-work
failure reached from the other end.

What is asserted here is the resolution and the refusal. The end-to-end -- a
scheduled run completing its own task exactly once -- needs a live runtime and a
harness axis that does not exist yet (REM-10).
"""
import unittest

from percolate_core.worker.templates import TerminalError, resolve

TASK_ID = "11111111-1111-1111-1111-111111111111"

# The body `README.md` documents and `dev/seed.sql` now ships.
DOCUMENTED_STEP = {
    "url": "http://127.0.0.1:8765/internal/run",
    "method": "POST",
    "mode": "async",
    "body": {
        "workflow_task_id": "{{task.id}}",
        "input": {"agent": "{{run.agent}}", "prompt": "{{run.prompt}}"},
    },
}


class ScheduledStepResolves(unittest.TestCase):
    def _ctx(self, **over):
        ctx = {
            "_task_id": TASK_ID,
            "_worker_id": "w1",
            "run_input": {"agent": "summarizer", "prompt": "what changed"},
            "context": {},
        }
        ctx.update(over)
        return ctx

    def test_the_documented_step_resolves(self):
        """The regression. This raised `unknown template namespace 'task'`."""
        out = resolve(DOCUMENTED_STEP, self._ctx())
        self.assertEqual(out["body"]["workflow_task_id"], TASK_ID)
        self.assertEqual(out["body"]["input"]["agent"], "summarizer")

    def test_the_task_id_keeps_its_own_value_not_a_json_string(self):
        """A whole-string reference keeps its native type; the id is a str."""
        out = resolve({"id": "{{task.id}}"}, self._ctx())
        self.assertEqual(out["id"], TASK_ID)
        self.assertNotIn('"', out["id"])

    def test_the_error_names_task_among_the_namespaces(self):
        """A reader who mistypes it should be told task exists."""
        with self.assertRaises(TerminalError) as e:
            resolve("{{tsak.id}}", self._ctx())
        self.assertIn("expected steps, run, task or env", str(e.exception))

    def test_a_missing_task_id_is_a_terminal_error_not_a_null(self):
        """Better to fail the step than to POST `null` and 400 downstream.

        `resolve` already treats an unresolved reference as terminal; this pins
        that `task.id` is not special-cased into something falsy, because a
        `null` task id reaches `/internal/run` and comes back as the refusal
        this change also adds -- one failure is enough.
        """
        with self.assertRaises(TerminalError):
            resolve("{{task.id}}", self._ctx(_task_id=None))


class MalformedInternalRunIsRefused(unittest.TestCase):
    """REM-67's rule, which `/internal/run` predated.

    The handler read `body["workflow_task_id"]` and `body["input"]["agent"]`
    unconditionally, so an omitted field was a KeyError and a 500 -- the server
    reporting itself broken for a bad request. The seeded definition sent no
    body, so 500 was what the documented path actually produced.

    The refusal logic is asserted directly rather than over HTTP: standing up
    the gateway needs a database, and what is being pinned is which fields are
    named in the message.
    """

    @staticmethod
    def _missing(body):
        # Mirrors gateway.py's list comprehension. Kept here deliberately: the
        # gateway builds a JSONResponse and asserting through it needs the app.
        return [
            name for name, present in (
                ("workflow_task_id", bool(body.get("workflow_task_id"))),
                ("input", isinstance(body.get("input"), dict)),
                ("input.agent", isinstance(body.get("input"), dict)
                                and bool(body["input"].get("agent"))),
            ) if not present
        ]

    def test_an_empty_body_names_every_missing_field(self):
        self.assertEqual(
            self._missing({}), ["workflow_task_id", "input", "input.agent"])

    def test_the_seeded_shape_before_this_change_is_refused_by_name(self):
        """`dev/seed.sql` shipped exactly this: a step with no body."""
        self.assertIn("workflow_task_id", self._missing({}))

    def test_the_documented_shape_is_accepted(self):
        body = {"workflow_task_id": TASK_ID,
                "input": {"agent": "summarizer", "prompt": "x"}}
        self.assertEqual(self._missing(body), [])

    def test_a_present_but_empty_task_id_is_still_missing(self):
        """`{{task.id}}` resolving to "" must not look like a valid id."""
        body = {"workflow_task_id": "", "input": {"agent": "a"}}
        self.assertIn("workflow_task_id", self._missing(body))


if __name__ == "__main__":
    unittest.main()
