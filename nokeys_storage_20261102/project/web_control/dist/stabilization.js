'use strict';
// UI polls status; the native service owns serial and the high-rate fusion loop.
let nativeService=false,nativeState=null,nativePolling=false,nativeConnecting=false;
let nativePortsRefreshing=false,lastNativePortsCheck=0,nativePortsSignature='';
let stableActionBusy=false,manualCalibrationError='';
async function refreshNativePorts(){
 if(nativePortsRefreshing)return;nativePortsRefreshing=true;
 try{
  const ports=await nativeAPI('ports');lastNativePortsCheck=Date.now();
  const signature=JSON.stringify(ports);if(signature===nativePortsSignature)return;
  nativePortsSignature=signature;const selector=$('serialPort'),previous=nativeState?.port||selector.value;
  const placeholder=document.createElement('option');placeholder.value='';placeholder.textContent='选择开发板串口';
  selector.replaceChildren(placeholder,...ports.map(p=>{const o=document.createElement('option');o.value=p.port;o.textContent=p.port+' · '+p.description;return o;}));
  const preferred=ports.find(p=>/CP210/i.test(p.description))||ports.find(p=>/CH34[01]|FTDI|USB.*(?:Serial|UART)/i.test(p.description));
  selector.value=ports.some(p=>p.port===previous)?previous:preferred?.port||'';
  if(!selector.value&&!port)connectionHint('未发现开发板 USB 串口。重新插接 USB 后，列表会自动更新。',true);
 }finally{nativePortsRefreshing=false;}
}
function updateCalibrationControls(s){
 const live=s.connected&&s.imu_online;
 if(!s.connected)manualCalibrationError='';
 const picture=document.querySelector('#outputPanel .video-wrap');
 // Keep the full capture for tracking/recording; present the corrected pane.
 if(picture&&Number.isInteger(s.hardware?.mode))picture.dataset.crop=s.hardware.mode===2&&!s.hardware.test&&trackingIsActive(s)?'right':'full';
 if(s.connected&&(!s.saved_calibration||s.axis_collecting))$('calibrationDetails').open=true;
 $('axisStart').disabled=stableActionBusy||!live||!s.bias_ready;
 $('axisFinish').disabled=stableActionBusy||!live||!s.axis_collecting;
 $('stableReference').disabled=stableActionBusy||!live||!s.bias_ready||!s.axis_calibrated||s.axis_collecting;
 $('stableStart').disabled=stableActionBusy||!live||!s.reference_ready||s.axis_collecting;
 const next=!s.connected?'先连接开发板串口。':!s.imu_online?'等待 IMU 有效数据；恢复在线后才能校准。':!s.bias_ready?(s.saved_calibration?'已检测到保存的安装标定。将相机放稳约2秒即可自动恢复，无需再次转动校准。':'将相机放稳约2秒，等待静止零偏完成。'):s.axis_collecting?'正在采集光轴：从相机后方看，绕镜头轴顺时针转动30°～60°，然后点击“结束光轴校准”。':!s.axis_calibrated?'静止零偏已完成。下一步：点击“开始光轴校准”，绕镜头轴顺时针转动30°～60°，再点击“结束光轴校准”；完成后才能设置水平基准。':!s.reference_ready?'光轴已识别。将相机摆正、画面调水平，停止转动约1秒，再点击“设为水平基准”。':s.reference_source==='saved'?'安装标定已自动恢复，可直接开启稳像。三轴模式以本次连接的起始姿态为参考。':'水平基准已设置，可以点击“开启稳像 · 矫正图/原图与矫正图对比图/跟随”。';
 $('stableNextStep').textContent=next;
 const p=s.axis_progress;
 $('axisProgress').textContent=p&&p.samples?`有效转动幅度 ${p.excursion_deg.toFixed(1)}° / ${p.required_deg}° · 有效样本 ${p.samples}（转回原位不会抵消）`:s.axis_collecting?'有效转动幅度 0.0° / 20° · 等待转动数据':'开始校准后显示有效转动幅度。';
 const feedback=$('axisFeedback');
 if(feedback){
  const failed=s.error&&/光轴|旋转数据|转动幅度|转动轴|静止数据|停止转动|方向长度/.test(s.error)?s.error:manualCalibrationError;
  feedback.textContent=failed?`校准尚未完成：${failed}`:s.axis_collecting?(!p?.samples?`尚未采到有效转动，请绕镜头轴转动相机；当前采样门槛 ${Number(p?.minimum_rate_dps??5).toFixed(1)}°/秒。`:p.excursion_deg<p.required_deg?'幅度尚未达到要求，可继续转动，再点击“结束光轴校准”。':'已达到转动幅度要求，可点击“结束光轴校准”；成功后开放水平基准。'):s.axis_calibrated?'光轴校准已完成；将相机摆正并放稳约1秒，再点击“设为水平基准”。':'';
  if(failed&&s.axis_collecting)$('stableNextStep').textContent=feedback.textContent;
 }
 if(s.connected&&!p)$('stableNextStep').textContent='PC 服务尚未加载本次校准修复：先断开串口，关闭原服务窗口，再重新运行“启动稳像控制.cmd”。仅刷新网页不会更新角度算法。';
 $('axisStart').textContent=s.axis_collecting?'重新开始光轴校准':'开始光轴校准';
 for(const id of ['axisStart','axisFinish','stableReference','stableStart'])$(id).title=$(id).disabled?next:'';
}
function bindNativePort(){
 port={native:true,writable:{getWriter(){return {
  async write(bytes){await nativeAPI('action',{action:'view',view:bytes[3],sequence:bytes[2]});},releaseLock(){}};}}};
  resetViewWrites();closing=false;gotFirmware=false;lastStatus=0;clearPending();
 $('connect').disabled=true;$('disconnect').disabled=false;$('connection').textContent='串口已连接 · 等待回报';
}
async function nativeAPI(path,body){
 const r=await fetch('/api/'+path,body?{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)}:{cache:'no-store'});
 const value=await r.json();if(!r.ok)throw new Error(value.error||'操作失败');return value;
}
async function discoverNative(){
 try{
  const state=await nativeAPI('status');if(!state.available)return;
  $('serviceState').textContent='统一控制服务已就绪';
  nativeService=true;$('stabilizationPanel').hidden=false;
  nativeState=state;await refreshNativePorts();
  $('stableMode').value=state.mode||'roll';$('shakeStrength').value=state.shake_strength||'balanced';$('stableZoom').value=state.zoom||1;
  $('stableOffset').value=(state.offset_us||0)/1000;$('stableDirection').value=state.image_y_sign===-1?'-1':'1';
  if($('serialPort').value||state.connected)connectionHint('统一控制已就绪。选择开发板串口，连接一次即可控制全部功能。');
  $('serialCaption').textContent='视角、IMU与稳像共享同一串口';
  nativeState=state;
  if(state.connected&&!port)bindNativePort();
  updateCalibrationControls(state);
 }catch(e){$('serviceState').textContent='统一控制服务未连接';connectionHint('统一控制服务未就绪，请运行“启动网页.cmd”，再打开本地控制网址。',true);}
}
async function connectNative(){
 if(nativeConnecting||port)return;nativeConnecting=true;$('connect').disabled=true;
 try{
  await refreshNativePorts();
  const selected=$('serialPort').value;if(!selected)throw new Error('未发现串口，请检查开发板连接');
  if(port)return;
  nativeState=await nativeAPI('connect',{port:selected});
  bindNativePort();requestInitialRaw();
  updateCalibrationControls(nativeState);
  connectionHint('保持相机静止约2秒，等待零偏校准。');log('PC 稳像服务已连接 '+selected);
 }catch(e){message(e.message);connectionHint(e.message,true);}
 finally{nativeConnecting=false;$('connect').disabled=!!port;}
}
async function disconnectNative(){
 try{await nativeAPI('disconnect',{});}catch(e){log(e.message);connectionHint('断开失败：'+e.message,true);return;}
  port=null;resetViewWrites();nativeState=null;clearPending();gotFirmware=false;imuOnline=false;imu=null;lastIMU=0;
 updateCalibrationControls({});
 $('connect').disabled=false;$('disconnect').disabled=true;$('connection').textContent='串口未连接';
 $('activeView').textContent='等待开发板';$('mode').textContent='—';$('imuId').textContent='等待数据';updateIMU();
 for(const b of viewButtons)b.classList.remove('selected');enableViews();message('串口已断开。');
}
async function stableAction(action,extra={}){
 if(stableActionBusy)return;
 if(['axis_start','axis_finish','reference'].includes(action))manualCalibrationError='';
 stableActionBusy=true;if(nativeState)updateCalibrationControls(nativeState);
 try{
  nativeState=await nativeAPI('action',{action,...extra});updateCalibrationControls(nativeState);
  $('stableMessage').textContent=({axis_start:'光轴采集已开始，请按上方提示转动相机。',axis_finish:'光轴校准成功，请停止转动并设置水平基准。',reference:'水平基准已设置。'})[action]||'操作已接收';
 }
 catch(e){
  $('stableMessage').textContent=e.message;
  // A rejected finish keeps collecting. Refresh the authoritative state and
  // show the reason next to the manual controls, even with advanced UI hidden.
  try{nativeState=await nativeAPI('status');}catch{}
  if(['axis_start','axis_finish','reference'].includes(action))manualCalibrationError=e.message;
 }
 finally{stableActionBusy=false;if(nativeState)updateCalibrationControls(nativeState);}
}
async function pollNative(){
 if(!nativeService||nativePolling)return;nativePolling=true;
 try{
  const s=await nativeAPI('status');nativeState=s;
  if(!s.connected&&Date.now()-lastNativePortsCheck>2000)await refreshNativePorts();
  if(s.connected&&!port)bindNativePort();
  if(!s.connected&&port?.native){port=null;gotFirmware=false;imuOnline=false;imu=null;lastIMU=0;clearPending();$('connect').disabled=false;$('disconnect').disabled=true;$('connection').textContent='串口未连接';$('activeView').textContent='等待开发板';$('mode').textContent='—';$('imuId').textContent='等待数据';updateIMU();}
  if(port?.native&&s.connected){
   const h=s.hardware;
   if(s.online&&h.view!==undefined)handleLine(`BW=${h.view},${h.sequence.toString(16).padStart(2,'0')},${h.mode},${+h.valid},${+h.test}`);
   if(s.imu_online&&s.raw){
    imu=s.raw;imuOnline=true;lastIMU=Date.now();$('imuId').textContent='ICM-42688-P · 在线';
    [...$('imuValues').querySelectorAll('b')].forEach((b,i)=>b.textContent=imu[i]);
   }else{
    imuOnline=false;imu=null;lastIMU=0;$('imuId').textContent='IMU 数据中断／异常';
    [...$('imuValues').querySelectorAll('b')].forEach(b=>b.textContent='—');updateIMU();
   }
  }
  $('stableBias').textContent=!s.connected?'等待连接':!s.imu_online?'等待IMU数据':s.bias_ready?'已完成':'静止校准中';
  $('stableAxis').textContent=s.axis_collecting?'正在采集转动':s.reference_ready?(s.reference_source==='saved'?'已自动恢复安装标定':'已设置水平基准'):s.axis_calibrated?'光轴已识别，等待水平基准':s.saved_calibration?'等待自动恢复':'等待光轴校准';
  const shownStable=s.connected&&s.online&&s.hardware.stabilized&&s.hardware.mode!==0&&s.hardware.view>=1&&s.hardware.view<=7;
  const layout=s.hardware.mode===1?'四宫格':s.hardware.mode===2?'对比右侧':s.hardware.view===6?'原图与矫正图对比图':'矫正图';
  const staticOnly=s.hardware.compact_pose_capable&&s.hardware.view>=1&&s.hardware.view<=5;
  $('stableActual').textContent=!s.connected?'串口未连接':!s.online?'等待开发板显示回报':staticOnly?'当前四角/四宫格为固定矫正 · 不使用IMU':s.imu_paused?'IMU暂时中断 · 暂停补偿，恢复后自动继续':shownStable?`HDMI 正在显示稳像 · ${layout}`:s.enabled?(s.hardware.mode===0?'稳像已开启 · 原图保持原始画面':!s.hardware.compact_pose_capable&&!s.hardware.all_views_capable&&s.hardware.view!==7?'当前烧录版本仅支持基准稳像，请烧录本版固件':'等待对应帧姿态'):'稳像关闭';
  $('exposurePreset').textContent='本工程曝光预设：500行 · 约22.5 ms · 增益2.0×；烧录统一曝光版后生效。';
  const poseLabels=$('imuPose').querySelectorAll('small');poseLabels[0].textContent=s.reference_ready?'相机俯仰':'传感器俯仰';poseLabels[1].textContent=s.reference_ready?'相机横滚':'传感器横滚';
  $('stableCounts').textContent=`已下发姿态 ${s.frames_sent} · IMU 缺样 ${s.sample_loss} · CRC 错误 ${s.crc_errors} · 板端丢包 ${s.hardware.dropped||0} · IMU自动恢复 ${s.imu_health?.resumes||0} 次`;
  updateCalibrationControls(s);
  updatePipelineDiagnostics(s);
  if(typeof updateAutomaticCalibration==='function')updateAutomaticCalibration(s);
  if(typeof updateTargetTracking==='function')updateTargetTracking(s);
  window.wycWorkflow?.update(s);
  window.wycPanorama?.update(s);
  if(s.image_controls?.input_source==='hdmi')$('sourceState').textContent='图源：HDMI输入';
  if(s.error)$('stableMessage').textContent=s.error;
 }catch(e){updateCalibrationControls({});$('serviceState').textContent='控制服务连接中断';$('stableMessage').textContent='统一控制服务连接中断：'+e.message;}
 finally{nativePolling=false;}
}
$('axisStart').onclick=()=>stableAction('axis_start');
$('axisFinish').onclick=()=>stableAction('axis_finish');
$('stableReference').onclick=()=>stableAction('reference');
$('stableStart').onclick=async()=>{try{await nativeAPI('action',stableSettingsPayload());await stableAction('enable',{enabled:true});}catch(e){$('stableMessage').textContent=e.message;}};
$('stableStop').onclick=()=>stableAction('enable',{enabled:false});
function stableSettingsPayload(){return {action:'settings',mode:$('stableMode').value,zoom:Number($('stableZoom').value),offset_us:Number($('stableOffset').value)*1000,image_y_sign:Number($('stableDirection').value),shake_strength:$('shakeStrength').value};}
$('stableSettings').onclick=()=>stableAction('settings',stableSettingsPayload());
discoverNative();setInterval(pollNative,250);

function updatePipelineDiagnostics(s){
 const syncBox=$('outputSyncState'),sync=s.output_sync;
 if(syncBox)syncBox.textContent=!sync?'低延迟同步：等待固件回报':
  Date.now()/1000-sync.host_time>2?'低延迟同步：回报中断':
  !sync.hdmi_input?'低延迟同步：摄像头沿用原输出节拍':
  !sync.requested?'低延迟同步：未开启，请确认当前固件':
  !sync.following_input?'低延迟同步：等待稳定的 720p60 输入':
  !sync.phase_locked?'低延迟同步：正在学习当前显示模式':
  `低延迟同步：已锁定 · 数据就绪预算 ${Number(sync.worst_ready_ms).toFixed(2)} ms`;
 const d=s.diagnostics,box=$('pipelineState');if(!box)return;
 if(!d||!Number.isFinite(d.latency_ms)){box.textContent='等待新版 FPGA 的逐帧测量回报。';return;}
 box.textContent=(s.diagnostics_stale?'诊断回报中断，以下保留最后一帧数据。 ':'')+`固件诊断 v${d.diagnostic_version||0}${d.diagnostic_version>=4?" · 基准逐段出屏版":""} · 帧 ${d.frame_id} · ${d.output_pixels===230400?'640×360 局部渲染':'1280×720 全幅渲染'} · ${d.diagnostic_partial?"处理进行中累计 · ":""}${d.stabilized?'IMU稳像':'固定视角'}`;
 const ms=x=>Number(x).toFixed(1)+' ms';
 $('pipelineLat').textContent=ms(d.latency_ms);$('pipelineOverlap').textContent=ms(d.overlap_ms);
 $('pipelineCapRnd').textContent=d.diagnostic_partial?'处理中，待完成回报':ms(d.capture_ms)+' / '+ms(d.render_ms);$('pipelineQueDsp').textContent=ms(d.queue_ms)+' / '+ms(d.display_ms);
 $('pipelineFps').textContent=(d.camera_fps_tenths? (d.camera_fps_tenths/10).toFixed(1):'测量中')+' / '+d.new_fps+' fps';$('pipelineOut').textContent=d.output_hz?d.output_hz.toFixed(1)+' Hz':'测量中';
 const a=s.diagnostic_summary||{};$('pipelineSummary').textContent=a.frames?`最近 ${a.frames} 帧：平均 ${ms(a.lat_mean_ms)} · P95 ${ms(a.lat_p95_ms)} · 最大 ${ms(a.lat_max_ms)}`:'';
 $('pipelineLoss').textContent=`采集拒收 ${d.capture_drops} · 重复扫描 ${d.repeat_frames} · 渲染异常 ${d.render_errors} · 姿态回退 ${d.pose_fallbacks}${Number.isFinite(d.refill_rows)?` · DDR补读 ${d.refill_rows} 行 · 缓存命中 ${d.cache_hits} / 查询 ${d.cache_hits+d.cache_misses}`:""}`;
 if(d.diagnostic_version>=4&&!d.stabilized&&d.view===7&&d.mode!==0&&d.mode!==2)
  box.textContent+=d.first_before_render_done?' · 本帧在整帧收尾前已出屏':' · 本帧首像素晚于处理收尾（受60Hz相位和预算影响）';
 const legacy=(d.diagnostic_version||0)<3;
 const fields=[['geometry_ms','坐标计算活动'],['geometry_wait_ms','任务槽满等待'],['source_wait_ms','输出窗口内等源行'],['order_wait_ms','已就绪任务等输出窗口'],['ddr_read_wait_ms','读地址背压'],['read_response_wait_ms','读响应等待'],['cache_load_ms','缓存提交活动'],['refill_active_ms','补读总活动'],['pixel_wait_ms','像素请求受阻'],['lookup_wait_ms','缓存查询受阻'],['packet_assembly_ms','写包组装活动'],['writer_buffer_wait_ms','写包缓冲已满'],['ddr_write_wait_ms','写地址/数据背压'],['pixel_idle_ms','像素引擎空闲'],['pose_wait_ms','等姿态'],['slot_wait_ms','等帧槽']];
 $('pipelineWaits').replaceChildren(...fields.filter(([key])=>Number.isFinite(d[key])&&!(legacy&&key==='cache_load_ms')).map(([key,label])=>{if(legacy&&key==='source_wait_ms')label='旧版：源行/输出窗口混合等待';if(legacy&&key==='pixel_wait_ms')label='旧版：像素任务空闲';const node=document.createElement('div'),small=document.createElement('small'),value=document.createElement('b');small.textContent=label;value.textContent=ms(d[key]);node.append(small,value);return node;}));
}
