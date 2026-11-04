const { chromium }=require('C:/Users/hwx/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const assert=require('node:assert/strict'),http=require('node:http'),fs=require('node:fs'),path=require('node:path');
(async()=>{
 let state={available:true,connected:false,online:false,imu_online:false,bias_ready:false,axis_calibrated:false,axis_collecting:false,reference_ready:false,enabled:false,mode:'roll',zoom:1,offset_us:0,frames_sent:0,samples:0,sample_loss:0,crc_errors:0,hardware:{},raw:null,pose:null,error:''};
 const actions=[];let connectCalls=0,apiAvailable=true;
 let testPorts=[{port:'COM3',description:'Bluetooth serial'}];
 state.axis_progress={samples:0,excursion_deg:0,total_deg:0,coherence:0,required_deg:20};
 const server=http.createServer(async(req,res)=>{
  res.setHeader('Cache-Control','no-store');
  if(req.url.startsWith('/api/')){
   if(!apiAvailable){res.statusCode=404;return res.end('No control service');}
   res.setHeader('Content-Type','application/json');let body='';for await(const b of req)body+=b;
   const a=body?JSON.parse(body):{};
   if(req.url==='/api/ports')return res.end(JSON.stringify(testPorts));
   if(req.url==='/api/connect'){connectCalls++;Object.assign(state,{connected:true,online:true,imu_online:true,raw:[0,-2048,0,0,0,0],pose:{roll:12,pitch:3},hardware:{view:6,sequence:0,mode:0,valid:true,test:false,dropped:0,all_views_capable:true,boosted_exposure:true}});}
   if(req.url==='/api/disconnect')Object.assign(state,{connected:false,online:false,imu_online:false,hardware:{}});
   if(req.url==='/api/action'){
    actions.push(a);
    if(a.action==='axis_start')Object.assign(state,{axis_collecting:true,axis_calibrated:false,reference_ready:false,error:'',axis_progress:{samples:0,excursion_deg:0,total_deg:0,coherence:0,required_deg:20}});
    if(a.action==='axis_finish'){
     if(state.axis_progress.excursion_deg<20){state.error='最大转动幅度为10.0°，不足20°；可以继续转动后再次结束校准';res.statusCode=400;return res.end(JSON.stringify({error:state.error}));}
     Object.assign(state,{axis_collecting:false,axis_calibrated:true,error:''});
    }
    if(a.action==='reference')Object.assign(state,{reference_ready:true,saved_calibration:true,reference_source:'manual'});
    if(a.action==='settings')Object.assign(state,{mode:a.mode,zoom:a.zoom,offset_us:a.offset_us});
    if(a.action==='enable'){state.enabled=a.enabled;Object.assign(state.hardware,{enabled:a.enabled,stabilized:a.enabled});if(a.enabled&&state.hardware.mode===0)Object.assign(state.hardware,{view:7,mode:3});}
    if(a.action==='view'){if(a.view===0x80||a.view===0x81)state.hardware.test=a.view===0x81;else Object.assign(state.hardware,{view:a.view,sequence:a.sequence,mode:a.view===7?3:a.view===5?1:2});}
   }
   return res.end(JSON.stringify(state));
  }
  try{const file=path.join(__dirname,'dist',req.url==='/'?'index.html':req.url.split('?')[0]);res.setHeader('Content-Type',file.endsWith('.js')?'text/javascript':file.endsWith('.css')?'text/css':'text/html');res.end(fs.readFileSync(file));}
  catch(e){res.statusCode=404;res.end();}
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const browser=await chromium.launch({headless:true,executablePath:'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'});
 try{
  const page=await browser.newPage({viewport:{width:1440,height:1000}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.addInitScript(()=>{window.serialPromptCount=0;Object.defineProperty(navigator,'serial',{configurable:true,value:{requestPort:async()=>{window.serialPromptCount++;throw Error('Unexpected Web Serial prompt');}}});});
  await page.goto(`http://localhost:${server.address().port}/`);
  await page.waitForSelector('#stabilizationPanel',{state:'visible'});
  await page.waitForFunction(()=>nativeService);
  assert.equal(await page.locator('#serialPort').inputValue(),'');
  testPorts=[{port:'COM7',description:'CP2102 test fixture'}];
  await page.waitForFunction(()=>document.getElementById('serialPort').value==='COM7');
  await page.evaluate(()=>Promise.all([connect(),connect()]));await page.waitForFunction(()=>nativeState?.online);
  assert.equal(connectCalls,1);assert.equal(await page.evaluate(()=>window.serialPromptCount),0);
  await page.waitForFunction(()=>document.getElementById('exposurePreset').textContent.includes('22.5 ms'));
  state.hardware.boosted_exposure=false;
  assert((await page.textContent('#exposurePreset')).includes('烧录统一曝光版后生效')); 
  state.hardware.boosted_exposure=true;
  await page.click('#testOn');await page.waitForFunction(()=>document.getElementById('sourceState').textContent.includes('可重复测试图'));
  await page.click('#testOff');await page.waitForFunction(()=>document.getElementById('sourceState').textContent.includes('摄像头'));
  assert.equal(await page.locator('#stableStart').isDisabled(),true);
  state.bias_ready=true;await page.waitForFunction(()=>!document.getElementById('axisStart').disabled);
  assert.equal(await page.locator('#stableReference').isDisabled(),true);
  assert((await page.textContent('#stableNextStep')).includes('完成后才能设置水平基准'));
  await page.click('#axisStart');await page.waitForFunction(()=>nativeState.axis_collecting);
  assert((await page.textContent('#stableNextStep')).includes('正在采集光轴'));
  assert.equal(await page.locator('#stableReference').isDisabled(),true);
  state.axis_progress={samples:100,excursion_deg:10,total_deg:10,coherence:1,required_deg:20};
  await page.waitForFunction(()=>document.getElementById('axisProgress').textContent.includes('10.0°'));
  await page.click('#axisFinish');
  await page.waitForFunction(()=>document.getElementById('stableMessage').textContent.includes('不足20°'));
  assert.equal(state.axis_collecting,true);
  assert.equal(await page.locator('#axisFinish').isDisabled(),false);
  state.axis_progress={samples:500,excursion_deg:45,total_deg:90,coherence:1,required_deg:20};
  await page.waitForFunction(()=>document.getElementById('axisProgress').textContent.includes('45.0°'));
  await page.click('#axisFinish');await page.waitForFunction(()=>nativeState.axis_calibrated);
  await page.waitForFunction(()=>!document.getElementById('stableReference').disabled);
  assert((await page.textContent('#stableNextStep')).includes('停止转动约1秒'));
  state.imu_online=false;
  await page.waitForFunction(()=>document.getElementById('stableReference').disabled);
  assert((await page.textContent('#stableNextStep')).includes('等待 IMU 有效数据'));
  state.imu_online=true;
  await page.waitForFunction(()=>!document.getElementById('stableReference').disabled);
  // A saved optical axis must not permit a reference while recalibration is active.
  await page.click('#axisStart');
  await page.waitForFunction(()=>nativeState.axis_collecting);
  assert.equal(await page.locator('#stableReference').isDisabled(),true);
  state.axis_progress={samples:500,excursion_deg:45,total_deg:90,coherence:1,required_deg:20};
  await page.click('#axisFinish');
  await page.waitForFunction(()=>!document.getElementById('stableReference').disabled);
  await page.click('#stableReference');await page.waitForFunction(()=>nativeState.reference_ready);
  await page.locator('#stableAdvanced>summary').click();await page.selectOption('#stableMode','lock3d');await page.fill('#stableZoom','1.2');await page.fill('#stableOffset','2.5');await page.click('#stableSettings');
  await page.click('#stableStart');await page.waitForFunction(()=>document.getElementById('stableActual').textContent.includes('正在显示稳像'));
  assert((await page.textContent('#stableActual')).includes('正在显示稳像'));
  assert(actions.some(a=>a.action==='settings'&&a.offset_us===2500&&a.mode==='lock3d'));
  await page.click('[data-view="4"]');await page.waitForFunction(()=>!pending);assert.equal(state.hardware.view,4);
  await page.waitForFunction(()=>document.getElementById('stableActual').textContent.includes('正在显示稳像 · 对比右侧'));
  await page.click('[data-view="5"]');await page.waitForFunction(()=>!pending);assert.equal(state.hardware.mode,1);
  await page.waitForFunction(()=>document.getElementById('stableActual').textContent.includes('正在显示稳像 · 四宫格'));
  await page.click('[data-view="7"]');await page.waitForFunction(()=>!pending);assert.equal(state.hardware.mode,3);
  await page.click('#stableStop');await page.waitForFunction(()=>document.getElementById('stableActual').textContent==='稳像关闭');
  await page.reload();await page.waitForFunction(()=>port?.native&&nativeState?.connected);
  assert.equal(await page.locator('#disconnect').isDisabled(),false);
  assert.equal(await page.locator('#stableMode').inputValue(),'lock3d');
  const savedProgress=state.axis_progress;delete state.axis_progress;
  await page.waitForFunction(()=>document.getElementById('stableNextStep').textContent.includes('仅刷新网页不会更新角度算法'));
  state.axis_progress=savedProgress;
  await page.waitForFunction(()=>!document.getElementById('stableNextStep').textContent.includes('尚未加载'));
  await page.evaluate(()=>window.scrollTo(0,0)); await page.screenshot({path:path.join(__dirname,'../verification_stabilization/web_preview.png'),fullPage:true});
  await page.screenshot({path:path.join(__dirname,'../verification_stabilization/unified_preview.png')});
  await page.click('#disconnect');assert.equal(state.connected,false);
  Object.assign(state,{bias_ready:false,axis_calibrated:false,reference_ready:false,reference_source:null});
  const starts=actions.filter(a=>a.action==='axis_start').length;
  await page.click('#connect');
  await page.waitForFunction(()=>document.getElementById('stableNextStep').textContent.includes('无需再次转动校准'));
  Object.assign(state,{bias_ready:true,axis_calibrated:true,reference_ready:true,reference_source:'saved'});
  await page.waitForFunction(()=>!document.getElementById('stableStart').disabled);
  assert((await page.textContent('#stableNextStep')).includes('安装标定已自动恢复'));
  assert.equal(actions.filter(a=>a.action==='axis_start').length,starts);
  await page.click('[data-view="5"]');await page.waitForFunction(()=>!pending);
  await page.click('#stableStart');
  await page.waitForFunction(()=>document.getElementById('stableActual').textContent.includes('正在显示稳像 · 四宫格'));
  assert.equal(state.hardware.view,5);
  state.hardware.mode=0;
  await page.waitForFunction(()=>document.getElementById('stableActual').textContent.includes('原图保持原始画面'));
  assert(!(await page.textContent('#stableActual')).includes('正在显示稳像'));
  await page.click('#stableStop');
  const previousConnectCalls=connectCalls;const other=await browser.newPage();
  await other.goto(`http://localhost:${server.address().port}/`);
  await other.waitForFunction(()=>port?.native&&nativeState.connected);assert.equal(connectCalls,previousConnectCalls);
  await other.click('#disconnect');await page.waitForFunction(()=>!port&&document.getElementById('connect').disabled===false);
  await other.close();
  testPorts=[{port:'COM3',description:'Bluetooth serial'}];
  await page.waitForFunction(()=>document.getElementById('serialPort').value==='');
  testPorts=[{port:'COM9',description:'CP2102 reconnected fixture'}];
  await page.waitForFunction(()=>document.getElementById('serialPort').value==='COM9');
  apiAvailable=false;await page.reload();await page.click('#connect');
  assert.equal(await page.evaluate(()=>window.serialPromptCount),0);
  assert((await page.textContent('#connectHint')).includes('统一控制服务未就绪'));
  assert.equal(await page.locator('#stabilizationPanel').isVisible(),true);
  apiAvailable=true;await page.click('#connect');await page.waitForFunction(()=>port?.native);
  await page.click('#disconnect');assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(__dirname,'../verification_stabilization/web_report.json'),JSON.stringify({passed:true,hardware_tested:false,checks:['single integrated page','USB port removal and reinsertion recovery','Bluetooth ports not automatically selected','one connect for all controls','double-connect prevention','native test source controls','exposure preset explicitly requires the named firmware','shared owner across two pages','no Web Serial fallback when backend unavailable','native serial owner','calibration gating and explicit next step','live maximum excursion display','retry finish after insufficient movement','reference disabled during recalibration','IMU offline and recovery gates','axis and reference wizard','3D mode and exposure offset','actual stabilization status for compare and quad','saved calibration restoration without calibration button clicks','enabling keeps selected quad','RAW never claims stabilization','right/quad/base acknowledgements','disable/disconnect','no page errors']},null,2));
  console.log('PASS unified page, single-owner controls, explicit exposure preset and stabilization');
 }finally{await browser.close();await new Promise(r=>server.close(r));}
})().catch(e=>{console.error(e);process.exit(1);});

