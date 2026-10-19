import { claims, config } from "./api.js";

// Capture the workspace and account when the editor opens. An async completion
// must never save one account's draft under an account selected later.
export function draftStore(name) {
  const key = "p8-editor:" + JSON.stringify([config().rest, claims()?.sub || "anonymous", name]);
  return {
    read(fallback = {}) {
      try { return JSON.parse(sessionStorage.getItem(key)) || fallback; }
      catch (_) { return fallback; }
    },
    write(value) {
      try { sessionStorage.setItem(key, JSON.stringify(value)); return true; }
      catch (_) { return false; }
    },
    clear() { sessionStorage.removeItem(key); }
  };
}

export function stageWorkflow(yaml, input = {}) {
  const previous = sessionStorage.getItem("p8-workflow-draft");
  if (previous?.trim() && previous !== yaml) {
    sessionStorage.setItem("p8-workflow-draft-backup", previous);
    sessionStorage.setItem("p8-workflow-input-backup", sessionStorage.getItem("p8-workflow-input") || "{}");
  }
  sessionStorage.setItem("p8-workflow-draft", yaml);
  sessionStorage.setItem("p8-workflow-input", JSON.stringify(input, null, 2));
}

export function sameInput(a, b) {
  const ordered = v => Array.isArray(v) ? v.map(ordered)
    : v && typeof v === "object" ? Object.fromEntries(Object.keys(v).sort().map(k => [k, ordered(v[k])])) : v;
  return JSON.stringify(ordered(a)) === JSON.stringify(ordered(b));
}
