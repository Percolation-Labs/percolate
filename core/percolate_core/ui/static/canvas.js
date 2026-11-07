import {h} from './ui.js';
import {rpc} from './api.js';
import {compactMenu} from './compact-menu.js';
import {resultCanvas} from './result-canvas.js';

export async function canvas() {
  const tableWidths=new Map();
  let state=null, serial=Promise.resolve(), disposed=false;
  const error=h('div',{role:'alert'}), stage=h('div'), info=h('span',{class:'hint'});
  const node=h('section',{class:'page wide canvas-workspace','aria-label':'Canvas'});
  const action=async (p_action,p_body={}) => (await rpc('workflow','canvas',{p_action,p_body})).rows;
  const reports=[{value:'workflow_runs',label:'Run counts by status'},{value:'workflow_steps',label:'Task counts by step and status'}];
  const report=compactMenu({label:'Report',options:reports,value:'workflow_runs',onChange:()=>{if(report.value!=='sql')load.click();}});
  function show(next) {
    if(next.unchanged || (next.session===state?.session && next.version < state.version))return;
    if(state?.view?.result?.id!==next.view?.result?.id)tableWidths.clear();
    state=next;info.textContent=next.session?'Saved':'';
    const view=next.view;
    if(view?.result?.query&&view.result.query!=='sql')report.setValue(view.result.query);
    report.node.hidden=view?.result?.query==='sql';
    if(!view){stage.replaceChildren(h('div',{class:'library-empty'},'Choose a report to begin. Your assistant can also send a result to this canvas.'));return;}
    const active=stage.contains(document.activeElement)?document.activeElement:null;
    const focusLabel=active?.getAttribute('aria-label'), focusText=active?.tagName==='BUTTON'?active.textContent:null;
    stage.replaceChildren(resultCanvas({columnWidths:tableWidths,rows:view.result.rows,columns:view.result.columns,title:view.caption,
      initial:{control:view.control,...view.options,rows:next.selection?.result_set===view.result.id?next.selection.rows:[],nodes:next.selection?.result_set===view.result.id?next.selection.nodes:[]},
      onView:body=>send('view',{...body,result_set:view.result.id}),
      onSelection:selection=>send('touch',{kind:'selection',result_set:view.result.id,...selection})}));
    const restore=[...stage.querySelectorAll('button,[tabindex]')].find(el=>focusLabel?el.getAttribute('aria-label')===focusLabel:focusText&&el.textContent===focusText);
    restore?.focus({preventScroll:true});
    if(view.result.source?.statement)stage.append(h('details',{class:'canvas-query-source'},h('summary',{},'SQL query · '+view.result.rows.length+' rows'),h('pre',{},view.result.source.statement)));
    load.hidden=view.result.query==='sql';
  }
  function send(kind,body={}) {
    serial=serial.then(async()=>{try{const next=await action(kind,{session:state?.session,...body});error.replaceChildren();if(kind==='touch'){state=next;}else{show(next);}return true;}catch(e){error.replaceChildren(h('p',{class:'note rose'},e.message));return false;}});
    return serial;
  }
  const load=h('button',{class:'btn canvas-refresh',type:'button','aria-label':'Refresh report',onclick:async()=>{
    load.disabled=true;
    try {if(!state?.session)show(await action('open'));await send('query',{query:report.value,caption:reports.find(r=>r.value===report.value).label});}
    catch(e){error.replaceChildren(h('p',{class:'note rose'},e.message));}finally{load.disabled=false;}
  }},'↻');
  node.append(h('header',{class:'canvas-commandbar'},h('h1',{},'Canvas'),report.node,load,h('span',{class:'spacer'}),info),error,stage);
  try{show(await action('read'));}catch(e){error.replaceChildren(h('p',{class:'note rose'},e.message));}
  const poll=async()=>{
    if(disposed)return;
    if(!node.isConnected){disposed=true;return;}
    await serial;
    try{const next=await action('read',{after:state?.version,known_session:state?.session});show(next);}catch(e){info.textContent='Connection interrupted';}
    if(!disposed)setTimeout(poll,600);
  };
  setTimeout(poll,600);return node;
}
