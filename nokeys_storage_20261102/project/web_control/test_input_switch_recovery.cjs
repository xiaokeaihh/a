const {chromium}=require('C:/Users/hwx/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const assert=require('node:assert/strict'),http=require('node:http'),fs=require('node:fs'),path=require('node:path');
(async()=>{
 const state={available:true,connected:true,online:true,imu_online:false,bias_ready:false,axis_calibrated:false,reference_ready:false,axis_collecting:false,
  mode:'roll',zoom:1,offset_us:0,enabled:false,frames_sent:0,samples:0,sample_loss:0,crc_errors:0,
  hardware:{view:7,mode:3,sequence:0,valid:true,test:false},auto_alignment:{state:'idle'},tracking:{state:'idle'},panorama:{state:'idle'},diagnostics:{},error:'',
  image_controls:{input_switch_supported:true,input_source:'camera',requested_source:'hdmi',input_switch_busy:true},input_transition:{source:'hdmi',started:100}};
 const actions=[],errors=[];let holdNext=true,held=null;
 const server=http.createServer(async(req,res)=>{
  res.setHeader('Cache-Control','no-store');
  if(req.url.startsWith('/api/')){
   res.setHeader('Content-Type','application/json');let body='';for await(const b of req)body+=b;const a=body?JSON.parse(body):{};
   if(req.url==='/api/ports')return res.end(JSON.stringify([{port:'TEST_COM',description:'Test-only serial'}]));
   if(req.url==='/api/person/devices')return res.end('[]');
   if(req.url==='/api/connect')state.connected=true;
   if(req.url==='/api/disconnect')state.connected=false;
   if(req.url==='/api/action'){
    actions.push(a);
    if(a.action==='input_source'){state.input_transition={source:a.source,started:101};state.image_controls.requested_source=a.source;}
    if(a.action==='view'){
     if(holdNext){holdNext=false;held=res;return;}
     Object.assign(state.hardware,{view:a.view,sequence:a.sequence,mode:a.view===7?3:a.view===5?1:2,valid:true});
    }
   }
   return res.end(JSON.stringify(state));
  }
  const pathname=new URL(req.url,'http://localhost').pathname;
  const file=path.join(__dirname,'dist',pathname==='/'?'index.html':pathname);
  try{res.setHeader('Content-Type',file.endsWith('.js')?'text/javascript':file.endsWith('.css')?'text/css':'text/html');res.end(fs.readFileSync(file));}
  catch{res.statusCode=404;res.end();}
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const browser=await chromium.launch({headless:true,executablePath:'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'});
 try{
  const page=await browser.newPage({viewport:{width:1440,height:1000}});page.on('pageerror',e=>errors.push(e.message));
  await page.goto(`http://localhost:${server.address().port}/`);
  await page.waitForFunction(()=>gotFirmware&&!!window.wycPanorama);
  await page.evaluate(()=>document.querySelector('#viewPanel details').open=true);
  assert.equal(await page.locator('#inputSource').isDisabled(),false,'Can reselect input while a new frame is absent');
  await page.selectOption('#inputSource','camera');await page.click('#applyInputSource');
  await page.waitForFunction(()=>nativeState.input_transition?.source==='camera');
  assert.equal(actions.find(a=>a.action==='input_source').source,'camera');
  state.input_transition=null;
  await page.waitForFunction(()=>document.getElementById('inputSourceState').textContent.includes('尚未收到'));
  assert.equal(await page.locator('#applyInputSource').isDisabled(),false);
  await page.click('[data-view="4"]');await page.waitForFunction(()=>pending?.view===4);
  await page.waitForTimeout(80);assert(held);
  await page.click('[data-view="5"]');await page.waitForFunction(()=>pending?.view===5);
  const first=actions.find(a=>a.action==='view');
  Object.assign(state.hardware,{view:4,sequence:first.sequence,mode:2,valid:true});
  await page.waitForTimeout(300);
  assert.equal(await page.evaluate(()=>pending?.view),5,'An old status must not acknowledge the latest request');
  held.writeHead(500);held.end(JSON.stringify({error:'test old-request failure'}));held=null;
  await page.waitForFunction(()=>pending===null&&nativeState.hardware.view===5&&document.getElementById('commandState').textContent.includes('四宫格'));
  assert(!((await page.textContent('#commandState')).includes('发送失败')),'An older failure cannot clear a newer request');
  holdNext=true;await page.click('[data-view="6"]');await page.waitForFunction(()=>pending?.view===6);
  await page.waitForTimeout(3300);
  assert.equal(await page.evaluate(()=>pending),null,'A blocked send cannot disable controls indefinitely');
  assert.equal(await page.locator('[data-view="7"]').isDisabled(),false);
  await page.click('[data-view="7"]');await page.waitForFunction(()=>pending?.view===7);
  held.writeHead(500);held.end(JSON.stringify({error:'test timeout release'}));held=null;
  await page.waitForFunction(()=>pending===null&&nativeState.hardware.view===7);
  assert.deepEqual(actions.filter(a=>a.action==='view').map(a=>a.view),[4,5,6,7],'Superseded retries must not be sent after the latest choice');
  holdNext=true;await page.click('[data-view="4"]');await page.waitForTimeout(80);assert(held);
  await page.click('#disconnect');await page.waitForFunction(()=>port===null);
  await page.selectOption('#serialPort','TEST_COM');await page.click('#connect');await page.waitForFunction(()=>gotFirmware&&!!port);
  await page.click('[data-view="6"]');await page.waitForFunction(()=>pending===null&&nativeState.hardware.view===6);
  held.writeHead(500);held.end(JSON.stringify({error:'test previous-connection failure'}));held=null;
  assert.deepEqual(actions.filter(a=>a.action==='view').map(a=>a.view),[4,5,6,7,4,6]);
  assert.deepEqual(errors,[]);
  const report={passed:true,hardware_measured:false,checks:['input can be retargeted during transition','absent input has actionable status','latest view supersedes pending view','old response and error cannot confirm/clear a new request','hung send has bounded wait','serialized writes skip stale retries','reconnect bypasses blocked previous-connection writes','no browser errors']};
  fs.writeFileSync(path.join(__dirname,'../verification/switch_browser_tests.json'),JSON.stringify(report,null,2));
  console.log(JSON.stringify(report));
 }finally{
  if(held){held.writeHead(500);held.end('{}');}
  await browser.close();server.closeAllConnections();await new Promise(r=>server.close(r));
 }
})().catch(e=>{console.error(e);process.exitCode=1;});
