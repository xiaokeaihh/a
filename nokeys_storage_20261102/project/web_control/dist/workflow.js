'use strict';
(()=>{
 const tracking=document.getElementById('trackingPanel');
 const options=document.createElement('div');options.className='workflow-options';
 options.innerHTML='<label><input type="checkbox" id="compositionEnabled" checked> 智能构图 · 目标等大缩放与运动留白</label><p id="compositionStatus" class="caption">以选定目标后的画面大小为基准，远时放大、近时缩小；视场80°～110°，超出范围后提示。</p>';
 tracking.querySelector('.tracking-actions').after(options);
 const controls=document.createElement('section');controls.className='card';controls.id='imageControlsPanel';
 controls.innerHTML='<div class="section-head"><h2>图像开关 · FPGA</h2></div><div class="workflow-buttons"><button id="controlGamma" data-image-control="gamma">Gamma：等待回报</button><button id="controlHighExposure" data-image-control="high_exposure">高曝光测试：等待回报</button><button id="controlWhiteBalance" data-image-control="auto_white_balance">自动白平衡：等待回报</button></div><p id="highExposureStatus" class="caption" role="status">Gamma联动自动曝光；高曝光测试优先锁定约32 ms、2倍增益。</p><p id="whiteBalanceStatus" class="caption">自动白平衡关闭时锁定当前颜色，再次开启后继续自动调整。</p><p id="imageControlsStatus" class="caption">按板端实际状态显示。</p>';
 document.getElementById('viewPanel').after(controls);
 const card=document.createElement('section');card.className='card';card.id='recordingPanel';
 card.innerHTML='<div class="section-head"><h2>手动录像与回放</h2><button id="recordingRefresh">刷新列表</button></div><div class="workflow-buttons"><button id="recordingStart" class="primary">开始录像</button><button id="recordingStop" disabled>停止并保存</button><button id="recordingBookmark" disabled>添加标记</button></div><p id="recordingState" role="status">仅点击“开始录像”后录制。对比模式时，同一段视频同时保存总览和跟随画面。</p><p class="caption">保存当前1280×720 HDMI采集画面，保留黑边；对比模式中的每侧内容为640×360。目标编码30fps，实际采集和录制帧率以实测为准。单段最多30分钟／2GiB，控制页保持打开且可见。</p><div id="recordingList" class="recording-list"></div><div id="recordingPlayback" hidden><h3 id="recordingTitle"></h3><video id="recordingReplay" controls playsinline preload="metadata"></video><div id="recordingEvents" class="workflow-buttons"></div><a id="recordingDownload" download>下载录像</a></div>';
 tracking.after(card);
 const overlay=document.createElement('div');overlay.className='attitude-overlay';overlay.id='attitudeOverlay';overlay.hidden=true;
 document.querySelector('.video-wrap').append(overlay);
 const client=crypto.randomUUID();let state=null,controlBusy=false,controlPending=null,controlFailure='',record=null,loading=false,playingId=null;
 const canvas=document.createElement('canvas');canvas.width=1280;canvas.height=720;
 const context=canvas.getContext('2d',{alpha:false});
 function source(){return window.wycDisplay?.source?.()||null;}
 function attitudeText(s){
  if(!s?.enabled||s.hardware?.test)return '';
  if(!s.imu_online||!s.reference_ready||!s.attitude)return '姿态等待有效IMU数据';
  const a=s.attitude,number=v=>(v>=0?'+':'')+Number(v).toFixed(1)+'°';
  return `横滚 R ${number(a.roll)}　俯仰 P ${number(a.pitch)}　相对航向 Y ${number(a.yaw)}`;
 }
 function imuText(s){
  const raw=s?.raw;
  if(!s?.connected||!s.enabled||!s.imu_online||s.hardware?.test||s.image_controls?.input_source==='hdmi'||!Array.isArray(raw)||raw.length!==6||!raw.every(Number.isFinite))return '';
  const angle=value=>Number.isFinite(value)?value.toFixed(1)+'°':'—';
  const prefix=s.reference_ready?'相机':'传感器';
  return `AX ${raw[0]}　AY ${raw[1]}　AZ ${raw[2]}\nGX ${raw[3]}　GY ${raw[4]}　GZ ${raw[5]}\n${prefix}俯仰 ${angle(s.pose?.pitch)}　${prefix}横滚 ${angle(s.pose?.roll)}`;
 }
 function drawAttitude(ctx,s){
  // The retired R/P/Y black strip is not rendered into recordings.
 }
 async function refresh(){
  if(loading)return;loading=true;
  try{
   const rows=await nativeAPI('recordings');const list=document.getElementById('recordingList');list.replaceChildren();
   for(const row of rows){
    const line=document.createElement('div');line.className='recording-row';
    const label=document.createElement('span');label.textContent=new Date(row.created*1000).toLocaleString()+` · ${Number(row.duration||0).toFixed(1)}秒 · ${(row.bytes/1048576).toFixed(1)}MiB · `+({ready:'已保存',partial:'部分保存',recording:'录制中',interrupted:'未完成'}[row.state]||row.state);
    line.append(label);
    if(['ready','partial'].includes(row.state)){
     const button=document.createElement('button');button.textContent='回放';button.onclick=()=>play(row);line.append(button);
    }
    if(['ready','partial','interrupted'].includes(row.state)){
     const button=document.createElement('button');button.textContent='删除';button.className='delete-recording';button.title='删除这段录像及其标记';
     button.onclick=async()=>{
      if(!confirm('确定删除这段录像及其标记吗？此操作无法撤销。'))return;
      button.disabled=true;
      try{
       await nativeAPI('recordings/delete',{id:row.id});
       if(playingId===row.id){const video=document.getElementById('recordingReplay');video.pause();video.removeAttribute('src');video.load();document.getElementById('recordingPlayback').hidden=true;playingId=null;}
       document.getElementById('recordingState').textContent='录像已删除。';await refresh();
      }catch(e){button.disabled=false;document.getElementById('recordingState').textContent=e.message;}
     };
     line.append(button);
    }
    list.append(line);
   }
   if(!rows.length)list.textContent='尚无录像。';
  }catch(e){document.getElementById('recordingList').textContent=e.message;}
  finally{loading=false;}
 }
 function play(row){
  playingId=row.id;
  const video=document.getElementById('recordingReplay');document.getElementById('recordingPlayback').hidden=false;
  document.getElementById('recordingTitle').textContent=new Date(row.created*1000).toLocaleString()+' · 总览／跟随同帧录像';
  const url='/api/recordings/'+row.id+'/video';video.src=url;video.load();
  const link=document.getElementById('recordingDownload');link.href=url;link.download='wyc_'+row.id+'.webm';
  const events=document.getElementById('recordingEvents');events.replaceChildren();
  for(const event of row.events||[]){const b=document.createElement('button');b.textContent=event.time.toFixed(1)+'秒 · '+event.type;b.onclick=()=>{video.currentTime=Math.min(event.time,Math.max(0,row.duration-.05));void video.play().catch(()=>{});};events.append(b);}
  void video.play().catch(()=>{});
 }
 async function event(type,note=''){
  const r=record;if(!r||r.finishing)return;
  try{await nativeAPI('recordings/event',{id:r.id,client_id:client,time:(performance.now()-r.started)/1000,type,note});}catch{}
 }
 function update(s){
  state=s;const c=s.image_controls||{},fresh=s.connected&&s.online&&c.fresh&&c.supported;
  if(controlPending){
   const {key,enabled,until}=controlPending;
   if(fresh&&c.requested?.[key]===enabled&&c.applied?.[key]===enabled&&(key!=='gamma'||!c.gamma_exposure_linked||c.requested?.high_exposure||c.applied?.auto_exposure===enabled))controlPending=null;
   else if(Date.now()>until){controlFailure='未收到切换完成回报，请检查开发板状态。';controlPending=null;}
  }
  const hdmi=c.input_source==='hdmi';
  const high=!!c.applied?.high_exposure,highPending=!!c.requested?.high_exposure!==high;
  for(const button of controls.querySelectorAll('[data-image-control]')){
   const key=button.dataset.imageControl,label={gamma:'Gamma',high_exposure:'高曝光测试',auto_white_balance:'自动白平衡'}[key];
   const capable=key==='gamma'?(c.gamma_exposure_linked||hdmi):key==='high_exposure'?c.high_exposure_supported:key==='auto_white_balance'?c.white_balance_supported:true;
   const applied=c.applied?.[key];
   const pending=fresh&&capable&&(c.requested?.[key]!==applied||(key==='gamma'&&c.gamma_exposure_linked&&!c.requested?.high_exposure&&c.applied?.auto_exposure!==c.requested?.gamma));
   button.disabled=controlBusy||!!controlPending||!fresh||!capable||pending||(key==='high_exposure'&&highPending);
   button.textContent=label+'：'+(!fresh?'等待新版回报':!capable?(hdmi?'HDMI不适用':'需要新版固件'):pending?'切换中':applied?'开启':key==='auto_white_balance'?'关闭（已锁定）':'关闭');
   button.classList.toggle('selected',fresh&&!!applied);button.setAttribute('aria-pressed',String(fresh&&!!applied));
  }
  document.getElementById('imageControlsStatus').textContent=!fresh?'连接串口并等待板端状态回报。':hdmi?(c.input_format_locked?'HDMI输入已锁定：1280×720；RAW原图旁路Gamma。':!c.receiver_initialized?'正在初始化HDMI接收器，请确认电脑HDMI已输出视频。':c.input_signal_present?'HDMI信号已检测到，正在确认1280×720画面尺寸。':'等待电脑HDMI信号；请检查输入接线及720p60活动信号模式。'):c.error?'摄像头设置更新失败，正在重试；以板端实际状态为准。':c.busy?'摄像头正在更新设置；请等待生效。':'状态来自FPGA；RAW原图旁路Gamma曲线。';
  document.getElementById('highExposureStatus').textContent=!fresh?'Gamma联动自动曝光；高曝光测试优先锁定约32 ms、2倍增益。':hdmi?'HDMI回放模式：Gamma只调整亮度曲线，录制视频的曝光保持不变。':!c.gamma_exposure_linked?'需要烧录Gamma联动与白平衡版固件后使用。':high?'高曝光已锁定：约32 ms、2倍增益。此时Gamma只切换亮度曲线，自动曝光保持暂停。':'Gamma同时控制亮度曲线与自动曝光，上限约32 ms；达到上限后才增加增益。高曝光测试可独立开启。';
  document.getElementById('whiteBalanceStatus').textContent=fresh&&hdmi?'HDMI模式使用视频中已有的颜色，自动白平衡和高曝光不参与处理。':fresh&&c.white_balance_supported?(c.applied?.auto_white_balance?'白平衡正在自动调整；关闭后锁定当前颜色。':'白平衡已锁定当前结果；重新开启后继续自动调整。'):'自动白平衡关闭时锁定当前颜色，再次开启后继续自动调整。';
  if(controlPending)document.getElementById('imageControlsStatus').textContent='正在等待开发板确认切换…';
  else if(controlFailure)document.getElementById('imageControlsStatus').textContent=controlFailure;
  const framing=s.tracking?.composition||{};document.getElementById('compositionEnabled').checked=framing.enabled!==false;
  document.getElementById('compositionStatus').textContent=framing.target_clipped?'目标过近或接近视野边界，当前无法同时保证完整目标与有效采样；可将目标移远。':s.tracking?.state==='following'?`实际视场 ${Number(s.tracking.hfov||100).toFixed(1)}° · ${framing.size_limited?'等大缩放已到有效取景范围':'目标等大缩放'} · 运动留白 ${Number(framing.lead_degrees||0).toFixed(1)}° · ${s.tracking.view_clamped?'已限制边缘方向':'平滑取景'}`:'跟随时以首次有效画面的目标大小为基准自动缩放；遮挡后持续寻找，连续确认后恢复。';
  overlay.textContent=imuText(s);overlay.hidden=!overlay.textContent||!source();
  if(fresh){
   document.getElementById('exposurePreset').textContent=hdmi?'输入：电脑HDMI 1280×720 / 60Hz；曝光与白平衡取决于录制的视频。':high?'高曝光测试：设定约32 ms、2倍增益；摄像头30 fps。':c.applied?.auto_exposure?(c.high_exposure_supported?'自动曝光：先延长到约32 ms，再提升增益（1～4倍）；实时数值尚未回读。':'自动曝光／自动增益已开启；传感器实时曝光数值尚未回读。'):'固定曝光：设定约22.5 ms、2倍增益。';
  }
  document.getElementById('recordingStart').disabled=!!record||!source();
  if(record){
   const signature=s.tracking?.state,previous=record.trackingState;
   if(signature!==previous){record.trackingState=signature;void event(({following:'跟随恢复',recovering:'目标遮挡',lost:'寻找目标',waiting:'等待目标',idle:'跟随停止'})[signature]||'状态改变');}
  }
  window.wycDisplay?.render();
 }
 controls.addEventListener('click',async e=>{
  const button=e.target.closest('[data-image-control]');if(!button||button.disabled||controlBusy||controlPending)return;
  const key=button.dataset.imageControl,enabled=!state.image_controls.applied[key];
  controlBusy=true;controlFailure='';controlPending={key,enabled,until:Date.now()+5000};update(state);
  try{const result=await nativeAPI('action',{action:'image_control',control:key,enabled});update(result);}
  catch(error){controlPending=null;controlFailure=error.message;}
  finally{controlBusy=false;update(state);}
 });
 document.getElementById('compositionEnabled').onchange=async e=>{
  try{await nativeAPI('action',{action:'tracking_options',composition:e.target.checked});}
  catch(error){document.getElementById('compositionStatus').textContent=error.message;}
 };
 async function start(){
  if(record||!source())return;
  const status=document.getElementById('recordingState');
  if(!window.MediaRecorder||!canvas.captureStream){status.textContent='当前浏览器不支持录像，请用独立Edge或Chrome。';return;}
  const mime=['video/webm;codecs=vp8','video/webm;codecs=vp9','video/webm'].find(v=>MediaRecorder.isTypeSupported(v));
  if(!mime){status.textContent='浏览器不支持WebM录像。';return;}
  let created=null;
  try{
   created=await nativeAPI('recordings/start',{client_id:client,mime,title:'手动总览与跟随录像'});
   const media=canvas.captureStream(0),recorder=new MediaRecorder(media,{mimeType:mime,videoBitsPerSecond:5000000});
   const r=record={id:created.id,media,recorder,started:performance.now(),frames:0,bytes:0,pending:0,sequence:0,upload:Promise.resolve(),error:'',acceptedUntil:0,timer:null,finishing:false,trackingState:state?.tracking?.state};
   recorder.ondataavailable=e=>{
    if(!e.data.size||r.error)return;
    const sequence=r.sequence++,until=(performance.now()-r.started)/1000;r.pending+=e.data.size;
    if(r.pending>12*1048576&&!r.error){r.error='磁盘写入跟不上，已停止录制并保留已写入片段';if(recorder.state==='recording')recorder.stop();return;}
    r.upload=r.upload.then(async()=>{
     if(r.error)return;
     const response=await fetch('/api/recordings/'+r.id+'/chunk',{method:'POST',headers:{'Content-Type':'application/octet-stream','X-Recording-Client':client,'X-Recording-Sequence':String(sequence)},body:e.data});
     const body=await response.json();if(!response.ok)throw Error(body.error||'录像写入失败');r.bytes=body.bytes;r.acceptedUntil=until;
    }).catch(error=>{r.error=error.message;if(recorder.state==='recording')recorder.stop();}).finally(()=>{r.pending-=e.data.size;});
   };
   recorder.onerror=e=>{r.error=e.error?.message||'浏览器录像中断';if(recorder.state==='recording')recorder.stop();};
   recorder.onstop=()=>{r.stopped=performance.now();void finish(r);};
   recorder.start(1000);
   const render=()=>{
    if(r!==record||r.finishing)return;const input=source();
    if(!input){r.error='采集画面已关闭';if(recorder.state==='recording')recorder.stop();return;}
    try{context.drawImage(input,0,0,1280,720);if(state?.hardware?.mode===2&&!state.hardware.test){context.fillStyle='#000';context.fillRect(1088,0,192,32);}drawAttitude(context,state);r.media.getVideoTracks()[0].requestFrame();r.frames++;}
    catch(error){r.error=error.message;if(recorder.state==='recording')recorder.stop();}
    const elapsed=(performance.now()-r.started)/1000;
    status.textContent=`正在录像 ${elapsed.toFixed(1)}秒 · 已写入 ${(r.bytes/1048576).toFixed(1)}MiB · 当前渲染 ${(r.frames/Math.max(.1,elapsed)).toFixed(1)}fps`;
    if(elapsed>=1800&&recorder.state==='recording')recorder.stop();
   };
   r.timer=setInterval(render,1000/30);render();void event('开始录像');
   document.getElementById('recordingStart').disabled=true;document.getElementById('recordingStop').disabled=false;document.getElementById('recordingBookmark').disabled=false;
  }catch(error){
   status.textContent=error.message;
   if(created)try{await nativeAPI('recordings/finish',{id:created.id,client_id:client,duration:.001,frames:0,note:error.message});}catch{}
   record=null;
  }
 }
 async function finish(r){
  if(r.finishing)return;r.finishing=true;clearInterval(r.timer);
  document.getElementById('recordingStop').disabled=true;document.getElementById('recordingBookmark').disabled=true;
  const status=document.getElementById('recordingState');status.textContent='正在写入最后片段并保存回放索引…';
  try{
   await r.upload;const elapsed=((r.stopped||performance.now())-r.started)/1000;
   const result=await nativeAPI('recordings/finish',{id:r.id,client_id:client,duration:Math.max(.001,r.error?r.acceptedUntil:elapsed),frames:r.frames,note:r.error});
   status.textContent=result.state==='ready'?'录像已保存，可在下方回放或下载。':result.state==='partial'?'已保存可回放片段：'+r.error:'录像未完整保存：'+result.note;
  }catch(error){status.textContent='录像保存失败：'+error.message;}
  finally{r.media.getTracks().forEach(track=>track.stop());if(record===r)record=null;if(state)update(state);await refresh();}
 }
 document.getElementById('recordingStart').onclick=start;
 document.getElementById('recordingStop').onclick=()=>{if(record?.recorder.state==='recording'){void event('停止录像');record.recorder.stop();}};
 document.getElementById('recordingBookmark').onclick=()=>void event('手动标记');document.getElementById('recordingRefresh').onclick=refresh;
 window.addEventListener('beforeunload',e=>{if(record){e.preventDefault();e.returnValue='';}});
 window.wycWorkflow={update,attitudeText,imuText,rotationText:imuText,drawAttitude,refresh,recording:()=>record?{id:record.id,pending_bytes:record.pending,frames:record.frames}:null};
 setInterval(()=>{if(state)update(state);},500);void refresh();
})();
