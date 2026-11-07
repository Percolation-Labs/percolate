const {chromium}=require(process.env.PLAYWRIGHT_PATH||'/Users/sirsh/code/p8-subsystems/demo/podcast-v5/node_modules/playwright');
const assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch();const page=await browser.newPage({viewport:{width:900,height:700}});
 try{
  await page.goto(process.env.P8_UI_TEST_URL||'http://127.0.0.1:8140');
  await page.evaluate(async()=>{
   const {resultCanvas}=await import('./result-canvas.js');window.selections=[];
   document.body.replaceChildren(resultCanvas({initial:{card_title:'name',card_fields:['count']},rows:[{name:'First',payload:{message:'Long JSON '.repeat(300),nested:{ok:true}},count:2},{name:'Second',payload:{message:'small'},count:1}],onSelection:s=>window.selections.push(s)}));
  });
  const first=page.locator('tbody tr').first(),cell=first.locator('td').nth(1);
  assert.ok((await first.boundingBox()).height<60,'JSON expanded the row');
  assert.ok(await cell.locator('span').evaluate(e=>e.scrollWidth>e.clientWidth),'Long value is not clipped');
  assert.match(await cell.getAttribute('title'),/"nested": \{/,'Hover must expose formatted JSON');
  const handle=page.getByRole('separator',{name:'Resize payload column'}),box=await handle.boundingBox();
  const before=(await cell.boundingBox()).width;
  await page.mouse.move(box.x+box.width/2,box.y+box.height/2);await page.mouse.down();await page.mouse.move(box.x+box.width/2+150,box.y+box.height/2,{steps:8});await page.mouse.up();
  const after=(await cell.boundingBox()).width;assert.ok(after>before+100);
  assert.equal(await page.locator('th').nth(1).getAttribute('aria-sort'),'none');assert.deepEqual(await page.evaluate(()=>window.selections),[]);
  await cell.click();assert.equal(await first.getAttribute('aria-selected'),'true');assert.ok(Math.abs((await cell.boundingBox()).width-after)<2);
  await page.getByRole('button',{name:'View as',exact:true}).click();await page.getByRole('option',{name:'Cards',exact:true}).click();await page.getByRole('button',{name:'View as',exact:true}).click();await page.getByRole('option',{name:'Table',exact:true}).click();
  assert.ok(Math.abs((await cell.boundingBox()).width-after)<2);
  await handle.focus();await page.keyboard.press('ArrowRight');assert.ok((await cell.boundingBox()).width>after+15);
  await page.setViewportSize({width:320,height:700});assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));
  await page.screenshot({path:'/tmp/percolate-compact-json-table.png'});
  console.log('PASS compact JSON rows, hover value, drag/keyboard resize, no accidental sorting/selection, width retention and mobile scroll.');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1});
