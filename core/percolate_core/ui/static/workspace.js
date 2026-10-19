import {h} from './ui.js';

let nextId = 0;

// Keep the same nodes mounted when changing modes: drafts and async results
// belong to the object being edited, not to a new render of its tab.
export function workspaceTabs({label, sections, initial, onChange = () => {}}) {
  const id = 'workspace-' + ++nextId;
  const tabs = h('div', {class:'workspace-tabs', role:'tablist', 'aria-label':label});
  const panes = h('div', {class:'workspace-panes'});
  const buttons = new Map(), panels = new Map();
  const node = h('section', {class:'workspace', 'aria-label':label}, tabs, panes);
  let selected;
  function show(key, focus = false) {
    if (!panels.has(key) || buttons.get(key).disabled) return;
    selected = key;
    for (const [name, button] of buttons) {
      button.setAttribute('aria-selected', String(name === key));
      button.tabIndex = name === key ? 0 : -1;
      panels.get(name).hidden = name !== key;
    }
    if (focus) buttons.get(key).focus();
    onChange(key);
  }
  for (const {key, title, content, disabled = false} of sections) {
    const button = h('button', {type:'button', role:'tab', id:id+'-'+key,
      'aria-controls':id+'-'+key+'-panel', disabled, onclick:() => show(key)}, title);
    const pane = h('div', {class:'workspace-pane', role:'tabpanel',
      id:id+'-'+key+'-panel', 'aria-labelledby':button.id}, content);
    button.addEventListener('keydown', event => {
      if (!['ArrowLeft','ArrowRight','Home','End'].includes(event.key)) return;
      event.preventDefault();
      const available = [...buttons].filter(([,b]) => !b.disabled).map(([k]) => k);
      const index = available.indexOf(key);
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? available.length-1
        : (index + (event.key === 'ArrowRight' ? 1 : -1) + available.length) % available.length;
      show(available[next], true);
    });
    buttons.set(key, button); panels.set(key, pane); tabs.append(button); panes.append(pane);
  }
  show(initial || sections.find(s => !s.disabled)?.key);
  return {node, show, get selected() { return selected; },
    enable(key, enabled) { const b = buttons.get(key); if (b) b.disabled = !enabled; },
    rename(key, title) { const b = buttons.get(key); if (b) b.textContent = title; }};
}

export function collectionWorkspace({label, library, detail}) {
  const title = h('h2', {tabindex:'-1'}, label);
  let origin = null, listScroll = 0;
  const node = h('section', {class:'collection-workspace', 'aria-label':label, 'data-view':'browse'});
  const collection = h('div', {class:'collection-library'}, library);
  const pane = h('div', {class:'collection-detail', hidden:true});
  const back = h('button', {class:'btn', type:'button', onclick:() => close()}, 'Back to list');
  const expand = h('button', {class:'btn', type:'button', 'aria-pressed':'false', onclick:() => {
    const wide = node.dataset.expanded !== 'true';
    node.dataset.expanded = String(wide); expand.setAttribute('aria-pressed', String(wide));
    expand.textContent = wide ? 'Show list' : 'Expand';
  }}, 'Expand');
  pane.append(h('header', {class:'workspace-object'}, back, title, expand), detail);
  node.append(collection, pane);
  function close() {
    node.dataset.view = 'browse'; pane.hidden = true;
    collection.scrollTop = listScroll;
    const target = origin?.isConnected ? origin : collection.querySelector('button, input, a');
    target?.focus();
  }
  return {node, close, title,
    open(name, {expanded = false, focus = true} = {}) {
      const active = document.activeElement;
      if (node.dataset.view === 'browse' || collection.contains(active)) listScroll = collection.scrollTop;
      if (active && active !== document.body && !pane.contains(active)) origin = active;
      title.textContent = name; pane.hidden = false;
      node.dataset.view = 'detail'; node.dataset.expanded = String(expanded);
      expand.setAttribute('aria-pressed', String(expanded));
      expand.textContent = expanded ? 'Show list' : 'Expand';
      if (focus && node.isConnected) { title.focus({preventScroll:true}); node.scrollIntoView({block:'start'}); }
    }};
}

export function splitWorkspace({primary, secondary, primaryLabel = 'Editor', secondaryLabel = 'Results'}) {
  const node = h('section', {class:'split-workspace', 'data-focus':'both'});
  const choices = h('div', {class:'workspace-view-controls', role:'group', 'aria-label':'Workspace layout'});
  const labels = {both:'Both', primary:primaryLabel, secondary:secondaryLabel};
  const buttons = {};
  const left = h('div', {class:'split-primary'}, primary);
  const right = h('div', {class:'split-secondary'}, secondary);
  function focus(mode) {
    node.dataset.focus = mode;
    for (const [key, button] of Object.entries(buttons)) button.setAttribute('aria-pressed', String(key === mode));
    left.hidden = mode === 'secondary'; right.hidden = mode === 'primary';
  }
  for (const [key, label] of Object.entries(labels)) {
    buttons[key] = h('button', {class:'btn', type:'button', onclick:() => focus(key)}, label);
    choices.append(buttons[key]);
  }
  node.append(choices, h('div', {class:'split-content'}, left, right));
  focus(matchMedia('(max-width: 900px)').matches ? 'primary' : 'both');
  return {node, focus,
    reveal(mode) { if (matchMedia('(max-width: 900px)').matches || node.dataset.focus !== 'both') focus(mode); },
    secondaryLabel(label) { buttons.secondary.textContent = label; }};
}

export const contextualHelp = (title, ...content) => h('details', {class:'contextual-help'},
  h('summary', {}, title), h('div', {class:'form-stack'}, ...content));

// A list and a substantial editor share the same focused mode on Agents and
// Schedules. Switching does not rebuild either node or discard form values.
export function editorWorkspace({label, browse, editor, createLabel, onCreate = () => {}}) {
  const workspace = collectionWorkspace({label, library:browse, detail:editor});
  const create = h('button', {class:'btn primary', onclick:() => {
    onCreate(); workspace.open(createLabel, {expanded:true});
  }}, createLabel);
  return {...workspace, create};
}
