"use strict";
(()=>{
 const layout=document.getElementById('layout'),status=document.getElementById('status');
 const overview=document.getElementById('overview'),output=document.getElementById('output'),video=document.getElementById('outputVideo');
 const kinds=new Set(['hdmi','overview','combined','original_follow']);let dragging=false;
 const originalVideo=document.getElementById('originalVideo');
 const preview=document.getElementById('outputPreview'),overviewPreview=document.getElementById('overviewPreview');
 const attitude=document.createElement('div');attitude.className='attitude-overlay';attitude.hidden=true;document.getElementById('outputPicture').append(attitude);
 const wanted=new URLSearchParams(location.search).get('view');layout.value=kinds.has(wanted)?wanted:'hdmi';
 function fit(){
  const r=document.getElementById('outputScreen').getBoundingClientRect(),picture=document.getElementById('outputPicture');
  const w=Math.max(0,Math.min(r.width,r.height*16/9));picture.style.width=w+'px';picture.style.height=w*9/16+'px';
  const o=document.getElementById('overviewPicture'),s=o.parentElement.getBoundingClientRect(),ow=Math.max(0,Math.min(s.width,s.height*16/9));o.style.width=ow+'px';o.style.height=ow*9/16+'px';
 }
 function bindStream(stream){
  if(video.srcObject===stream)return;
  // The control page owns this track. Never call stop() in a viewer.
  video.srcObject=stream;video.hidden=!stream;output.hidden=!!stream;
  if(stream)void video.play().catch(()=>{video.hidden=true;output.hidden=false;});
 }
 function bindPreview(url){
  if(url){if(preview.getAttribute('src')!==url)preview.src=url;preview.hidden=false;output.hidden=true;video.hidden=true;}
  else{preview.hidden=true;if(preview.hasAttribute('src'))preview.removeAttribute('src');if(!video.srcObject)output.hidden=false;}
 }
 function bindOverviewPreview(url){
  if(url){if(overviewPreview.getAttribute('src')!==url)overviewPreview.src=url;overviewPreview.hidden=false;}
  else{overviewPreview.hidden=true;if(overviewPreview.hasAttribute('src'))overviewPreview.removeAttribute('src');}
 }
 function drawPeople(t){
  const ctx=overview.getContext('2d');ctx.clearRect(0,0,640,360);
  if(!t)return;
  for(const person of t.people||[]){
   const selected=person.id===t.selected_id;ctx.strokeStyle=selected?'#5df2cb':'#ffd36d';ctx.lineWidth=selected?3:1;ctx.strokeRect(...person.bbox);
   ctx.fillStyle=ctx.strokeStyle;ctx.font='14px Microsoft YaHei';ctx.fillText('人物 '+person.id,person.bbox[0]+3,Math.max(16,person.bbox[1]-5));
  }
 }
 function bindOriginalStream(stream){
  if(originalVideo.srcObject!==stream){originalVideo.srcObject=stream;if(stream)void originalVideo.play().catch(()=>{});}
  originalVideo.hidden=!stream;
 }
 function originalFrame(input,stream,url,mode,diagnostic=false){
  const picture=document.getElementById('overviewPicture'),ctx=overview.getContext('2d');
  picture.dataset.crop=mode===0?'full':'left';
  const available=!!input&&!diagnostic&&(mode===2||mode===0);
  bindOriginalStream(available?stream:null);bindOverviewPreview(available?url:null);
  ctx.clearRect(0,0,640,360);overview.hidden=available&&!!(stream||url);
  if(available&&!stream&&!url){
   if(mode===2)ctx.drawImage(input,0,180,640,360,0,0,640,360);
   else ctx.drawImage(input,0,0,1280,720,0,0,640,360);
  }else if(!available){
   ctx.fillStyle='#211d20';ctx.fillRect(0,0,640,360);ctx.fillStyle='#dfc3a8';ctx.textAlign='center';ctx.font='18px Microsoft YaHei';
   ctx.fillText(diagnostic?'颜色诊断中，返回摄像头后显示原图':input?'开启跟随／对比模式后显示原图':'等待控制页打开画面',320,180);ctx.textAlign='start';
  }
 }
 function clearOriginal(){bindOriginalStream(null);overview.hidden=false;document.getElementById('overviewPicture').dataset.crop='left';}
 function attach(){
  document.body.dataset.layout=layout.value;
  document.title=layout.value==='overview'?'稳视 · 跟随总览':layout.value==='hdmi'?'稳视 · 跟随画面':layout.value==='original_follow'?'稳视 · 原图与跟随':'稳视 · 总览与跟随';
  document.getElementById('overviewTitle').textContent=layout.value==='original_follow'?'原图':'总览';
  overviewPreview.alt=layout.value==='original_follow'?'原图':'实时总览';
  document.getElementById('title').textContent=document.title;fit();
  try{
   if(!window.opener||window.opener.closed){bindStream(null);bindOriginalStream(null);bindPreview(null);bindOverviewPreview(null);status.textContent='控制网页已关闭；当前保留最后一帧。请重新从控制页弹出窗口。';return;}
   window.opener.wycDisplay?.attach(window,layout.value);
  }catch{bindStream(null);status.textContent='请从同一个控制网页弹出显示窗口。';}
 }
 window.wycObservation={overview,output,bindStream,bindPreview,bindOverviewPreview,drawPeople,originalFrame,clearOriginal,usesVideo:()=>!video.hidden&&!!video.srcObject,
  setCrop:value=>{document.getElementById('outputPicture').dataset.crop=value==='right'?'right':'full';},
  updateBadge:source=>{const badge=document.getElementById('outputStatus');badge.hidden=true;badge.getContext('2d').clearRect(0,0,badge.width,badge.height);},
  setAttitude:text=>{attitude.textContent=text;attitude.hidden=!text;},
  hideMarker:value=>{document.getElementById('markerCover').hidden=!value;},
  setStatus:(text,note)=>{status.textContent=text;document.getElementById('overviewStatus').textContent=note;}};
 layout.addEventListener('change',attach);const resize=new ResizeObserver(fit);resize.observe(document.getElementById('outputScreen'));resize.observe(document.getElementById('overviewPicture').parentElement);
 document.getElementById('fullscreen').addEventListener('click',async()=>{
  try{if(document.fullscreenElement)await document.exitFullscreen();else await document.documentElement.requestFullscreen();}
  catch{status.textContent='可按 F11 使用浏览器全屏。';}
 });
 document.addEventListener('fullscreenchange',()=>{document.getElementById('fullscreen').textContent=document.fullscreenElement?'退出全屏':'全屏显示';fit();});
 document.getElementById('close').addEventListener('click',()=>window.close());
 function forward(type,e){
  if(layout.value==='original_follow')return;
  const r=overview.getBoundingClientRect(),scale=Math.min(r.width/640,r.height/360);if(scale<=0)return;
  const x=(e.clientX-r.left-(r.width-640*scale)/2)/scale,y=(e.clientY-r.top-(r.height-360*scale)/2)/scale;
  try{window.opener?.wycDisplay?.pointer(window,type,x,y);}catch{}
 }
 overview.addEventListener('pointerdown',e=>{if(e.button!==0)return;dragging=true;overview.setPointerCapture(e.pointerId);forward('down',e);e.preventDefault();});
 overview.addEventListener('pointermove',e=>{if(dragging)forward('move',e);});
 overview.addEventListener('pointerup',e=>{if(dragging)forward('up',e);dragging=false;});
 overview.addEventListener('pointercancel',e=>{dragging=false;forward('cancel',e);});
 addEventListener('pagehide',()=>{bindStream(null);bindOriginalStream(null);bindPreview(null);bindOverviewPreview(null);});attach();setInterval(attach,1000);
})();
