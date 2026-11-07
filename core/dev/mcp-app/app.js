import {App} from '@modelcontextprotocol/ext-apps';
import {h} from '../../percolate_core/ui/static/ui.js';
import {resultCanvas} from '../../percolate_core/ui/static/result-canvas.js';
const app=new App({name:'Percolate Canvas',version:'1.0.0'},{});
const status=h('span',{class:'hint',role:'status'},'Connecting…');
const error=h('p',{class:'note rose',role:'alert'}),stage=h('main');
document.body.append(h('header',{class:'canvas-commandbar'},h('strong',{},'Canvas'),h('span',{class:'spacer'}),status),error,stage);
const tableWidths=new Map();
let state=null,serial=Promise.resolve(),closed=false;
function show(next){
 if(next.unchanged)return;
 if(next.session===state?.session&&next.version<state.version)return;
 const changedResult=state?.view?.result?.id!==next.view?.result?.id;
 if(changedResult)tableWidths.clear();
 state=next;status.textContent='';error.textContent='';
 if(changedResult)app.updateModelContext({structuredContent:{canvas_selection:null,selected_values:[],result_set:next.view?.result?.id||null}}).catch(()=>{});
 const view=next.view;
 if(!view){stage.replaceChildren(h('p',{class:'note'},'Ask your assistant to query tables and show them here.'));return;}
 const selected=next.selection?.result_set===view.result.id?next.selection:{};
 stage.replaceChildren(resultCanvas({columnWidths:tableWidths,rows:view.result.rows,columns:view.result.columns,title:view.caption,
  initial:{control:view.control,...view.options,rows:selected.rows||[],nodes:selected.nodes||[]},
  onView:body=>send('view',{...body,result_set:view.result.id}),
  onSelection:selection=>send('touch',{kind:'selection',result_set:view.result.id,...selection})}));
}
async function rpc(action,body={}){
 const r=await app.callServerTool({name:'canvas_ui',arguments:{action,...body}});
 if(r.isError)throw new Error(r.content?.find(c=>c.type==='text')?.text||'Canvas request failed');
 return r.structuredContent;
}
function send(action,body={}){
 serial=serial.then(async()=>{
  try{
   const next=await rpc(action,{session:state?.session,...body});
   if(action==='touch'){
    state=next;status.textContent='';error.textContent='';
    const selection=next.selection;
    try{await app.updateModelContext({structuredContent:{canvas_selection:selection,selected_values:selection.rows.map(i=>next.view.result.rows[i])}});}catch{/* Durable selection is still returned by the next MCP call. */}
   }else show(next);
   return true;
  }catch(e){error.textContent=e.message;status.textContent='Needs attention';return false;}
 });return serial;
}
async function refresh(){
 await serial;
 const next=await rpc('read',state?{after:state.version,known_session:state.session}:{});show(next);
}
async function poll(){
 if(closed)return;
 try{if(!document.hidden)await refresh();}catch(e){error.textContent=e.message;status.textContent='Connection interrupted';}
 if(!closed)setTimeout(poll,1200);
}
app.ontoolresult=()=>{serial=serial.then(refreshNow).catch(e=>{error.textContent=e.message;});};
async function refreshNow(){show(await rpc('read'));}
app.onteardown=async()=>{closed=true;return {};};
try{await app.connect();await refreshNow();setTimeout(poll,1200);}catch(e){error.textContent=e.message;status.textContent='Could not connect to the host';}
