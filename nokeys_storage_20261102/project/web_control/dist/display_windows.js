"use strict";
// Viewers reuse the existing capture. They never request a camera or own control.
(()=>{
 const windows=new Map(),video=document.getElementById('video'),overview=document.getElementById('trackingOverview');
 const controls=document.getElementById('controlsOnly'),message=document.getElementById('displayMessage');
 const kinds=new Set(['hdmi','overview','combined','original_follow']);let ticket=null;
 function source(){
  const image=document.getElementById('personVideo');
  if(typeof trackingIsActive==='function'&&trackingIsActive()&&nativeState?.tracking?.kind==='person'&&!image.hidden&&image.naturalWidth===1280)return image;
  if(video.srcObject&&video.readyState>=2&&video.videoWidth>0)return video;
  return null;
 }
 function prune(){
  let removed=false;
  for(const [key,item] of windows)if(item.window.closed){windows.delete(key);removed=true;}
  if(removed&&!windows.size){
   controls.checked=false;document.body.classList.remove('controls-only');
   message.textContent='独立显示窗口已关闭，页面画面已恢复；HDMI采集与跟随继续运行。';
  }
 }
 function hasWindows(){prune();return windows.size>0;}
 function render(){
  prune();if(!windows.size)return;
  const input=source();
  for(const item of windows.values())try{
   const view=item.window.wycObservation;if(!view)continue;
   const nativeUrl=input&&input!==video?input.src:null;
   if(item.kind!=='overview'){
    view.setCrop?.(document.querySelector('#outputPanel .video-wrap')?.dataset.crop==='right'?'right':'full');
    view.updateBadge?.(input);
    view.bindStream(input===video?video.srcObject:null);view.bindPreview(nativeUrl);
    if(input&&!nativeUrl&&!view.usesVideo())view.output.getContext('2d').drawImage(input,0,0,1280,720);
    if(input)view.hideMarker((nativeState?.hardware?.mode===2||nativeState?.image_controls?.panorama_marker)&&!nativeState?.hardware?.test);
    view.setAttitude?.(input?window.wycWorkflow?.imuText(nativeState)||'':'');
   }else{view.bindStream(null);view.bindPreview(null);}
   if(item.kind==='original_follow')view.originalFrame?.(input,input===video?video.srcObject:null,nativeUrl,nativeState?.hardware?.mode,!!nativeState?.hardware?.test);
   else{
    view.clearOriginal?.();view.bindOverviewPreview(item.kind!=='hdmi'?nativeUrl:null);
    if(item.kind!=='hdmi'){if(nativeUrl)view.drawPeople(nativeState?.tracking);else view.overview.getContext('2d').drawImage(overview,0,0,640,360);}
   }
   view.setStatus(input?'共用控制页当前画面 · 可拖到扩展屏后点击“全屏显示”':'等待控制页打开画面；如已停止，当前保留最后一帧',
    item.kind==='original_follow'?(nativeState?.hardware?.test?'颜色诊断中，返回摄像头后显示原图':nativeState?.hardware?.mode===2?'原图不叠加检测框；选择目标请切换“跟随总览”':nativeState?.hardware?.mode===0?'当前为原图模式；开启跟随后可对比':'开启跟随／对比模式后显示原图'):typeof trackingIsActive==='function'&&trackingIsActive()?'可点击人物或拖动框选目标':'总览在自动跟随时更新；停止后保留最后一帧');
  }catch{}
 }
 function schedule(){
  if(ticket!==null||!windows.size||video.paused||!video.srcObject)return;
  if(typeof video.requestVideoFrameCallback==='function')ticket=video.requestVideoFrameCallback(()=>{ticket=null;render();schedule();});
 }
 function attach(child,kind){
  if(!child||child.closed||!kinds.has(kind))return;
  try{
   if(child.location.origin!==location.origin)return;
   const item=[...windows.values()].find(v=>v.window===child);
   if(item)item.kind=kind;else windows.set(child.name||kind,{window:child,kind});
   render();schedule();
  }catch{}
 }
 function open(kind){
  if(!kinds.has(kind))return false;
  const name='wyc-display-'+kind;
  // One user click opens one named native browser window, avoiding a blocked
  // second popup. Opening an existing view focuses it instead of duplicating it.
  const child=window.open('display.html?view='+kind+'&ui=20261028-wyc-merged-r2',name,'popup=yes,width=1100,height=740,resizable=yes,scrollbars=no');
  if(!child){message.textContent='浏览器拦截了独立窗口：请允许 localhost 的弹出窗口后重试。建议在独立 Edge／Chrome 中打开控制页。';return false;}
  windows.set(name,{window:child,kind});window.wycFloating?.dock(kind==='hdmi'?'output':'overview');
  message.textContent='已弹出独立窗口。拖动窗口最上方的系统标题栏到扩展屏（也可按 Win＋Shift＋←／→），再点击全屏；控制网页保持打开。';
  try{child.focus();}catch{}render();schedule();return true;
 }
 document.querySelectorAll('[data-display-kind]').forEach(b=>b.addEventListener('click',()=>open(b.dataset.displayKind)));
 video.addEventListener('playing',()=>{render();schedule();});video.addEventListener('loadeddata',render);
 window.wycDisplay={open,attach,render,hasWindows,source,pointer(child,type,x,y){
  const item=[...windows.values()].find(v=>v.window===child);
  if(item&&item.kind!=='hdmi'&&item.kind!=='original_follow'&&Number.isFinite(x)&&Number.isFinite(y))window.wycTrackingPointer?.(type,x,y);
 }};
 setInterval(()=>{prune();if(windows.size){render();schedule();}},1000);
})();
