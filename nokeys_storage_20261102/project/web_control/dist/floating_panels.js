'use strict';
(()=>{
 const panels=new Map(),controls=document.getElementById('controlsOnly'),message=document.getElementById('displayMessage');
 let highest=3000;
 for(const panel of document.querySelectorAll('[data-floating-kind]')){
  const kind=panel.dataset.floatingKind,media=panel.querySelector('.monitor-media');
  const picture=media.querySelector('canvas,.video-wrap'),header=panel.querySelector('.float-drag-handle');
  const resize=document.createElement('div');resize.className='float-resize-handle';resize.hidden=true;
  resize.tabIndex=0;resize.setAttribute('role','button');resize.setAttribute('aria-label','调整'+(kind==='overview'?'总览':'跟随画面')+'浮窗尺寸');panel.append(resize);
  const item={kind,panel,media,picture,header,resize,floating:false,placeholder:null,maximized:null};panels.set(kind,item);
  header.addEventListener('pointerdown',e=>{
   if(!item.floating||e.button!==0||e.target.closest('button'))return;
   begin(e,item,'move',header);
  });
  resize.addEventListener('pointerdown',e=>{if(item.floating&&e.button===0)begin(e,item,'resize',resize);});
  resize.addEventListener('keydown',e=>{
   if(!item.floating||!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(e.key))return;
   const r=panel.getBoundingClientRect();size(item,r.width+(e.key==='ArrowRight'?20:e.key==='ArrowLeft'?-20:0),r.height+(e.key==='ArrowDown'?20:e.key==='ArrowUp'?-20:0));e.preventDefault();
  });
  panel.addEventListener('pointerdown',()=>{if(item.floating)panel.style.zIndex=String(++highest);});
  new ResizeObserver(()=>fit(item)).observe(media);
 }
 function fit(item){
  if(!item.floating){item.picture.style.width='';item.picture.style.height='';return;}
  const r=item.media.getBoundingClientRect(),w=Math.max(0,Math.min(r.width,r.height*16/9));
  item.picture.style.width=w+'px';item.picture.style.height=w*9/16+'px';
 }
 function size(item,w,h){
  item.panel.style.width=Math.max(240,Math.min(innerWidth-16,w))+'px';
  item.panel.style.height=Math.max(200,Math.min(innerHeight-16,h))+'px';fit(item);
 }
 function position(item,x,y){
  const r=item.panel.getBoundingClientRect();
  item.panel.style.left=Math.max(0,Math.min(Math.max(0,innerWidth-r.width),x))+'px';
  item.panel.style.top=Math.max(0,Math.min(Math.max(0,innerHeight-r.height),y))+'px';
 }
 function begin(e,item,operation,handle){
  const r=item.panel.getBoundingClientRect(),sx=e.clientX,sy=e.clientY;
  item.maximized=null;item.panel.querySelector('[data-float-maximize]').textContent='铺满网页';
  handle.setPointerCapture(e.pointerId);e.preventDefault();
  function move(event){
   if(operation==='move')position(item,r.left+event.clientX-sx,r.top+event.clientY-sy);
   else size(item,r.width+event.clientX-sx,r.height+event.clientY-sy);
  }
  function end(){handle.removeEventListener('pointermove',move);handle.removeEventListener('pointerup',end);handle.removeEventListener('pointercancel',end);}
  handle.addEventListener('pointermove',move);handle.addEventListener('pointerup',end);handle.addEventListener('pointercancel',end);
 }
 function describe(){
  const count=[...panels.values()].filter(v=>v.floating).length;
  if(!count&&!window.wycDisplay?.hasWindows()){controls.checked=false;document.body.classList.remove('controls-only');}
  message.textContent=count?`已浮起 ${count} 幅画面 · 拖动标题栏移动，拖动右下角缩放；点击“归位”收回。`:'两幅画面已归位；点标题栏的“浮窗”可单独浮起。';
 }
 function float(kind){
  const item=panels.get(kind);if(!item||item.floating){if(item)item.panel.style.zIndex=String(++highest);return;}
  const placeholder=document.createElement('div');placeholder.className='monitor-placeholder';
  const label=document.createElement('span');label.textContent=(kind==='overview'?'总览':'跟随画面')+'已浮起';
  const back=document.createElement('button');back.textContent='归位';back.onclick=()=>dock(kind);placeholder.append(label,back);
  item.panel.replaceWith(placeholder);item.placeholder=placeholder;document.body.append(item.panel);
  item.floating=true;item.panel.classList.add('floating-panel');item.resize.hidden=false;
  item.panel.querySelector('[data-float-toggle]').textContent='归位';item.panel.querySelector('[data-float-maximize]').hidden=false;
  const w=Math.max(260,Math.min(400,(innerWidth-(innerWidth>1100?428:48))/2));size(item,w,w*9/16+82);
  position(item,kind==='overview'?16:32+w,96);item.panel.style.zIndex=String(++highest);describe();
 }
 function dock(kind){
  const item=panels.get(kind);if(!item||!item.floating)return;
  item.placeholder.replaceWith(item.panel);item.placeholder=null;item.floating=false;item.maximized=null;
  item.panel.classList.remove('floating-panel');item.panel.removeAttribute('style');item.resize.hidden=true;
  item.panel.querySelector('[data-float-toggle]').textContent='网页浮窗';
  item.panel.querySelector('[data-float-maximize]').hidden=true;item.panel.querySelector('[data-float-maximize]').textContent='铺满网页';
  fit(item);describe();
 }
 function both(){float('overview');float('output');}
 document.querySelectorAll('[data-float-toggle]').forEach(button=>button.addEventListener('click',()=>{
  const kind=button.dataset.floatToggle;panels.get(kind).floating?dock(kind):float(kind);
 }));
 document.querySelectorAll('[data-float-maximize]').forEach(button=>button.addEventListener('click',()=>{
  const item=panels.get(button.dataset.floatMaximize);if(!item.floating)return;
  if(item.maximized){const r=item.maximized;item.maximized=null;size(item,r.width,r.height);position(item,r.left,r.top);button.textContent='铺满网页';}
  else{item.maximized=item.panel.getBoundingClientRect();size(item,innerWidth-16,innerHeight-16);position(item,8,8);button.textContent='还原大小';item.panel.style.zIndex=String(++highest);}
 }));
 document.getElementById('floatBoth').addEventListener('click',both);
 document.getElementById('floatDockAll').addEventListener('click',()=>{dock('overview');dock('output');});
 addEventListener('keydown',e=>{if(e.key==='Escape'){dock('overview');dock('output');}});
 controls.addEventListener('change',()=>{if(controls.checked){if(window.wycDisplay?.hasWindows()){dock('overview');dock('output');}else both();}document.body.classList.toggle('controls-only',controls.checked);});
 addEventListener('resize',()=>{for(const item of panels.values())if(item.floating){const r=item.panel.getBoundingClientRect();size(item,r.width,r.height);position(item,r.left,r.top);}});
 function update(){
  const s=typeof nativeState==='undefined'?null:nativeState;
  const video=document.getElementById('video'),image=document.getElementById('personVideo');
  const visible=(!image.hidden&&image.naturalWidth>0)||(video.srcObject&&video.readyState>=2);
  // This covers only displayed pixels. Both frame decoders keep the untouched
  // source, so time/pose pairing and tracking remain unchanged.
  document.getElementById('frameMarkerCover').hidden=!(visible&&(s?.hardware?.mode===2||s?.image_controls?.panorama_marker));
 }
 window.wycFloating={float,dock,both,update};setInterval(update,200);update();
})();
