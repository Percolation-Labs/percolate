const {chromium}=require(process.env.PLAYWRIGHT_PATH||'/Users/sirsh/code/p8-subsystems/demo/podcast-v5/node_modules/playwright');
const assert=require('node:assert/strict'),fs=require('node:fs');
const cfg=JSON.parse(fs.readFileSync('.local/canvas-client.json'));
async function rpc(method,params={}){const r=await fetch('http://127.0.0.1:8141/mcp',{method:'POST',headers:{Authorization:'Bearer '+cfg.token,'Content-Type':'application/json'},body:JSON.stringify({jsonrpc:'2.0',id:1,method,params})});const b=await r.json();assert.ok(!b.error,JSON.stringify(b.error));return b.result;}
(async()=>{
 const list=await rpc('tools/list'),tool=list.tools.find(t=>t.name==='canvas');assert.ok(tool._meta.ui.resourceUri);
 assert.deepEqual(list.tools.find(t=>t.name==='canvas_ui')._meta.ui.visibility,['app']);
 const resource=await rpc('resources/read',{uri:tool._meta.ui.resourceUri});const html=resource.contents[0].text;
 assert.equal(resource.contents[0].mimeType,'text/html;profile=mcp-app');assert.ok(!html.includes(cfg.token));
 await rpc('tools/call',{name:'canvas',arguments:{action:'open'}});
 const q=await rpc('tools/call',{name:'canvas',arguments:{action:'query',control:'table',options:{card_title:'schema',card_fields:['tables'],x:'schema',y:'tables',form:'bar'},statement:'select n.nspname as schema, count(*)::int as tables from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace where c.relkind=\'r\' and n.nspname not like \'pg_%\' and n.nspname<>\'information_schema\' group by n.nspname order by tables desc limit 30'}});
 assert.ok(!q.isError);await rpc('tools/call',{name:'canvas',arguments:{action:'view',control:'table',options:{card_title:'schema',card_fields:['tables'],x:'schema',y:'tables',form:'bar'}}});
 const browser=await chromium.launch();const page=await browser.newPage({viewport:{width:1100,height:850}});const errors=[],network=[];page.on('pageerror',e=>errors.push(e.message));
 try{
 await page.exposeFunction('hostTool',params=>rpc('tools/call',params));
 await page.route('**/*',r=>{network.push(r.request().url());r.abort();});
 await page.setContent('<iframe sandbox="allow-scripts" style="width:100%;height:800px;border:0"></iframe>');
 await page.evaluate(()=>{window.contexts=[];window.addEventListener('message',async event=>{
  const m=event.data;if(!m?.method||m.id===undefined)return;
  let result={};
  try{
   if(m.method==='ui/initialize')result={protocolVersion:m.params.protocolVersion,hostInfo:{name:'test-host',version:'1'},hostCapabilities:{serverTools:{},updateModelContext:{}},hostContext:{theme:'light',displayMode:'inline'}};
   else if(m.method==='tools/call')result=await window.hostTool(m.params);
   else if(m.method==='ui/update-model-context')window.contexts.push(m.params);
   event.source.postMessage({jsonrpc:'2.0',id:m.id,result},'*');
  }catch(e){event.source.postMessage({jsonrpc:'2.0',id:m.id,error:{code:-32603,message:e.message}},'*');}
 });});
 const secured=html.replace('<head>','<head><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; script-src \'unsafe-inline\'; style-src \'unsafe-inline\'; connect-src \'none\'">');
 await page.locator('iframe').evaluate((el,src)=>el.srcdoc=src,secured);
 const frame=page.frameLocator('iframe');await frame.locator('tbody tr').first().waitFor();
 assert.ok(await frame.locator('tbody tr').count()>5,'App must receive full results, not five-row model preview');
 await frame.getByRole('button',{name:'View as',exact:true}).click();await frame.getByRole('option',{name:'Cards',exact:true}).click();await frame.locator('.result-card').first().click();
 await page.waitForFunction(()=>window.contexts.some(c=>c.structuredContent.selected_values.length>0));
 const context=await page.evaluate(()=>window.contexts.at(-1));assert.equal(context.structuredContent.selected_values.length,1);
 // Let multiple UI reads happen: they must not consume the model's selection.
 await page.waitForTimeout(2600);
 const consumed=await rpc('tools/call',{name:'canvas',arguments:{action:'consume'}});assert.ok(consumed.structuredContent.since_last_call.some(t=>t.kind==='selection'));
 await frame.getByRole('button',{name:'View as',exact:true}).click();await frame.getByRole('option',{name:'Plot',exact:true}).click();await frame.locator('.plot-mark').first().waitFor();
 await page.screenshot({path:'/tmp/rem1329-embedded-canvas.png',fullPage:true});
 await rpc('tools/call',{name:'canvas',arguments:{action:'view',control:'table',options:{card_title:'schema',card_fields:['tables'],x:'schema',y:'tables',form:'bar'}}});await frame.locator('tbody tr').first().waitFor();
 await rpc('tools/call',{name:'canvas',arguments:{action:'query',query:'workflow_runs',control:'cards',options:{card_title:'status',card_fields:['runs']}}});
 await frame.locator('.result-card').first().waitFor();
 await page.waitForFunction(()=>window.contexts.at(-1)?.structuredContent.canvas_selection===null);
 assert.deepEqual(network,[],'Embedded app must not make network requests');assert.deepEqual(errors,[]);
 console.log('PASS sandboxed MCP App: full live data, cards/select/context, cursor retained across polling, plot, external chat view change; zero browser network requests.');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
