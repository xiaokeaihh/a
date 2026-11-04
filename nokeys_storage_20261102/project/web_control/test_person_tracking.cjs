const {chromium}=require('C:/Users/hwx/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const assert=require('node:assert/strict'),http=require('node:http'),fs=require('node:fs'),path=require('node:path');
(async()=>{
 const state={available:true,connected:true,online:true,imu_online:true,bias_ready:true,axis_calibrated:true,reference_ready:true,saved_calibration:true,
  mode:'roll',zoom:1,offset_us:0,raw:[0,2000,0,0,0,0],hardware:{view:6,mode:2,sequence:0,valid:true,test:false,tracking_capable:true,all_views_capable:true},
  auto_alignment:{state:'idle'},tracking:{kind:'person',state:'idle',token:1,note:'人的跟随已停止。',processed:0},diagnostics:{},error:''};
 const actions=[],selects=[],errors=[];let uploads=0;
 const preview=fs.readFileSync(path.join(__dirname,'../verification_tracking/person_preview_fixture.jpg'));
 const server=http.createServer(async(req,res)=>{
  res.setHeader('Cache-Control','no-store');
  if(req.url.startsWith('/api/person/preview.jpg')){res.setHeader('Content-Type','image/jpeg');return res.end(preview);}
  if(req.url.startsWith('/api/')){
   res.setHeader('Content-Type','application/json');let body='';for await(const chunk of req)body+=chunk;const data=body?JSON.parse(body):{};
   if(req.url==='/api/ports')return res.end('[]');
   if(req.url==='/api/person/devices')return res.end(JSON.stringify([{index:0,name:'Integrated Camera'},{index:1,name:'USB Video'}]));
   if(req.url==='/api/action'){
    actions.push(data);
    if(data.action==='tracking_start'){
     assert.equal(data.backend,'person');assert.equal(data.camera,1);
     state.tracking={kind:'person',state:'waiting',phase:'waiting',token:state.tracking.token+1,owner_client:data.client_id,note:'多人请点击人物框。',preview_available:true,
      processed:12,people:[{id:1,bbox:[80,80,80,180]},{id:2,bbox:[400,80,80,180]}],selected_id:null,worker_ready:true,hfov:100,
      model:{provider:'DmlExecutionProvider',model_bytes:10634838},inference_ms:4.3,tracking_ms:1.2,tracking_fps:30,process_rss_mib:160,process_peak_rss_mib:180};
     state.enabled=true;
    }
    if(data.action==='tracking_stop')Object.assign(state.tracking,{state:'idle',phase:'idle',token:state.tracking.token+1,owner_client:'',note:'已停止',bbox:null});
   }
   if(req.url==='/api/person/select'){
    assert.equal(data.client_id,state.tracking.owner_client);assert.equal(data.token,state.tracking.token);selects.push(data.id);
    Object.assign(state.tracking,{state:'following',phase:'following',selected_id:data.id,bbox:[80,80,80,180],note:'正在跟随人物1。'});
   }
   if(req.url==='/api/tracking/frame')uploads++;
   return res.end(JSON.stringify(state));
  }
  const file=path.join(__dirname,'dist',req.url==='/'?'index.html':req.url.split('?')[0]);
  try{res.setHeader('Content-Type',file.endsWith('.js')?'text/javascript':file.endsWith('.css')?'text/css':'text/html');res.end(fs.readFileSync(file));}catch{res.statusCode=404;res.end();}
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const browser=await chromium.launch({headless:true,executablePath:'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'});
 try{
  const page=await browser.newPage({viewport:{width:1400,height:1100}});page.on('pageerror',e=>errors.push(e.message));
  await page.goto(`http://localhost:${server.address().port}/`);
  await page.waitForFunction(()=>document.getElementById('personCamera').value==='1'&&!document.getElementById('trackingStart').disabled);
  await page.click('#trackingStart');await page.waitForFunction(()=>!document.getElementById('personVideo').hidden);
  assert.equal(await page.evaluate(()=>stream),null);
  await page.waitForTimeout(600);assert.equal(state.tracking.state,'waiting');assert.equal(uploads,0);
  const observer=await browser.newPage();observer.on('pageerror',e=>errors.push(e.message));await observer.goto(`http://localhost:${server.address().port}/`);
  await observer.waitForFunction(()=>document.getElementById('trackingState').textContent.includes('另一页面'));
  assert(await observer.locator('#trackingReselect').isDisabled());
  await page.locator('#trackingOverview').scrollIntoViewIfNeeded();const rect=await page.locator('#trackingOverview').boundingBox();
  await page.mouse.click(rect.x+120*rect.width/640,rect.y+150*rect.height/360);
  await page.waitForFunction(()=>nativeState.tracking.selected_id===1);assert.deepEqual(selects,[1]);
  Object.assign(state.tracking,{phase:'recovering',note:'目标暂时不可见，保持视角并尝试恢复原目标。'});
  await page.waitForFunction(()=>document.getElementById('trackingState').textContent.includes('暂时不可见'));
  Object.assign(state.tracking,{phase:'following',view_clamped:true,hfov:80,note:'正在跟随人物1。'});
  await page.waitForFunction(()=>document.getElementById('personBoundary').textContent.includes('允许人物偏离中心'));
  assert((await page.locator('#personMetrics').textContent()).includes('1帧'));
  assert((await page.locator('#pipelinePanel h2').textContent()).includes('核心矫正'));
  await page.screenshot({path:path.join(__dirname,'../verification_tracking/person_web_mock.png'),fullPage:true});
  await page.click('#trackingStop');await page.waitForFunction(()=>document.getElementById('personVideo').hidden);
  assert.equal(actions.filter(a=>a.action==='tracking_stop').length,1);assert.equal(uploads,0);assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(__dirname,'../verification_tracking/person_web_test.json'),JSON.stringify({passed:true,hardware_validated:false,uploads,
   checks:['PC selects USB card instead of default webcam','AI start without browser video','native preview','no browser frame uploads','observer cannot stop owner','click selects person ID','occlusion status','edge constraint status','separate AI/core metrics','explicit stop releases preview','no page errors']},null,2));
  await observer.close();console.log('PASS native person-follow webpage (simulated API and image)');
 }finally{await browser.close();await new Promise(r=>server.close(r));}
})().catch(e=>{console.error(e);process.exit(1);});
