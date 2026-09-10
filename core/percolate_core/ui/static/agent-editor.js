/* Assemble an agent: a prompt, an output shape, skills and tools.
 *
 * Replaces a 16-row JSON textarea. The parts are the ones `brief.md` §5.4
 * defines, each independently omittable, and the assembled spec stays visible
 * on its own tab so nothing the old editor could express is lost.
 *
 * Layout follows `specs/agentic/ui-design-language.md` §3: one identity header
 * carrying object name, dirty state and the primary action; `workspaceTabs`
 * for Build / Suggest with AI / Specification; `form-stack` groups with field
 * help at the field; `details` for the parts most agents leave alone; and the
 * suggestion card, Apply-then-Save separation and stale-draft guard that
 * `api-sources.js` established.
 */

import { h, panel } from "./ui.js";
import { rpc, read, config, authFetch, token } from "./api.js";
import { READS } from "./reads.js";
import { draftStore } from "./drafts.js";
import { workspaceTabs, contextualHelp } from "./workspace.js";
import { AGENT_DEFAULTS, VISIBILITIES, fromRow, toSpec, toolLabel, composedPrompt, skillDelta } from "./agent-authoring.js";
import { suggestSchema } from "./agent-assist.js";

const field = (label, node, hint) =>
  h("label", { class: "field" }, h("span", {}, label), node, hint ? h("small", { class: "hint" }, hint) : null);
const error = (e) => h("div", { class: "note rose", role: "alert" }, e.message);

export function agentEditor() {
  const store = draftStore("agent-editor");
  const drafts = store.read();
  let draftKey = "new";
  let form = { ...AGENT_DEFAULTS };
  let saved = null;                 // the row as last read, for the skill delta
  let editRevision = 0;             // bumped on every edit; guards a stale apply
  let catalogue = { skills: [], servers: [] };
  const bodies = {};                // skill name -> content, loaded on demand

  const out = h("div", { role: "status" });
  const state = h("span", { class: "draft-state", role: "status" }, "Draft");

  /* ── identity ─────────────────────────────────────────────────── */
  const name = h("input", { class: "control", "aria-label": "Agent name" });
  const model = h("input", { class: "control mono", "aria-label": "Model" });
  const visibility = h("select", { class: "control", "aria-label": "Visibility" },
    VISIBILITIES.map((v) => h("option", { value: v }, v)));

  /* ── prompt ───────────────────────────────────────────────────── */
  const prompt = h("textarea", { class: "control", rows: 8, "aria-label": "System prompt" });

  /* ── skills ───────────────────────────────────────────────────── */
  const skillPick = h("select", { class: "control", "aria-label": "Skill to attach" });
  const skillChips = h("div", { class: "pill-row" });
  const skillNote = h("small", { class: "hint" });
  const composed = h("div", { class: "form-stack" });

  /* ── tools ────────────────────────────────────────────────────── */
  const serverPick = h("select", { class: "control", "aria-label": "Tool server" });
  const operations = h("div", { class: "form-stack" });
  const toolChips = h("div", { class: "pill-row" });

  /* ── output shape ─────────────────────────────────────────────── */
  const shape = h("textarea", { class: "control mono", rows: 8, "aria-label": "Structured output shape" });

  /* ── advanced ─────────────────────────────────────────────────── */
  const category = h("input", { class: "control", "aria-label": "Category" });
  const audience = h("select", { class: "control", "aria-label": "Audience" },
    [["", "not set"], ["user", "user — offered in pickers"], ["system", "system — hidden from pickers"]]
      .map(([value, label]) => h("option", { value }, label)));
  const tags = h("input", { class: "control", "aria-label": "Tags" });

  /* Read-only: `plugin` is set by whatever installed the agent, and an agent a
     plugin owns is one a plugin update can replace. Editing it by hand is a
     decision worth making knowingly, so the editor states it and does not
     offer to change it. */
  const provenance = h("div", { class: "note" });

  const inputs = { name, model, visibility, prompt, shape, category, audience, tags };

  function collect() {
    return {
      ...form,
      name: name.value, model: model.value, visibility: visibility.value,
      system_prompt: prompt.value, structured_output_schema: shape.value,
      category: category.value, audience: audience.value, tags: tags.value,
    };
  }
  function changed() {
    form = collect();
    editRevision += 1;
    state.textContent = "Unsaved changes";
    out.replaceChildren();
    drafts[draftKey] = form;
    store.write(drafts);
  }
  for (const node of Object.values(inputs)) node.addEventListener("input", changed);
  visibility.addEventListener("change", changed);
  audience.addEventListener("change", changed);

  /* ── rendering the reference parts ────────────────────────────── */
  function paintSkills() {
    skillChips.replaceChildren(...(form.skills.length
      ? form.skills.map((s, i) => h("span", { class: "chip kind" }, `${i + 1}. ${s}`,
          h("button", { class: "btn ghost", "aria-label": "Remove skill " + s, onclick: () => {
            form.skills = form.skills.filter((x) => x !== s); changed(); paintSkills(); paintComposed();
          } }, "×")))
      : [h("span", { class: "hint" }, "No skills. The prompt is the whole instruction.")]));
    skillNote.textContent = saved
      ? "Attached with agentic.attach_skill when you save, one statement per skill."
      : "Skills attach after the agent exists — saving creates it, then attaches these.";
  }
  function paintComposed() {
    const parts = composedPrompt(form, bodies);
    composed.replaceChildren(...(parts.length
      ? parts.map((p) => h("div", {},
          h("small", { class: "hint" }, p.source),
          h("pre", { class: "code suggestion-code" }, p.text)))
      : [h("p", { class: "hint" }, "Nothing yet: no prompt and no skills.")]));
  }
  function paintTools() {
    toolChips.replaceChildren(...(form.tools.length
      ? form.tools.map((t) => h("span", { class: "chip kind" }, toolLabel(t),
          h("button", { class: "btn ghost", "aria-label": "Remove " + t.server, onclick: () => {
            form.tools = form.tools.filter((x) => x !== t); changed(); paintTools();
          } }, "×")))
      : [h("span", { class: "hint" }, "No tools. The agent answers from its prompt alone.")]));
  }
  function paintOperations() {
    const server = catalogue.servers.find((s) => s.name === serverPick.value);
    if (!server) { operations.replaceChildren(); return; }
    const names = (server.cached_tools || []).map((t) => t.name || t).filter(Boolean);
    if (!names.length) {
      /* An empty catalogue is not an empty server: REM-18's rule at the
         authoring surface. Offering no operations would read as "this server
         has none", which is a different and false claim. */
      operations.replaceChildren(h("div", { class: "note amber" },
        h("strong", {}, "Catalogue not synced. "),
        `${server.name} has not reported its operations, so they cannot be listed. Sync it below, or attach the whole server.`),
        h("button", { class: "btn", onclick: (e) => sync(server, e.currentTarget) }, "Sync " + server.name),
        h("button", { class: "btn", onclick: () => addTool(server.name, []) }, "Attach every operation"));
      return;
    }
    const boxes = names.map((n) => h("label", { class: "field" },
      h("input", { type: "checkbox", value: n, "aria-label": n }), h("span", {}, n)));
    operations.replaceChildren(
      h("div", { class: "form-stack" }, ...boxes),
      h("div", { class: "form-actions" },
        h("button", { class: "btn", onclick: () => addTool(server.name,
          boxes.map((b) => b.querySelector("input")).filter((i) => i.checked).map((i) => i.value)) },
          "Add tool reference")));
  }
  function addTool(server, tools) {
    form.tools = [...form.tools.filter((t) => t.server !== server), { server, tools }];
    changed(); paintTools();
  }
  async function sync(server, button) {
    button.disabled = true;
    try {
      const base = config().core?.replace(/\/$/, "");
      if (!base) throw new Error("Configure the agent runtime in Settings.");
      const res = await authFetch(base + "/tools/" + encodeURIComponent(server.name) + "/sync",
        { method: "POST", headers: { Authorization: "Bearer " + token() } });
      const data = await res.json();
      if (!res.ok) throw new Error(data.detail || "HTTP " + res.status);
      server.cached_tools = data.tools;
      paintOperations();
    } catch (e) { operations.append(error(e)); }
    finally { button.disabled = false; }
  }

  /* ── writing a new skill ──────────────────────────────────────────
   *
   * `attach_skill(agent, name, spec)` defines the skill and pins it in one
   * statement, so composing a fragment is not a trip to another screen.
   *
   * "Lift from prompt" is the reason this is here rather than in a skills
   * editor somewhere else: the way you discover a skill is by noticing that a
   * paragraph of a prompt is doing a separable job. Select it, lift it, and
   * the prompt loses that paragraph while the agent keeps it — same composed
   * text, one reusable piece. */
  const newSkill = {
    name: h("input", { class: "control", "aria-label": "New skill name", placeholder: "house-style-attribution" }),
    description: h("input", { class: "control", "aria-label": "What the skill is" }),
    when_to_use: h("input", { class: "control", "aria-label": "When it applies" }),
    content: h("textarea", { class: "control", rows: 6, "aria-label": "Skill body" }),
  };
  const newSkillOut = h("div", { role: "status" });

  const lift = h("button", { class: "btn", onclick: () => {
    const start = prompt.selectionStart ?? 0;
    const end = prompt.selectionEnd ?? 0;
    const taken = (end > start ? prompt.value.slice(start, end) : prompt.value).trim();
    if (!taken) {
      newSkillOut.replaceChildren(h("div", { class: "note amber" },
        "Select the part of the prompt to lift, or write the body below."));
      return;
    }
    newSkill.content.value = taken;
    if (end > start) {
      /* Only a selection is removed. Lifting the whole prompt leaves it in
         place, because "make my prompt a skill" and "empty my prompt" are
         different intentions and one of them is not undoable here. */
      prompt.value = (prompt.value.slice(0, start) + prompt.value.slice(end))
        .replace(/\n{3,}/g, "\n\n").trim();
      changed();
    }
    newSkillOut.replaceChildren(h("div", { class: "note" },
      end > start ? "Lifted out of the prompt. Name it, then create it."
        : "Copied the prompt. Name it, then create it — the prompt is unchanged."));
    newSkill.name.focus();
  } }, "Lift from prompt");

  const createSkill = h("button", { class: "btn primary", onclick: async () => {
    createSkill.disabled = true;
    try {
      const skill = newSkill.name.value.trim();
      if (!skill) throw new Error("Name the skill.");
      if (!newSkill.content.value.trim()) throw new Error("A skill needs a body — the text pinned into the prompt.");
      const spec = { content: newSkill.content.value };
      for (const key of ["description", "when_to_use"]) {
        if (newSkill[key].value.trim()) spec[key] = newSkill[key].value.trim();
      }
      if (saved?.name) {
        /* The agent exists, so define and pin in the one statement. */
        await rpc("agentic", "attach_skill", { p_agent: saved.name, p_skill: skill, p_spec: spec });
        saved.skills = [...(saved.skills || []), skill];
      } else {
        /* It does not exist yet and attach_skill refuses to create one. Define
           the skill now; saving the agent pins it with the others. */
        await rpc("agentic", "upsert_skill", { p_spec: { ...spec, name: skill } });
      }
      if (!form.skills.includes(skill)) form.skills = [...form.skills, skill];
      bodies[skill] = spec.content;
      changed(); paintSkills(); paintComposed();
      await loadCatalogue();
      newSkillOut.replaceChildren(h("div", { class: "note" },
        saved?.name ? `Created ${skill} and pinned it to ${saved.name}.`
          : `Created ${skill}. It pins to the agent when you save.`));
      for (const node of Object.values(newSkill)) node.value = "";
    } catch (e) { newSkillOut.replaceChildren(error(e)); }
    finally { createSkill.disabled = false; }
  } }, "Create and attach");

  const skillWriter = contextualHelp("Write a new skill",
    h("p", { class: "hint" }, "A skill is a named fragment of prompt. Lift a paragraph that does a separable job out of the prompt above, or write one here."),
    h("div", { class: "form-actions" }, lift),
    field("Name", newSkill.name, "Lowercase with hyphens, the way the registered skills are named."),
    field("What it is", newSkill.description, "One line. Shown in the picker."),
    field("When it applies", newSkill.when_to_use, "One line. Used to match the skill to a task."),
    field("Body", newSkill.content, "The text concatenated into the system prompt."),
    h("div", { class: "form-actions" }, createSkill), newSkillOut);

  /* ── the assistant ────────────────────────────────────────────── */
  const wanted = h("textarea", { class: "control", rows: 4, "aria-label": "What the agent should return" });
  const aiStatus = h("p", { class: "hint", role: "status" });
  const aiOut = h("div");
  const suggest = h("button", { class: "btn primary", onclick: async () => {
    suggest.disabled = true;
    aiOut.replaceChildren();
    const requested = editRevision;
    try {
      const v = await suggestSchema({
        description: wanted.value, prompt: prompt.value, current: shape.value,
        onStatus: (t) => { aiStatus.textContent = t; },
      });
      aiStatus.textContent = v.schema ? "Proposed. Review it, then apply." : "Needs one more detail.";
      aiOut.replaceChildren(h("article", { class: "suggestion-card" },
        h("p", {}, v.schema ? v.explanation : v.needs_clarification),
        v.assumptions.length ? h("ul", {}, v.assumptions.map((a) => h("li", {}, a))) : null,
        v.schema ? h("details", { open: true }, h("summary", {}, "Proposed output shape"),
          h("pre", { class: "code suggestion-code" }, v.pretty)) : null,
        v.schema ? h("div", { class: "form-actions" },
          h("button", { class: "btn primary", onclick: () => {
            /* The draft may have moved while the model was thinking. Say so
               rather than overwriting it (design language §3.3). */
            if (editRevision !== requested) {
              aiStatus.textContent = "Your draft changed. Ask again to work from the current one.";
              return;
            }
            shape.value = v.pretty; changed();
            tabs.show("build"); shape.focus();
            out.replaceChildren(h("div", { class: "note" },
              h("strong", {}, "Applied to the draft. "), "Nothing is saved until you choose Save agent."));
          } }, "Apply suggestion")) : null));
    } catch (e) {
      aiStatus.textContent = "Could not finish this proposal.";
      aiOut.replaceChildren(error(e));
    } finally { suggest.disabled = false; }
  } }, "Suggest an output shape");

  /* ── saving ───────────────────────────────────────────────────── */
  const save = h("button", { class: "btn primary", onclick: async () => {
    save.disabled = true;
    const submitted = editRevision;
    try {
      form = collect();
      const spec = toSpec(form);
      await rpc("agentic", "upsert_agent", { p_spec: spec });
      /* Skills are a separate statement per `plugins.md` §5.5, and they can
         only attach to an agent that exists — which is why this runs after
         the upsert rather than inside the spec. */
      const { attach, detach } = skillDelta(saved?.skills || [], form.skills);
      for (const skill of detach) await rpc("agentic", "detach_skill", { p_agent: spec.name, p_skill: skill });
      for (const skill of attach) await rpc("agentic", "attach_skill", { p_agent: spec.name, p_skill: skill });
      saved = { ...spec, skills: [...form.skills] };
      sessionStorage.setItem("p8-chat-agent", spec.name);
      window.dispatchEvent(new Event("p8-definitions-changed"));
      const moved = editRevision !== submitted;
      state.textContent = moved ? "Unsaved changes" : "Saved";
      out.replaceChildren(h("div", { class: "note" },
        moved ? `Saved ${spec.name}. Your newer edits are still a draft.` : `Saved ${spec.name}. `,
        attach.length || detach.length
          ? h("span", {}, `${attach.length} skill(s) attached, ${detach.length} detached. `) : null,
        h("a", { href: "#/chat" }, "Open Chat")));
      paintSkills();
    } catch (e) { out.replaceChildren(error(e)); }
    finally { save.disabled = false; }
  } }, "Save agent");

  /* ── the three tabs ───────────────────────────────────────────── */
  const build = h("div", { class: "form-stack" },
    h("div", { class: "form-stack" },
      field("Name", name, "Lowercase letters, numbers and underscores. A new name creates an agent; an existing one updates it."),
      field("Model", model, "Must name a provider configured in this deployment."),
      field("Visibility", visibility), provenance),
    panel("Prompt", "what the agent is for", h("div", { class: "body" },
      field("System prompt", prompt, "The whole instruction, unless you split part of it into skills below."))),
    panel("Skills", "prompt fragments, pinned in order", h("div", { class: "body form-stack" },
      h("p", { class: "hint" }, "A skill is a named fragment concatenated into the system prompt. Splitting an instruction that does four jobs into four skills lets other agents reuse them."),
      h("div", { class: "form-actions" }, skillPick,
        h("button", { class: "btn", onclick: () => {
          const value = skillPick.value;
          if (!value || form.skills.includes(value)) return;
          form.skills = [...form.skills, value]; changed(); paintSkills(); loadBody(value);
        } }, "Attach skill")),
      skillChips, skillNote,
      skillWriter,
      contextualHelp("Composed prompt", composed))),
    panel("Tools", "references to registered servers", h("div", { class: "body form-stack" },
      h("p", { class: "hint" }, "Tools are rows: an agent references a registered server and the operations it may call."),
      field("Tool server", serverPick), operations, toolChips)),
    panel("Output shape", "optional", h("div", { class: "body" },
      field("Structured output schema", shape,
        "JSON Schema. Leave empty for free text. Suggest with AI writes a first version for you to edit."))),
    contextualHelp("Classification and routing",
      field("Category", category, "Groups agents in pickers."),
      field("Audience", audience, "`user` agents appear in pickers; `system` agents do not."),
      field("Tags", tags, "Comma separated.")));

  const ai = h("div", { class: "form-stack" },
    h("p", {}, "Describe what the agent should return and AI proposes a JSON Schema. It is a draft: review it, apply it to the form, then save."),
    field("Wanted output", wanted, "For example: one row per incident with its cause, the services affected and a confidence."),
    h("div", { class: "form-actions" }, suggest), aiStatus, aiOut);

  const specPre = h("pre", { class: "code package-code" });
  const spec = h("div", { class: "form-stack" },
    h("p", { class: "hint" }, "The spec this editor will send to agentic.upsert_agent. Skills are attached separately and are listed for reference."),
    specPre);

  const tabs = workspaceTabs({
    label: "Agent authoring",
    sections: [
      { key: "build", title: "Build", content: build },
      { key: "ai", title: "Suggest with AI", content: ai },
      { key: "spec", title: "Specification", content: spec },
    ],
    onChange: (key) => { if (key === "spec") paintSpec(); if (key === "build") paintComposed(); },
  });

  function paintSpec() {
    try {
      specPre.textContent = JSON.stringify(
        { ...toSpec(collect()), skills: form.skills }, null, 2);
    } catch (e) { specPre.textContent = e.message; }
  }

  /* ── mounting ─────────────────────────────────────────────────── */
  /* The actions bar goes INSIDE the workspace card, above the tab strip.
     `.workspace-actions` is `padding: .65rem 0` on purpose — everywhere else
     it sits in a padded container and aligns with that container's content.
     As a bare child of the page it had no left padding at all, so the primary
     action sat flush against the edge of its own background. */
  tabs.node.prepend(h("div", { class: "workspace-actions" }, save, state));
  const node = h("div", { class: "form-stack" }, tabs.node, out);

  function apply(values) {
    form = { ...AGENT_DEFAULTS, ...values };
    name.value = form.name; model.value = form.model; visibility.value = form.visibility;
    prompt.value = form.system_prompt; shape.value = form.structured_output_schema;
    category.value = form.category; audience.value = form.audience; tags.value = form.tags;
    provenance.replaceChildren(saved?.plugin
      ? h("span", {}, h("strong", {}, "Installed by the " + saved.plugin + " plugin. "),
          "Editing it here is a local change a plugin update can replace.")
      : h("span", { class: "hint" }, "Hand-authored. No plugin owns this agent."));
    paintSkills(); paintTools(); paintComposed();
    form.skills.forEach(loadBody);
  }

  async function loadBody(skill) {
    if (bodies[skill] !== undefined) return;
    try {
      const { rows } = await read(READS.skillBodies, "name=eq." + encodeURIComponent(skill));
      bodies[skill] = rows?.[0]?.content ?? "(this skill has no body)";
    } catch (e) { bodies[skill] = "(could not load: " + e.message + ")"; }
    paintComposed();
  }

  async function loadCatalogue() {
    const [skills, servers] = await Promise.all([
      read(READS.skills).then((r) => r.rows || []).catch(() => []),
      read(READS.toolServers).then((r) => r.rows || []).catch(() => []),
    ]);
    catalogue = { skills, servers };
    skillPick.replaceChildren(h("option", { value: "" }, skills.length ? "Choose a skill…" : "No skills registered"),
      ...skills.map((s) => h("option", { value: s.name, title: s.description || "" }, s.name)));
    serverPick.replaceChildren(h("option", { value: "" }, servers.length ? "Choose a server…" : "No tool servers registered"),
      ...servers.map((s) => h("option", { value: s.name }, `${s.name} · ${s.kind}`)));
    paintOperations();
  }
  serverPick.addEventListener("change", paintOperations);
  loadCatalogue();

  function open(key, values) {
    drafts[draftKey] = form; store.write(drafts);
    draftKey = key;
    const restored = Object.hasOwn(drafts, key);
    apply(restored ? drafts[key] : values);
    state.textContent = restored ? "Draft restored" : "Draft";
    out.replaceChildren();
    tabs.show("build");
    name.focus();
  }

  node.load = (row) => { saved = row; open("agent:" + row.name, fromRow(row)); };
  node.startNew = () => { saved = null; open("new", { ...AGENT_DEFAULTS }); };
  node.startNew();
  return node;
}
