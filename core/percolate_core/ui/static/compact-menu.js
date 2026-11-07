import {h} from './ui.js';
let nextId=0;

// Native popover dismissal, custom presentation and keyboard listbox navigation.
export function compactMenu({label, options, value, onChange=()=>{}}) {
  let current=value;
  const id='canvas-menu-'+ ++nextId;
  const caption=h('span',{class:'compact-menu-value'});
  const trigger=h('button',{type:'button',class:'compact-menu-trigger','aria-label':label,
    'aria-haspopup':'listbox','aria-expanded':'false','aria-controls':id},
    h('span',{class:'compact-menu-label'},label),caption,h('span',{class:'compact-menu-chevron','aria-hidden':'true'},'⌄'));
  const list=h('div',{id,popover:'auto',role:'listbox','aria-label':label,class:'compact-menu-list'});
  const node=h('div',{class:'compact-menu'},trigger,list);
  const buttons=options.map(option=>h('button',{type:'button',role:'option',tabindex:'-1','data-value':option.value,
    onclick:()=>{setValue(option.value);list.hidePopover();trigger.focus();onChange(current);}},
    h('span',{},option.label),h('span',{class:'compact-menu-check','aria-hidden':'true'},'✓')));
  list.append(...buttons);
  function setValue(v){current=v;caption.textContent=options.find(o=>o.value===v)?.label||'Choose';buttons.forEach(b=>b.setAttribute('aria-selected',String(b.dataset.value===v)));}
  function open(last=false){
    if(!options.length)return;
    list.showPopover();
    const rect=trigger.getBoundingClientRect(),width=Math.min(Math.max(rect.width,220),innerWidth-24);
    list.style.width=width+'px';list.style.left=Math.max(12,Math.min(rect.left,innerWidth-width-12))+'px';
    const below=innerHeight-rect.bottom-12;
    list.style.top=(below>=180?rect.bottom+6:Math.max(12,rect.top-Math.min(list.scrollHeight,280)-6))+'px';
    (last?buttons.at(-1):buttons.find(b=>b.dataset.value===current)||buttons[0])?.focus();
  }
  trigger.addEventListener('click',()=>list.matches(':popover-open')?list.hidePopover():open());
  trigger.addEventListener('keydown',e=>{if(['ArrowDown','ArrowUp'].includes(e.key)){e.preventDefault();open(e.key==='ArrowUp');}});
  list.addEventListener('toggle',()=>trigger.setAttribute('aria-expanded',String(list.matches(':popover-open'))));
  list.addEventListener('keydown',e=>{
    if(e.key==='Escape'){e.preventDefault();list.hidePopover();trigger.focus();return;}
    if(e.key==='Tab'){list.hidePopover();trigger.focus();return;}
    if(!['ArrowDown','ArrowUp','Home','End'].includes(e.key))return;
    e.preventDefault();const i=buttons.indexOf(document.activeElement);
    const n=e.key==='Home'?0:e.key==='End'?buttons.length-1:(i+(e.key==='ArrowDown'?1:-1)+buttons.length)%buttons.length;
    buttons[n]?.focus();
  });
  setValue(value);
  return {node,setValue,get value(){return current;}};
}
