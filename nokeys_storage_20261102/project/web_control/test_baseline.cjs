const { chromium } = require('C:/Users/hwx/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const assert=require('node:assert/strict'),fs=require('node:fs'),http=require('node:http'),path=require('node:path');
(async()=>{
 const server=http.createServer((req,res)=>{
  const url=new URL(req.url,'http://localhost');
  const file=path.join(__dirname,'dist',url.pathname==='/'?'index.html':path.basename(url.pathname));
  try{res.setHeader('Content-Type',file.endsWith('.js')?'text/javascript':file.endsWith('.css')?'text/css':'text/html');res.end(fs.readFileSync(file));}catch(e){res.statusCode=404;res.end();}
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const browser=await chromium.launch({headless:true,executablePath:'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'});
 try{
  const page=await browser.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.addInitScript(()=>{
   window.serialWrites=[];window.openOptions=null;window.closeCount=0;
   function stream(){return new ReadableStream({start(c){window.serialInput=c;}});}
   let input=stream();
   const p={open:async options=>{window.openOptions=options;},close:async()=>{window.closeCount++;},
    get readable(){return input;},writable:new WritableStream({write(x){window.serialWrites.push([...x]);}})};
   window.injectOverrun=()=>{const old=window.serialInput;input=stream();old.error(new DOMException('Buffer overrun','BufferOverrunError'));};
   Object.defineProperty(navigator,'serial',{configurable:true,value:{requestPort:async()=>p}});
  });
  await page.goto(`http://localhost:${server.address().port}/`);await page.waitForFunction(()=>window.wycAppReady);
  await page.click('#connect');assert.equal(await page.evaluate(()=>openOptions.bufferSize),65536);
  async function status(view,seq,mode){await page.evaluate(([v,s,m])=>serialInput.enqueue(new TextEncoder().encode(`BW=${v},${s.toString(16).padStart(2,'0')},${m},1,0\r\n`)),[view,seq,mode]);await page.waitForTimeout(30);}
  await status(6,0,0);
  assert.equal(await page.locator('[data-view="0"]').count(),0);
  assert.equal(await page.locator('[data-view="6"]').count(),1);
  await page.click('[data-view="7"]');assert.equal((await page.evaluate(()=>serialWrites.at(-1)))[3],7);
  await status(7,1,2);assert((await page.textContent('#commandState')).includes('等待 HDMI'));
  await status(7,1,3);assert.equal(await page.textContent('#mode'),'基准全屏 BASE');
  assert((await page.textContent('#commandState')).includes('基准全屏'));
  await page.evaluate(()=>WYC.handleLine('ID=47 AX=0000 AY=0000 AZ=0800 GX=0000 GY=0000 GZ=0000'));
  assert.equal(await page.textContent('#imuPitch'),'0.0°');assert.equal(await page.textContent('#imuRoll'),'0.0°');
  await page.evaluate(()=>WYC.handleLine('ID=47 AX=0800 AY=0000 AZ=0800 GX=0000 GY=0000 GZ=0000'));
  assert.equal(await page.textContent('#imuPitch'),'-45.0°');
  await page.evaluate(()=>WYC.handleLine('ID=47 AX=0000 AY=0800 AZ=0800 GX=0000 GY=0000 GZ=0000'));
  assert.equal(await page.textContent('#imuRoll'),'45.0°');
  await page.evaluate(()=>WYC.handleLine('ID=FF ERR'));assert.equal(await page.textContent('#imuRoll'),'—');
  await status(6,0,0);
  await page.click('[data-view="4"]');assert.equal((await page.evaluate(()=>serialWrites.at(-1)))[3],4);
  await status(5,1,1);assert((await page.textContent('#commandState')).includes('等待 HDMI'));
  await status(4,1,2);assert.equal(await page.textContent('#mode'),'对比 SPL');assert((await page.textContent('#commandState')).includes('当前为对比'));
  await page.click('[data-view="5"]');await status(5,2,2);assert((await page.textContent('#commandState')).includes('等待 HDMI'));
  await status(5,2,1);assert.equal(await page.textContent('#mode'),'四宫格 QUAD');assert((await page.textContent('#commandState')).includes('当前为四宫格'));
  await page.evaluate(()=>injectOverrun());await page.waitForTimeout(150);await status(4,3,2);
  assert.equal(await page.evaluate(()=>closeCount),0);assert((await page.textContent('#log')).includes('Buffer overrun'));
  await page.click('#disconnect');assert.equal(await page.evaluate(()=>closeCount),1);assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(__dirname,'../verification_quality/baseline_web_report.json'),JSON.stringify({passed:true,hardware_tested:false,checks:['64 KiB buffer','right-bottom packet','no false QUAD acknowledgement','quad layout acknowledgement','overrun recovery','manual disconnect','no page errors','local center removed; wide center retained','BASE mode3 confirmation','IMU pitch/roll estimates and offline clearing']},null,2));
  await page.screenshot({path:path.join(__dirname,'../verification_quality/baseline_web_preview.png'),fullPage:true});
  console.log('PASS baseline full-screen UI, IMU tilt, acknowledgements and serial recovery');
 }finally{await browser.close();await new Promise(resolve=>server.close(resolve));}
})().catch(e=>{console.error(e);process.exitCode=1;});
