'use strict';
let trackingBusy=false,trackingControlBusy=false,trackingDragging=null,trackingSnapshot=null,trackingLastFrame=null,trackingLastToken=null;
let trackingQueuedSelection=null;
let trackingHasOverview=false;
const trackingClientId=crypto.randomUUID();
let trackingOwnedToken=null;
const trackingFull=document.createElement('canvas');trackingFull.width=1280;trackingFull.height=720;
const trackingRaw=document.createElement('canvas');trackingRaw.width=640;trackingRaw.height=360;
const trackingFrozen=document.createElement('canvas');trackingFrozen.width=640;trackingFrozen.height=360;
const trackingCanvas=$('trackingOverview'),trackingContext=trackingCanvas.getContext('2d');
let personPreviewBusy=false,personDevicesBusy=false;
const personPreview=$('personVideo');
function personChosen(){return trackingIsActive()?(nativeState.tracking.kind==='person'):$('trackingBackend').value==='person';}
async function personDevices(){
 if(personDevicesBusy)return;personDevicesBusy=true;$('personDevices').disabled=true;
 try{
  const devices=await nativeAPI('person/devices');if(!Array.isArray(devices))throw Error('请重新启动更新后的控制服务。');
  const previous=$('personCamera').value;$('personCamera').replaceChildren(new Option('选择HDMI采集卡',''),...devices.map(d=>new Option(d.name,String(d.index))));
  const selected=devices.find(d=>String(d.index)===previous)||devices.find(d=>/USB Video|HDMI|capture|采集/i.test(d.name));
  if(selected)$('personCamera').value=String(selected.index);
  $('personDeviceHint').textContent=devices.length?`发现${devices.length}个PC采集设备。选择HDMI采集卡；人的推理不经过网页上传。`:'未发现PC视频设备，请检查采集卡USB连接。';
 }catch(e){$('personDeviceHint').textContent=e.message;}
 finally{personDevicesBusy=false;$('personDevices').disabled=false;if(nativeState)updateTargetTracking(nativeState);}
}
let personPreviewKey=null,personPreviewRAF=null,personPreviewRetry=0,personPreviewLast=0,personPreviewFrame=null;
let personPreviewTimes=[],personPreviewFPS=0,personPreviewFrames=0;
function personPreviewStop(){
 if(personPreviewRAF!==null)cancelAnimationFrame(personPreviewRAF);personPreviewRAF=null;
 personPreview.onerror=null;personPreview.onload=null;personPreview.removeAttribute('src');personPreview.hidden=true;
 personPreviewKey=null;personPreviewBusy=false;personPreviewTimes=[];personPreviewFPS=0;personPreviewFrame=null;
}
function personPreviewTick(){
 const t=nativeState?.tracking,active=t?.kind==='person'&&trackingIsActive();
 if(!active){if(personPreviewKey!==null)personPreviewStop();return;}
 if(personPreviewKey!==null&&personPreviewKey!==t.token)personPreviewStop();
 const now=performance.now();
 if(personPreviewKey!==null){
  // A hidden control tab may have its repaint callbacks throttled. The native
  // MJPEG viewers still decode independently, so do not restart their source.
  if(!document.hidden&&now-personPreviewLast>3000){personPreviewStop();personPreviewRetry=now+300;}
  return;
 }
 if(!t.preview_available||now<personPreviewRetry)return;
 personPreviewKey=t.token;personPreviewLast=now;personPreviewFrames=0;personPreviewBusy=true;
 personPreview.onerror=()=>{personPreviewStop();personPreviewRetry=performance.now()+1000;};
 personPreview.src='/api/person/preview.mjpg?token='+t.token+'&v=20261015-unmirror-f7';
 function draw(){
  personPreviewRAF=null;
  if(personPreviewKey===null)return;
  if(!trackingIsActive()||nativeState?.tracking?.kind!=='person'||nativeState.tracking.token!==personPreviewKey){personPreviewStop();return;}
  if(personPreview.naturalWidth===1280&&personPreview.naturalHeight===720){
   try{
    personPreview.hidden=false;$('video').style.display='none';$('emptyVideo').style.display='none';$('stopVideo').disabled=false;
    const ctx=trackingFull.getContext('2d');ctx.drawImage(personPreview,0,0,1280,720);
    const tag=trackingMarker(ctx),time=performance.now();
    if(!tag||tag.frame_id!==personPreviewFrame){
     personPreviewLast=time;
     if(tag){
      personPreviewFrame=tag.frame_id;personPreviewFrames++;personPreviewTimes.push(time);
      while(personPreviewTimes.length>2&&time-personPreviewTimes[0]>2000)personPreviewTimes.shift();
      if(personPreviewTimes.length>1)personPreviewFPS=(personPreviewTimes.length-1)*1000/(time-personPreviewTimes[0]);
     }
     trackingRaw.getContext('2d').drawImage(trackingFull,0,180,640,360,0,0,640,360);trackingHasOverview=true;trackingDraw();
    }
    $('previewState').textContent=tag?`PC直采1280×720 · 实测新画面 ${personPreviewFPS.toFixed(1)} fps · AI独立运行`:'实时预览已连接 · 等待源帧标记';
   }catch{}
  }
  personPreviewRAF=requestAnimationFrame(draw);
 }
 personPreviewRAF=requestAnimationFrame(draw);
}
window.wycPersonPreview={url:()=>personPreviewKey===null?null:personPreview.src,
 stats:()=>({fps:personPreviewFPS,frames:personPreviewFrames,source_frame:personPreviewFrame})};
document.addEventListener('visibilitychange',()=>{personPreviewLast=performance.now();});
function trackingMarker(ctx){
 const image=ctx.getImageData(1088,0,192,32),bytes=new Uint8Array(12);
 for(let bit=0;bit<96;bit++){
  const x=(bit%24)*8+4,y=Math.floor(bit/24)*8+4;let luma=0;
  for(let dy=-1;dy<=1;dy++)for(let dx=-1;dx<=1;dx++){
   const i=((y+dy)*192+x+dx)*4;luma+=image.data[i]+image.data[i+1]+image.data[i+2];
  }
  if(luma>9*3*128)bytes[bit>>3]|=1<<(bit&7);
 }
 let crc=0;for(const value of bytes.slice(0,10)){crc^=value;for(let j=0;j<8;j++)crc=crc&128?((crc<<1)^7)&255:(crc<<1)&255;}
 if(bytes[0]!==0xa5||bytes[1]!==1||bytes[10]!==crc||bytes[11]!==((~crc)&255))return null;
 const d=new DataView(bytes.buffer);return {frame_id:d.getUint32(2,true),capture_tick:d.getUint32(6,true)};
}
function trackingVideoReady(){const v=$('video');return !!stream&&v.videoWidth===1280&&v.videoHeight===720&&v.readyState>=2;}
function trackingIsActive(s=nativeState){return ['waiting','selecting','following','recovering','lost'].includes(s?.tracking?.state);}
function trackingOwnsSession(s=nativeState){return trackingIsActive(s)&&s.tracking.owner_client===trackingClientId&&s.tracking.token===trackingOwnedToken;}
function trackingDraw(){
 if(!trackingHasOverview){
  trackingContext.fillStyle='#211d20';trackingContext.fillRect(0,0,640,360);
  trackingContext.fillStyle='#c7b09a';trackingContext.textAlign='center';trackingContext.font='18px Microsoft YaHei';
  trackingContext.fillText('进入自动跟随后显示总览',320,180);trackingContext.textAlign='start';
  window.wycFloating?.update();window.wycDisplay?.render();return;
 }
 trackingContext.drawImage(trackingDragging?trackingFrozen:trackingRaw,0,0);
 const box=trackingDragging?.box||nativeState?.tracking?.bbox;
 if(box){trackingContext.strokeStyle=trackingDragging||nativeState?.tracking?.timing_wait||(nativeState?.tracking?.kind==='person'&&nativeState.tracking.phase!=='following')?'#ffd36d':'#5df2cb';trackingContext.lineWidth=2;trackingContext.strokeRect(...box);}
 if(nativeState?.tracking?.kind==='person')for(const person of nativeState.tracking.people||[]){
  const selected=person.id===nativeState.tracking.selected_id;trackingContext.strokeStyle=selected?'#5df2cb':'#ffd36d';trackingContext.lineWidth=selected?3:1;
  trackingContext.strokeRect(...person.bbox);trackingContext.font='14px Microsoft YaHei';trackingContext.fillStyle=trackingContext.strokeStyle;
  trackingContext.fillText('人物 '+person.id,person.bbox[0]+3,Math.max(16,person.bbox[1]-5));
 }
 window.wycFloating?.update();window.wycDisplay?.render();
}
function updateTargetTracking(s){
 const t=s.tracking||{},active=trackingIsActive(s),owns=trackingOwnsSession(s),v=trackingVideoReady(),person=active?t.kind==='person':$('trackingBackend').value==='person';
 if(t.token!==trackingLastToken){trackingLastToken=t.token;trackingLastFrame=null;trackingSnapshot=null;trackingDragging=null;trackingQueuedSelection=null;if(active)trackingHasOverview=false;}
 const reason=!s.connected?'先连接开发板串口。':!s.online?'等待开发板显示回报。':!s.hardware?.tracking_capable?'请烧录 fisheye5_720p60_pipeline_demo_trim.sbit，再连接串口。':person?(!$('personCamera').value?'先查找并选择 USB Video 采集卡。':s.hardware?.test?'先返回摄像头图源。':['collecting','solving'].includes(s.auto_alignment?.state)||s.axis_collecting?'先结束安装标定。':''):!v?'先打开1280×720 HDMI采集卡画面。':s.hardware?.test?'先返回摄像头图源。':['collecting','solving'].includes(s.auto_alignment?.state)||s.axis_collecting?'先结束安装标定。':'';
 $('trackingStart').disabled=trackingControlBusy||active||!!reason;
 $('trackingStop').disabled=trackingControlBusy||!active;
 $('trackingReselect').disabled=trackingControlBusy||!owns||(person?!t.worker_ready:!v);
 $('trackingBackend').disabled=active;$('personCamera').disabled=active;$('personCameraLabel').hidden=!person;$('personDevices').hidden=!person;
 $('trackingReselect').textContent=person?'重新选择人物':'重新框选';$('trackingStart').textContent=person?'开启人物跟随':'进入物体跟随';
 $('startVideo').disabled=active&&person;$('listVideo').disabled=active&&person;
 if(!active&&personPreview.src){personPreviewStop();if(!stream){$('emptyVideo').style.display='block';$('previewState').textContent='PC直采已停止 · 采集卡已释放';}$('stopVideo').disabled=!stream;}
 const trackingPoseReady=s.imu_online&&s.bias_ready&&s.reference_ready&&!s.imu_paused;
 $('trackingState').textContent=active?(!trackingPoseReady?'视觉跟随模式：自动跟随继续运行；IMU未在线或安装标定未就绪时，相机转动不会获得姿态稳像补偿。':owns?t.note:'跟随在另一页面运行，本页仅查看状态；更改目标请在启动跟随的页面操作。'):(reason||t.note||'自动跟随无需IMU；无IMU时可进行视觉数字跟随，相机转动稳像需IMU。进入后在总览中框选物体。');
 $('trackingStart').title=reason;
 if(!active)$('trackingCapture').textContent='进入自动跟随后更新实时总览；停止时保留最后一帧。';
 $('trackingMetrics').textContent=t.processed?`处理 ${t.processed}帧 · 计算 ${Number(t.compute_ms).toFixed(1)} ms · 结果距拍摄 ${Number(t.result_age_ms||0).toFixed(0)} ms · 跟随视场 ${t.hfov}°`:'跟踪在电脑上运行；FPGA HDMI 保持720p输出，两侧各640×360。';
 const fields=person?[
  ['人的检测',t.model?.provider==='DmlExecutionProvider'?'RTX显卡 · YOLO11n':t.model?.provider==='CPUExecutionProvider'?'CPU · YOLO11n':'等待加载'],
  ['检测 / 跟踪计算',`${Number(t.inference_ms||0).toFixed(1)} / ${Number(t.tracking_ms||0).toFixed(1)} ms`],
  ['位置更新',`${Number(t.tracking_fps||0).toFixed(1)} fps`],
  ['自动找回人物',`已接续 ${t.reacquire_count||0} 次`],
  ['PC预览推送 / 网页新画面',`${Number(t.preview_fps||0).toFixed(1)} / ${personPreviewFPS.toFixed(1)} fps`],
  ['PC工作集 / 峰值',`${Number(t.process_rss_mib||0).toFixed(0)} / ${Number(t.process_peak_rss_mib||0).toFixed(0)} MiB`],
  ['模型 / 最新帧队列',`${t.model?.model_bytes?(t.model.model_bytes/1048576).toFixed(1):'—'} MiB / 1帧`],
  ['本次新增FPGA帧缓存','0 · 显存暂未测得']]:[
  ['自动找回物体',`已接续 ${t.reacquire_count||0} 次`],
  ['跟踪计算',`${Number(t.compute_ms||0).toFixed(1)} ms`],
  ['最新帧队列','1帧 · 不累积历史画面']];
 $('personMetrics').replaceChildren(...fields.map(([label,value])=>{const box=document.createElement('div'),small=document.createElement('small'),b=document.createElement('b');small.textContent=label;b.textContent=value;box.append(small,b);return box;}));
 $('personBoundary').textContent=t.view_clamped?`目标靠近有效视野边缘：已限制视角，允许${person?'人物':'物体'}偏离中心以减少黑边。`:'';
 if(active){
  $('activeView').textContent=!trackingPoseReady?'视觉跟随 · 无姿态稳像':t.timing_wait?'目标跟随 · 等待新帧':t.state==='following'?`目标跟随 · ${Number(t.hfov||100).toFixed(1)}°虚拟视角`:t.state==='recovering'?'目标遮挡 · 保持视角':t.state==='lost'?'总览对比 · 自动寻找目标':'总览对比 · 等待目标';
  $('commandState').textContent=t.timing_wait?t.note:t.state==='following'?'FPGA正在生成目标跟随视角；切换视图可退出。':['recovering','lost'].includes(t.state)?t.note:person?'检测人物中；多人时首次点击指定目标。':'在总览中框选目标；遮挡后会自动尝试找回。';
  for(const id of ['axisStart','axisFinish','stableReference','stableSettings','autoStart','stableStart'])$(id).disabled=true;
  // A viewer page must never stop another page's global session. Temporary
  // decoder buffering is handled by the source-frame watchdog, not a stop RPC.
  if(!person&&owns&&!stream&&!trackingControlBusy)void trackingAction('tracking_stop','video_closed');
 }
 trackingDraw();
}
async function trackingAction(action,cause='manual'){
 if(trackingControlBusy)return;trackingControlBusy=true;
 try{
  const v=$('video');
  const backend=$('trackingBackend').value;
  if(action==='tracking_start'&&backend==='person')await stopVideo();
  nativeState=await nativeAPI('action',{action,backend,camera:Number($('personCamera').value),client_id:trackingClientId,token:nativeState?.tracking?.token,cause,video_width:v.videoWidth,video_height:v.videoHeight});
  if(action==='tracking_start')trackingOwnedToken=nativeState.tracking.token;
  else if(action==='tracking_stop')trackingOwnedToken=null;
  updateTargetTracking(nativeState);
 }catch(e){$('trackingState').textContent=e.message;}
 finally{trackingControlBusy=false;if(nativeState)updateTargetTracking(nativeState);}
}
async function trackingSend(snapshot,roi){
 if(!snapshot||!trackingOwnsSession())return;
 if(trackingBusy){if(roi)trackingQueuedSelection={snapshot,roi,token:nativeState.tracking.token};return;}
 trackingBusy=true;const token=nativeState.tracking.token;
 try{
  const t=await nativeAPI('tracking/frame',{token,client_id:trackingClientId,...snapshot.marker,jpeg:snapshot.jpeg,...(roi?{roi}:{} )});
  if(nativeState?.tracking?.token===token){nativeState.tracking=t;updateTargetTracking(nativeState);}
 }catch(e){$('trackingCapture').textContent=e.message;}
 finally{
  trackingBusy=false;const queued=trackingQueuedSelection;trackingQueuedSelection=null;
  if(queued&&queued.token===nativeState?.tracking?.token)void trackingSend(queued.snapshot,queued.roi);
 }
}
function trackingCapture(){
 if(nativeState?.tracking?.kind==='person')return;
 if(!trackingOwnsSession()||!trackingVideoReady()||trackingDragging||trackingQueuedSelection)return;
 const ctx=trackingFull.getContext('2d',{willReadFrequently:true});ctx.drawImage($('video'),0,0,1280,720);
 const marker=trackingMarker(ctx);
 if(!marker){$('trackingCapture').textContent='等待有效视频帧标记；请确认新固件及摄像头对比模式。';return;}
 trackingRaw.getContext('2d').drawImage(trackingFull,0,180,640,360,0,0,640,360);trackingHasOverview=true;trackingDraw();
 const snapshot={marker,jpeg:trackingRaw.toDataURL('image/jpeg',.8).split(',')[1]};trackingSnapshot=snapshot;
 $('trackingCapture').textContent=`源帧 ${marker.frame_id} · 拍摄标记校验通过 · 拖动框选目标`;
 if(marker.frame_id===trackingLastFrame||trackingBusy)return;
 trackingLastFrame=marker.frame_id;void trackingSend(snapshot);
}
function trackingPoint(e){if(e.trackingCoordinates)return e.trackingCoordinates;const r=trackingCanvas.getBoundingClientRect();return [Math.max(0,Math.min(640,(e.clientX-r.left)*640/r.width)),Math.max(0,Math.min(360,(e.clientY-r.top)*360/r.height))];}
function trackingPointerDown(e){
 if(nativeState?.tracking?.kind==='person'){
  if(!trackingOwnsSession()||!trackingHasOverview)return;const [x,y]=trackingPoint(e);
  const people=(nativeState.tracking.people||[]).filter(p=>x>=p.bbox[0]&&x<=p.bbox[0]+p.bbox[2]&&y>=p.bbox[1]&&y<=p.bbox[1]+p.bbox[3]);
  people.sort((a,b)=>a.bbox[2]*a.bbox[3]-b.bbox[2]*b.bbox[3]);
  if(people.length)void nativeAPI('person/select',{id:people[0].id,token:nativeState.tracking.token,client_id:trackingClientId}).catch(e=>{$('trackingCapture').textContent=e.message;});
  return;
 }
 if(!trackingOwnsSession()||!trackingSnapshot||nativeState.tracking.state==='selecting')return;
 if(!e.trackingCoordinates)trackingCanvas.setPointerCapture(e.pointerId);trackingFrozen.getContext('2d').drawImage(trackingRaw,0,0);
 trackingDragging={start:trackingPoint(e),box:null,snapshot:trackingSnapshot};e.preventDefault();
}
function trackingPointerMove(e){
 if(!trackingDragging)return;const [x,y]=trackingPoint(e),[sx,sy]=trackingDragging.start;
 trackingDragging.box=[Math.floor(Math.min(sx,x)),Math.floor(Math.min(sy,y)),Math.floor(Math.abs(x-sx)),Math.floor(Math.abs(y-sy))];trackingDraw();
}
function trackingPointerUp(e){
 if(!trackingDragging)return;const drag=trackingDragging;trackingDragging=null;
 if(drag.box&&drag.box[2]>=12&&drag.box[3]>=12)void trackingSend(drag.snapshot,drag.box);
 else $('trackingCapture').textContent='请拖动框选至少12×12像素的物体。';trackingDraw();
}
trackingCanvas.addEventListener('pointerdown',trackingPointerDown);
trackingCanvas.addEventListener('pointermove',trackingPointerMove);
trackingCanvas.addEventListener('pointerup',trackingPointerUp);
trackingCanvas.addEventListener('pointercancel',()=>{trackingDragging=null;trackingDraw();});
window.wycTrackingPointer=(type,x,y)=>{
 const e={trackingCoordinates:[Math.max(0,Math.min(640,x)),Math.max(0,Math.min(360,y))],preventDefault(){}};
 if(type==='down')trackingPointerDown(e);
 else if(type==='move')trackingPointerMove(e);
 else if(type==='up')trackingPointerUp(e);
 else if(type==='cancel'){trackingDragging=null;trackingDraw();}
};
$('trackingStart').onclick=()=>trackingAction('tracking_start');
$('trackingStop').onclick=()=>trackingAction('tracking_stop');
$('trackingReselect').onclick=()=>{
 if(nativeState?.tracking?.kind==='person')void nativeAPI('person/reselect',{token:nativeState.tracking.token,client_id:trackingClientId}).catch(e=>{$('trackingCapture').textContent=e.message;});
 else $('trackingCapture').textContent='直接在总览中拖动新目标框；锁定成功后替换原目标。';
};
$('personDevices').onclick=personDevices;$('personCamera').onchange=()=>nativeState&&updateTargetTracking(nativeState);
$('trackingBackend').onchange=()=>{if(nativeState)updateTargetTracking(nativeState);if(personChosen())void personDevices();};
$('stopVideo').onclick=()=>nativeState?.tracking?.kind==='person'&&trackingIsActive()?trackingAction('tracking_stop'):stopVideo();
void personDevices();setInterval(personPreviewTick,200);
setInterval(trackingCapture,100);
