'use strict';
(()=>{
 const client=crypto.randomUUID();let state=null,session=null,busy=false,posting=false,finishing=false,mediaTime=-1,lastRevision=-1,loading=false,loadedResult=null,lastCompleted=null,inputDirty=false,pendingImage=null;
 const source=document.createElement('section');source.className='card input-source-global';source.id='inputSourcePanel';
 source.innerHTML='<div class="section-head"><h2>输入口</h2><span class="muted">同一固件切换</span></div><div class="input-source-row"><select id="inputSource" aria-label="FPGA输入口"><option value="camera">摄像头</option><option value="hdmi">HDMI</option></select><button id="applyInputSource">切换输入</button></div><p id="inputSourceState" class="caption" role="status">等待开发板输入状态。</p>';
 document.querySelector('main').prepend(source);
 const card=document.createElement('section');card.id='panoramaPanel';card.className='card';
 card.innerHTML='<div class="section-head"><h2>全景拍摄与拖动查看</h2><span class="muted">PC拼接 · 摄像头输入</span></div><div class="button-row"><button id="panoramaStart" class="primary">开始全景</button><button id="panoramaFinish" disabled>完成拼接</button><button id="panoramaCancel" disabled>取消</button></div><p id="panoramaState" role="status">打开采集画面，点击开始后缓慢左右扫动。全景独立保存为照片，不会启动录像。</p><p class="caption">尽量绕镜头转动，保持重叠并避开近处移动物体。拖动宽全景或右侧视角可选择方向；未拍到的区域保持空白。建议先固定焦距与曝光。无需开启 IMU 也能视觉拼接；手、支架等近物尽量离开画面。出现配准提示时先回到上一方向。</p><div class="panorama-stage"><figure><figcaption>已拍全景 · 拖动选择方向</figcaption><canvas id="panoramaMap" class="panorama-map" width="1024" height="512"></canvas></figure><figure><figcaption>所选方向 · 历史全景取景</figcaption><canvas id="panoramaView" width="960" height="540"></canvas><p id="panoramaDirection" class="caption"></p></figure></div><label>视角范围<input id="panoramaFov" type="range" min="45" max="110" value="90" step="1"></label><p id="panoramaMetrics" class="caption"></p><div class="button-row"><button id="panoramaRefresh">已保存全景</button><button id="panoramaPopout" disabled>弹出所选视角</button><a id="panoramaJpg" hidden download>保存 JPG</a><a id="panoramaPng" hidden download>保存 PNG</a></div><div id="panoramaFiles" class="panorama-files"></div>';
 ($('recordingPanel')||$('trackingPanel')).after(card);
 const full=document.createElement('canvas');full.width=1280;full.height=720;const fullCtx=full.getContext('2d',{willReadFrequently:true});
 const map=$('panoramaMap'),ctx=map.getContext('2d');let picture=null,viewer=null;
 try{viewer=new WYCPanoramaViewer($('panoramaView'),v=>{
  $('panoramaFov').value=v.fov;$('panoramaDirection').textContent=`方向 ${v.yaw.toFixed(0)}° · 俯仰 ${v.pitch.toFixed(0)}° · 视场 ${v.fov.toFixed(0)}°`;
  drawMap();
 });}catch(e){$('panoramaDirection').textContent=e.message;}
 function drawMap(){
  ctx.fillStyle='#000';ctx.fillRect(0,0,map.width,map.height);if(!picture)return;
  const h=map.width*picture.naturalHeight/picture.naturalWidth,y=(map.height-h)/2;ctx.drawImage(picture,0,y,map.width,h);
  if(viewer){const x=(viewer.yaw/360+.5)*map.width,w=viewer.fov/360*map.width;ctx.strokeStyle='#e9aa7f';ctx.lineWidth=2;for(const shift of [-map.width,0,map.width])ctx.strokeRect(x-w/2+shift,y,w,h);}
 }
 let mapDragging=false;
 function choose(e){const r=map.getBoundingClientRect();viewer?.set((e.clientX-r.left)/r.width*360-180);}
 map.addEventListener('pointerdown',e=>{mapDragging=true;map.setPointerCapture(e.pointerId);choose(e);});
 map.addEventListener('pointermove',e=>{if(mapDragging)choose(e);});
 for(const kind of ['pointerup','pointercancel','lostpointercapture'])map.addEventListener(kind,()=>mapDragging=false);
 $('panoramaFov').oninput=e=>{if(viewer){viewer.fov=Number(e.target.value);viewer.render();}};
 function active(){return ['collecting','solving'].includes(state?.panorama?.state);}
 async function load(url){if(loading){pendingImage=url;return;}loading=true;try{const image=new Image();image.src=url;await image.decode();picture=image;viewer?.image(image);drawMap();}catch(e){$('panoramaState').textContent='全景预览加载失败：'+e.message;}finally{loading=false;if(pendingImage){const next=pendingImage;pendingImage=null;void load(next);}}}
 async function act(action){
  if(busy)return;busy=true;
  try{
   if(action==='panorama_start'){
    if(window.wycWorkflow?.recording())throw Error('请先停止并保存录像');
    if(trackingIsActive()){await trackingAction('tracking_stop');if(trackingIsActive())throw Error('请先停止正在运行的跟随');}
    if(!stream)await startVideo();
    const v=$('video');if(!stream||v.videoWidth!==1280||v.videoHeight!==720)throw Error('请先打开1280×720采集画面');
    const s=await nativeAPI('action',{action,client_id:client,video_width:v.videoWidth,video_height:v.videoHeight});
    session={token:s.panorama.token,client_id:client};mediaTime=-1;lastRevision=-1;loadedResult=null;lastCompleted=null;
    $('panoramaPopout').disabled=true;$('panoramaJpg').hidden=$('panoramaPng').hidden=true;update(s);
   }else{
    if(action==='panorama_finish'){
     finishing=true;$('panoramaState').textContent='正在收尾当前关键帧，随后生成完整全景…';
     const deadline=performance.now()+8000;
     while(posting&&performance.now()<deadline)await new Promise(resolve=>setTimeout(resolve,25));
     if(posting)throw Error('当前图像响应超时，请取消本次全景后重试');
    }
    const s=await nativeAPI('action',{action,...session});update(s);if(action==='panorama_cancel')session=null;
   }
  }catch(e){$('panoramaState').textContent=e.message;}
  finally{busy=false;finishing=false;if(state)buttons();}
 }
 function buttons(){
  const p=state?.panorama||{},c=state?.image_controls||{},own=p.client_id===client;
  $('panoramaStart').disabled=busy||active()||!state?.connected||c.fresh===false||!c.input_switch_supported||c.input_source!=='camera'||c.input_switch_busy||!!window.wycWorkflow?.recording();
  $('panoramaFinish').disabled=busy||p.state!=='collecting'||!own||p.keyframes<2;
  $('panoramaCancel').disabled=busy||!active()||!own;
   $('applyInputSource').disabled=busy||active()||!state?.connected||c.fresh===false||!c.input_switch_supported||!!window.wycWorkflow?.recording();
  $('inputSource').disabled=$('applyInputSource').disabled;
  if(active())for(const button of document.querySelectorAll('#stabilizationPanel button,#stabilizationPanel select,#viewPanel button,#imageControlsPanel button,#trackingStart,#recordingStart,#colorPattern,#colorCamera'))button.disabled=true;
  if(c.input_source==='hdmi')for(const id of ['trackingStart','stableStart','autoStart','axisStart','axisFinish','stableReference'])$(id).disabled=true;
 }
 function update(s){
  state=s;const p=s.panorama||{},c=s.image_controls||{};
  if(!inputDirty&&document.activeElement!==$('inputSource'))$('inputSource').value=s.input_transition?.source||c.requested_source||c.input_source||'camera';
   $('inputSourceState').textContent=!s.connected?'串口未连接，请选择 COM7 并连接。':c.fresh===false?'正在等待开发板最新功能回报；持续无回报时请断开后重新连接串口。':!c.input_switch_supported?'当前固件回报不支持双输入全景，请确认烧录本目录的试验固件。':s.input_transition?'正在切换，等待所选输入的新帧；可重新选择输入口…':c.input_switch_busy?'尚未收到所选输入的新帧，请检查720p信号，或重新选择输入口。':c.input_source==='hdmi'?`HDMI输入 · ${c.input_format_locked?'720p帧格式已锁定':'等待1280×720信号'}；曝光与姿态以录制视频为准。`:`摄像头输入 · ${c.input_signal_present?'已接收视频':'等待相机视频'} · IMU与原有功能可用。`;
  if(active()||p.state==='complete'||p.state==='failed')$('panoramaState').textContent=({collecting:'拍摄中：',solving:'正在生成完整全景：',complete:'',failed:'拼接失败：'})[p.state]+(p.error||p.note||'');
  if(p.state==='idle'&&session){$('panoramaState').textContent=p.note||'全景已退出';session=null;}
  $('panoramaMetrics').textContent=p.state&&p.state!=='idle'?`关键帧 ${p.keyframes}/${p.max_keyframes} · 水平覆盖 ${Number(p.covered_degrees||0).toFixed(0)}° · 最近计算 ${Number(p.processing_ms||0).toFixed(0)}ms · 最新帧队列1帧 · JPEG暂存 ${(Number(p.jpeg_bytes||0)/1048576).toFixed(1)}MiB（不含拼接工作内存）；FPGA核心延迟另见性能数据。`:'';
  if(p.revision>0&&p.revision!==lastRevision&&!loading){lastRevision=p.revision;void load('/api/panorama/preview.jpg?token='+p.token+'&revision='+p.revision);}
  if(p.result?.id&&p.result.id!==lastCompleted){lastCompleted=p.result.id;void openResult(p.result);void refresh();session=null;}
  buttons();
 }
 async function openResult(row){
  loadedResult=row.id;await load('/api/panoramas/'+row.id+'.jpg');
  for(const [id,suffix] of [['panoramaJpg','jpg'],['panoramaPng','png']]){const a=$(id);a.href='/api/panoramas/'+row.id+'.'+suffix;a.download='wyc_panorama_'+row.id+'.'+suffix;a.hidden=false;}
  $('panoramaPopout').disabled=false;$('panoramaPopout').onclick=()=>window.open('panorama_view.html?id='+row.id,'wyc-panorama-'+row.id,'popup,width=1200,height=760');
 }
 async function refresh(){
  try{const rows=await nativeAPI('panoramas');const list=$('panoramaFiles');list.replaceChildren();for(const row of rows){const line=document.createElement('div'),text=document.createElement('span'),button=document.createElement('button');text.textContent=new Date(row.created*1000).toLocaleString()+` · ${row.width}×${row.height} · 已覆盖${Number(row.covered_degrees).toFixed(0)}°`;button.textContent='查看全景';button.onclick=()=>void openResult(row);line.append(text,button);list.append(line);}if(!rows.length)list.textContent='尚无已保存全景。';}catch(e){$('panoramaFiles').textContent=e.message;}
 }
 async function send(){
  const p=state?.panorama,v=$('video');if(posting||finishing||!session||p?.state!=='collecting'||p.client_id!==client||!stream||state.hardware?.mode!==0||!state.image_controls?.panorama_marker||v.currentTime===mediaTime)return;
  posting=true;
  try{
   fullCtx.drawImage(v,0,0,1280,720);mediaTime=v.currentTime;const marker=trackingMarker(fullCtx);if(!marker)return;
   let blob=await new Promise(resolve=>full.toBlob(resolve,'image/jpeg',.96));
   for(const quality of [.92,.88]){if(blob&&blob.size<=680000)break;blob=await new Promise(resolve=>full.toBlob(resolve,'image/jpeg',quality));}
   if(!blob)throw Error('采集图像编码失败');
   if(blob.size>700000)throw Error('图像噪声较大，请改善照明后继续拍摄');
   const jpeg=await new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result.split(',')[1]);reader.onerror=()=>reject(Error('采集图像读取失败'));reader.readAsDataURL(blob);});
   const result=await nativeAPI('panorama/frame',{...session,...marker,jpeg});
   if(state.panorama.token===result.token){state.panorama=result;update(state);}
  }catch(e){$('panoramaState').textContent=e.message;}
  finally{posting=false;buttons();}
 }
 $('panoramaStart').onclick=()=>void act('panorama_start');$('panoramaFinish').onclick=()=>void act('panorama_finish');$('panoramaCancel').onclick=()=>void act('panorama_cancel');$('panoramaRefresh').onclick=refresh;
 $('inputSource').onchange=()=>inputDirty=true;
 $('applyInputSource').onclick=async()=>{if(busy)return;busy=true;const selected=$('inputSource').value;try{const response=await nativeAPI('action',{action:'input_source',source:selected});inputDirty=false;update(response);}catch(e){$('inputSourceState').textContent=e.message;}finally{busy=false;buttons();}};
 window.addEventListener('beforeunload',()=>{if(session&&active())navigator.sendBeacon('/api/action',new Blob([JSON.stringify({action:'panorama_cancel',...session})],{type:'application/json'}));});
 window.wycPanorama={update,active};setInterval(send,250);void refresh();
})();
