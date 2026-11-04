const {chromium}=require('C:/Users/hwx/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const assert=require('node:assert/strict'),http=require('node:http'),fs=require('node:fs'),path=require('node:path');
(async()=>{
 const state={available:true,connected:true,online:true,imu_online:true,bias_ready:true,axis_calibrated:true,reference_ready:true,saved_calibration:true,
  mode:'roll',zoom:1,offset_us:0,raw:[0,2000,0,0,0,0],hardware:{view:6,mode:2,sequence:0,valid:true,test:false,tracking_capable:true,all_views_capable:true},
  auto_alignment:{state:'idle'},tracking:{kind:'person',state:'idle',token:1,note:'已停止',processed:0},diagnostics:{},error:''};
 const errors=[],actions=[],selects=[];let uploads=0;
 const preview=fs.readFileSync(path.join(__dirname,'../verification_tracking/person_preview_fixture.jpg'));
 const tag=Uint8Array.from([0xa5,1,42,0,0,0,100,0,0,0,0,0]);let crc=0;
 for(const v of tag.slice(0,10)){crc^=v;for(let j=0;j<8;j++)crc=crc&128?((crc<<1)^7)&255:(crc<<1)&255;}tag[10]=crc;tag[11]=(~crc)&255;
 const taggedPreview=Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="720"><image href="data:image/jpeg;base64,${preview.toString('base64')}" width="1280" height="720"/>${Array.from({length:96},(_,bit)=>`<rect x="${1088+(bit%24)*8}" y="${Math.floor(bit/24)*8}" width="8" height="8" fill="${tag[bit>>3]&(1<<(bit&7))?'white':'black'}"/>`).join('')}</svg>`);
 const server=http.createServer(async(req,res)=>{
  res.setHeader('Cache-Control','no-store');
  if(req.url.startsWith('/api/person/preview.jpg')){res.setHeader('Content-Type','image/svg+xml');return res.end(taggedPreview);}
  if(req.url.startsWith('/api/')){
   res.setHeader('Content-Type','application/json');let body='';for await(const c of req)body+=c;const data=body?JSON.parse(body):{};
   if(req.url==='/api/ports')return res.end('[]');
   if(req.url==='/api/person/devices')return res.end(JSON.stringify([{index:1,name:'USB Video'}]));
   if(req.url==='/api/action'){
    actions.push(data);
    if(data.action==='tracking_start')state.tracking={kind:'person',state:'waiting',phase:'waiting',token:state.tracking.token+1,owner_client:data.client_id,note:'点击人物选择。',preview_available:true,
     processed:12,people:[{id:1,bbox:[80,80,80,180]},{id:2,bbox:[400,80,80,180]}],selected_id:null,worker_ready:true,hfov:100,model:{provider:'DmlExecutionProvider',model_bytes:10634838},tracking_fps:30};
    if(data.action==='tracking_stop')Object.assign(state.tracking,{state:'idle',phase:'idle',token:state.tracking.token+1,owner_client:'',note:'已停止'});
   }
   if(req.url==='/api/person/select'){selects.push(data.id);Object.assign(state.tracking,{state:'following',phase:'following',selected_id:data.id,bbox:[80,80,80,180],note:'正在跟随。'});}
   if(req.url==='/api/tracking/frame')uploads++;
   return res.end(JSON.stringify(state));
  }
  const file=path.join(__dirname,'dist',req.url==='/'?'index.html':req.url.split('?')[0]);
  try{res.setHeader('Content-Type',file.endsWith('.js')?'text/javascript':file.endsWith('.css')?'text/css':'text/html');res.end(fs.readFileSync(file));}catch{res.statusCode=404;res.end();}
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const browser=await chromium.launch({headless:true,executablePath:'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'});
 try{
  const context=await browser.newContext({viewport:{width:1440,height:1000}}),page=await context.newPage();
  page.on('pageerror',e=>errors.push(e.message));
  await page.addInitScript(()=>{window.__openCalls=0;window.open=()=>{window.__openCalls++;throw Error('Floating panels must stay in the page');};});
  await page.goto(`http://localhost:${server.address().port}/`);await page.waitForFunction(()=>!document.getElementById('trackingStart').disabled);
  assert((await page.locator('#uiRevision').textContent()).includes('F4'));assert.equal(await page.locator('#displayCombined').count(),0);
  await page.click('#trackingStart');await page.waitForFunction(()=>!document.getElementById('personVideo').hidden);
  const identities=await page.evaluate(()=>{window.__originalVideo=document.getElementById('video');window.__originalImage=document.getElementById('personVideo');window.__originalOverview=document.getElementById('trackingOverview');return true;});
  const sourceTag=await page.evaluate(()=>{const c=document.createElement('canvas');c.width=1280;c.height=720;const ctx=c.getContext('2d');ctx.drawImage(personPreview,0,0);return trackingMarker(ctx);});
  assert(sourceTag,'Original source still needs its valid time marker');
  await page.click('#floatOverview');assert.equal(await page.locator('.floating-panel').count(),1);
  await page.click('#floatOutput');assert.equal(await page.locator('.floating-panel').count(),2);assert.equal(context.pages().length,1);
  assert(await page.evaluate(()=>document.getElementById('video')===window.__originalVideo&&document.getElementById('personVideo')===window.__originalImage&&document.getElementById('trackingOverview')===window.__originalOverview));
  const before=await page.locator('#overviewPanel').boundingBox();
  await page.mouse.move(before.x+22,before.y+22);await page.mouse.down();await page.mouse.move(before.x+92,before.y+62,{steps:5});await page.mouse.up();
  const moved=await page.locator('#overviewPanel').boundingBox();assert(moved.x>before.x+60&&moved.y>before.y+30);
  const handle=await page.locator('#overviewPanel .float-resize-handle').boundingBox();
  await page.mouse.move(handle.x+10,handle.y+10);await page.mouse.down();await page.mouse.move(handle.x+110,handle.y+90,{steps:5});await page.mouse.up();
  const resized=await page.locator('#overviewPanel').boundingBox();assert(resized.width>moved.width+90&&resized.height>moved.height+70);
  const canvas=await page.locator('#trackingOverview').boundingBox();
  await page.mouse.click(canvas.x+120*canvas.width/640,canvas.y+150*canvas.height/360);
  await page.waitForFunction(()=>nativeState.tracking.selected_id===1);assert.deepEqual(selects,[1]);
  await page.locator('[data-float-maximize="overview"]').click();assert((await page.locator('#overviewPanel').boundingBox()).width>1400);
  await page.locator('[data-float-maximize="overview"]').click();
  assert(Math.abs((await page.locator('#overviewPanel').boundingBox()).width-resized.width)<2);
  await page.waitForFunction(()=>!document.getElementById('frameMarkerCover').hidden);
  const geometry=await page.evaluate(()=>{const a=document.getElementById('frameMarkerCover').getBoundingClientRect(),b=document.querySelector('#outputPanel .video-wrap').getBoundingClientRect();return {width:a.width/b.width,height:a.height/b.height,right:a.right-b.right,background:getComputedStyle(document.getElementById('frameMarkerCover')).backgroundColor};});
  assert(geometry.width>=.15&&geometry.width<.18&&geometry.height>=32/720&&geometry.height<.08&&Math.abs(geometry.right)<3);assert.equal(geometry.background,'rgb(0, 0, 0)');
  const tagAfter=await page.evaluate(()=>{const c=document.createElement('canvas');c.width=1280;c.height=720;const ctx=c.getContext('2d');ctx.drawImage(personPreview,0,0);return trackingMarker(ctx);});
  assert.deepEqual(tagAfter,sourceTag,'Display cover must never alter source or timing decoder');
  // Raw/full-screen modes must not have an unnecessary covered image corner.
  state.hardware.mode=0;await page.waitForFunction(()=>document.getElementById('frameMarkerCover').hidden);
  state.hardware.mode=2;await page.waitForFunction(()=>!document.getElementById('frameMarkerCover').hidden);
  await page.keyboard.press('Escape');assert.equal(await page.locator('.floating-panel').count(),0);
  await page.locator('#controlsOnly').check();assert.equal(await page.locator('.floating-panel').count(),2);assert(!(await page.locator('#monitorBoard').isVisible()));
  assert(await page.locator('#overviewPanel').isVisible());assert(await page.locator('#outputPanel').isVisible());
  await page.locator('#overviewPanel .float-drag-handle').dblclick({position:{x:10,y:14}});
  await page.evaluate(()=>{document.querySelector('header .brand span').textContent='网页浮窗界面验证（模拟画面）';});
  await page.screenshot({path:path.join(__dirname,'../floating_panels_preview.png')});
  await page.keyboard.press('Escape');assert(!(await page.locator('#controlsOnly').isChecked()));
  assert.equal(await page.locator('#monitorBoard #trackingOverview').count(),1);assert.equal(await page.locator('#monitorBoard #video').count(),1);
  await page.locator('#trackingStop').click();await page.waitForFunction(()=>!trackingIsActive());
  assert.equal(uploads,0);assert.equal(await page.evaluate(()=>window.__openCalls),0);assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(__dirname,'../floating_test_report.json'),JSON.stringify({passed:true,hardware_verified:false,popup_calls:0,extra_capture_calls:0,source_marker_unchanged:true,errors,
   checks:['visible F3 revision','each panel independently floats','in-page dragging','resizing preserves selection coordinates','target selection after resize','maximize and restore','display-only marker cover','underlying frame marker still decodes','no cover in raw mode','controls-only keeps floats visible','Escape and dock restore original DOM','same video/image/canvas objects','no new windows or browser frame uploads']},null,2));
  console.log('PASS internal floating panels, selection, display-only marker cover and source preservation');
 }finally{await browser.close();await new Promise(r=>server.close(r));}
})().catch(e=>{console.error(e);process.exit(1);});
