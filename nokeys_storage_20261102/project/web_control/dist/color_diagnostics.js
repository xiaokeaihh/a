"use strict";
(()=>{
 const pattern=document.getElementById('colorPattern'),camera=document.getElementById('colorCamera'),status=document.getElementById('colorDiagnosticState');
 let waiting=null,deadline=0,sending=false,failure='';
 function refresh(){
  if(window.wycPanorama?.active()){pattern.disabled=camera.disabled=true;status.textContent='全景拍摄期间保持当前图源。';return;}
  const state=typeof nativeState!=='undefined'?nativeState:null;
  const connected=!!state?.connected&&!!state?.online;
  pattern.disabled=camera.disabled=!connected||sending||waiting!==null;
  if(!connected){waiting=null;status.textContent='连接开发板后可使用；切换测试图会停止跟随。';return;}
  const showing=!!state.hardware?.test;
  if(waiting!==null){
   if(showing===waiting){waiting=null;failure='';}
   else if(Date.now()<deadline){status.textContent='正在等待开发板切换画面…';return;}
   else{waiting=null;failure='未收到切换回报，请确认已烧录本次颜色修正版固件。';}
  }
  pattern.disabled=sending||!!showing;camera.disabled=sending||!showing;
  status.textContent=failure||(showing?'当前显示彩条与灰阶；白色和灰色应保持中性。':'当前显示摄像头画面；切换测试图会停止跟随。');
 }
 async function change(enabled){
  if(sending)return;sending=true;failure='';refresh();
  try{
   nativeState=await nativeAPI('action',{action:'color_diagnostic',enabled});
   waiting=enabled;deadline=Date.now()+2000;status.textContent='正在等待开发板切换画面…';
   updateCalibrationControls(nativeState);
  }catch(e){failure=e.message;}
  finally{sending=false;refresh();}
 }
 pattern.addEventListener('click',()=>change(true));camera.addEventListener('click',()=>change(false));
 setInterval(refresh,400);refresh();
})();
