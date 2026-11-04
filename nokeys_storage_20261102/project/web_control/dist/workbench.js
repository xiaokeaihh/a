'use strict';
/* Presentation only: keep every media element, handler, ID and API owner intact. */
(()=>{
 const byId=id=>document.getElementById(id);
 const create=(tag,cls,text)=>{const el=document.createElement(tag);if(cls)el.className=cls;if(text)el.textContent=text;return el;};
 const title='稳视·鱼眼矫正与智能取景系统';
 document.title=title;
 const brand=document.querySelector('.brand');
 if(brand){brand.replaceChildren();brand.insertAdjacentHTML('beforeend','<svg viewBox="0 0 40 40" fill="none" aria-hidden="true"><path d="M14 5H6v8M26 5h8v8M6 27v8h8M34 27v8h-8" stroke="currentColor" stroke-width="2.5"/><circle cx="20" cy="20" r="8" stroke="currentColor" stroke-width="2"/><path d="M13 20h14" stroke="currentColor" stroke-width="1.5"/></svg>');brand.append(create('h1','',title));}
 const main=document.querySelector('main'),header=document.querySelector('header');
 const nav=create('nav','workbench-nav');nav.setAttribute('aria-label','工作台导航');
 const routes=[['监看','monitor'],['录像','recordings'],['全景','panorama']];
 routes.forEach(([text,key])=>{const a=create('a','',text);a.href='#/'+key;a.dataset.page=key;nav.append(a);});
 const toolbar=create('div','device-toolbar');toolbar.id='deviceToolbar';
 const source=byId('inputSourcePanel'),actions=document.querySelector('.hero .actions'),capture=document.querySelector('.capture');
 if(source){source.querySelector('h2').textContent='输入';source.querySelector('.muted')?.remove();toolbar.append(source);}
 if(actions)toolbar.append(actions);if(capture)toolbar.append(capture);
 main.prepend(nav,toolbar);
 const details=create('details','connection-details');details.id='deviceDetails';details.append(create('summary','','连接详情'));
 ['connection','connectHint','inputSourceState','previewState','serialCaption','commandState','serviceState','uiRevision'].forEach(id=>{const n=byId(id);if(n)details.append(n);});
 if(byId('uiRevision'))byId('uiRevision').textContent='20261028-original-panorama-raw-r3';
 const alert=create('div','workbench-alert');alert.id='workbenchAlert';alert.hidden=true;alert.setAttribute('role','status');alert.setAttribute('aria-live','polite');
 main.prepend(nav,toolbar,alert,details);document.querySelector('.hero')?.remove();
 const controlOnly=byId('controlsOnly');if(controlOnly&&header){const btn=create('button','workbench-header-action','仅显示控制');btn.id='workbenchControlsOnly';btn.type='button';btn.setAttribute('aria-pressed',String(controlOnly.checked));const sync=()=>{btn.setAttribute('aria-pressed',String(controlOnly.checked));btn.textContent=controlOnly.checked?'显示画面':'仅显示控制';};btn.addEventListener('click',()=>{controlOnly.checked=!controlOnly.checked;controlOnly.dispatchEvent(new Event('change',{bubbles:true}));sync();});controlOnly.addEventListener('change',sync);header.append(btn);}
 document.querySelector('#overviewPanel .float-drag-handle>span:first-child').textContent='总览';
 const trackingDetails=document.querySelector('#trackingPanel .tracking-details');
 ['trackingCapture','personDeviceHint','compositionStatus'].forEach(id=>{const n=byId(id);if(n&&trackingDetails)trackingDetails.append(n);});
 document.querySelector('#trackingPanel .section-head .muted')?.remove();
 const composition=byId('compositionEnabled')?.parentElement;if(composition)for(const n of composition.childNodes)if(n.nodeType===Node.TEXT_NODE)n.textContent=' 智能构图';
 const installation=byId('installationCalibration'),stable=byId('stabilizationPanel');
 if(installation&&stable){const facts=stable.querySelector(':scope>.facts'),next=byId('stableNextStep');const summary=installation.querySelector('summary');if(facts)summary.after(facts);if(next)(facts||summary).after(next);}
 const view=byId('viewPanel');if(view){view.parentElement.prepend(view);const more=view.querySelector('details');if(more){const quad=more.querySelector('.quad-button'),grid=more.querySelector('.view-grid');if(quad)more.before(quad);if(grid)more.before(grid);more.remove();}}
 const image=byId('imageControlsPanel');if(image)image.querySelector('h2').textContent='图像';
 const recording=byId('recordingPanel');if(recording){recording.querySelector('h2').textContent='录像回放';const state=byId('recordingState');if(state?.textContent.startsWith('仅点击'))state.textContent='尚未开始录像';const info=create('details','recording-help');info.append(create('summary','','录像说明'));recording.querySelectorAll(':scope>.caption').forEach(n=>info.append(n));const library=create('details','recording-library');library.id='recordingLibrary';library.append(create('summary','','录像列表'));const refresh=byId('recordingRefresh'),list=byId('recordingList');if(refresh)library.append(refresh);if(list)library.append(list);library.append(info);recording.append(library);const browse=create('button','','录像列表 ↗');browse.id='recordingBrowse';browse.type='button';browse.addEventListener('click',()=>{library.open=!library.open;});recording.querySelector('.section-head').append(browse);}
 const panorama=byId('panoramaPanel');if(panorama){panorama.querySelector('h2').textContent='全景拍摄';panorama.querySelector('.section-head .muted')?.remove();}
 // Keep IDs and status nodes for existing controllers; omit these tools from
 // the visible product without destroying their bindings or polling targets.
 const internal=create('div','');internal.id='workbenchInternal';internal.hidden=true;main.append(internal);
 for(const node of [byId('pipelinePanel'),document.querySelector('.communication'),byId('colorDiagnostics'),byId('stableAdvanced'),trackingDetails])if(node)internal.append(node);
 image?.querySelectorAll(':scope>.caption,.image-help').forEach(node=>internal.append(node));
 const monitor=document.querySelector('.workspace');monitor.id='monitorPage';monitor.classList.add('workbench-page');monitor.setAttribute('aria-label','监看');
 const preview=document.querySelector('.preview.card');
 const monitorSlot=create('div','workbench-media-slot');monitorSlot.id='monitorPreviewSlot';preview.before(monitorSlot);monitorSlot.append(preview);
 const recordingsPage=create('section','workbench-page recordings-page');recordingsPage.id='recordingsPage';recordingsPage.setAttribute('aria-label','录像');
 const recordingLayout=create('div','recordings-layout'),recordingSlot=create('div','workbench-media-slot');recordingSlot.id='recordingPreviewSlot';
 recordingLayout.append(recordingSlot,recording);recordingsPage.append(recordingLayout);main.append(recordingsPage);
 const panoramaPage=create('section','workbench-page panorama-page');panoramaPage.id='panoramaPage';panoramaPage.setAttribute('aria-label','全景');
 const panoramaSlot=create('div','workbench-media-slot panorama-live-preview');panoramaSlot.id='panoramaPreviewSlot';
 panoramaPage.append(panoramaSlot,panorama);main.append(panoramaPage);
 const pages={monitor,recordings:recordingsPage,panorama:panoramaPage};
 const slots={monitor:monitorSlot,recordings:recordingSlot,panorama:panoramaSlot};
 const outputCaption=byId('outputPanel').querySelector('.float-drag-handle>span:first-child');
 const selectPage=()=>{
  const requested=location.hash.replace(/^#\/?/,'');
  const key=Object.hasOwn(pages,requested)?requested:'monitor';
  if(location.hash!=='#/'+key)history.replaceState(null,'','#/'+key);
  // Move the existing media once. Do not recreate streams, video, recorder,
  // canvas or serial owners when switching the visible page.
  if(preview.parentElement!==slots[key]){
   if(typeof slots[key].moveBefore==='function')slots[key].moveBefore(preview,null);
   else{
    const playing=[...preview.querySelectorAll('video')].filter(video=>!video.paused);
    slots[key].append(preview);for(const video of playing)if(video.paused)void video.play().catch(()=>{});
   }
  }
  for(const [name,page] of Object.entries(pages))page.hidden=name!==key;
  document.body.dataset.workbenchPage=key;
  for(const link of nav.querySelectorAll('a')){
   const selected=link.dataset.page===key;link.classList.toggle('selected',selected);
   if(selected)link.setAttribute('aria-current','page');else link.removeAttribute('aria-current');
  }
  outputCaption.textContent=key==='panorama'?'实时采集画面':'跟随画面';
  document.title=routes.find(([,name])=>name===key)[0]+' · '+title;
  window.scrollTo({top:0,left:0,behavior:'instant'});
  requestAnimationFrame(()=>dispatchEvent(new Event('resize')));
 };
 addEventListener('hashchange',selectPage);selectPage();
 // Watch only status text, never video/canvas mutations or image frames.
 const nodes=['connectHint','commandState','previewState','inputSourceState','imageControlsStatus','trackingCapture','stableMessage'].map(byId).filter(Boolean);
 const generic=/^(?:正在连接本地服务|等待新版 FPGA|连接后可|等待开发板|按板端实际)/;
 const bad=/失败|超时|拒绝|中断|异常|未就绪|未发现开发板|未找到视频|未收到切换完成/;
 const updateNotice=()=>{const messages=nodes.map(n=>n.textContent.trim()).filter(t=>t&&!generic.test(t)&&bad.test(t));const text=[...new Set(messages)].join('　');if(alert.textContent!==text)alert.textContent=text;alert.hidden=!text;};
 const observer=new MutationObserver(updateNotice);nodes.forEach(n=>observer.observe(n,{childList:true,subtree:true,characterData:true}));updateNotice();
 window.wycWorkbench={version:'20261028-original-panorama-raw-r3',get page(){return document.body.dataset.workbenchPage;}};
})();
