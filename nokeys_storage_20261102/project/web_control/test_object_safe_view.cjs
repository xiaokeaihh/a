const {chromium}=require('C:/Users/hwx/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const assert=require('node:assert/strict'),http=require('node:http'),fs=require('node:fs'),path=require('node:path');
(async()=>{
 const state={available:true,connected:true,online:true,imu_online:true,bias_ready:true,axis_calibrated:true,axis_collecting:false,reference_ready:true,saved_calibration:true,enabled:false,mode:'roll',zoom:1,offset_us:0,frames_sent:0,samples:1000,sample_loss:0,crc_errors:0,raw:[0,-2048,0,0,0,0],pose:{roll:0,pitch:0},hardware:{view:6,mode:0,sequence:0,valid:true,test:false,tracking_capable:false,all_views_capable:true},auto_alignment:{state:'idle'},tracking:{state:'idle',token:0,note:'等待进入跟随',processed:0},error:''};
 let uploads=0,inflight=0,maxInflight=0,lastROI=null;
 const actions=[],errors=[];
 const server=http.createServer(async(req,res)=>{
  res.setHeader('Cache-Control','no-store');
  if(req.url.startsWith('/api/')){
   res.setHeader('Content-Type','application/json');let body='';for await(const chunk of req)body+=chunk;const data=body?JSON.parse(body):{};
   if(req.url==='/api/ports')return res.end('[]');
   if(req.url==='/api/action'){
    actions.push(data.action);
    if(data.action==='tracking_start'){state.tracking={state:'waiting',token:state.tracking.token+1,owner_client:data.client_id,note:'请框选目标',processed:0};Object.assign(state.hardware,{mode:2,view:6,stabilized:true});state.enabled=true;}
    if(data.action==='tracking_stop')Object.assign(state.tracking,{state:'idle',token:state.tracking.token+1,bbox:null,note:'已停止'});
   }
   if(req.url==='/api/tracking/frame'){
    uploads++;inflight++;maxInflight=Math.max(inflight,maxInflight);
    assert(data.jpeg.length>1000);assert(Number.isInteger(data.frame_id));assert(Number.isInteger(data.capture_tick));
    if(data.roi){lastROI=data.roi;Object.assign(state.tracking,{state:'following',bbox:data.roi,note:'正在平滑跟随',score:.9});}
    state.tracking.processed++;Object.assign(state.tracking,{source_frame:data.frame_id,hfov:100,compute_ms:18});
    await new Promise(r=>setTimeout(r,130));inflight--;return res.end(JSON.stringify(state.tracking));
   }
   return res.end(JSON.stringify(state));
  }
  const file=path.join(__dirname,'dist',req.url==='/'?'index.html':req.url.split('?')[0]);
  try{res.setHeader('Content-Type',file.endsWith('.js')?'text/javascript':file.endsWith('.css')?'text/css':'text/html');res.end(fs.readFileSync(file));}catch{res.statusCode=404;res.end();}
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const browser=await chromium.launch({headless:true,executablePath:'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',args:['--autoplay-policy=no-user-gesture-required']});
 try{
  const page=await browser.newPage({viewport:{width:1300,height:1100}});page.on('pageerror',e=>errors.push(e.message));
  await page.goto(`http://localhost:${server.address().port}/`);await page.waitForFunction(()=>nativeState?.connected);
  await page.selectOption('#trackingBackend','object');
  await page.waitForFunction(()=>document.getElementById('trackingState').textContent.includes('demo_trim.sbit'));
  assert(await page.locator('#trackingStart').isDisabled());
  await page.evaluate(async()=>{
   const c=document.createElement('canvas');c.width=1280;c.height=720;window.fixture=c;window.fixtureFrame=1;window.fixtureCorrupt=false;
   const draw=()=>{
    const ctx=c.getContext('2d');ctx.fillStyle='#162638';ctx.fillRect(0,0,1280,720);ctx.fillStyle='#409572';ctx.fillRect(140,270,100,80);
    ctx.fillStyle='#66aac8';ctx.fillRect(820,270,160,160);const b=new Uint8Array(12);b[0]=165;b[1]=1;
    const d=new DataView(b.buffer);d.setUint32(2,fixtureFrame,true);d.setUint32(6,fixtureFrame*3333,true);let crc=0;
    for(const v of b.slice(0,10)){crc^=v;for(let i=0;i<8;i++)crc=crc&128?((crc<<1)^7)&255:(crc<<1)&255;}b[10]=crc;b[11]=crc^255;
    for(let i=0;i<96;i++){ctx.fillStyle=!fixtureCorrupt&&b[i>>3]&(1<<(i&7))?'white':'black';ctx.fillRect(1088+(i%24)*8,Math.floor(i/24)*8,8,8);}
   };
   draw();window.fixtureTimer=setInterval(()=>{fixtureFrame++;draw();},33);stream=c.captureStream(30);$('video').srcObject=stream;await $('video').play();$('video').style.display='block';
  });
  state.hardware.tracking_capable=true;await page.waitForFunction(()=>!document.getElementById('trackingStart').disabled);
  // A second controller page without HDMI must not stop the capture page.
  const observer=await browser.newPage();observer.on('pageerror',e=>errors.push(e.message));
  await observer.goto(`http://localhost:${server.address().port}/`);await observer.waitForFunction(()=>nativeState?.connected);
  await page.click('#trackingStart');await page.waitForFunction(()=>document.getElementById('trackingCapture').textContent.includes('校验通过'));
  await page.waitForTimeout(700);assert.equal(state.tracking.state,'waiting','Observer without video stopped the active page');
  await observer.waitForFunction(()=>document.getElementById('trackingState').textContent.includes('另一页面'));
  assert(await observer.locator('#trackingReselect').isDisabled());
  const beforeBufferStops=actions.filter(a=>a==='tracking_stop').length;
  await page.evaluate(()=>Object.defineProperty($('video'),'readyState',{configurable:true,get:()=>1}));
  await page.waitForTimeout(700);assert.equal(state.tracking.state,'waiting','Transient buffering stopped the owner');
  assert.equal(actions.filter(a=>a==='tracking_stop').length,beforeBufferStops);
  await page.evaluate(()=>delete $('video').readyState);
  await page.locator('#trackingOverview').scrollIntoViewIfNeeded();
  await page.waitForFunction(()=>trackingBusy);const rect=await page.locator('#trackingOverview').boundingBox();
  await page.mouse.move(rect.x+160*rect.width/640,rect.y+100*rect.height/360);await page.mouse.down();
  await page.mouse.move(rect.x+260*rect.width/640,rect.y+180*rect.height/360,{steps:5});await page.mouse.up();
  await page.waitForFunction(()=>nativeState.tracking.state==='following');assert(lastROI);assert(Math.abs(lastROI[0]-160)<=1);assert(Math.abs(lastROI[1]-100)<=1);assert(Math.abs(lastROI[2]-100)<=1);
  assert(await page.locator('#autoStart').isDisabled());assert(await page.locator('#stableReference').isDisabled());
  Object.assign(state.tracking,{view_clamped:true,hfov:80});
  await page.waitForFunction(()=>document.getElementById('personBoundary').textContent.includes('允许物体偏离中心'));
  assert((await page.locator('#trackingMetrics').textContent()).includes('80°'));
  assert(!(await page.locator('#personBoundary').textContent()).includes('人物'));
  Object.assign(state.tracking,{view_clamped:false,hfov:100});
  await page.waitForFunction(()=>document.getElementById('personBoundary').textContent==='');
  const beforePausedUploads=uploads;
  Object.assign(state.tracking,{timing_wait:true,note:'画面或跟踪延迟约720ms，暂停目标跟随，等待新帧自动恢复。',result_age_ms:720});
  await page.waitForFunction(()=>document.getElementById('trackingState').textContent.includes('等待新帧自动恢复'));
  await page.waitForTimeout(350);assert(uploads>beforePausedUploads,'Paused timing must keep sending fresh frames');
  assert.equal(state.tracking.state,'following');
  Object.assign(state.tracking,{timing_wait:false,note:'正在平滑跟随'});
  await page.waitForFunction(()=>document.getElementById('activeView').textContent.includes('100°虚拟视角'));
  await page.screenshot({path:path.join(__dirname,'../verification_tracking/object_safe_view_web.png'),fullPage:true});
  Object.assign(state.tracking,{state:'lost',bbox:null,note:'目标丢失，请重新框选'});await page.waitForFunction(()=>document.getElementById('trackingState').textContent.includes('目标丢失'));
  await page.evaluate(()=>window.fixtureCorrupt=true);await page.waitForFunction(()=>document.getElementById('trackingCapture').textContent.includes('等待有效视频帧标记'));
  const before=uploads;await page.waitForTimeout(350);assert(uploads<=before+1);
  await page.click('#trackingStop');await page.waitForFunction(()=>!document.getElementById('trackingStart').disabled);
  await page.evaluate(()=>window.fixtureCorrupt=false);await page.click('#trackingStart');
  await page.waitForFunction(()=>['waiting','following'].includes(nativeState.tracking.state));
  await page.evaluate(()=>{stream.getTracks().forEach(t=>t.stop());stream=null;});
  await page.waitForFunction(()=>nativeState.tracking.state==='idle');assert.equal(maxInflight,1);assert.deepEqual(errors,[]);
  await observer.close();
  fs.writeFileSync(path.join(__dirname,'../verification_tracking/object_safe_view_web.json'),JSON.stringify({passed:true,hardware_validated:false,checks:['old firmware gated','true canvas video frame stamp decode','640x360 raw pane crop','CSS-scaled pointer ROI','one HTTP frame in flight','observer without HDMI does not stop owner','temporary decoder buffering does not stop owner','timing pause keeps fresh frame transfer and resumes','owner video stop cancels follow','IMU calibration controls protected during follow','object edge constraint and live 80-degree FOV', 'boundary clears on recovery', 'loss hint','invalid CRC not uploaded','no page errors'],uploads,maxInflight},null,2));
  console.log('PASS object-safe-view web flow and bounded frame transfer (simulated video)');
 }finally{await browser.close();await new Promise(r=>server.close(r));}
})().catch(e=>{console.error(e);process.exit(1);});
