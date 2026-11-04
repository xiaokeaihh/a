const {chromium}=require('C:/Users/hwx/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const assert=require('node:assert/strict'),http=require('node:http'),fs=require('node:fs'),path=require('node:path');
(async()=>{
 const state={available:true,connected:true,online:true,imu_online:true,bias_ready:true,axis_calibrated:true,reference_ready:true,saved_calibration:true,
  mode:'roll',zoom:1,offset_us:0,raw:[0,2000,0,0,0,0],hardware:{view:6,mode:2,sequence:0,valid:true,test:false,tracking_capable:true,all_views_capable:true},
  auto_alignment:{state:'idle'},tracking:{kind:'person',state:'idle',token:1,note:'人的跟随已停止。',processed:0},diagnostics:{},error:''};
 const errors=[],actions=[],selects=[],rois=[];let uploads=0,mediaCalls=0;
 const preview=fs.readFileSync(path.join(__dirname,'../verification_tracking/person_preview_fixture.jpg'));
 const server=http.createServer(async(req,res)=>{
  res.setHeader('Cache-Control','no-store');
  if(req.url.startsWith('/api/person/preview.jpg')){res.setHeader('Content-Type','image/jpeg');return res.end(preview);}
  if(req.url.startsWith('/api/')){
   res.setHeader('Content-Type','application/json');let body='';for await(const c of req)body+=c;const data=body?JSON.parse(body):{};
   if(req.url==='/api/ports')return res.end('[]');
   if(req.url==='/api/person/devices')return res.end(JSON.stringify([{index:1,name:'USB Video'}]));
   if(req.url==='/api/action'){
    actions.push(data);
    if(data.action==='tracking_start'){
     state.tracking={kind:data.backend,state:'waiting',phase:'waiting',token:state.tracking.token+1,owner_client:data.client_id,note:'在总览中选择目标。',preview_available:data.backend==='person',
      processed:12,people:[{id:1,bbox:[80,80,80,180]},{id:2,bbox:[400,80,80,180]}],selected_id:null,worker_ready:true,hfov:100,
      model:{provider:'DmlExecutionProvider',model_bytes:10634838},inference_ms:4.3,tracking_ms:1.2,tracking_fps:30,process_rss_mib:160,process_peak_rss_mib:180};
     state.enabled=true;
    }
    if(data.action==='tracking_stop')Object.assign(state.tracking,{state:'idle',phase:'idle',token:state.tracking.token+1,owner_client:'',note:'已停止',bbox:null});
    if(data.action==='view'){state.hardware.view=data.view;state.hardware.sequence=data.sequence;state.hardware.mode=2;}
   }
   if(req.url==='/api/person/select'){
    selects.push(data.id);Object.assign(state.tracking,{state:'following',phase:'following',selected_id:data.id,bbox:[80,80,80,180],note:'正在跟随人物。'});
   }
   if(req.url==='/api/tracking/frame'){
    uploads++;if(data.roi){rois.push(data.roi);Object.assign(state.tracking,{state:'following',bbox:data.roi,note:'正在跟随物体。'});}
    return res.end(JSON.stringify(state.tracking));
   }
   return res.end(JSON.stringify(state));
  }
  const file=path.join(__dirname,'dist',req.url==='/'?'index.html':req.url.split('?')[0]);
  try{res.setHeader('Content-Type',file.endsWith('.js')?'text/javascript':file.endsWith('.css')?'text/css':'text/html');res.end(fs.readFileSync(file));}catch{res.statusCode=404;res.end();}
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const browser=await chromium.launch({headless:true,executablePath:'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',args:['--autoplay-policy=no-user-gesture-required']});
 const context=await browser.newContext({viewport:{width:1440,height:1000}});
 context.on('page',p=>p.on('pageerror',e=>errors.push(e.message)));
 await context.addInitScript(()=>{
  window.__captureCalls=0;if(navigator.mediaDevices)navigator.mediaDevices.getUserMedia=async()=>{window.__captureCalls++;throw Error('TEST: must reuse source');};
 });
 async function popup(page,button){const waiting=page.waitForEvent('popup');await page.click(button);const w=await waiting;await w.waitForFunction(()=>!!window.wycObservation);return w;}
 async function point(page,x,y){
  const r=await page.locator('#overview').boundingBox(),s=Math.min(r.width/640,r.height/360);
  return [r.x+(r.width-s*640)/2+x*s,r.y+(r.height-s*360)/2+y*s];
 }
 function pixels(){const c=document.getElementById('output'),ctx=c.getContext('2d');return [[0,0],[1100,10],[1279,31],[100,700],[640,360]].map(([x,y])=>Array.from(ctx.getImageData(x,y,1,1).data));}

 try{
  const page=await context.newPage();await page.goto(`http://localhost:${server.address().port}/`);
  await page.waitForFunction(()=>!document.getElementById('trackingStart').disabled);
  assert((await page.locator('#uiRevision').textContent()).includes('F4'));
  await page.click('#trackingStart');await page.waitForFunction(()=>!document.getElementById('personVideo').hidden);
  const overview=await popup(page,'#displayOverview'),hdmi=await popup(page,'#displayHdmi');
  await hdmi.waitForFunction(()=>document.getElementById('status').textContent.includes('共用'));
  assert.equal(context.pages().length,3);assert.equal(await overview.locator('body').getAttribute('data-layout'),'overview');
  assert.equal(await hdmi.locator('body').getAttribute('data-layout'),'hdmi');
  await page.locator('#controlsOnly').check();assert(!(await page.locator('#monitorBoard').isVisible()));
  assert.equal(await page.locator('.floating-panel').count(),0,'External viewers must not generate internal floating panels');
  const expected=await page.evaluate(()=>{
   const c=document.createElement('canvas');c.width=1280;c.height=720;const x=c.getContext('2d');x.drawImage(personPreview,0,0,1280,720);
   return [[0,0],[1100,10],[1279,31],[100,700],[640,360]].map(([a,b])=>Array.from(x.getImageData(a,b,1,1).data));
  });
  assert.deepEqual(await hdmi.evaluate(pixels),expected,'Full source pixels, including borders, must remain unchanged');
  await hdmi.waitForFunction(()=>!document.getElementById('markerCover').hidden);
  const g=await hdmi.evaluate(()=>{
   const a=document.getElementById('markerCover').getBoundingClientRect(),b=document.getElementById('outputPicture').getBoundingClientRect();
   return {w:a.width/b.width,h:a.height/b.height,bw:b.width,bh:b.height};
  });assert(g.w>=.15&&g.w<.18&&g.h>=32/720&&g.h<.08);assert(Math.abs(g.bw/g.bh-16/9)<.01);
  await hdmi.setViewportSize({width:800,height:950});await hdmi.waitForTimeout(100);
  assert(await hdmi.evaluate(()=>{const p=document.getElementById('outputPicture').getBoundingClientRect();return Math.abs(p.width/p.height-16/9)<.01;}));
  state.hardware.mode=0;await hdmi.waitForFunction(()=>document.getElementById('markerCover').hidden);
  state.hardware.mode=2;await hdmi.waitForFunction(()=>!document.getElementById('markerCover').hidden);
  const p=await point(overview,120,150);await overview.mouse.click(...p);await page.waitForFunction(()=>nativeState.tracking.selected_id===1);
  assert.deepEqual(selects,[1]);assert.equal(uploads,0);
  await hdmi.click('#fullscreen');await hdmi.waitForFunction(()=>!!document.fullscreenElement);await hdmi.click('#fullscreen');
  await hdmi.locator('#layout').selectOption('combined');assert(await hdmi.locator('#overviewPane').isVisible());
  const count=context.pages().length;await page.click('#displayHdmi');await hdmi.waitForFunction(()=>document.body.dataset.layout==='hdmi');assert.equal(context.pages().length,count);
  await hdmi.setViewportSize({width:1440,height:900});
  await hdmi.evaluate(()=>document.getElementById('title').textContent='扩展屏界面验证（模拟画面）');
  await hdmi.screenshot({path:path.join(__dirname,'../external_display_preview.png')});
  await overview.close();assert(await page.locator('#controlsOnly').isChecked());
  await hdmi.close();await page.waitForFunction(()=>!document.getElementById('controlsOnly').checked);
  assert(await page.locator('#monitorBoard').isVisible());assert(await page.evaluate(()=>trackingIsActive()));
  assert.equal(actions.filter(a=>a.action==='tracking_stop').length,0,'Closing viewers must not stop follow');
  await page.click('#trackingStop');await page.waitForFunction(()=>!trackingIsActive());
  // A canvas stream is a test fixture, never a new physical capture.
  await page.evaluate(async()=>{
   const c=document.createElement('canvas');c.width=1280;c.height=720;c.getContext('2d').drawImage(personPreview,0,0,1280,720);
   const tag=Uint8Array.from([0xa5,1,42,0,0,0,100,0,0,0,0,0]);let crc=0;
   for(const v of tag.slice(0,10)){crc^=v;for(let j=0;j<8;j++)crc=crc&128?((crc<<1)^7)&255:(crc<<1)&255;}tag[10]=crc;tag[11]=(~crc)&255;
   const cx=c.getContext('2d');for(let bit=0;bit<96;bit++){cx.fillStyle=tag[bit>>3]&(1<<(bit&7))?'white':'black';cx.fillRect(1088+(bit%24)*8,Math.floor(bit/24)*8,8,8);}
   window.__sourceCanvas=c;stream=c.captureStream(30);const v=document.getElementById('video');v.srcObject=stream;await v.play();v.style.display='block';
   window.__sourceTimer=setInterval(()=>{const x=c.getContext('2d');x.fillStyle='#597a80';x.fillRect(0,50,5,5);},33);
  });
  const mirror=await popup(page,'#displayHdmi');await mirror.waitForFunction(()=>document.getElementById('outputVideo').videoWidth===1280&&!document.getElementById('outputVideo').paused);
  assert(await mirror.evaluate(()=>document.getElementById('outputVideo').srcObject===window.opener.document.getElementById('video').srcObject));
  await mirror.close();assert.equal(await page.evaluate(()=>stream.getVideoTracks()[0].readyState),'live');
  // Legacy internal floats continue to work, while popup actions dock them.
  await page.click('#floatBoth');assert.equal(await page.locator('.floating-panel').count(),2);
  const fromFloat=await popup(page,'#displayHdmi');assert.equal(await page.locator('.floating-panel').count(),1);
  await page.locator('#controlsOnly').check();assert.equal(await page.locator('.floating-panel').count(),0);
  await fromFloat.close();await page.waitForFunction(()=>!document.getElementById('controlsOnly').checked);
  // Generic drag forwarding is independent of hidden master DOM positions.
  await page.selectOption('#trackingBackend','object');await page.waitForFunction(()=>!document.getElementById('trackingStart').disabled);
  await page.click('#trackingStart');await page.waitForFunction(()=>!!trackingSnapshot);
  const generic=await popup(page,'#displayOverview');await page.locator('#controlsOnly').check();
  const a=await point(generic,90,90),b=await point(generic,210,240);
  await generic.mouse.move(...a);await generic.mouse.down();await generic.mouse.move(...b,{steps:4});await generic.mouse.up();
  await page.waitForFunction(()=>nativeState.tracking.state==='following');assert(rois.length===1);
  await generic.close();await page.click('#trackingStop');await page.waitForFunction(()=>!document.getElementById('controlsOnly').checked);
  await page.evaluate(()=>{window.__savedOpen=window.open;window.open=()=>null;});
  await page.click('#displayHdmi');assert((await page.locator('#displayMessage').textContent()).includes('拦截'));assert(!(await page.locator('#controlsOnly').isChecked()));
  await page.evaluate(()=>{window.open=window.__savedOpen;clearInterval(window.__sourceTimer);stream.getTracks().forEach(t=>t.stop());});
  mediaCalls=await page.evaluate(()=>window.__captureCalls);assert.equal(mediaCalls,0);assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(__dirname,'../external_test_report.json'),JSON.stringify({passed:true,hardware_verified:false,multi_monitor_drag_manually_verified:false,extra_getUserMedia_calls:mediaCalls,errors,
   checks:['separate named native browser popups for two views','controls-only page with no internal float conflict','full-frame source unchanged','display-only marker cover follows 16:9 picture after resize','RAW mode has no cover','person selection in viewer','named window reuse','fullscreen','combined viewer option','last viewer close restores main views without stopping follow','same browser MediaStream and live track after viewer closes','internal floats retained','generic ROI forwarding','popup blocker guidance']},null,2));
  console.log('PASS F4 external viewers and source preservation (simulated source, no physical capture)');
 }finally{await context.close();await browser.close();await new Promise(r=>server.close(r));}
})().catch(e=>{console.error(e);process.exit(1);});
