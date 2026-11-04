const {chromium}=require('C:/Users/hwx/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const assert=require('node:assert/strict'),http=require('node:http'),fs=require('node:fs'),path=require('node:path');
(async()=>{
 const state={available:true,connected:true,online:true,imu_online:true,bias_ready:true,axis_calibrated:true,reference_ready:true,saved_calibration:true,
  mode:'roll',zoom:1,offset_us:0,raw:[0,2000,0,0,0,0],hardware:{view:6,mode:2,sequence:0,valid:true,test:false,tracking_capable:true,all_views_capable:true},
  auto_alignment:{state:'idle'},tracking:{kind:'person',state:'idle',token:1,note:'人的跟随已停止。',processed:0},diagnostics:{},error:''};
 const errors=[],actions=[],selects=[],rois=[];let uploads=0,mediaCalls=0;
 const preview=fs.readFileSync(path.join(__dirname,'../verification_tracking/person_preview_fixture.jpg'));
 const frames=fs.readdirSync(path.join(__dirname,'../verification_tracking/jpeg_frames')).sort().map(f=>fs.readFileSync(path.join(__dirname,'../verification_tracking/jpeg_frames',f)));let connections=0;const started=Date.now();
 const server=http.createServer(async(req,res)=>{
  res.setHeader('Cache-Control','no-store');
  if(req.url.startsWith('/api/person/preview.mjpg')){
   connections++;res.writeHead(200,{'Content-Type':'multipart/x-mixed-replace; boundary=wycframe'});let last=-1;const timer=setInterval(()=>{const id=Math.floor((Date.now()-started)*30/1000);if(id===last)return;last=id;const body=frames[id%frames.length];res.write(Buffer.concat([Buffer.from('--wycframe\r\nContent-Type: image/jpeg\r\nContent-Length: '+body.length+'\r\n\r\n'),body,Buffer.from('\r\n')]));},3);res.on('close',()=>{connections--;clearInterval(timer);});return;
  }
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
  assert((await page.locator('#uiRevision').textContent()).includes('F5'));
  await page.click('#trackingStart');await page.waitForFunction(()=>window.wycPersonPreview.stats().frames>=45);
  const first=await page.evaluate(()=>window.wycPersonPreview.stats());assert(first.fps>=26&&first.fps<=33,JSON.stringify(first));
  assert.equal(connections,1,'The main view uses one continuous connection');
  await page.click('#floatBoth');assert.equal(await page.locator('.floating-panel').count(),2);
  const mainImage=await page.evaluate(()=>{const c=document.createElement('canvas');c.width=1280;c.height=720;c.getContext('2d').drawImage(personPreview,0,0);return trackingMarker(c.getContext('2d'));});
  assert(mainImage,'MJPEG source must preserve synchronization pixels');
  await page.keyboard.press('Escape');
  const overview=await popup(page,'#displayOverview'),hdmi=await popup(page,'#displayHdmi');
  await hdmi.waitForFunction(()=>document.getElementById('outputPreview').naturalWidth===1280);
  await overview.waitForFunction(()=>document.getElementById('overviewPreview').naturalWidth===1280);
  await page.locator('#controlsOnly').check();assert.equal(await page.locator('.floating-panel').count(),0);
  assert(!(await page.locator('#monitorBoard').isVisible()));
  assert(await page.evaluate(()=>{
   const before=personPreviewKey;Object.defineProperty(document,'hidden',{configurable:true,get:()=>true});
   personPreviewLast=performance.now()-6000;personPreviewTick();const preserved=personPreviewKey===before;
   delete document.hidden;document.dispatchEvent(new Event('visibilitychange'));return preserved;
  }),'Background control-page repaint throttling must not restart live viewers');
  // A visible external window reads MJPEG directly, not parent-page repainting.
  await hdmi.bringToFront();
  const external=await hdmi.evaluate(async()=>{
   const image=document.getElementById('outputPreview'),canvas=document.createElement('canvas');canvas.width=1280;canvas.height=720;const ctx=canvas.getContext('2d');
   let last=null,times=[];const end=performance.now()+2000;
   await new Promise(resolve=>{function tick(){ctx.drawImage(image,0,0);const tag=window.opener.trackingMarker(ctx),now=performance.now();if(tag&&tag.frame_id!==last){last=tag.frame_id;times.push(now);}if(now<end)requestAnimationFrame(tick);else resolve();}tick();});
   return {frames:times.length,fps:(times.length-1)*1000/(times.at(-1)-times[0])};
  });assert(external.fps>=26&&external.fps<=33,JSON.stringify(external));
  assert(!(await hdmi.locator('#markerCover').isHidden()));
  const p=await point(overview,120,150);await overview.mouse.click(...p);await page.waitForFunction(()=>nativeState.tracking.selected_id===1);assert.deepEqual(selects,[1]);
  await hdmi.locator('#layout').selectOption('combined');assert(await hdmi.locator('#overviewPane').isVisible());
  await hdmi.click('#fullscreen');await hdmi.waitForFunction(()=>!!document.fullscreenElement);await hdmi.click('#fullscreen');
  await hdmi.evaluate(()=>document.getElementById('title').textContent='30fps扩展屏验证（模拟视频）');
  await hdmi.screenshot({path:path.join(__dirname,'../live30_preview.png')});
  await overview.close();await hdmi.close();await page.waitForFunction(()=>!document.getElementById('controlsOnly').checked);
  assert.equal(actions.filter(a=>a.action==='tracking_stop').length,0);
  await page.bringToFront();await page.click('#trackingStop');await page.waitForFunction(()=>!trackingIsActive());
  await page.waitForTimeout(1200);assert.equal(connections,0,'Stopping follow must close every preview stream');
  assert.equal(await page.evaluate(()=>window.__captureCalls),0);assert.equal(uploads,0);assert.deepEqual(errors,[]);
  const report={passed:true,physical_capture:false,main_unique_fps:first.fps,external_unique_fps:external.fps,
   extra_camera_calls:0,browser_frame_uploads:uploads,source_marker_preserved:true,errors,
   checks:['continuous MJPEG playback','unique source frame measurement','in-page floats with live source','independent external video streams','controls-only main page','external total-overview person selection','marker hidden only in display','combined viewer and fullscreen','closing viewers does not stop tracking','stopping follow closes all video streams']};
  fs.writeFileSync(path.join(__dirname,'../browser_test_report.json'),JSON.stringify(report,null,2));
  console.log(JSON.stringify(report));
 }finally{await context.close();await browser.close();await new Promise(r=>server.close(r));}
})().catch(e=>{console.error(e);process.exit(1);});
