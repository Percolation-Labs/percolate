const {chromium}=require(process.env.PLAYWRIGHT_PATH||'/Users/sirsh/code/p8-subsystems/demo/podcast-v5/node_modules/playwright');
const assert=require('node:assert/strict');const fs=require('node:fs');
(async()=>{
 const cfg=JSON.parse(fs.readFileSync('.local/canvas-client.json','utf8'));
 const call=async(action,body={})=>{const r=await fetch(cfg.rest+'/rpc/canvas',{method:'POST',headers:{Authorization:'Bearer '+cfg.token,'Content-Type':'application/json','Content-Profile':'workflow'},body:JSON.stringify({p_action:action,p_body:body})});assert.ok(r.ok,await r.clone().text());return r.json();};
 await call('open');await call('query',{query:'workflow_steps',caption:'Task counts by step and status',control:'table',options:{card_title:'step',card_fields:['status','tasks'],x:'step',y:'tasks',form:'bar'}});
 const browser=await chromium.launch({headless:true});const page=await browser.newPage({viewport:{width:1440,height:1000}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.addInitScript(token=>sessionStorage.setItem('p8-token',token),cfg.token);
 try{
  await page.goto('http://127.0.0.1:8140/#/canvas');await page.getByRole('button',{name:'View as',exact:true}).waitFor();assert.equal(await page.locator('.nav-section[open]').count(),0);assert.ok(await page.locator('a[href="#/canvas"]').isVisible());await page.getByText('Data',{exact:true}).click();assert.ok(await page.locator('a[href="#/query"]').isVisible());await page.getByText('Data',{exact:true}).click();await page.getByRole('button',{name:'View as',exact:true}).click();await page.getByRole('option',{name:'Cards',exact:true}).click();await page.locator('.result-card').first().waitFor();
  await page.locator('.result-card').first().locator('h3').click();
  await page.getByRole('button',{name:'View as',exact:true}).click();await page.getByRole('option',{name:'Plot',exact:true}).click();await page.locator('.plot-mark').first().waitFor();
  await page.waitForFunction(()=>document.querySelector('.result-view-control .compact-menu-value')?.textContent==='Plot');
  let state;for(let i=0;i<30;i++){state=await call('read');if(state.view.control==='plot')break;await new Promise(r=>setTimeout(r,100));}assert.equal(state.view.control,'plot');const id=state.view.result.id;
  const touches=await call('consume');assert.ok(touches.since_last_call.some(t=>t.kind==='selection'&&t.rows.includes(0)));
  await page.reload();await page.locator('.plot-mark').first().waitFor();assert.equal((await call('read')).view.result.id,id);
  await call('view',{control:'cards',options:{card_title:'step',card_fields:['status','tasks'],x:'step',y:'tasks',form:'bar'}});await page.locator('.result-card').first().waitFor();assert.equal((await call('read')).view.result.id,id);
  await page.screenshot({path:'/tmp/rem1329-workspace-desktop.png',fullPage:true});
  await page.setViewportSize({width:390,height:844});await page.getByRole('button',{name:'View as',exact:true}).click();await page.getByRole('option',{name:'Plot',exact:true}).click();await page.locator('.plot-mark').first().waitFor();assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));
  await page.screenshot({path:'/tmp/rem1329-workspace-phone.png',fullPage:true});assert.deepEqual(errors,[]);
  console.log('PASS: real core RPC, core sidebar, Cards/Plot, selection returned to client, saved-result identity, reload and external view switch, phone.');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
