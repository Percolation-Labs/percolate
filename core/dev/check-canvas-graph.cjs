const {chromium}=require(process.env.PLAYWRIGHT_PATH||'/Users/sirsh/code/p8-subsystems/demo/podcast-v5/node_modules/playwright');
const assert=require('node:assert/strict'),fs=require('node:fs');
const cfg=JSON.parse(fs.readFileSync('.local/canvas-client.json','utf8'));
let saved;
async function mcp(name,args){const r=await fetch('http://127.0.0.1:8141/mcp',{method:'POST',headers:{Authorization:'Bearer '+cfg.token,'Content-Type':'application/json'},body:JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}})});const body=await r.json();assert.ok(!body.error,JSON.stringify(body));return body.result;}
(async()=>{
 const browser=await chromium.launch({headless:true});const page=await browser.newPage({viewport:{width:1440,height:1000}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
 try{
  const result=await mcp('canvas',{action:'query',statement:"select n.nspname||'.'||c.relname as source, tn.nspname||'.'||t.relname as target, k.conname as relation from pg_catalog.pg_constraint k join pg_catalog.pg_class c on c.oid=k.conrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace join pg_catalog.pg_class t on t.oid=k.confrelid join pg_catalog.pg_namespace tn on tn.oid=t.relnamespace where k.contype='f' and n.nspname='workflow' limit 100",control:'graph',options:{source:'source',target:'target',relation:'relation'}});assert.ok(!result.isError,JSON.stringify(result));
  const full=await mcp('canvas_ui',{action:'read'});saved=full.structuredContent.view.result;
  await page.addInitScript(token=>sessionStorage.setItem('p8-token',token),cfg.token);
  await page.goto('http://127.0.0.1:8140/?dev=1#/canvas');await page.locator('.network-node').first().waitFor();
  const ids=[...new Set(saved.rows.flatMap(r=>[r.source,r.target]))];assert.equal(await page.locator('.network-node').count(),ids.length);assert.equal(await page.locator('.network-edge').count(),saved.rows.length);
  if(await page.getByRole('button',{name:'Clear selection',exact:true}).isVisible()){await page.getByRole('button',{name:'Clear selection',exact:true}).click();}
  const node=page.getByRole('button',{name:'Node workflow.runs',exact:true});await node.click();assert.equal(await node.getAttribute('aria-pressed'),'true');
  await page.getByText('Saved',{exact:true}).waitFor();
  let touch;for(let i=0;i<30;i++){const reply=await mcp('query',{query:'SCHEMA "p8ql"'});touch=reply.structuredContent?.canvas?.since_last_call?.find(t=>t.nodes?.includes('workflow.runs'));if(touch)break;await new Promise(r=>setTimeout(r,100));}assert.ok(touch,'selected graph node never reached chat: '+(await page.locator('[role=alert]').allTextContents()).join(' '));
  assert.deepEqual(touch.rows,saved.rows.flatMap((r,i)=>r.source==='workflow.runs'||r.target==='workflow.runs'?[i]:[]));

  await page.screenshot({path:'/tmp/rem1329-live-graph.png',fullPage:true});
  const transform=await node.getAttribute('transform'),box=await node.boundingBox();await page.mouse.move(box.x+box.width/2,box.y+box.height/2);await page.mouse.down();await page.mouse.move(box.x+box.width/2+70,box.y+box.height/2+30,{steps:5});await page.mouse.up();assert.notEqual(await node.getAttribute('transform'),transform);assert.equal(await node.getAttribute('aria-pressed'),'true');
  const scene=page.locator('.network-svg > g'),before=await scene.getAttribute('transform');await page.getByRole('button',{name:'Zoom in',exact:true}).click();assert.notEqual(await scene.getAttribute('transform'),before);await page.getByRole('button',{name:'Fit',exact:true}).click();
  await page.getByRole('button',{name:'View as',exact:true}).click();await page.getByRole('option',{name:'Table',exact:true}).click();await page.locator('tbody tr').first().waitFor();assert.equal(await page.locator('tbody tr[aria-selected=true]').count(),touch.rows.length);
  await page.getByRole('button',{name:'View as',exact:true}).click();await page.getByRole('option',{name:'Graph',exact:true}).click();await page.locator('.network-node').first().waitFor();await page.reload();await page.getByRole('button',{name:'Node workflow.runs',exact:true}).waitFor();assert.equal(await page.getByRole('button',{name:'Node workflow.runs',exact:true}).getAttribute('aria-pressed'),'true');
  for(const width of [390,320]){await page.setViewportSize({width,height:844});await page.waitForTimeout(300);await page.screenshot({path:'/tmp/graph-phone-debug.png'});assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),JSON.stringify(await page.evaluate(()=>[...document.querySelectorAll('body *')].filter(e=>e.getBoundingClientRect().right>innerWidth+1).map(e=>[e.tagName,e.className,e.getBoundingClientRect().right]).slice(0,12))));}
  await page.screenshot({path:'/tmp/rem1329-live-graph-phone.png',fullPage:true});
  const denied=await mcp('canvas',{action:'query',statement:'select * from rbac.users limit 1'});assert.equal(denied.isError,true);
  const write=await mcp('canvas',{action:'query',statement:"delete from workflow.runs"});assert.equal(write.isError,true);
  const unchanged=await mcp('canvas',{action:'read'});assert.equal(unchanged.structuredContent.view.result.id,saved.id);
  assert.deepEqual(errors,[]);console.log(`PASS live graph: ${ids.length} nodes/${saved.rows.length} actual FKs, selection to chat, drag/zoom/fit, table identity, reload, phone, denied SQL retains view.`);
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
