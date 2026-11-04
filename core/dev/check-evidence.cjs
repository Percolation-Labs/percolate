// Run against `percolate ui serve` configured with the prepared local example.
const {chromium}=require(process.env.PLAYWRIGHT_PATH||'/Users/sirsh/code/p8-subsystems/demo/podcast-v5/node_modules/playwright');
const assert=require('node:assert/strict');
const base=process.env.P8_UI_TEST_URL||'http://127.0.0.1:8082';
(async()=>{
  const browser=await chromium.launch({headless:true});
  const page=await browser.newPage({viewport:{width:1440,height:1100}});
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  try {
    await page.goto(base+'/#/evidence');
    await page.getByText('Open the experiment workbench · cases, filters and SQL',{exact:true}).click();
    await page.getByRole('heading',{name:'Evidence',exact:true}).waitFor();
    assert.equal(await page.locator('.nav-item[aria-current="page"]').innerText(),'Evidence');
    assert.match(await page.locator('.evidence-stats').innerText(),/18 of 50/);
    assert.match(await page.locator('.evidence-stats').innerText(),/5 of 50/);
    await page.screenshot({path:'/private/tmp/evidence-core-finding.png',fullPage:true});
    await page.getByLabel('Question type').selectOption('knowledge_update');
    assert.match(await page.locator('.evidence-stats').innerText(),/62/);
    await page.getByRole('button',{name:'Inspect decision N004 →'}).click();
    assert.equal(await page.getByLabel('Decision',{exact:true}).inputValue(),'N004');
    assert.match(await page.locator('.evidence-content').innerText(),/cooking/i);
    assert.equal(await page.getByText('No answer found',{exact:true}).count(),2);
    await page.getByRole('button',{name:'Next →',exact:true}).click();
    assert.equal(await page.getByLabel('Decision',{exact:true}).inputValue(),'N005');
    await page.getByLabel('Search decisions').fill('N099');
    assert.equal(await page.getByLabel('Decision',{exact:true}).inputValue(),'N099');
    await page.getByLabel('Search decisions').fill('no decision matches this text');
    await page.getByText('No decisions match these filters.').waitFor();
    await page.getByRole('button',{name:'Query',exact:true}).click();
    await page.getByText('Query complete. All 100 recorded cases are available.').waitFor({timeout:60000});
    assert.deepEqual(await page.locator('.evidence-table tbody tr').allTextContents(),['NEW-shown501836','OFF50510']);
    await page.getByRole('button',{name:'Missing answers',exact:true}).click();
    await page.getByRole('button',{name:'Run query',exact:true}).click();
    await page.getByText('32 rows',{exact:true}).waitFor();
    await page.getByLabel('SQL query').fill('SELECT no_such_column FROM cases');
    await page.getByRole('button',{name:'Run query',exact:true}).click();
    await page.getByRole('alert').waitFor({state:'visible'});
    await page.getByLabel('SQL query').fill('SELECT count(*) AS decisions FROM cases');
    await page.getByRole('button',{name:'Run query',exact:true}).click();
    await page.getByText('1 rows',{exact:true}).waitFor();
    assert.equal(await page.locator('.evidence-table td').innerText(),'100');
    await page.screenshot({path:'/private/tmp/evidence-core-query.png',fullPage:true});
    for(const width of [390,320]) {
      await page.setViewportSize({width,height:844});
      for(const view of ['Finding','Cases','Query']) {
        await page.getByRole('button',{name:view,exact:true}).click();
        assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),`${view} page overflows ${width}`);
        assert.ok(await page.locator('.main').evaluate(e=>e.scrollWidth<=e.clientWidth+1),`${view} main overflows ${width}`);
      }
    }
    await page.getByRole('button',{name:'Finding',exact:true}).click();
    await page.screenshot({path:'/private/tmp/evidence-core-phone.png',fullPage:true});
    assert.deepEqual(errors,[]);
    console.log('PASS: core admin sidebar, filtered findings, readable decisions, SQL, errors and narrow layouts');
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
