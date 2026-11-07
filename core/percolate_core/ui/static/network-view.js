import {h} from './ui.js';
let nextId=0;
const svgEl=(tag,attrs={},text)=>{const e=document.createElementNS('http://www.w3.org/2000/svg',tag);for(const[k,v]of Object.entries(attrs))e.setAttribute(k,v);if(text!=null)e.textContent=text;return e;};
const key=v=>String(v);
export function networkView({rows,source,target,relation,selectedRows=[],selectedNodes=[],onSelection=()=>{}}){
  const root=h('div',{class:'network-view'});
  if(!source||!target||source===target){root.append(h('p',{class:'note'},'Choose distinct source and target columns.'));return root;}
  if(rows.some(r=>![r[source],r[target]].every(v=>typeof v==='string'||typeof v==='number'))){root.append(h('p',{class:'note'},'Every relationship needs a source and target name or number.'));return root;}
  const ids=[...new Set(rows.flatMap(r=>[key(r[source]),key(r[target])]))].sort();
  if(ids.length>150||rows.length>300){root.append(h('p',{class:'note'},`This result has ${ids.length} nodes and ${rows.length} edges. Filter to at most 150 nodes and 300 edges to draw it.`));return root;}
  if(!ids.length){root.append(h('p',{class:'note'},'No relationships in this result.'));return root;}
  const width=1000,height=640;
  const nodes=ids.map((id,i)=>({id,x:width/2+Math.cos(i/ids.length*2*Math.PI)*280,y:height/2+Math.sin(i/ids.length*2*Math.PI)*220,w:Math.min(230,Math.max(80,id.length*6.5+28))}));
  const byId=new Map(nodes.map(n=>[n.id,n]));
  const pairs=new Map();
  const edges=rows.map((row,i)=>({i,a:byId.get(key(row[source])),b:byId.get(key(row[target])),label:relation?String(row[relation]??''):''}));
  edges.forEach(e=>{const k=JSON.stringify([e.a.id,e.b.id]);e.parallel=pairs.get(k)||0;pairs.set(k,e.parallel+1);});
  // Deterministic layout: stable across reloads, no animation keeping the page busy.
  for(let turn=0;turn<220;turn++){
    const forces=nodes.map(()=>({x:0,y:0}));
    nodes.forEach((a,i)=>{nodes.forEach((b,j)=>{if(i>=j)return;let dx=a.x-b.x,dy=a.y-b.y;const d=Math.max(15,Math.hypot(dx,dy));const force=18000/(d*d);forces[i].x+=dx/d*force;forces[i].y+=dy/d*force;forces[j].x-=dx/d*force;forces[j].y-=dy/d*force;});});
    edges.forEach(e=>{if(e.a===e.b)return;const dx=e.b.x-e.a.x,dy=e.b.y-e.a.y,d=Math.max(1,Math.hypot(dx,dy)),f=(d-210)*.014;const a=nodes.indexOf(e.a),b=nodes.indexOf(e.b);forces[a].x+=dx/d*f;forces[a].y+=dy/d*f;forces[b].x-=dx/d*f;forces[b].y-=dy/d*f;});
    nodes.forEach((n,i)=>{n.x+=Math.max(-8,Math.min(8,forces[i].x+(width/2-n.x)*.002));n.y+=Math.max(-8,Math.min(8,forces[i].y+(height/2-n.y)*.002));});
  }
  let chosenNodes=new Set(selectedNodes),chosenRows=new Set(selectedRows),zoom=1,panX=0,panY=0,drag=null,moved=false;
  const marker='network-arrow-'+ ++nextId;
  const svg=svgEl('svg',{viewBox:`0 0 ${width} ${height}`,class:'network-svg','aria-label':'Network relationships'});
  const defs=svgEl('defs'),arrow=svgEl('marker',{id:marker,viewBox:'0 0 10 10',refX:9,refY:5,markerWidth:6,markerHeight:6,orient:'auto-start-reverse'});arrow.append(svgEl('path',{d:'M 0 0 L 10 5 L 0 10 z',class:'network-arrow'}));defs.append(arrow);svg.append(defs);
  const scene=svgEl('g'),edgeLayer=svgEl('g'),nodeLayer=svgEl('g');scene.append(edgeLayer,nodeLayer);svg.append(scene);
  const note=h('span',{class:'hint',role:'status'}),detail=h('div',{class:'network-detail'});
  const notify=()=>{note.textContent=`${nodes.length} nodes · ${edges.length} relationships${chosenNodes.size?' · '+[...chosenNodes].join(', '):''}`;detail.replaceChildren(...(chosenRows.size?[h('ul',{},edges.filter(e=>chosenRows.has(e.i)).slice(0,10).map(e=>h('li',{},h('span',{},`${e.a.id} → ${e.b.id}`),h('small',{},e.label)))),...(chosenRows.size>10?[h('p',{},'Showing the first 10 selected relationships.')]:[])]:[]));onSelection({nodes:[...chosenNodes],rows:[...chosenRows],columns:[source,target]});};
  const transform=()=>scene.setAttribute('transform',`translate(${panX} ${panY}) scale(${zoom})`);
  function fit(){const minX=Math.min(...nodes.map(n=>n.x-n.w/2))-30,maxX=Math.max(...nodes.map(n=>n.x+n.w/2))+30,minY=Math.min(...nodes.map(n=>n.y))-65,maxY=Math.max(...nodes.map(n=>n.y))+65;zoom=Math.min(1.5,width/(maxX-minX),height/(maxY-minY));panX=(width-(maxX+minX)*zoom)/2;panY=(height-(maxY+minY)*zoom)/2;transform();}
  const setZoom=f=>{const next=Math.max(.2,Math.min(5,zoom*f));panX=width/2-(width/2-panX)*next/zoom;panY=height/2-(height/2-panY)*next/zoom;zoom=next;transform();};
  const controls=h('div',{class:'network-controls'},note,h('span',{class:'spacer'}),
    h('button',{class:'btn',type:'button','aria-label':'Zoom out',onclick:()=>setZoom(.8)},'−'),h('button',{class:'btn',type:'button','aria-label':'Zoom in',onclick:()=>setZoom(1.25)},'+'),h('button',{class:'btn',type:'button',onclick:fit},'Fit'));
  function selectNode(id){chosenNodes.has(id)?chosenNodes.delete(id):chosenNodes.add(id);chosenRows=new Set(edges.filter(e=>chosenNodes.has(e.a.id)||chosenNodes.has(e.b.id)).map(e=>e.i));renderSelection();notify();}
  const edgePaths=[],nodeGroups=[];
  edges.forEach(e=>{
    const g=svgEl('g',{class:'network-edge','data-edge':e.i,tabindex:0,role:'button','aria-label':`${e.a.id} → ${e.b.id}${e.label?' · '+e.label:''}`});
    const path=svgEl('path',{'marker-end':`url(#${marker})`}),hit=svgEl('path',{class:'network-edge-hit'}),title=svgEl('title',{},`${e.a.id} → ${e.b.id}${e.label?' · '+e.label:''}`);g.append(hit,path,title);
    g.addEventListener('pointerdown',ev=>{ev.stopPropagation();moved=false;});
    const toggleEdge=()=>{chosenNodes.clear();chosenRows.has(e.i)?chosenRows.delete(e.i):chosenRows.add(e.i);renderSelection();notify();};g.addEventListener('click',e=>{if(!moved)toggleEdge();e.stopPropagation();});g.addEventListener('keydown',ev=>{if(ev.key==='Enter'||ev.key===' '){ev.preventDefault();toggleEdge();}});edgeLayer.append(g);edgePaths.push({e,g,path,hit});
  });
  nodes.forEach(n=>{
    const g=svgEl('g',{class:'network-node','data-node':n.id,tabindex:0,role:'button','aria-label':`Node ${n.id}`});
    g.append(svgEl('rect',{x:-n.w/2,y:-19,width:n.w,height:38,rx:7}),svgEl('text',{'text-anchor':'middle',y:4},n.id.length>32?n.id.slice(0,30)+'…':n.id),svgEl('title',{},n.id));
    g.addEventListener('click',ev=>{ev.stopPropagation();if(ev.detail===0)selectNode(n.id);});g.addEventListener('keydown',ev=>{if(ev.key==='Enter'||ev.key===' '){ev.preventDefault();selectNode(n.id);}});
    g.addEventListener('pointerdown',ev=>{ev.stopPropagation();startDrag(ev,n);});nodeLayer.append(g);nodeGroups.push({n,g});
  });
  function renderSelection(){nodeGroups.forEach(({n,g})=>{const on=chosenNodes.has(n.id);g.classList.toggle('selected',on);g.setAttribute('aria-pressed',String(on));});edgePaths.forEach(({e,g})=>{const on=chosenRows.has(e.i);g.classList.toggle('selected',on);g.setAttribute('aria-pressed',String(on));});}
  function positions(){
    nodeGroups.forEach(({n,g})=>g.setAttribute('transform',`translate(${n.x} ${n.y})`));
    edgePaths.forEach(({e,path,hit})=>{let d;if(e.a===e.b){d=`M${e.a.x-18},${e.a.y-19} C${e.a.x-65},${e.a.y-95-e.parallel*25} ${e.a.x+65},${e.a.y-95-e.parallel*25} ${e.a.x+18},${e.a.y-19}`;}else{
      const dx=e.b.x-e.a.x,dy=e.b.y-e.a.y;const cut=n=>Math.min((n.w/2+4)/(Math.abs(dx)||.001),23/(Math.abs(dy)||.001));const a=Math.min(.4,cut(e.a)),b=Math.min(.4,cut(e.b));const offset=e.parallel*24,dist=Math.max(1,Math.hypot(dx,dy));d=`M${e.a.x+dx*a},${e.a.y+dy*a} Q${(e.a.x+e.b.x)/2-dy/dist*offset},${(e.a.y+e.b.y)/2+dx/dist*offset} ${e.b.x-dx*b},${e.b.y-dy*b}`;}
      path.setAttribute('d',d);hit.setAttribute('d',d);
    });
  }
  function point(ev){const p=svg.createSVGPoint();p.x=ev.clientX;p.y=ev.clientY;return p.matrixTransform(svg.getScreenCTM().inverse());}
  function startDrag(ev,node=null){if(ev.button!==0)return;const p=point(ev);moved=false;drag={node,x:p.x,y:p.y,ox:node?node.x:panX,oy:node?node.y:panY};svg.setPointerCapture(ev.pointerId);}
  svg.addEventListener('pointerdown',ev=>startDrag(ev));
  svg.addEventListener('pointermove',ev=>{if(!drag)return;const p=point(ev),dx=p.x-drag.x,dy=p.y-drag.y;if(Math.hypot(dx,dy)>4)moved=true;if(drag.node){drag.node.x=drag.ox+dx/zoom;drag.node.y=drag.oy+dy/zoom;positions();}else{panX=drag.ox+dx;panY=drag.oy+dy;transform();}});
  svg.addEventListener('pointerup',ev=>{const picked=drag?.node;if(picked&&!moved)selectNode(picked.id);drag=null;if(svg.hasPointerCapture(ev.pointerId))svg.releasePointerCapture(ev.pointerId);});
  svg.addEventListener('pointercancel',()=>{drag=null;});
  svg.addEventListener('wheel',ev=>{ev.preventDefault();setZoom(ev.deltaY<0?1.1:1/1.1);},{passive:false});
  root.append(controls,svg,detail);positions();renderSelection();fit();note.textContent=`${nodes.length} nodes · ${edges.length} relationships`;
  return root;
}
