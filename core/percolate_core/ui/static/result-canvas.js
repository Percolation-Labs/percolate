/* One saved result, three views. View switches never execute another query. */
import {h} from './ui.js';
import {compactMenu} from './compact-menu.js';
import {rendererNames,rendererError} from './renderers.js';
import {networkView} from './network-view.js';
const text = v => v == null ? '—' : typeof v === 'object' ? JSON.stringify(v) : String(v);
const number = v => typeof v === 'number' && Number.isFinite(v);
const svgNode = (name, attrs = {}, content) => {
  const node = document.createElementNS('http://www.w3.org/2000/svg', name);
  for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value);
  if (content != null) node.textContent = content;
  return node;
};
export function resultCanvas({rows, columns = [...new Set(rows.flatMap(Object.keys))], title = 'Result', onSelection = () => {}, onView = () => {}, initial = {}, columnWidths = new Map()}) {
  let mode = initial.control || 'table', shape = initial.form || 'bar', selected = new Set(initial.rows || []), sort = null, ascending = true;
  for(const c of columns) if(!columnWidths.has(c)) columnWidths.set(c,Math.min(280,Math.max(120,c.length*8+40,...rows.slice(0,50).map(r=>Math.min(240,text(r[c]).length*7+28)))));
  const numeric = columns.filter(c => rows.some(r => number(r[c])) && rows.every(r => r[c] == null || number(r[c])));
  let x=initial.x||'', y=initial.y||'';
  let source=initial.source||'',target=initial.target||'',relation=initial.relation||'';
  let cardTitle=initial.card_title||'',cardFields=initial.card_fields||[],configuring=false,pending=false;
  const options=()=>({x:x||null,y:y||null,form:shape,source:source||null,target:target||null,relation:relation||null,card_title:cardTitle||null,card_fields:cardFields});
  if(rendererError(mode,options(),columns,rows))mode='table';
  let selectedNodes=initial.nodes||[];
  const node = h('section', {class:'result-canvas', 'aria-label':title});
  const stage = h('div', {class:'result-stage'}), settings = h('div', {class:'result-settings'});
  const count = h('span', {class:'hint', role:'status'});
  const controls=h('div',{class:'result-view-control'}), feedback=h('p',{class:'result-feedback',role:'alert'});
  const configure=h('button',{type:'button',class:'btn','aria-expanded':'false',onclick:()=>{configuring=!configuring;draw();}},'Configure view');
  async function apply(type,opts){
    const problem=rendererError(type,opts,columns,rows);
    if(problem){feedback.textContent=problem;return;}
    if(pending)return;
    pending=true;configure.disabled=true;controls.querySelector('button').disabled=true;feedback.textContent='';
    try{
      const saved=await onView({control:type,options:opts});
      if(saved===false)throw new Error('The view could not be saved. Your previous view is unchanged.');
      ({x,y,form:shape,source,target,relation,card_title:cardTitle,card_fields:cardFields}={...options(),...opts});
      mode=type;configuring=false;draw();
    }catch(error){draw();feedback.textContent=error.message;}
    finally{pending=false;configure.disabled=false;controls.querySelector('button').disabled=false;}
  }
  function editor(){
    let draft={...options(),card_fields:[...cardFields]},kind=mode;
    const fields=h('div',{class:'renderer-fields'});
    const menu=(label,values,key)=>compactMenu({label,options:[{value:'',label:'Choose…'},...values.map(v=>({value:v,label:v}))],value:draft[key]||'',onChange:v=>{draft[key]=v;}}).node;
    const scalar=columns.filter(c=>rows.every(r=>r[c]==null||typeof r[c]!=='object'));
    function fieldsFor(){
      fields.replaceChildren();
      if(kind==='table')fields.append(h('p',{class:'hint'},'All result columns. Drag a column edge to resize; use Inspect value for details.'));
      if(kind==='plot')fields.append(menu('X field',columns,'x'),menu('Y field',numeric,'y'),menu('Chart type',['bar','line','scatter'],'form'));
      if(kind==='graph')fields.append(h('p',{class:'hint'},'Each row must describe a relationship.'),menu('Source field',scalar,'source'),menu('Target field',scalar,'target'),menu('Relationship label (optional)',columns,'relation'));
      if(kind==='cards'){
        fields.append(menu('Card title',scalar,'card_title'),h('p',{class:'hint'},'Choose up to six detail fields.'));
        fields.append(h('div',{class:'card-field-choices'},columns.map(c=>h('label',{},h('input',{type:'checkbox',checked:draft.card_fields.includes(c),onchange:e=>{draft.card_fields=e.target.checked?[...draft.card_fields,c]:draft.card_fields.filter(f=>f!==c);}}),c))));
      }
    }
    const kindMenu=compactMenu({label:'Renderer',options:Object.entries(rendererNames).map(([value,label])=>({value,label})),value:kind,onChange:v=>{kind=v;fieldsFor();}}).node;
    fieldsFor();
    return h('div',{class:'renderer-editor'},kindMenu,fields,h('button',{class:'btn primary',type:'button',onclick:()=>apply(kind,draft)},'Apply view'));
  }
  const toggle = i => {
    const restore=node.contains(document.activeElement)&&document.activeElement.dataset.row===String(i);
    selected.has(i) ? selected.delete(i) : selected.add(i);
    onSelection({rows:[...selected], columns:mode==='table'?columns:mode==='cards'?[cardTitle,...cardFields]:[x,y].filter(Boolean)});draw();
    if(restore)node.querySelector(`[data-row="${i}"]`)?.focus({preventScroll:true});
  };
  const rowEvents = i => ({tabindex:'0','data-row':i,onclick:()=>toggle(i),onkeydown:e=>{
    if(e.target===e.currentTarget&&(e.key==='Enter'||e.key===' ')){e.preventDefault();toggle(i);}
  }});
  function cell(value,column){
    const full=typeof value==='object'&&value!==null?JSON.stringify(value,null,2):text(value);
    const content=h('td',{title:full},h('span',{class:'result-cell'},text(value)));
    if(full.length>80||value!==null&&typeof value==='object')content.append(h('button',{type:'button',class:'cell-inspect','aria-label':`Inspect ${column} value`,onclick:e=>{
      e.stopPropagation();
      const dialog=h('dialog',{class:'cell-dialog'},h('strong',{},column),h('pre',{},full));
      dialog.append(h('button',{class:'btn',type:'button',onclick:()=>dialog.close()},'Close'));
      dialog.addEventListener('close',()=>dialog.remove());node.append(dialog);dialog.showModal();
    }},'⋯'));
    return content;
  }
  function draw() {
    controls.replaceChildren(compactMenu({label:'View as',options:Object.entries(rendererNames).filter(([type])=>!rendererError(type,options(),columns,rows)).map(([value,label])=>({value,label})),value:mode,onChange:type=>apply(type,options())}).node);
    configure.setAttribute('aria-expanded',String(configuring));
    clear.hidden=!selected.size;
    count.textContent = `${rows.length} ${rows.length===1?'row':'rows'}${selected.size ? ` · ${selected.size} selected` : ''}`;
    settings.replaceChildren(); stage.replaceChildren();
    if(configuring)settings.append(editor());
    if (!rows.length) {stage.append(h('div',{class:'library-empty'},'This result has no rows.'));return;}
    if(mode==='graph'){

      stage.append(networkView({rows,source,target,relation,selectedRows:[...selected],selectedNodes,
        onSelection:selection=>{selected=new Set(selection.rows);selectedNodes=selection.nodes;clear.hidden=!selected.size;count.textContent=`${rows.length} rows · ${selected.size} selected`;onSelection(selection);}}));
    } else if (mode==='plot') {
      if (!numeric.length) {stage.append(h('div',{class:'library-empty'},'No numeric column to plot. Use Table or Cards to inspect this result.'));return;}
      if (shape==='scatter' && !numeric.includes(x)) {
        stage.append(h('div',{class:'note',role:'status'},'Scatter needs a numeric horizontal axis. Choose one above, or use Bar or Line.'));return;
      }
      const data=rows.map((row,i)=>({row,i})).filter(({row})=>number(row[y])&&(shape!=='scatter'||number(row[x])));
      if(!data.length){stage.append(h('p',{},'No numeric values in this result.'));return;}
      const width=Math.min(900,Math.max(260,innerWidth-(innerWidth<600?100:340))),height=innerWidth<600?320:400,left=55,right=20,top=25,bottom=60,iw=width-left-right,ih=height-top-bottom;
      const min=Math.min(0,...data.map(d=>d.row[y])),max=Math.max(0,...data.map(d=>d.row[y]));
      const py=v=>top+ih-(v-min)/(max-min||1)*ih;
      const xmin=Math.min(...data.map(d=>d.row[x])),xmax=Math.max(...data.map(d=>d.row[x]));
      const px=(d,i)=>shape==='scatter'?left+(xmax===xmin?.5:(d.row[x]-xmin)/(xmax-xmin))*iw:left+(i+.5)/data.length*iw;
      const svg=svgNode('svg',{viewBox:`0 0 ${width} ${height}`,role:'img','aria-label':`${shape} plot: ${y} by ${x}`,class:'result-plot'});
      for(let tick=0;tick<=4;tick++) {
        const value=min+(max-min)*tick/4,pos=py(value);
        svg.append(svgNode('line',{x1:left,x2:width-right,y1:pos,y2:pos,class:'plot-grid'}),svgNode('text',{x:left-12,y:pos+4,'text-anchor':'end',class:'plot-label'},Number(value.toPrecision(4))));
      }
      if(shape==='line') svg.append(svgNode('path',{d:data.map((d,i)=>`${i?'L':'M'}${px(d,i)},${py(d.row[y])}`).join(' '),class:'plot-line'}));
      data.forEach((d,i)=>{
        const at=px(d,i),value=d.row[y],mark=shape==='bar'?svgNode('rect',{x:at-iw/data.length*.32,y:Math.min(py(0),py(value)),width:iw/data.length*.64,height:Math.max(2,Math.abs(py(value)-py(0)))}):svgNode('circle',{cx:at,cy:py(value),r:6});
        mark.setAttribute('class','plot-mark'+(selected.has(d.i)?' selected':''));
        mark.setAttribute('tabindex','0');mark.setAttribute('role','button');mark.setAttribute('aria-pressed',String(selected.has(d.i)));
        mark.setAttribute('aria-label',`${text(d.row[x])}: ${value}; select row ${d.i+1}`);
        mark.append(svgNode('title',{},`${text(d.row[x])}: ${value}`));
        mark.addEventListener('click',()=>toggle(d.i));mark.addEventListener('keydown',e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();toggle(d.i);}});svg.append(mark);
        if(data.length<=16 || i%Math.ceil(data.length/12)===0) svg.append(svgNode('text',{x:at,y:height-bottom+24,'text-anchor':'middle',class:'plot-label'},text(d.row[x]).slice(0,18)));
      });
      svg.append(svgNode('text',{x:width/2,y:height-12,'text-anchor':'middle',class:'plot-label'},x));stage.append(svg);

    } else if(mode==='cards') {
      stage.append(h('div',{class:'result-cards'},rows.map((row,i)=>h('article',{
        class:'result-card'+(selected.has(i)?' selected':''),role:'button','aria-pressed':String(selected.has(i)),
        'aria-label':`Row ${i+1}: ${text(row[cardTitle])}`,...rowEvents(i)},
        h('div',{class:'result-card-head'},h('h3',{},text(row[cardTitle])),h('span',{class:'row-selection-mark','aria-hidden':'true'},selected.has(i)?'✓':'')),
        h('dl',{},cardFields.filter(c=>c!==cardTitle).map(c=>[h('dt',{},c),h('dd',{},text(row[c]))]))))));
    } else {
      const ordered=rows.map((row,i)=>({row,i}));
      if(sort) ordered.sort((a,b)=>(ascending?1:-1)*(number(a.row[sort])&&number(b.row[sort])?a.row[sort]-b.row[sort]:text(a.row[sort]).localeCompare(text(b.row[sort]))));
      const table=h('table',{class:'data result-table'});
      const cols=columns.map(c=>h('col',{style:`width:${columnWidths.get(c)}px`}));
      const resize=(index,width)=>{
        columnWidths.set(columns[index],Math.min(1200,Math.max(80,width)));
        cols.forEach((col,i)=>col.style.width=`${columnWidths.get(columns[i])}px`);
        table.style.width=`${[...columnWidths.values()].reduce((a,b)=>a+b,0)}px`;
        table.querySelectorAll('.result-resize').forEach((handle,i)=>handle.setAttribute('aria-valuenow',Math.round(columnWidths.get(columns[i]))));
      };
      const headers=columns.map((c,index)=>{
        const handle=h('span',{class:'result-resize',role:'separator',tabindex:'0',
          'aria-label':`Resize ${c} column`,'aria-orientation':'vertical','aria-valuemin':'80','aria-valuemax':'1200',
          'aria-valuenow':Math.round(columnWidths.get(c)),title:'Drag to resize; arrow keys adjust width',
          onclick:e=>e.stopPropagation(),onkeydown:e=>{
            if(!['ArrowLeft','ArrowRight'].includes(e.key))return;
            e.preventDefault();e.stopPropagation();resize(index,columnWidths.get(c)+(e.key==='ArrowRight'?20:-20));
          },onpointerdown:e=>{
            if(e.button!==0)return;
            e.preventDefault();e.stopPropagation();
            table.querySelectorAll('th').forEach((th,i)=>columnWidths.set(columns[i],th.getBoundingClientRect().width));
            const start=e.clientX,width=columnWidths.get(c);resize(index,width);handle.setPointerCapture(e.pointerId);
            handle.onpointermove=move=>resize(index,width+move.clientX-start);
            handle.onlostpointercapture=()=>{handle.onpointermove=null;};
          }});
        return h('th',{'aria-sort':sort===c?(ascending?'ascending':'descending'):'none'},
          h('button',{type:'button',class:'result-column',title:c,onclick:()=>{ascending=sort===c?!ascending:true;sort=c;draw();}},c,sort===c?(ascending?' ↑':' ↓'):''),handle);
      });
      table.append(h('colgroup',{},cols),h('thead',{},h('tr',{},headers)),
        h('tbody',{},ordered.map(({row,i})=>h('tr',{class:'result-row'+(selected.has(i)?' selected':''),'aria-selected':String(selected.has(i)),'aria-label':`Row ${i+1}: ${text(row[columns[0]])}`,...rowEvents(i)},
          columns.map(c=>cell(row[c],c))))));
      resize(0,columnWidths.get(columns[0]));
      stage.append(h('div',{class:'result-table-scroll'},table));
    }
  }
  const clear=h('button',{class:'btn',type:'button',onclick:()=>{selected.clear();selectedNodes=[];onSelection({rows:[],columns:[]});draw();}},'Clear selection');
  node.append(h('header',{class:'result-toolbar'},h('strong',{class:'result-title',title},title),h('span',{class:'spacer'}),count,controls,configure,clear),settings,feedback,stage);
  draw(); return node;
}
