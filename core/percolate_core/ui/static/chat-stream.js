/* Which run an event belongs to, and what each run and message has said so far.
 *
 * brief.md §4: every run in a session, delegated sub-runs included, publishes on
 * ONE `agui_<session_id>` channel "tagged with its own runId". So a turn to an
 * agent that delegates arrives as parent and children interleaved, token by
 * token. The chat screen appended every TEXT_MESSAGE_CONTENT to whichever bubble
 * was opened last, and rendered a parent's answer with a child's words shuffled
 * through it; a child's failed RUN_FINISHED marked the whole turn failed while
 * the parent kept running.
 *
 * So text is kept per run AND per message (`run_id` + `message_id`), and only the
 * ROOT run -- the one with no parent -- decides how the turn ended. How a child is
 * shown is §5.1 item 2: its streamed turn is "that call's contents", nested under
 * the delegation, never text in the parent's answer.
 *
 * THIS FILE IMPORTS NOTHING, so node tests it without a DOM
 * (tests/test_chat_stream.py). access.js owns the elements.
 */

export const messageKey = (runId, messageId) => (runId || "") + "/" + (messageId || "");

/* SSE off a fetch body: frames end at a blank line and carry one `data:` JSON
   object. Returns the complete frames and the unfinished remainder. */
export function takeFrames(buf) {
  const frames = [];
  let cut;
  while ((cut = buf.indexOf("\n\n")) !== -1) {
    const frame = buf.slice(0, cut);
    buf = buf.slice(cut + 2);
    let type = "message", data = {};
    for (const line of frame.split("\n")) {
      if (line.startsWith("event:")) type = line.slice(6).trim();
      else if (line.startsWith("data:")) {
        try { data = JSON.parse(line.slice(5).trim()); } catch (e) { data = {}; }
      }
    }
    frames.push({ type, data });
  }
  return { frames, rest: buf };
}

/* The turn's state. `apply` returns where the event belongs:
     scope "root"    -- the run this turn started
     scope "child"   -- a delegated run; `parent_run_id` says whose
     scope "session" -- no run_id, e.g. the stream's own closing RUN_ERROR,
                        which is about the turn and so counts as the root's */
export function turnModel() {
  const runs = new Map();
  const texts = new Map();
  let root = null;
  const model = {
    runs,
    failed: false,
    finished: false,
    get root() { return root; },
    text: (key) => texts.get(key) || "",
    apply(type, data = {}) {
      const id = data.run_id || null;
      if (id && !runs.has(id)) {
        runs.set(id, { id, parent_run_id: data.parent_run_id || null, agent_name: null, status: "running" });
      }
      const run = id ? runs.get(id) : null;
      if (type === "RUN_STARTED" && run) {
        run.parent_run_id = data.parent_run_id || run.parent_run_id;
        run.agent_name = data.agent_name || run.agent_name;
      }
      // The first run seen with no parent is the turn. A run first seen after
      // that is somebody's child even if its RUN_STARTED was missed.
      if (run && root === null && !run.parent_run_id) root = id;
      const scope = !id ? "session" : id === root ? "root" : "child";
      const out = { type, scope, run_id: id, parent_run_id: run ? run.parent_run_id : null,
                    agent_name: run ? run.agent_name : null };

      if (type.startsWith("TEXT_MESSAGE_")) {
        out.key = messageKey(id, data.message_id);
        if (type === "TEXT_MESSAGE_START") texts.set(out.key, texts.get(out.key) || "");
        if (type === "TEXT_MESSAGE_CONTENT") texts.set(out.key, (texts.get(out.key) || "") + (data.delta || ""));
        out.text = texts.get(out.key) || "";
      } else if (type === "RUN_FINISHED" || type === "RUN_ERROR") {
        const status = type === "RUN_ERROR" ? "failed" : (data.status || "succeeded");
        if (run) run.status = status;
        out.status = status;
        if (scope !== "child") {
          model.finished = true;
          model.failed ||= status !== "succeeded";
        }
      }
      return out;
    },
  };
  return model;
}

/* What to do once the stream closes. Rows decide, not the verdict: a failed turn
   still wrote its runs and messages, and gating the re-read on success left the
   session panel at `RUNS 0` over 52 of them. Only a turn that wrote nothing
   keeps the streamed copy, and says so when it did not fail. */
export function afterTurn({ before, after, failed }) {
  if (after !== null && after !== undefined && after > before) return "reread";
  return failed ? "none" : "unpersisted";
}

/* Runs with no parent: the turns a person asked for. */
export const rootRuns = (runs) => (runs || []).filter((r) => !r.parent_run_id);

/* A persisted transcript, grouped the way the stream is: a root run's messages
   are the conversation, and every message of a delegated run -- its prompt,
   its answer, its own delegations -- belongs to the depth-1 delegation it
   descends from, placed where that delegation's first message falls. */
export function threadOf(messages, runs) {
  const byId = new Map((runs || []).map((r) => [r.id, r]));
  const delegation = (runId) => {
    let run = byId.get(runId);
    if (!run || !run.parent_run_id) return null;
    for (let parent = byId.get(run.parent_run_id); parent && parent.parent_run_id;
         parent = byId.get(run.parent_run_id)) run = parent;
    return run;
  };
  const items = [], groups = new Map();
  for (const message of [...(messages || [])].sort((a, b) => (a.seq ?? 0) - (b.seq ?? 0))) {
    const run = message.run_id ? delegation(message.run_id) : null;
    if (!run) { items.push({ kind: "message", message }); continue; }
    if (!groups.has(run.id)) {
      const group = { kind: "delegation", run, messages: [] };
      groups.set(run.id, group);
      items.push(group);
    }
    groups.get(run.id).messages.push(message);
  }
  return items;
}
