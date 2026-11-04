const {chromium}=require('C:/Users/hwx/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const {spawn}=require('node:child_process'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
(async()=>{
 const root=path.resolve(__dirname,'..'),port=8895,base=`http://127.0.0.1:${port}`;
 const log=fs.openSync(path.join(root,'verification_smart_follow/web_server.log'),'w');
 const server=spawn('D:/python prince/python.exe',['-X','utf8','-B',path.join(root,'stabilization_tools/server.py'),'--no-browser','--port',String(port)],{cwd:root,windowsHide:true,stdio:['ignore',log,log]});
 let browser;
 try{
  for(let i=0;i<50;i++){try{if((await fetch(base+'/api/status')).ok)break;}catch{}await new Promise(r=>setTimeout(r,150));}
  const state={available:true,connected:true,online:true,imu_online:true,bias_ready:true,axis_calibrated:true,axis_collecting:false,axis_progress:{samples:0},reference_ready:true,reference_source:'saved',saved_calibration:true,enabled:true,mode:'roll',zoom:1,offset_us:0,image_y_sign:1,frames_sent:5,samples:1000,sample_loss:0,crc_errors:0,raw:[0,2048,0,0,0,0],pose:{roll:12.3,pitch:-4.5},attitude:{roll:12.3,pitch:-4.5,yaw:26.7},hardware:{view:6,mode:2,sequence:1,valid:true,test:false,tracking_capable:true,compact_pose_capable:true,stabilized:true,dropped:0},auto_alignment:{state:'idle'},imu_health:{resumes:0},tracking:{kind:'object',state:'idle',token:1,processed:0,composition:{enabled:true}},image_controls:{version:3,gamma_exposure_linked:true,white_balance_supported:true,high_exposure_supported:true,supported:true,attitude_supported:false,fresh:true,requested:{gamma:true,auto_exposure:true,sharpen:false,high_exposure:false,auto_white_balance:true},applied:{gamma:true,auto_exposure:true,sharpen:false,high_exposure:false,auto_white_balance:true},busy:false,error:false},diagnostics:{},error:''};
  let acknowledge=true,reject=false;const actions=[],errors=[];
  browser=await chromium.launch({headless:true,executablePath:'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',args:['--autoplay-policy=no-user-gesture-required']});
  const page=await browser.newPage({viewport:{width:1480,height:1100}});page.on('pageerror',e=>errors.push(e.message));
  await page.route('**/api/status',route=>route.fulfill({json:state}));
  await page.route('**/api/ports',route=>route.fulfill({json:[]}));
  await page.route('**/api/person/devices',route=>route.fulfill({json:[{index:1,name:'USB Video'}]}));
  await page.route('**/api/action',async route=>{
   const data=route.request().postDataJSON();actions.push(data);
   if(data.action==='image_control'){
    if(reject){await route.fulfill({status:400,json:{error:'模拟通信失败'}});return;}
    if(acknowledge){
     const c=state.image_controls;c.applied[data.control]=data.enabled;c.requested[data.control]=data.enabled;
     if(data.control==='gamma'||data.control==='high_exposure'){
      c.requested.auto_exposure=c.requested.gamma&&!c.requested.high_exposure;
      if(acknowledge!=='gamma_only')c.applied.auto_exposure=c.requested.auto_exposure;
     }
    }
   }
   if(data.action==='tracking_options')state.tracking.composition.enabled=data.composition;
   await route.fulfill({json:state});
  });
  await page.goto(base);await page.waitForFunction(()=>window.wycWorkflow&&nativeState?.connected);
  await page.selectOption('#trackingBackend','object');
  await page.evaluate(async()=>{
   const c=document.createElement('canvas');c.width=1280;c.height=720;window.fixture=c;window.fixtureFrame=0;
   const draw=()=>{const ctx=c.getContext('2d');ctx.fillStyle='#06101b';ctx.fillRect(0,0,1280,720);ctx.fillStyle='#174d62';ctx.fillRect(0,180,640,360);ctx.fillStyle='#73501c';ctx.fillRect(640,180,640,360);ctx.fillStyle='#fff';ctx.font='38px sans-serif';ctx.fillText('OVERVIEW '+fixtureFrame,40,230);ctx.fillText('FOLLOW '+fixtureFrame,700,230);ctx.fillStyle='#40e7bd';ctx.fillRect(100+fixtureFrame%150,300,80,90);ctx.fillRect(900,290,160,150);fixtureFrame++;};
   draw();window.fixtureTimer=setInterval(draw,33);stream=c.captureStream(30);$('video').srcObject=stream;await $('video').play();$('video').style.display='block';$('emptyVideo').style.display='none';
  });
  await page.waitForFunction(()=>!document.getElementById('recordingStart').disabled);
  await page.waitForFunction(()=>document.getElementById('attitudeOverlay').textContent.includes('26.7'));
  const popupPromise=page.waitForEvent('popup');await page.locator('[data-display-kind="hdmi"]').first().click();const popup=await popupPromise;
  await popup.waitForFunction(()=>document.querySelector('.attitude-overlay')?.textContent.includes('26.7'));
  await popup.close();
  const before=await (await fetch(base+'/api/recordings')).json();
  await page.waitForTimeout(500);assert.equal((await (await fetch(base+'/api/recordings')).json()).length,before.length,'Must not auto-record');
  assert.equal(await page.locator('#controlAutoExposure').count(),0,'Automatic exposure must be merged into Gamma');
  await page.waitForFunction(()=>!document.getElementById('controlGamma').disabled);
  // Curve feedback alone cannot acknowledge the combined control before exposure commits.
  acknowledge='gamma_only';await page.click('#controlGamma');
  await page.waitForFunction(()=>document.getElementById('controlGamma').textContent.includes('切换中'));
  assert(await page.locator('#controlGamma').isDisabled());state.image_controls.applied.auto_exposure=false;acknowledge=true;
  await page.waitForFunction(()=>!document.getElementById('controlGamma').disabled&&document.getElementById('controlGamma').textContent.includes('关闭'));
  await page.click('#controlHighExposure');await page.waitForFunction(()=>document.getElementById('controlHighExposure').textContent.includes('开启'));
  await page.click('#controlGamma');await page.waitForFunction(()=>document.getElementById('controlGamma').textContent.includes('开启'));
  assert(state.image_controls.applied.high_exposure&&!state.image_controls.applied.auto_exposure,'Gamma enabled auto exposure under high lock');
  assert((await page.locator('#highExposureStatus').textContent()).includes('保持暂停'));
  await page.click('#controlGamma');await page.waitForFunction(()=>document.getElementById('controlGamma').textContent.includes('关闭'));
  assert(state.image_controls.applied.high_exposure&&!state.image_controls.applied.auto_exposure);
  await page.click('#controlWhiteBalance');await page.waitForFunction(()=>document.getElementById('controlWhiteBalance').textContent.includes('已锁定'));
  assert(state.image_controls.applied.high_exposure&&!state.image_controls.applied.auto_white_balance);
  await page.click('#controlWhiteBalance');await page.waitForFunction(()=>document.getElementById('controlWhiteBalance').textContent.includes('开启'));
  await page.click('#controlHighExposure');await page.waitForFunction(()=>document.getElementById('controlHighExposure').textContent.includes('关闭'));
  assert(!state.image_controls.applied.auto_exposure,'Gamma off must restore fixed exposure');
  await page.click('#controlGamma');await page.waitForFunction(()=>document.getElementById('controlGamma').textContent.includes('开启'));
  assert(state.image_controls.applied.auto_exposure,'Gamma on must enable auto exposure normally');
  await page.click('#controlHighExposure');await page.waitForFunction(()=>document.getElementById('controlHighExposure').textContent.includes('开启'));
  await page.click('#controlHighExposure');await page.waitForFunction(()=>document.getElementById('controlHighExposure').textContent.includes('关闭'));
  assert(state.image_controls.applied.auto_exposure,'Gamma on must resume auto after leaving high test');
  reject=true;await page.click('#controlHighExposure');await page.waitForFunction(()=>document.getElementById('imageControlsStatus').textContent.includes('模拟通信失败'));reject=false;
  acknowledge=false;await page.click('#controlWhiteBalance');await page.waitForFunction(()=>document.getElementById('imageControlsStatus').textContent.includes('未收到切换完成'),{timeout:8000});acknowledge=true;
  assert(state.image_controls.applied.auto_white_balance,'Unacknowledged AWB change must not show locked');
  state.image_controls.version=1;state.image_controls.gamma_exposure_linked=false;state.image_controls.high_exposure_supported=false;state.image_controls.white_balance_supported=false;
  await page.waitForFunction(()=>document.getElementById('controlGamma').disabled&&document.getElementById('controlHighExposure').disabled&&document.getElementById('controlWhiteBalance').disabled);
  assert(!await page.locator('#controlSharpen').isDisabled());
  state.image_controls.version=3;state.image_controls.gamma_exposure_linked=true;state.image_controls.high_exposure_supported=true;state.image_controls.white_balance_supported=true;
  state.connected=false;await page.waitForFunction(()=>document.getElementById('controlGamma').disabled);state.connected=true;
  await page.waitForFunction(()=>!document.getElementById('controlGamma').disabled);
  await page.click('#controlHighExposure');await page.waitForFunction(()=>document.getElementById('controlHighExposure').textContent.includes('开启'));
  await page.click('#controlWhiteBalance');await page.waitForFunction(()=>document.getElementById('controlWhiteBalance').textContent.includes('已锁定'));
  const panel=page.locator('#imageControlsPanel');await panel.scrollIntoViewIfNeeded();
  await panel.screenshot({path:path.join(root,'verification_high_exposure/high_exposure_panel.png')});
  await page.setViewportSize({width:500,height:1000});await page.waitForTimeout(150);
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
  await panel.scrollIntoViewIfNeeded();await page.screenshot({path:path.join(root,'verification_high_exposure/high_exposure_narrow.png'),fullPage:true});
  await page.setViewportSize({width:1480,height:1100});
  await page.click('#controlHighExposure');await page.waitForFunction(()=>document.getElementById('controlHighExposure').textContent.includes('关闭'));
  await page.click('#controlSharpen');await page.waitForFunction(()=>document.getElementById('controlSharpen').textContent.includes('开启'));
  await page.uncheck('#compositionEnabled');await page.waitForFunction(()=>!document.getElementById('compositionEnabled').checked);
  assert(actions.some(a=>a.action==='tracking_options'&&!a.composition));
  await page.click('#recordingStart');await page.waitForFunction(()=>window.wycWorkflow.recording()?.frames>10);
  await page.waitForTimeout(2200);await page.click('#recordingBookmark');await page.waitForTimeout(1200);
  const running=await page.evaluate(()=>window.wycWorkflow.recording());assert(running.pending_bytes<12*1048576);
  await page.click('#recordingStop');await page.waitForFunction(()=>document.getElementById('recordingState').textContent.includes('录像已保存'),{timeout:20000});
  const rows=await (await fetch(base+'/api/recordings')).json();const row=rows.find(r=>r.id===running.id);
  assert(row);assert.equal(row.state,'ready');assert(row.bytes>1000);assert(row.events.some(e=>e.type==='手动标记'));assert(row.duration>3);
  const range=await fetch(base+'/api/recordings/'+row.id+'/video',{headers:{Range:'bytes=0-99'}});assert.equal(range.status,206);assert.equal((await range.arrayBuffer()).byteLength,100);
  await page.locator('#recordingList button').first().click();await page.waitForFunction(()=>Number.isFinite(document.getElementById('recordingReplay').duration)&&document.getElementById('recordingReplay').duration>2);
  const duration=await page.locator('#recordingReplay').evaluate(v=>v.duration);assert(Math.abs(duration-row.duration)<.1);
  await page.waitForFunction(()=>document.getElementById('recordingReplay').readyState>=2);
  const pixels=await page.locator('#recordingReplay').evaluate(v=>{const c=document.createElement('canvas');c.width=1280;c.height=720;const x=c.getContext('2d');x.drawImage(v,0,0,1280,720);return [Array.from(x.getImageData(40,300,1,1).data),Array.from(x.getImageData(700,300,1,1).data)];});
  assert(pixels[1][0]-pixels[0][0]>50,'Both source views must survive recording and decoding');
  await page.locator('#recordingReplay').evaluate(v=>{v.pause();v.currentTime=1.2;});await page.waitForFunction(()=>Math.abs(document.getElementById('recordingReplay').currentTime-1.2)<.15);
  state.image_controls.supported=false;await page.waitForFunction(()=>document.getElementById('controlGamma').disabled);
  state.image_controls.supported=true;state.enabled=false;await page.waitForFunction(()=>document.getElementById('attitudeOverlay').hidden);
  state.enabled=true;await page.waitForFunction(()=>!document.getElementById('attitudeOverlay').hidden);
  state.hardware.test=true;await page.waitForFunction(()=>document.querySelector('#outputPanel .video-wrap').dataset.crop==='full'&&document.getElementById('attitudeOverlay').hidden);
  state.hardware.test=false;await page.waitForFunction(()=>document.querySelector('#outputPanel .video-wrap').dataset.crop==='right'&&!document.getElementById('attitudeOverlay').hidden);
  await page.locator('#recordingPanel').scrollIntoViewIfNeeded();await page.screenshot({path:path.join(root,'verification_smart_follow/workflow_web.png'),fullPage:true});
  assert.deepEqual(errors,[]);
  fs.writeFileSync(path.join(root,'verification_smart_follow/web_report.json'),JSON.stringify({passed:true,hardware_validated:false,id:row.id,bytes:row.bytes,duration,row_duration:row.duration,render_fps:row.render_fps,checks:['single Gamma toggles curve and AE','Gamma ACK waits for exposure','high lock survives Gamma on and off','independent AWB lock/resume','high exit follows Gamma state','communication failure and ACK timeout','old firmware capability gating','desktop and narrow layout','no recording before manual click','three actual-control API requests','composition toggle','three-angle overlay gating','real MediaRecorder encoder','bounded chunk upload to real Python backend','persistent recording list','manual bookmark','single recording includes both views','finite duration metadata','HTTP range playback','seek','old firmware controls disabled','no JavaScript errors']},null,2));
  console.log('PASS unified Gamma/AE, high exposure lock and AWB; real browser recording, persistence, range playback, seek, overlay and switch controls');
 }finally{if(browser)await browser.close();server.kill();fs.closeSync(log);}
})().catch(e=>{console.error(e);process.exit(1)});
