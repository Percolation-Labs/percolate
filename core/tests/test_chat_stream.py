"""One session channel carries every run in a delegation tree, and chat keeps them apart.

Run: python -m unittest discover -s tests -p test_chat_stream.py

brief.md §4 puts a parent and every delegated child on ONE `agui_<session>`
channel, each event tagged with its own `run_id`. The chat screen appended every
TEXT_MESSAGE_CONTENT to whichever bubble was open last, so a turn to an agent
that delegated rendered as one bubble of two runs' tokens shuffled together --
"I don. 2't. **Port State Control Reports:** These contain have details" -- and a
child's failed RUN_FINISHED marked the whole turn failed while the parent was
still running. A turn marked failed was then never re-read, so the session panel
kept saying `RUNS 0` over a session with 52 runs.

§5.1 item 2 says how a child is shown: its streamed turn is "that call's
contents", nested under the delegation, not text in the parent's answer. The
state that decides all of that is in `chat-stream.js`, which imports nothing, so
node checks it here with no DOM and no runtime.
"""
import json
import shutil
import subprocess
import unittest
from pathlib import Path

STATIC = Path(__file__).resolve().parents[1] / "percolate_core/ui/static"
MODULE = (STATIC / "chat-stream.js").as_uri()

ROOT, CHILD, SIBLING, GRANDCHILD = "r-root", "r-child", "r-sibling", "r-grand"


@unittest.skipUnless(shutil.which("node"), "node runs the chat stream model")
class ChatStreamTest(unittest.TestCase):
    def run_js(self, source):
        script = ("import assert from 'node:assert/strict';\n"
                  f"const m = await import({json.dumps(MODULE)});\n"
                  f"const [ROOT, CHILD, SIBLING, GRANDCHILD] = {json.dumps([ROOT, CHILD, SIBLING, GRANDCHILD])};\n"
                  + source)
        result = subprocess.run(["node", "--input-type=module", "-e", script],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_interleaved_deltas_stay_with_their_run_and_message(self):
        """The observed defect: two runs' tokens alternating on one channel."""
        self.run_js("""
        const t = m.turnModel();
        t.apply('RUN_STARTED', {run_id: ROOT, agent_name: 'harbourmaster'});
        t.apply('TEXT_MESSAGE_START', {run_id: ROOT, message_id: 'm1'});
        t.apply('RUN_STARTED', {run_id: CHILD, parent_run_id: ROOT, agent_name: 'fleet_analyst'});
        t.apply('TEXT_MESSAGE_START', {run_id: CHILD, message_id: 'm2'});
        const tokens = [[ROOT,'m1','I don'],[CHILD,'m2','1. '],[ROOT,'m1',"'t "],[CHILD,'m2','Reports'],
                        [ROOT,'m1','have access.'],[CHILD,'m2',' contain details']];
        const scopes = tokens.map(([run_id, message_id, delta]) =>
          t.apply('TEXT_MESSAGE_CONTENT', {run_id, message_id, delta}));
        assert.equal(t.text(m.messageKey(ROOT, 'm1')), "I don't have access.");
        assert.equal(t.text(m.messageKey(CHILD, 'm2')), '1. Reports contain details');
        assert.deepEqual(scopes.map(s => s.scope), ['root','child','root','child','root','child']);
        assert.equal(scopes[1].parent_run_id, ROOT);
        """)

    def test_two_messages_in_one_run_are_two_texts(self):
        self.run_js("""
        const t = m.turnModel();
        t.apply('RUN_STARTED', {run_id: ROOT});
        t.apply('TEXT_MESSAGE_CONTENT', {run_id: ROOT, message_id: 'a', delta: 'first'});
        t.apply('TEXT_MESSAGE_CONTENT', {run_id: ROOT, message_id: 'b', delta: 'second'});
        assert.equal(t.text(m.messageKey(ROOT, 'a')), 'first');
        assert.equal(t.text(m.messageKey(ROOT, 'b')), 'second');
        """)

    def test_only_the_root_run_ends_the_turn(self):
        """A delegated child failing is a tool result for the parent, not the turn's verdict."""
        self.run_js("""
        const t = m.turnModel();
        t.apply('RUN_STARTED', {run_id: ROOT});
        t.apply('RUN_STARTED', {run_id: CHILD, parent_run_id: ROOT});
        const child = t.apply('RUN_FINISHED', {run_id: CHILD, status: 'failed'});
        assert.equal(child.scope, 'child');
        assert.equal(t.finished, false);
        assert.equal(t.failed, false);
        t.apply('RUN_ERROR', {run_id: CHILD, message: 'child broke'});
        assert.equal(t.failed, false);
        assert.equal(t.runs.get(CHILD).status, 'failed');
        t.apply('RUN_FINISHED', {run_id: ROOT, status: 'succeeded'});
        assert.equal(t.finished, true);
        assert.equal(t.failed, false);
        """)

    def test_a_stream_level_error_fails_the_turn(self):
        """api.py's closing RUN_ERROR carries no run_id: it is about the turn."""
        self.run_js("""
        const t = m.turnModel();
        t.apply('RUN_STARTED', {run_id: ROOT});
        assert.equal(t.apply('RUN_ERROR', {message: 'refused'}).scope, 'session');
        assert.equal(t.failed, true);
        """)

    def test_a_run_never_seen_starting_is_not_the_root(self):
        """Joined mid-delegation: an unknown run after the root is somebody's child."""
        self.run_js("""
        const t = m.turnModel();
        t.apply('RUN_STARTED', {run_id: ROOT});
        assert.equal(t.apply('TOOL_CALL_START', {run_id: SIBLING, tool_call_id: 'x'}).scope, 'child');
        const first = m.turnModel();
        assert.equal(first.apply('TEXT_MESSAGE_CONTENT', {run_id: ROOT, message_id: 'a', delta: 'x'}).scope, 'root');
        """)

    def test_frames_split_across_reads_are_held_until_complete(self):
        self.run_js("""
        let {frames, rest} = m.takeFrames('event: RUN_STARTED\\ndata: {"run_id":"r"}\\n\\nevent: TEXT_MESS');
        assert.deepEqual(frames, [{type: 'RUN_STARTED', data: {run_id: 'r'}}]);
        ({frames, rest} = m.takeFrames(rest + 'AGE_CONTENT\\ndata: {"delta":"hi"}\\n\\n'));
        assert.deepEqual(frames, [{type: 'TEXT_MESSAGE_CONTENT', data: {delta: 'hi'}}]);
        assert.equal(rest, '');
        """)

    def test_a_failed_turn_that_wrote_rows_is_still_re_read(self):
        """`RUNS 0`: the re-read was gated on the turn not having failed."""
        self.run_js("""
        assert.equal(m.afterTurn({before: 0, after: 205, failed: true}), 'reread');
        assert.equal(m.afterTurn({before: 0, after: 205, failed: false}), 'reread');
        assert.equal(m.afterTurn({before: 4, after: 4, failed: false}), 'unpersisted');
        assert.equal(m.afterTurn({before: 4, after: 4, failed: true}), 'none');
        assert.equal(m.afterTurn({before: 4, after: null, failed: false}), 'unpersisted');
        """)

    def test_persisted_child_messages_nest_under_their_delegation(self):
        """The re-read had the same defect as the stream: 52 `user` bubbles for one turn."""
        self.run_js("""
        const runs = [{id: ROOT, parent_run_id: null}, {id: CHILD, parent_run_id: ROOT},
                      {id: GRANDCHILD, parent_run_id: CHILD}, {id: SIBLING, parent_run_id: ROOT}];
        const msgs = [
          {seq: 1, run_id: ROOT, role: 'user'}, {seq: 2, run_id: ROOT, role: 'tool_call'},
          {seq: 3, run_id: CHILD, role: 'user'}, {seq: 4, run_id: GRANDCHILD, role: 'user'},
          {seq: 5, run_id: CHILD, role: 'assistant'}, {seq: 6, run_id: ROOT, role: 'tool_response'},
          {seq: 7, run_id: SIBLING, role: 'user'}, {seq: 8, run_id: ROOT, role: 'assistant'},
          {seq: 9, run_id: null, role: 'user'}];
        const items = m.threadOf(msgs, runs);
        assert.deepEqual(items.map(i => i.kind === 'message' ? i.message.seq : 'd:' + i.run.id),
                         [1, 2, 'd:' + CHILD, 6, 'd:' + SIBLING, 8, 9]);
        assert.deepEqual(items[2].messages.map(x => x.seq), [3, 4, 5]);
        assert.deepEqual(m.rootRuns(runs).map(r => r.id), [ROOT]);
        """)

    def test_chat_reads_the_stream_through_the_model(self):
        """The model is only a fix if the screen uses it."""
        access = (STATIC / "access.js").read_text()
        self.assertIn('from "./chat-stream.js"', access)
        for name in ("turnModel", "takeFrames", "threadOf", "afterTurn"):
            self.assertIn(name + "(", access, f"access.js does not call {name}")
        self.assertNotIn("text += data.delta", access,
                         "a delta appended to one shared buffer is the interleaving defect")


if __name__ == "__main__":
    unittest.main()
