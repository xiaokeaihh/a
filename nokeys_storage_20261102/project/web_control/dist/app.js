const $=id=>document.getElementById(id);
const names=['原图','左上720p','右上720p','左下720p','右下720p','四宫格拼接','原图与矫正图对比图','矫正图'];
const modeNames=['原图','四宫格','原图与矫正图对比图','矫正图'];
let port=null,reader=null,readTask=null,closing=false,buffer='',sequence=0,pending=null,timer=null,lastStatus=0,lastIMU=0,imu=null,stream=null;
let previousReport='';let gotFirmware=false;const viewButtons=[...document.querySelectorAll('[data-view]')];
let imuOnline=false;
let videoListBusy=false,videoListPending=false;
let viewSendQueue=Promise.resolve();
let initialRawRequested=false;
function requestInitialRaw(){initialRawRequested=true;tryInitialRaw();}
function tryInitialRaw(){
 if(!initialRawRequested||!port||!gotFirmware)return;
 if(window.wycPanorama?.active()||window.wycWorkflow?.recording()||(typeof trackingIsActive==='function'&&trackingIsActive())){initialRawRequested=false;return;}
 if(port.native&&nativeState?.image_controls?.raw_view_supported!==true)return;
 initialRawRequested=false;
 if(port.native&&nativeState.hardware?.mode===0&&nativeState.hardware.valid)return;
 void chooseView(0);
}
function inclination(values){const [ax,ay,az]=values;if(Math.hypot(ax,ay,az)<1)return null;return {roll:Math.atan2(ay,az)*180/Math.PI,pitch:Math.atan2(-ax,Math.hypot(ay,az))*180/Math.PI};}
function updateIMU(){
 if(!imuOnline||!imu||Date.now()-lastIMU>2000){$('imuPitch').textContent='—';$('imuRoll').textContent='—';return;}
 [...$('imuValues').querySelectorAll('b')].forEach((b,i)=>b.textContent=imu[i]);
 const tilt=(port?.native&&typeof nativeState!=='undefined'&&nativeState?.pose)?nativeState.pose:inclination(imu);$('imuPitch').textContent=tilt?tilt.pitch.toFixed(1)+'°':'—';$('imuRoll').textContent=tilt?tilt.roll.toFixed(1)+'°':'—';
}
function crc8(bytes){let c=0;for(const b of bytes){c^=b;for(let k=0;k<8;k++)c=(c&128)?((c<<1)^7)&255:(c<<1)&255;}return c;}
function packet(seq,view){return new Uint8Array([0xa5,0x5a,seq,view,crc8([seq,view])]);}
function log(s){$('log').textContent=(`${new Date().toLocaleTimeString()} ${s}\n`+$('log').textContent).slice(0,10000);}
function enableViews(){for(const b of viewButtons){const rawUnsupported=+b.dataset.view===0&&port?.native&&nativeState?.image_controls?.raw_view_supported!==true;b.disabled=!port||!gotFirmware||!!window.wycPanorama?.active()||rawUnsupported;b.title=rawUnsupported?'请烧录本次支持原图按钮的固件':'';}}
function message(s,kind=''){ $('commandState').textContent=s;$('statusDot').className=kind; }
function connectionHint(s,error=false){$('connectHint').textContent=s;$('connectHint').classList.toggle('error',error);}
function preflight(){
 if(document.body.dataset.control==='unified'&&location.protocol!=='file:')return '';
 if(location.protocol==='file:')return '当前直接打开了 HTML。请运行“启动网页.cmd”，然后在 Edge/Chrome 打开 http://localhost:8770/。';
 if(!window.isSecureContext)return '此地址不支持串口授权。请打开 http://localhost:8770/。';
 if(!navigator.serial||typeof navigator.serial.requestPort!=='function')return '当前浏览器不支持网页串口。请复制地址到独立的 Edge 或 Chrome 浏览器中打开。';
 return '';
}

function resetViewWrites(){viewSendQueue=Promise.resolve();}
function clearPending(){pending=null;clearTimeout(timer);for(const b of viewButtons)b.classList.remove('pending');enableViews();}
function handleLine(line){
 const m=/^BW=([0-7]),([0-9a-f]{2}),([0-3]),([01]),([01])$/i.exec(line.trim());
 if(m){
  const v=+m[1],seq=parseInt(m[2],16),mode=+m[3],valid=m[4]==='1';
  lastStatus=Date.now();gotFirmware=true;
  if(previousReport!==m[0]){previousReport=m[0];log('开发板回报：'+m[0]);}
  $('sourceState').textContent=m[5]==='1'?'图源：可重复测试图':'图源：摄像头';
  if(!pending)sequence=seq;
  $('mode').textContent=modeNames[mode];
  $('activeView').textContent=valid?'显示视角：'+(mode===0?names[0]:names[v]):'等待有效视频帧';
  for(const b of viewButtons){const selected=valid&&(mode===0?+b.dataset.view===0:+b.dataset.view!==0&&+b.dataset.view===v);b.classList.toggle('selected',selected);b.setAttribute('aria-pressed',String(selected));}
  if(pending&&seq===pending.seq&&(pending.view===0?mode===0:v===pending.view&&mode===(pending.view===7?3:pending.view===5?1:2))&&valid){const name=names[pending.view];clearPending();message(`FPGA 已在 HDMI 输出${name}。`,'ready');log(`显示确认：${name}，序号 ${seq}`);}
  else if(!pending)message(valid?(mode===0?'显示屏当前为原图；请通过视角按钮选择矫正图、对比图或四宫格。':'已收到 HDMI 实际输出回报。'):'串口已通，等待采集与矫正完成。',valid?'ready':'wait');
  enableViews();tryInitialRaw();return;
 }
 if(/^(?:MV|FV|QB)=/.test(line)){gotFirmware=false;enableViews();connectionHint('检测到旧版烧录程序。请烧录 balanced 新版 sbit 后重连。',true);message('旧版程序没有完整720p基准和测试图源。');return;}
 const id=/^ID=([0-9a-f]{2})\s/i.exec(line);
 if(id){lastIMU=Date.now();imuOnline=id[1].toUpperCase()==='47'&&!/\bERR\b/.test(line);$('imuId').textContent=imuOnline?'ICM-42688-P · 在线':`ID=${id[1]} · 通信异常`;const vals=[...line.matchAll(/(?:AX|AY|AZ|GX|GY|GZ)=([0-9a-f]{4})/gi)];if(imuOnline&&vals.length===6)imu=vals.map(x=>{const v=parseInt(x[1],16);return v>=32768?v-65536:v;});else if(!imuOnline){imu=null;[...$('imuValues').querySelectorAll('b')].forEach(b=>b.textContent='—');}updateIMU();}
}
async function pump(){
 const activePort=port;
 let failures=0;
 try{
  while(!closing&&port===activePort&&activePort.readable){
   const decoder=new TextDecoder();
   const currentReader=activePort.readable.getReader();reader=currentReader;
   try{
    while(!closing&&port===activePort){
     const {value,done}=await currentReader.read();if(done)break;
     if(!value)continue;
     buffer+=decoder.decode(value,{stream:true});
     let k;while((k=buffer.indexOf('\n'))>=0){
      const line=buffer.slice(0,k).replace(/\r$/,'');buffer=buffer.slice(k+1);
      try{handleLine(line);}catch(e){log('回报处理异常：'+e.message);}
     }
     if(buffer.length>4096)buffer='';
     failures=0;
    }
   }catch(e){
    if(closing||port!==activePort)break;
    failures++;buffer='';clearPending();gotFirmware=false;lastStatus=0;
    log('串口接收异常：'+e.name+' · '+e.message);
    if(!activePort.readable||failures>=5)throw e;
    message('接收异常，正在恢复；等待下一条完整 FPGA 回报。','wait');
    connectionHint('串口保持打开，正在恢复接收。');
   }finally{
    currentReader.releaseLock();if(reader===currentReader)reader=null;
   }
   if(!closing&&port===activePort)await new Promise(resolve=>setTimeout(resolve,100));
  }
  if(!closing&&port===activePort)throw Error('设备接收流已关闭');
 }catch(e){
  if(!closing&&port===activePort){
   const reason=e.name+' · '+e.message;log('无法恢复接收：'+reason);
   await disconnect();connectionHint('串口断开：'+reason,true);message('串口断开：'+reason);
  }
 }
}
async function connect(){
 if(document.body.dataset.control==='unified'){
  if(typeof discoverNative!=='function'){connectionHint('稳像控制脚本未加载，请刷新页面。',true);return;}
  if(!nativeService)await discoverNative();
  if(!nativeService){connectionHint('统一控制服务未就绪，请运行“启动网页控制.cmd”。',true);return;}
  return connectNative();
 }
 if(typeof nativeService!=='undefined'&&nativeService)return connectNative();
 const problem=preflight();
 if(problem){connectionHint(problem,true);message(problem);log(problem);return;}
 if(port)return;
 $('connect').disabled=true;connectionHint('正在打开设备选择窗口，请选择 CP2102 对应的 COM 口。');
 let candidate=null;
 try{
  candidate=await navigator.serial.requestPort();
  connectionHint('正在打开串口…若串口助手已打开该 COM 口，请先关闭它。');
  await candidate.open({baudRate:115200,dataBits:8,stopBits:1,parity:'none',flowControl:'none',bufferSize:65536});
  port=candidate;resetViewWrites();closing=false;gotFirmware=false;buffer='';lastStatus=0;previousReport='';
  $('disconnect').disabled=false;$('connection').textContent='串口已连接 · 等待 FPGA';
  connectionHint('串口已打开，正在接收 FPGA 回报。');
  message('等待新版 FPGA 的 BW 显示回报；旧版程序无法控制视角。','wait');
  readTask=pump();requestInitialRaw();enableViews();log('串口已打开，115200 8N1');
 }catch(e){
  port=null;$('connect').disabled=false;
  const detail=e.name==='NotFoundError'?'未选择串口或取消了窗口，请重试。':
   e.name==='NetworkError'?'无法打开串口。先关闭 SSCOM、其他串口程序及已连接该串口的网页，再重试。':
   e.name==='SecurityError'?'浏览器禁止串口访问。请在独立的 Edge/Chrome 中打开 http://localhost:8770/。':e.message;
  connectionHint(`连接失败：${detail}`,true);message(`连接失败：${detail}`);log(`${e.name}: ${e.message}`);enableViews();
 }
}
async function disconnect(){if(port?.native)return disconnectNative();if(!port)return;imuOnline=false;imu=null;lastIMU=0;$('imuId').textContent='等待数据';[...$('imuValues').querySelectorAll('b')].forEach(b=>b.textContent='—');updateIMU();closing=true;resetViewWrites();clearPending();gotFirmware=false;const old=port;port=null;try{if(reader)await reader.cancel();if(readTask&&reader)await readTask;await old.close();}catch(e){log(e.message);}readTask=null;reader=null;$('connect').disabled=false;$('disconnect').disabled=true;$('connection').textContent='串口未连接';$('activeView').textContent='等待开发板';$('mode').textContent='—';for(const b of viewButtons)b.classList.remove('selected');message('串口已断开。');connectionHint('串口已断开，可重新连接。');enableViews();}
function sendCurrent(request=pending){const activePort=port;const send=async()=>{if(!activePort||port!==activePort||pending!==request)return;const writer=activePort.writable.getWriter();try{await writer.write(packet(request.seq,request.view));}finally{writer.releaseLock();}};const result=viewSendQueue.then(send);viewSendQueue=result.catch(()=>{});return result;}
async function chooseView(view){initialRawRequested=false;if(!port||!gotFirmware||window.wycPanorama?.active())return;clearPending();sequence=(sequence+1)&255;const request={view,seq:sequence,tries:0};pending=request;enableViews();viewButtons.find(b=>+b.dataset.view===view).classList.add('pending');message(`正在设置${names[view]}，等待 HDMI 完成视图与模式切换…`,'wait');log(`请求视角：${names[view]}，序号 ${sequence}`);timer=setTimeout(retry,1000);try{await sendCurrent(request);}catch(e){if(pending===request){clearPending();message(`发送失败：${e.message}`);}}}
async function retry(){const request=pending;if(!request)return;if(++request.tries>=3){clearPending();message('未收到显示确认，可重新选择视角；请确认所选输入有有效视频信号。','wait');return;}timer=setTimeout(retry,1000);try{await sendCurrent(request);}catch(e){if(pending===request){clearPending();message(`发送失败：${e.message}`);}}}
function videoProblem(e){
 const reasons={NotAllowedError:'当前网页未获得摄像头权限。请在地址栏的网站权限中允许摄像头，再点击查找设备。',NotReadableError:'视频设备被其他网页或程序占用，或驱动暂时无法打开。',NotFoundError:'浏览器没有找到可访问的视频设备。',OverconstrainedError:'所选设备或1280×720采集规格已不可用，请重新查找设备。',AbortError:'视频设备连接中断，请重新查找设备。'};
 return `${e.name||'Error'}：${reasons[e.name]||e.message||'视频设备操作失败'}`;
}
function fillVideoDevices(devices,preferred){
 const videos=devices.filter(d=>d.kind==='videoinput');
 $('camera').replaceChildren(new Option('选择 HDMI 采集卡（通常名为 USB Video）',''));
 for(const [i,d] of videos.entries()){
  const option=new Option(d.label||`视频设备${i+1}（等待浏览器授权名称）`,d.deviceId||'');
  option.disabled=!d.deviceId;$('camera').add(option);
 }
 const previous=videos.find(d=>d.deviceId&&d.deviceId===preferred);
 const capture=videos.find(d=>d.deviceId&&/HDMI|capture|USB Video|采集/i.test(d.label));
 if(previous||capture)$('camera').value=(previous||capture).deviceId;
 return videos;
}
async function listVideo(options={}){
 if(videoListBusy){videoListPending=true;return;}
 videoListBusy=true;$('listVideo').disabled=true;
 const preferred=$('camera').value,allowPrompt=options.requestPermission!==false;
 let permissionError=null;
 try{
  if(!navigator.mediaDevices?.enumerateDevices)throw Error('当前浏览器无法枚举视频设备，请在独立Edge或Chrome中打开本机网页。');
  let videos=fillVideoDevices(await navigator.mediaDevices.enumerateDevices(),preferred);
  // List already-authorized devices without opening a default webcam first.
  if(allowPrompt&&!stream&&(!videos.length||videos.some(d=>!d.label||!d.deviceId))){
   let temporary=null;
   try{
    const candidate=videos.find(d=>d.deviceId&&/HDMI|capture|USB Video|采集/i.test(d.label));
    $('previewState').textContent='等待浏览器摄像头授权，请在地址栏允许本机网页访问采集卡。';temporary=await navigator.mediaDevices.getUserMedia({video:candidate?{deviceId:{exact:candidate.deviceId}}:true,audio:false});
   }catch(e){permissionError=e;}
   finally{temporary?.getTracks().forEach(t=>t.stop());}
   // A busy default device must not prevent enumerating another capture card.
   videos=fillVideoDevices(await navigator.mediaDevices.enumerateDevices(),preferred);
  }
  if(!stream){
   const unavailable=permissionError?`；${videoProblem(permissionError)}`:'';
   $('previewState').textContent=videos.length?`检测到${videos.length}个视频设备，请选择USB Video采集卡${unavailable}`:`未找到视频设备${unavailable}`;
  }
  log(`视频设备列表已更新：${videos.length}个。HDMI采集卡通常显示为USB Video。`);
 }catch(e){if(!stream)$('previewState').textContent=`查找失败：${videoProblem(e)}`;log(`视频设备查找失败：${videoProblem(e)}`);}
 finally{
  videoListBusy=false;$('listVideo').disabled=false;
  if(videoListPending){videoListPending=false;queueMicrotask(()=>listVideo({requestPermission:false}));}
 }
}
async function stopVideo(){stream?.getTracks().forEach(t=>t.stop());stream=null;$('video').srcObject=null;$('video').style.display='none';$('emptyVideo').style.display='block';$('stopVideo').disabled=true;$('previewState').textContent='采集卡未连接';$('saveFrame').disabled=true;}
async function startVideo(){try{const id=$('camera').value;if(!id)throw Error('先查找设备并选择 HDMI 采集卡。');await stopVideo();stream=await navigator.mediaDevices.getUserMedia({video:{deviceId:{exact:id},width:{exact:1280},height:{exact:720},frameRate:{ideal:60}},audio:false});const track=stream.getVideoTracks()[0];track.onended=()=>{if(stream?.getVideoTracks().includes(track)){void stopVideo().then(()=>{$('previewState').textContent='采集卡视频连接中断，请重新查找设备。';});void listVideo({requestPermission:false});}};$('video').srcObject=stream;await $('video').play();$('video').style.display='block';$('emptyVideo').style.display='none';$('stopVideo').disabled=false;const s=track.getSettings();if(s.width!==1280||s.height!==720)throw Error('采集尺寸不是1280×720，禁止自动缩放保存。');$('saveFrame').disabled=false;$('previewState').textContent=`采集：${s.width}×${s.height} / ${s.frameRate?.toFixed(1)||'—'} fps`;requestInitialRaw();}catch(e){await stopVideo();$('previewState').textContent=`打开失败：${videoProblem(e)}`;}}
$('connect').onclick=connect;$('disconnect').onclick=disconnect;$('listVideo').onclick=listVideo;$('startVideo').onclick=startVideo;$('stopVideo').onclick=stopVideo;
if(navigator.mediaDevices?.addEventListener)navigator.mediaDevices.addEventListener('devicechange',()=>listVideo({requestPermission:false}));
for(const b of viewButtons)b.onclick=()=>chooseView(+b.dataset.view);
setInterval(()=>{updateIMU();if(port&&lastStatus&&Date.now()-lastStatus>2000){gotFirmware=false;enableViews();message('FPGA 显示回报中断，请检查板卡。','wait');$('connection').textContent='串口已连接 · 回报中断';}else if(port&&gotFirmware){$('connection').textContent='已连接';connectionHint('已连接');}if(lastIMU&&Date.now()-lastIMU>2000){$('imuId').textContent='IMU 数据中断';[...$('imuValues').querySelectorAll('b')].forEach(b=>b.textContent='—');}},250);
enableViews();

window.WYC={crc8,packet,handleLine,inclination};window.wycAppReady=true;
const startupProblem=preflight();connectionHint(startupProblem||(document.body.dataset.control==='unified'?'正在连接统一控制服务…':'程序已加载。点击连接，选择 CP2102 对应的 COM 口。'),!!startupProblem);

$('saveFrame').onclick=()=>{
 const v=$('video');if(!stream||v.videoWidth!==1280||v.videoHeight!==720){message('必须实际采集1280×720，禁止缩放保存。');return;}
 const c=document.createElement('canvas');c.width=1280;c.height=720;c.getContext('2d').drawImage(v,0,0);
 c.toBlob(blob=>{const u=URL.createObjectURL(blob),a=document.createElement('a');a.href=u;a.download='wyc_720p_'+new Date().toISOString().replace(/[:.]/g,'-')+'.png';a.click();setTimeout(()=>URL.revokeObjectURL(u),1000);},'image/png');
};
