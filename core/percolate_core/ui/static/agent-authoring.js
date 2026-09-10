/* What an agent is made of, as data. Imports nothing, so it can be tested.
 *
 * `brief.md` §5.4 defines the parts and the UI had none of them: the editor
 * was one JSON textarea whose starter template mentioned neither `skills` nor
 * `structured_output_schema`, so the two fields that most change an agent's
 * behaviour were discoverable only by reading the schema.
 *
 * The four parts are a prompt, an optional output shape, skills and tools.
 * Each is independently omittable — an agent with a prompt and nothing else is
 * a legitimate agent, and the form has to make that one step rather than an
 * argument for a simpler screen.
 */

/** The starter an empty workspace offers. Every part named, none required. */
export const AGENT_DEFAULTS = {
  name: "", model: "openai:gpt-4.1-mini", visibility: "private",
  system_prompt: "", structured_output_schema: "", skills: [], tools: [],
  category: "", audience: "", tags: "",
};

export const VISIBILITIES = ["private", "org", "public"];

/* A tool reference is `{server, tools:[...]}`. Stored specs also accept a bare
   string for the whole server, which the runtime reads as "every operation"
   — kept on read so an agent authored elsewhere survives a round trip. */
export const toolRef = (entry) =>
  typeof entry === "string" ? { server: entry, tools: [] } : { server: entry.server, tools: entry.tools || [] };

export const toolLabel = (ref) =>
  ref.tools?.length ? `${ref.server} · ${ref.tools.join(", ")}` : `${ref.server} · all operations`;

/** Read an agent row into the form's shape. */
export function fromRow(row = {}) {
  return {
    ...AGENT_DEFAULTS,
    name: row.name || "",
    model: row.model || AGENT_DEFAULTS.model,
    visibility: row.visibility || "private",
    system_prompt: row.system_prompt || "",
    structured_output_schema: row.structured_output_schema
      ? JSON.stringify(row.structured_output_schema, null, 2) : "",
    skills: [...(row.skills || [])],
    tools: (row.tools || []).map(toolRef),
    category: row.category || "",
    audience: row.audience || "",
    tags: (row.tags || []).join(", "),
  };
}

/** The form's shape as the spec `agentic.upsert_agent` receives.
 *
 * Empty parts are OMITTED rather than sent as null: upsert_agent merges what
 * it is given, so sending `structured_output_schema: null` for an agent that
 * has one would silently clear it. Opting out of a part in this editor means
 * "I am not setting this", not "remove it".
 */
export function toSpec(form) {
  const name = (form.name || "").trim();
  if (!name) throw new Error("An agent name is required.");
  if (!/^[a-z][a-z0-9_]*$/i.test(name)) {
    throw new Error("Use a name starting with a letter, then letters, numbers or underscores.");
  }
  if (!(form.model || "").trim()) throw new Error("Choose a model with a configured provider.");

  const spec = { name, model: form.model.trim(), visibility: form.visibility || "private" };
  if ((form.system_prompt || "").trim()) spec.system_prompt = form.system_prompt;
  if ((form.structured_output_schema || "").trim()) {
    spec.structured_output_schema = parseSchema(form.structured_output_schema);
  }
  if (form.tools?.length) spec.tools = form.tools.map(toolRef);
  for (const key of ["category", "audience"]) {
    if ((form[key] || "").trim()) spec[key] = form[key].trim();
  }
  const tags = (form.tags || "").split(",").map((t) => t.trim()).filter(Boolean);
  if (tags.length) spec.tags = tags;
  /* `skills` is deliberately not here. It is attached through
     `agentic.attach_skill`, which `plugins.md` §5.5 requires: a statement, not
     a read-modify-write, so two people editing one agent cannot clobber each
     other's skill list by each saving a whole array. */
  return spec;
}

export function parseSchema(text) {
  let value;
  try {
    value = JSON.parse(text);
  } catch (e) {
    throw new Error("The output shape is not valid JSON: " + e.message);
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("An output shape is a JSON object, for example {\"type\":\"object\",\"properties\":{}}.");
  }
  return value;
}

/** The prompt the model will actually see: the system prompt, then each
 *  attached skill's body, in the order `agents.skills` names them.
 *
 * `brief.md` §5.4: skills are "concatenated into the system prompt". The
 * editor shows that rather than describing it, because a skill list is the
 * one part of an agent whose effect is invisible from its own field. */
export function composedPrompt(form, bodies = {}) {
  const parts = [];
  if ((form.system_prompt || "").trim()) parts.push({ source: "system prompt", text: form.system_prompt.trim() });
  for (const name of form.skills || []) {
    parts.push({ source: "skill: " + name, text: bodies[name] ?? "(body not loaded)" });
  }
  return parts;
}

/** Which skills have to be attached, and which detached, to reach `wanted`. */
export function skillDelta(current = [], wanted = []) {
  return {
    attach: wanted.filter((s) => !current.includes(s)),
    detach: current.filter((s) => !wanted.includes(s)),
  };
}
