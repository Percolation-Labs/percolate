const {chromium}=require(process.env.PLAYWRIGHT_PATH||'/Users/sirsh/code/p8-subsystems/demo/podcast-v5/node_modules/playwright');
const assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch();const page=await browser.newPage({viewport:{width:1200,height:900}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
 const choose=async(label,value)=>{await page.getByRole('button',{name:label,exact:true}).click();await page.getByRole('option',{name:value,exact:true}).click();};
 try{
  await page.goto(process.env.P8_UI_TEST_URL||'http://127.0.0.1:8140');
  await page.evaluate(async()=>{const {resultCanvas}=await import('./result-canvas.js');window.changes=[];window.selections=[];window.reject=false;document.body.replaceChildren(resultCanvas({title:'Agent run samples',rows:[{name:'Retrieve',tasks:48,source:'A',target:'B',payload:{text:'detail '.repeat(100)}},{name:'Judge',tasks:32,source:'B',target:'C',payload:{ok:true}}],onSelection:s=>window.selections.push(s),onView:v=>{window.changes.push(v);return !window.reject;}}));});
  assert.equal(await page.locator('.result-title').innerText(),'Agent run samples');
  await page.getByRole('button',{name:'View as',exact:true}).click();assert.equal(await page.getByRole('option').count(),1);await page.keyboard.press('Escape');
  await page.getByRole('button',{name:'Inspect payload value'}).first().click();assert.match(await page.locator('dialog').innerText(),/detail detail/);assert.deepEqual(await page.evaluate(()=>window.selections),[]);await page.getByRole('button',{name:'Close',exact:true}).click();
  await page.locator('tbody tr').first().click();assert.equal(await page.locator('tbody tr').first().getAttribute('aria-selected'),'true');
  await page.getByRole('button',{name:'Configure view',exact:true}).click();await choose('Renderer','Cards');await page.getByRole('button',{name:'Apply view'}).click();assert.match(await page.locator('.result-feedback').innerText(),/title field/);assert.equal(await page.locator('tbody tr').count(),2);
  await choose('Card title','name');await page.getByLabel('tasks',{exact:true}).check();await page.getByRole('button',{name:'Apply view'}).click();assert.equal(await page.locator('.result-card').count(),2);assert.equal(await page.locator('.result-card').first().locator('h3').innerText(),'Retrieve');assert.equal(await page.locator('.result-card').first().locator('dt').innerText(),'tasks');
  await choose('View as','Table');assert.equal(await page.locator('tbody tr').first().getAttribute('aria-selected'),'true');
  await page.getByRole('button',{name:'Configure view',exact:true}).click();await choose('Renderer','Plot');await choose('X field','name');await choose('Y field','tasks');await page.getByRole('button',{name:'Apply view'}).click();assert.equal(await page.locator('.plot-mark').count(),2);
  await page.evaluate(()=>window.reject=true);await choose('View as','Table');assert.equal(await page.locator('.plot-mark').count(),2);assert.match(await page.locator('.result-feedback').innerText(),/could not be saved/);assert.equal(await page.locator('.result-view-control .compact-menu-value').innerText(),'Plot');await page.evaluate(()=>window.reject=false);
  await page.getByRole('button',{name:'Configure view',exact:true}).click();await choose('Renderer','Graph');await choose('Source field','source');await choose('Target field','target');await page.getByRole('button',{name:'Apply view'}).click();assert.equal(await page.locator('.network-svg').count(),1);
  await choose('View as','Table');await page.setViewportSize({width:320,height:750});assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));
  await page.screenshot({path:'/tmp/percolate-renderer-review-mobile.png'});assert.deepEqual(errors,[]);
  console.log('PASS explicit renderer setup, conditional alternatives, mapped cards, rejected view preservation, plot/graph, selection, inspector and mobile overflow.');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1});
