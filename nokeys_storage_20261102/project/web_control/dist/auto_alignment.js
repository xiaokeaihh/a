'use strict';
let autoFrameBusy=false,autoEnding=false,autoPreviousMediaTime=-1,autoLastToken=null,autoControlBusy=false;
const autoCanvas=document.createElement('canvas');autoCanvas.width=640;autoCanvas.height=360;
function updateAutomaticCalibration(s){
 const a=s.auto_alignment||{},collecting=a.state==='collecting',solving=a.state==='solving',active=collecting||solving;
 const v=$('video'),videoReady=!!stream&&v.videoWidth===1280&&v.videoHeight===720;
 const ready=s.connected&&s.imu_online&&s.bias_ready&&s.hardware?.valid&&s.hardware?.mode===0&&!s.hardware?.test&&videoReady;
 $('autoStart').disabled=autoControlBusy||active||!ready;
 $('autoFinish').disabled=autoControlBusy||autoEnding||!collecting||a.valid_pairs<50;
 $('autoCancel').disabled=autoControlBusy||!active;
 for(const id of ['axisStart','axisFinish','stableReference','stableStart','stableSettings','stableMode','shakeStrength'])if(active)$(id).disabled=true;
 if(!active){$('stableMode').disabled=false;$('shakeStrength').disabled=false;$('stableSettings').disabled=false;}
 if(collecting)$('autoState').textContent=`采集中 ${a.elapsed_seconds.toFixed(1)}秒 / ${a.max_seconds}秒 · 有效运动 ${a.valid_pairs}组 · ${a.note||'请缓慢左右、上下及绕镜头转动；结束前放稳1秒'}`;
 else if(solving)$('autoState').textContent='正在计算安装关系，原标定保持有效…';
 else if(a.state==='complete')$('autoState').textContent=`自动标定已保存 · 有效运动 ${a.result.valid_pairs}组 · 拟合误差 ${a.result.fit_error_deg.toFixed(2)}°；拍摄时间偏移保持原值。`;
 else if(a.state==='failed')$('autoState').textContent='自动标定失败，保留旧参数：'+a.error;
 else $('autoState').textContent=!s.connected?'先连接开发板串口。':!s.imu_online?'等待IMU有效数据。':!s.bias_ready?'将相机放稳约2秒。':!videoReady?'先查找并打开USB Video采集卡画面。':s.hardware?.mode!==0||s.hardware?.test?'在网页选择摄像头输入和原图，再开始自动标定。':'可以开始自动标定；采集中请以转动为主，减少平移。';
 $('autoStart').title=$('autoStart').disabled?$('autoState').textContent:'';
 $('shakeState').textContent=s.mode==='follow'?`三轴消抖：${({light:'轻柔',balanced:'均衡',strong:'较强'})[s.shake_strength]||'均衡'} · 当前补偿 ${Number(s.shake_correction_deg||0).toFixed(2)}° / 4° · 不额外等待图像帧；裁剪余量不足时仍可能露出边界。`:'三轴消抖过滤快速小抖动，持续转动时平滑跟随。选择该模式并开启稳像后生效。';
 if(a.token!==autoLastToken){autoLastToken=a.token;autoPreviousMediaTime=-1;}
 if(collecting&&!autoFrameBusy&&!autoEnding&&videoReady&&a.elapsed_seconds<a.max_seconds)void sendAutomaticFrame(a.token);
}
async function sendAutomaticFrame(token){
 if(autoFrameBusy)return;
 const v=$('video');if(v.currentTime===autoPreviousMediaTime)return;
 autoFrameBusy=true;autoPreviousMediaTime=v.currentTime;
 try{
  const captured=Date.now()/1000;autoCanvas.getContext('2d').drawImage(v,0,0,640,360);
  const jpeg=autoCanvas.toDataURL('image/jpeg',.8).split(',')[1];
  await nativeAPI('calibration/frame',{token,captured_at:captured,jpeg});
 }catch(e){$('autoState').textContent='采集提示：'+e.message;}
 finally{autoFrameBusy=false;}
}
async function automaticAction(action){
 if(autoControlBusy)return;autoControlBusy=true;
 if(action==='auto_finish')autoEnding=true;
 try{
  if(action==='auto_start'){
   const v=$('video');if(!stream||v.videoWidth!==1280||v.videoHeight!==720)throw Error('先打开1280×720 HDMI原图预览');
  }
  if(action==='auto_finish'&&autoFrameBusy)throw Error('当前帧正在上传，请稍后再次结束');
  nativeState=await nativeAPI('action',{action});updateCalibrationControls(nativeState);
 }catch(e){$('stableMessage').textContent=e.message;}
 finally{autoControlBusy=false;autoEnding=false;if(nativeState)updateAutomaticCalibration(nativeState);}
}
$('autoStart').onclick=()=>automaticAction('auto_start');
$('autoFinish').onclick=()=>automaticAction('auto_finish');
$('autoCancel').onclick=()=>automaticAction('auto_cancel');
