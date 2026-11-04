const {chromium}=require('C:/Users/hwx/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const assert=require('node:assert/strict');const fs=require('node:fs');
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'});
 const page=await browser.newPage({viewport:{width:1440,height:1100}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.addInitScript(()=>{window.serialWrites=[];const p={open:async()=>{},close:async()=>{},readable:new ReadableStream({start(c){window.serialInput=c;}}),writable:new WritableStream({write(x){serialWrites.push([...x]);}})};Object.defineProperty(navigator,'serial',{configurable:true,value:{requestPort:async()=>p}});});
 await page.goto('http://localhost:8778');await page.waitForFunction(()=>window.wycAppReady);
 assert.equal(await page.locator('[data-view]').count(),7);await page.click('#connect');
 await page.evaluate(()=>serialInput.enqueue(new TextEncoder().encode('MV=0,00,0,1\r\n')));await page.waitForTimeout(50);
 assert(await page.locator('[data-view="5"]').isDisabled());assert((await page.textContent('#connectHint')).includes('旧版'));
 async function status(v,s,m){await page.evaluate(([v,s,m])=>serialInput.enqueue(new TextEncoder().encode(`FV=${v},${s.toString(16).padStart(2,'0')},${m},1\r\n`)),[v,s,m]);await page.waitForTimeout(50);}
 await status(6,0,1);assert(await page.locator('[data-view="6"]').evaluate(b=>b.classList.contains('selected')));
 await page.click('[data-view="5"]');assert.deepEqual((await page.evaluate(()=>serialWrites.at(-1))).slice(0,4),[165,90,1,5]);await status(5,1,1);
 assert((await page.textContent('#commandState')).includes('保留矫正'));
 await status(5,1,2);await page.click('[data-view="2"]');await status(2,2,2);assert.equal(await page.textContent('#mode'),'对比 SPL');
 await page.click('[data-view="6"]');await status(6,3,2);assert.equal(await page.textContent('#mode'),'对比 SPL');
 await status(6,3,0);await page.click('[data-view="0"]');await status(0,4,0);assert((await page.textContent('#commandState')).includes('原图模式保持'));
 await status(6,4,1);await page.screenshot({path:'verification_fullview_plus/web_desktop.png',fullPage:true});await page.click('#disconnect');
 await page.setViewportSize({width:390,height:844});await page.screenshot({path:'verification_fullview_plus/web_mobile.png',fullPage:true});
 assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));assert.deepEqual(errors,[]);
 fs.writeFileSync('verification_fullview_plus/web_report.json',JSON.stringify({passed:true,hardware_tested:false,checks:['seven visible choices','old firmware rejected with instructions','original full correction selected','quad visible and sends view5','RAW/COR/SPL preserved','restoring full view keeps compare mode','desktop/mobile overflow','no page errors']},null,2));
 await browser.close();console.log('PASS full correction plus five rectangles plus mosaic website');
})().catch(e=>{console.error(e);process.exit(1);});
