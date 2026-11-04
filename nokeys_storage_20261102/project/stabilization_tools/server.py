"""Single serial owner: 500-Hz fusion runs independently of webpage refresh."""
from pathlib import Path
from collections import deque
from http.server import ThreadingHTTPServer,SimpleHTTPRequestHandler
import argparse,json,struct,threading,time,webbrowser,csv,socket
import numpy as np
import serial
from serial.tools import list_ports
from protocol import Decoder,command,pose_packet,pose_bundle,active_pose_packet,attitude_packet
from attitude_display import camera_angles
from recordings import Recordings
from urllib.parse import urlsplit
from attitude import Fusion,Clock
from projection_reference import matrix,view_matrices,active_view_matrix,ROOT,CFG
from shake_filter import ShakeFilter
from auto_alignment import AutoAlignment
from target_tracking import TargetTracking
from tracking_mux import TrackingMux
from imu_health import ImuHealth
from panorama import Panorama
from attitude import rotation
from tracking_geometry import world_camera

CONFIG=ROOT/'stabilization_tools/camera_imu.json'
CONTROL_VERSION='20261031-manual-imu-slow-turn-r5'
SEND_LEGACY_ANGLE_OSD=False
HDMI_UNAVAILABLE_ERROR='HDMI未收到有效720p60视频，已保持摄像头画面；输入恢复后可重试'
INPUT_TIMEOUT_ERROR='尚未收到所选输入的新帧，请检查720p信号；可重新选择输入口'

class Controller:
    def __init__(self):
        self.lock=threading.RLock();self.port=None;self.thread=None;self.stop=threading.Event()
        self.fusion=Fusion();self.clock=Clock();self.decoder=Decoder();self.seq=0
        self.enabled=False;self.mode='roll';self.zoom=1.0;self.offset_us=0
        self.pose_target_view=None;self.pose_target_sequence=0;self.pose_target_pending=False
        self.controls={};self.controls_received=0.;self.last_attitude_sent=0.;self.output_sync=None
        self.image_y_sign=1
        self.pending=deque(maxlen=32);self.last_sample=0.;self.last_status=0.;self.frames_sent=0
        self.samples=0;self.sample_loss=0;self.last_seq=None;self.last_raw=None
        self.diagnostics={};self.diagnostic_history=deque(maxlen=1800);self.diagnostic_frames=set();self.hardware={};self.error='';self.log=None;self.writer=None;self.config={}
        self.opened_at=0
        self.imu_fault=False;self.imu_health=ImuHealth()
        self.last_packet=0.;self.link_phase='idle';self.link_deadline=0.;self.link_resyncs=0;self.link_recoveries=0
        self.reference_source=None
        self.shake_strength='balanced';self.shake=ShakeFilter()
        self.auto_alignment=AutoAlignment(CFG['source_K'],CFG['source_D'])
        self.calibration_pose_origin=None
        self.tracking=TrackingMux(CFG['source_K'],CFG['source_D'],self.tracking_context)
        self.capture_events={};self.tracking_entered=False;self.tracking_deadline=0.
        self.tracking_imu_fallback=False
        self.panorama=Panorama(ROOT/'panoramas',CFG['source_K'],CFG['source_D'])
        self.panorama_restore=None;self.input_transition=None;self.camera_resume=False;self.camera_gamma_before_hdmi=None
        if CONFIG.exists():self.config=json.loads(CONFIG.read_text(encoding='utf-8'))
        self.image_y_sign=int(self.config.get('image_y_sign',1))
        self.offset_us=float(self.config.get('timestamp_offset_us',0))
        self.zoom=float(self.config.get('zoom',1))
        self.mode=self.config.get('mode','roll')
        self.shake_strength=self.config.get('shake_strength','balanced')
        if self.shake_strength not in ('light','balanced','strong'):self.shake_strength='balanced'
        self.shake=ShakeFilter(self.shake_strength)

    def connect(self,name):
        with self.lock:
            if self.port:raise ValueError('串口已连接')
            self.fusion=Fusion();self.clock=Clock();self.decoder=Decoder();self.pending.clear()
            self.capture_events.clear();self.tracking.stop('连接已重置，请重新进入跟随。')
            self.tracking_imu_fallback=False
            self.frames_sent=self.samples=self.sample_loss=0;self.last_seq=None;self.last_raw=None;self.diagnostics={};self.output_sync=None;self.diagnostic_history.clear();self.diagnostic_frames.clear()
            self.enabled=False;self.error='';self.hardware={};self.last_status=0;self.last_sample=0;self.pose_target_view=None;self.pose_target_pending=False
            self.input_transition=None;self.camera_resume=False;self.camera_gamma_before_hdmi=None
            self.controls={};self.controls_received=0.;self.last_attitude_sent=0.
            self.imu_fault=False;self.imu_health=ImuHealth()
            self.last_packet=0.;self.link_phase='idle';self.link_deadline=0.;self.link_resyncs=0;self.link_recoveries=0
            self.reference_source=None
            self.shake=ShakeFilter(self.shake_strength);self.auto_alignment.cancel();self.calibration_pose_origin=None
            try:
                self.port=serial.Serial(name,115200,timeout=.01,write_timeout=.3)
                if hasattr(self.port,'set_buffer_size'):self.port.set_buffer_size(rx_size=65536,tx_size=65536)
                self.opened_at=time.monotonic()
                self.port.reset_input_buffer();self.port.write(command(0,0x83));self.port.flush()
                time.sleep(.025);self.port.baudrate=921600;self.port.reset_input_buffer()
                folder=ROOT/'stabilization_reports';folder.mkdir(exist_ok=True)
                self.log=(folder/time.strftime('session_%Y%m%d_%H%M%S.csv')).open('w',newline='',encoding='utf-8-sig')
                self.writer=csv.writer(self.log);self.writer.writerow(['host_time','frame_id','capture_tick_10us','pose_tick_10us','mode','zoom','pose_sent','crc_errors','sample_loss'])
                self.stop.clear();self.thread=threading.Thread(target=self.run,daemon=True);self.thread.start()
            except Exception as error:
                if self.port:
                    try:self.port.close()
                    except Exception:pass
                self.port=None;self.enabled=False;self.opened_at=0
                if self.log:self.log.close();self.log=self.writer=None
                self.error='串口连接失败：'+str(error)
                raise


    def disconnect(self):
        with self.lock:
            if self.panorama.active():self.panorama.cancel(reason='串口已断开，本次全景已取消')
            self.restore_panorama()
        self.stop.set()
        if self.thread and self.thread is not threading.current_thread():self.thread.join(timeout=1)
        with self.lock:
            if self.port:
                try:
                    self.port.write(command(0,0x84));self.port.flush();time.sleep(.01)
                    self.port.write(command(0,0x82));self.port.flush();time.sleep(.01)
                except Exception as error:
                    self.error='设备连接已中断，已释放串口；未能发送速率复位：'+str(error)
                finally:
                    try:self.port.close()
                    except Exception:pass
                    self.port=None
            if self.log:self.log.close();self.log=self.writer=None
            self.enabled=False;self.last_status=0;self.last_sample=0;self.pending.clear()
            self.input_transition=None;self.camera_resume=False;self.camera_gamma_before_hdmi=None
            self.auto_alignment.cancel();self.shake=ShakeFilter(self.shake_strength);self.tracking_imu_fallback=False
            self.tracking.stop('串口已断开，跟随已停止。');self.tracking_imu_fallback=False


    def write_command(self,code,seq=None):
        if not self.port:raise ValueError('串口未连接')
        self.seq=(self.seq+1)&255 if seq is None else int(seq)&255
        wire_view=self.display_view(int(code))
        if wire_view<8:
            self.pose_target_view=wire_view;self.pose_target_sequence=self.seq;self.pose_target_pending=True
        self.port.write(command(self.seq,wire_view))

    def display_view(self,view,corrected=None):
        # Horizontal reflection exchanges the physical left/right regions.
        # The mapping is its own inverse, for both commands and wire reports.
        if self.controls.get('input_source')=='hdmi':return view
        if corrected is None:corrected=self.hardware.get('mirror_corrected',False)
        return {1:2,2:1,3:4,4:3}.get(view,view) if corrected else view

    def run(self):
        try:
            while not self.stop.is_set():
                data=self.port.read(max(1,self.port.in_waiting))
                with self.lock:
                    for kind,payload in self.decoder.feed(data):self.receive(kind,payload)
                    self.check_serial_link()
                    self.check_imu_health()
                    self.flush_frames()
                    self.send_attitude_display()
                    self.service_panorama()
                    if not self.last_status and time.monotonic()-self.opened_at>2:
                        self.error='未收到新版二进制回报，请确认已烧录稳像版，并关闭其它串口程序后重新连接'

        except Exception as e:
            with self.lock:
                if self.stop.is_set():return
                failed=self.port;self.port=None;self.stop.set()
                name=getattr(failed,'port','开发板串口')
                self.error=f'串口通信中断，请重新连接 {name}：{e}'
                self.enabled=False;self.opened_at=0;self.last_status=0.;self.last_sample=0.;self.last_packet=0.
                self.controls_received=0.;self.link_phase='disconnected';self.pending.clear();self.capture_events.clear()
                self.input_transition=None;self.camera_resume=False;self.pose_target_pending=False
                self.auto_alignment.cancel();self.tracking_imu_fallback=False
                self.tracking.stop('串口通信中断，跟随已停止。')
                if self.panorama.active():self.panorama.cancel(reason='串口通信中断，请重新连接后重新拍摄全景')
                self.panorama_restore=None
                if failed:
                    try:failed.close()
                    except Exception:pass
                if self.log:
                    try:self.log.close()
                    except Exception:pass
                    self.log=self.writer=None
            # On communication failure the RTL's frame timeout keeps video live.

    def send_attitude_display(self):
        # Disable only the retired display packet, not frame pose data.
        if not SEND_LEGACY_ANGLE_OSD:return
        now=time.monotonic()
        if not self.enabled or not self.port or now-self.last_sample>.15 or now-self.last_attitude_sent<.1:return
        if not self.controls.get('attitude_supported') or now-self.controls_received>1:return
        angles=camera_angles(self.fusion.q,self.fusion.alignment,self.fusion.reference)
        if angles is None:return
        self.port.write(attitude_packet(self.seq,angles));self.last_attitude_sent=now

    def receive(self,kind,p):
        self.last_packet=time.monotonic()
        if kind==5:
            version,requested,applied,busy,error,sequence,capabilities,source_flags=p
            if version in (1,2,3,4,5,6):
                names=('gamma','auto_exposure','sharpen','high_exposure','auto_white_balance') if version>=3 and capabilities&32 else ('gamma','auto_exposure','sharpen','high_exposure') if version>=2 and capabilities&16 else ('gamma','auto_exposure','sharpen')
                self.controls=dict(version=version,input_source='hdmi' if version>=3 and source_flags&1 else 'camera',input_format_locked=bool(version>=3 and source_flags&2),receiver_initialized=bool(version>=3 and source_flags&4),input_signal_present=bool(version>=3 and source_flags&8),gamma_exposure_linked=bool(version>=3 and capabilities&64),white_balance_supported=bool(version>=3 and capabilities&32),high_exposure_supported=bool(version>=2 and capabilities&16),supported=bool(capabilities&3==3),sharpen_supported=bool(capabilities&4),attitude_supported=bool(capabilities&8),
                    requested={k:bool(requested&(1<<i)) for i,k in enumerate(names)},
                    applied={k:bool(applied&(1<<i)) for i,k in enumerate(names)},busy=bool(busy),error=bool(error),sequence=sequence)
                self.controls_received=time.monotonic()
                self.controls.update(raw_view_supported=version>=6,input_switch_supported=bool(version>=4 and capabilities&128),
                    input_switch_busy=bool(version>=4 and source_flags&16),
                    requested_source='hdmi' if version>=4 and source_flags&32 else 'camera' if version>=4 else None,
                    panorama_marker=bool(version>=4 and source_flags&64),input_stream_error=bool(version>=4 and source_flags&128))
            return
        if kind==1:
            seq,tick,chip,flags,*raw=struct.unpack('<HIBB6h',p)
            absolute=self.clock.unwrap(tick)
            if self.last_seq is not None:self.sample_loss+=(seq-self.last_seq-1)&65535
            self.last_seq=seq;self.samples+=1;self.last_raw=raw
            if chip!=0x47 or not flags&1 or all(x==-1 for x in raw) or all(x==0 for x in raw):
                if not self.imu_fault:self.fusion=Fusion();self.pending.clear();self.reference_source=None;self.shake=ShakeFilter(self.shake_strength);self.auto_alignment.cancel()
                self.imu_fault=True;self.error='IMU 标识或采样异常，请检查连接或复位开发板';return
            self.imu_fault=False
            self.last_sample=time.monotonic();self.imu_health.sample(self.last_sample,absolute);self.fusion.update(absolute,raw)
            if self.fusion.bias_ready:
                self.shake.update(absolute,self.fusion.q)
                if self.auto_alignment.state=='collecting':
                    if self.calibration_pose_origin is None:self.calibration_pose_origin=time.time()-absolute*1e-5
                    self.auto_alignment.add_pose(self.calibration_pose_origin+absolute*1e-5,self.fusion.q)
            if self.fusion.bias_ready and self.fusion.optical_axis is None and self.fusion.axis_samples is None and self.config.get('alignment_calibrated'):
                try:
                    self.fusion.restore_calibration(self.config['optical_axis'],self.config['imu_to_camera'])
                    self.reference_source='saved'
                except (ValueError,KeyError) as e:self.error=str(e)
        elif kind==2:
            frame,tick=struct.unpack('<II',p);absolute=self.clock.unwrap(tick)
            self.pending.append((frame,tick,absolute));self.capture_events[frame]=(tick,absolute)
            if len(self.capture_events)>512:self.capture_events.pop(next(iter(self.capture_events)))
        elif kind==6:
            flags,target,worst,switches,acquisitions,ready_phase,output_phase=struct.unpack('<7I',p)
            self.output_sync=dict(version=flags>>16,requested=bool(flags&1),following_input=bool(flags&2),
                phase_locked=bool(flags&4),hdmi_input=bool(flags&8),raster_running=bool(flags&16),
                target_phase_pixels=target,worst_ready_ms=worst/125000,
                clock_switches=switches&65535 if flags>>16>=3 else switches,phase_acquisitions=acquisitions&65535 if flags>>16>=3 else acquisitions,
                last_ready_phase_pixels=ready_phase&0x1fffff if flags>>16>=4 else ready_phase,last_output_phase_pixels=output_phase&0x1fffff if flags>>16>=5 else output_phase,host_time=time.time())
            if flags>>16>=4:self.output_sync['certified_base_profile']=bool(ready_phase&0x80000000)
            if flags>>16>=5:
                reason=(output_phase>>21)&1023
                reason_names=('source_failed','source_budget','service_budget','source_reader','task_queue','writer_protocol','stripe_order','scan_underflow','legacy_budget','external_abort')
                self.output_sync['stability']=dict(jitter_allowance_cycles=768,jitter_peak_cycles=(ready_phase>>21)&1023,
                    last_failure_bits=reason,last_failure_reasons=[name for bit,name in enumerate(reason_names) if reason&(1<<bit)])
            if flags>>16>=2:
                admission=(flags>>8)&255
                self.output_sync.update(phase_state=(flags>>5)&7,early_admission=dict(
                    enabled=bool(admission&1),arming=bool(admission&2),admitted=bool(admission&4),
                    budget_fault=bool(admission&8),fast_disabled=bool(admission&16),
                    source_timing_fault=bool(admission&32),service_timing_fault=bool(admission&64),
                    source_complete=bool(admission&128)))
            if flags>>16>=3:
                recovery=(switches>>16)&65535
                self.output_sync['receiver_recovery']=dict(total=recovery>>8,attempts=(recovery>>6)&3,
                    limited=bool(recovery&32),pending=bool(recovery&16),resetting=bool(recovery&8),
                    clock_valid=bool(recovery&4),video_present=bool(recovery&2),requested_hdmi=bool(recovery&1))
                activity=(acquisitions>>16)&255
                self.output_sync['input_activity']=dict(pixel_clock=bool(activity&1),vsync=bool(activity&2),
                    data_enable=bool(activity&4),vs_level=bool(activity&8),de_level=bool(activity&16),
                    qualified=bool(activity&32),receiver_ready=bool(activity&64),source_present=bool(activity&128))
        elif kind==4:
            values=struct.unpack('<%dI'%(len(p)//4),p)
            names=['frame_id','flags','latency_tenths','capture_tenths','queue_tenths','render_tenths','display_tenths','overlap_tenths','camera_fps_tenths','raw_fps','render_fps','new_fps','capture_drops','repeat_frames','render_errors','pose_fallbacks','total_cycles','geometry_cycles','geometry_wait_cycles','source_wait_cycles','ddr_read_wait_cycles','cache_load_cycles','pixel_wait_cycles','ddr_write_wait_cycles','subdivisions','output_pixels','pose_wait_cycles','slot_wait_cycles']
            names+=['order_wait_cycles','read_response_wait_cycles','refill_active_cycles','packet_assembly_cycles','writer_buffer_wait_cycles','pixel_idle_cycles','lookup_wait_cycles','cache_hits','cache_misses','refill_rows','tap_accepted','tap_dropped']
            d=dict(zip(names,values));d['host_time']=time.time();d['view']=self.display_view(values[1]&7);d['mode']=(values[1]>>4)&3;d['stabilized']=bool(values[1]&64);d['output_hz']=(values[1]>>16)/10
            for key in ['latency','capture','queue','render','display','overlap']:d[key+'_ms']=d[key+'_tenths']/10
            for key in ['geometry','geometry_wait','source_wait','ddr_read_wait','cache_load','pixel_wait','ddr_write_wait','pose_wait','slot_wait']:d[key+'_ms']=d[key+'_cycles']/125000
            d['diagnostic_version']=(values[1]>>8)&127;d['diagnostic_partial']=bool(values[1]&0x8000)
            d['first_before_render_done']=bool(values[1]&8)
            for key in ['order_wait','read_response_wait','refill_active','packet_assembly','writer_buffer_wait','pixel_idle','lookup_wait']:
                if key+'_cycles' in d:d[key+'_ms']=d[key+'_cycles']/125000
            d['processing_ms']=d['total_cycles']/125000
            d['measurement_mode']='fusion_person' if self.tracking.active() and self.tracking.current is self.tracking.person else 'fusion_object' if self.tracking.active() else 'core'
            sync=self.output_sync
            if sync and time.time()-sync['host_time']<2:
                d.update(sync_requested=sync['requested'],sync_following_input=sync['following_input'],
                    sync_phase_locked=sync['phase_locked'],sync_target_phase_pixels=sync['target_phase_pixels'],
                    sync_worst_ready_ms=sync['worst_ready_ms'])
            self.diagnostics=d
            if d['frame_id'] not in self.diagnostic_frames:
                self.diagnostic_history.append(d);self.diagnostic_frames.add(d['frame_id'])
                if len(self.diagnostic_frames)>4096:self.diagnostic_frames={x['frame_id'] for x in self.diagnostic_history}
            elif not d['diagnostic_partial']:
                # Replace the same frame's early snapshot, never count its
                # completion update as another camera/display frame.
                for index in range(len(self.diagnostic_history)-1,-1,-1):
                    if self.diagnostic_history[index]['frame_id']==d['frame_id']:
                        self.diagnostic_history[index]=d;break
        else:
            view,seq,mode,valid,test,flags,dropped=struct.unpack('<6BH',p)
            view=self.display_view(view,bool(flags&64))
            self.hardware=dict(view=view,sequence=seq,mode=mode,valid=bool(valid),test=bool(test),
                               imu_online=bool(flags&1),stabilized=bool(flags&2) and mode!=0 and 1<=view<=7 and bool(valid),enabled=bool(flags&4),all_views_capable=bool(flags&8),boosted_exposure=bool(flags&16),tracking_capable=bool(flags&32),mirror_corrected=bool(flags&64),compact_pose_capable=bool(flags&128),dropped=dropped)
            if not self.pose_target_pending or seq==self.pose_target_sequence:
                self.pose_target_view=self.display_view(view,bool(flags&64));self.pose_target_sequence=seq;self.pose_target_pending=False
            self.last_status=time.monotonic()
            if self.tracking.active():
                if mode==2 and view==6 and valid and not test:self.tracking_entered=True
                elif self.tracking_entered or time.monotonic()>self.tracking_deadline:
                    self.tracking.stop('显示方式或图源已改变，跟随已停止。');self.end_visual_fallback()

    def check_serial_link(self):
        if not self.port:return
        now=time.monotonic()
        if self.link_phase=='switching':
            if now>=self.link_deadline:
                self.port.baudrate=921600;self.port.reset_input_buffer();self.decoder=Decoder()
                self.link_phase='awaiting';self.link_deadline=now+3
            return
        if self.last_packet and now-self.last_packet<2:
            if self.link_phase!='idle':
                self.write_command(0x84);self.link_recoveries+=1;self.error=''
            self.link_phase='idle';return
        if now-(self.last_packet or self.opened_at)<2 or (self.link_phase=='awaiting' and now<self.link_deadline):return
        if self.link_phase=='idle':
            # All packet types stopped, unlike an IMU-only sampling gap. A
            # board reset/reflash starts a new timestamp epoch and heading.
            self.enabled=False;self.tracking.stop('开发板回报中断，正在重同步串口；恢复后重新开启跟随，单人自动锁定。')
            self.tracking_imu_fallback=False
            self.fusion=Fusion();self.clock=Clock();self.pending.clear();self.capture_events.clear()
            self.shake=ShakeFilter(self.shake_strength);self.reference_source=None;self.auto_alignment.cancel()
            self.last_seq=None;self.last_sample=0.;self.last_status=0.;self.last_raw=None;self.hardware={};self.imu_fault=False;self.pose_target_view=None;self.pose_target_pending=False
            self.imu_health.last_sample=None;self.imu_health.last_tick=None;self.imu_health.fresh_since=None
        self.port.baudrate=115200;self.port.reset_input_buffer();self.decoder=Decoder()
        self.write_command(0x83);self.link_phase='switching';self.link_deadline=now+.03;self.link_resyncs+=1
        self.error='开发板回报中断，正在重新同步串口；请确认烧录支持IMU与跟随的兼容固件'

    def check_imu_health(self):
        if not self.tracking.active() and self.tracking_imu_fallback:self.end_visual_fallback()
        ready=self.fusion.bias_ready and self.fusion.reference is not None and self.fusion.alignment is not None
        event=self.imu_health.poll(time.monotonic(),self.enabled,not self.imu_fault,ready)
        if event=='pause':
            if self.tracking.active():self.tracking_imu_fallback=True;return
            self.write_command(0x84);self.pending.clear()
            self.error=self.imu_health.reason+'，暂停姿态补偿；视频和人物检测继续，数据恢复后自动接续'
        elif event=='resume':
            if self.tracking.active():
                self.pending.clear();self.tracking.reset_pose(self.fusion.reference,self.image_y_sign)
                self.write_command(0x85);self.error='';self.tracking_imu_fallback=False
                return
            self.pending.clear();self.tracking.reset_pose(self.fusion.reference,self.image_y_sign)
            self.write_command(0x85);self.error=''

    def flush_frames(self):
        tracking_active=self.tracking.active()
        imu_ready=(self.fusion.bias_ready and self.fusion.reference is not None and self.fusion.alignment is not None
                   and not self.imu_health.paused and not self.imu_fault and self.last_sample and time.monotonic()-self.last_sample<=.15)
        visual_only=tracking_active and not imu_ready
        imu_blocked=(not tracking_active and (self.imu_health.paused or self.imu_fault or time.monotonic()-self.last_sample>.15))
        if not self.enabled or imu_blocked:
            self.pending.clear();return
        if visual_only and not self.tracking_entered:
            self.pending.clear();return
        while self.pending:
            frame,raw_tick,tick=self.pending[0]
            target=tick+round(self.offset_us/10)
            q=self.fusion.at(target) if imu_ready else None
            if visual_only and q is None:q=np.array([1.,0.,0.,0.])
            if q is None:
                if self.fusion.last_tick is None or self.fusion.last_tick<target:break
                self.pending.popleft();continue
            self.pending.popleft()
            if not self.enabled:continue
            try:
                try:
                    if visual_only:rotation=np.eye(3)
                    else:rotation=self.shake.compensation(target,q,self.fusion.alignment) if self.mode=='follow' else self.fusion.compensation(q,self.mode)
                except ValueError:
                    # A vertical optical axis makes gravity-only roll undefined.
                    # Target following has its own continuous look-at basis.
                    if not self.tracking.active():raise
                    rotation=self.fusion.compensation(q,'lock3d')
                alignment=np.eye(3) if visual_only else self.fusion.alignment
                if self.hardware.get('compact_pose_capable'):
                    target_view=self.pose_target_view if self.pose_target_view is not None else self.hardware.get('view')
                    if target_view not in (6,7):continue
                    h=active_view_matrix(target_view,rotation,self.zoom,self.image_y_sign)
                    if target_view==6:
                        tracked=self.tracking.matrix(target,q,alignment)
                        if tracked is not None:h=tracked
                    self.port.write(active_pose_packet(self.pose_target_sequence,frame,raw_tick,target_view,h.flat))
                elif self.hardware.get('all_views_capable'):
                    bundle=view_matrices(rotation,self.zoom,self.image_y_sign)
                    tracking_matrix=self.tracking.matrix(target,q,alignment)
                    if tracking_matrix is not None:bundle[5]=tracking_matrix
                    self.port.write(pose_bundle(frame&255,frame,raw_tick,bundle))
                else:
                    basis=np.diag([1,self.image_y_sign,1]);h=matrix(basis@rotation@basis,self.zoom)
                    self.port.write(pose_packet(frame&255,frame,raw_tick,[int(x) for x in h.flat]))
                self.frames_sent+=1
                self.error=''
                if self.writer:self.writer.writerow([time.time(),frame,raw_tick,target,self.mode,self.zoom,1,self.decoder.crc_errors,self.sample_loss])
                if self.log and self.frames_sent%60==0:self.log.flush()
            except ValueError as e:self.error=str(e)

    def end_visual_fallback(self):
        if not self.tracking_imu_fallback:return
        if self.enabled and self.port:
            try:self.write_command(0x84)
            except Exception as error:self.error='视觉跟随已停止，但无法关闭姿态输出：'+str(error)
        self.enabled=False;self.tracking_imu_fallback=False

    def require_input_controls(self):
        if not self.port:raise ValueError('请先连接开发板串口（COM7），再使用输入切换或全景')
        if not self.controls_received:raise ValueError('串口已打开，正在等待开发板功能回报；请稍候重试')
        if time.monotonic()-self.controls_received>1:
            raise ValueError('开发板功能回报已中断，请断开后重新连接串口；无需因本提示重新烧录')
        if not self.controls.get('input_switch_supported'):
            raise ValueError('当前固件回报不支持双输入全景，请确认烧录本目录的试验固件')

    def act(self,a):
        with self.lock:
            kind=a['action']
            if kind=='input_source':
                source=a.get('source')
                if source not in ('camera','hdmi'):raise ValueError('输入口无效')
                self.require_input_controls()
                if (source==self.controls.get('input_source') and not self.controls.get('input_switch_busy') and not self.input_transition
                    and self.controls.get('input_signal_present') and (source=='camera' or
                    self.controls.get('receiver_initialized') and self.controls.get('input_format_locked'))):
                    if source=='hdmi':
                        if recordings.active:raise ValueError('请先停止并保存录像，再切换输入口')
                        self.apply_hdmi_input_defaults()
                    return
                if recordings.active:raise ValueError('请先停止并保存录像，再切换输入口')
                if self.panorama.active():raise ValueError('请先完成或取消全景，再切换输入口')
                if self.auto_alignment.state in ('collecting','solving'):raise ValueError('请先结束IMU安装标定')
                if self.tracking.active():self.tracking.stop('输入口已切换，跟随已停止。')
                if source=='hdmi':
                    self.camera_resume=self.camera_resume or self.enabled
                    if self.controls.get('input_source')=='camera' and self.camera_gamma_before_hdmi is None:
                        before=self.controls.get('requested',{}).get('gamma',self.controls.get('applied',{}).get('gamma'))
                        if isinstance(before,bool):self.camera_gamma_before_hdmi=before
                self.enabled=False;self.write_command(0x84);self.pending.clear();self.capture_events.clear()
                self.write_command(0x96+int(source=='hdmi'))
                self.input_transition=dict(source=source,started=time.monotonic());self.error='';return
            if kind in ('panorama_start','panorama_finish','panorama_cancel'):
                if kind=='panorama_start':
                    if recordings.active:raise ValueError('请先停止并保存录像，再拍摄全景')
                    self.require_input_controls()
                    if self.controls.get('input_source')!='camera' or self.controls.get('input_switch_busy') or self.input_transition:
                        raise ValueError('先切换到摄像头输入并等待画面稳定')
                    if self.tracking.active():raise ValueError('请先停止跟随并打开采集画面，再开始全景')
                    if self.auto_alignment.state in ('collecting','solving') or self.fusion.axis_samples is not None:
                        raise ValueError('请先结束IMU安装标定')
                    if a.get('video_width')!=1280 or a.get('video_height')!=720:raise ValueError('请先打开1280×720采集画面')
                    self.panorama.start(a.get('client_id'))
                    self.panorama_restore=dict(enabled=self.enabled)
                    try:
                        self.enabled=False;self.write_command(0x84);self.pending.clear();self.write_command(0x99)
                    except Exception:
                        self.panorama.cancel();self.restore_panorama();raise
                elif kind=='panorama_finish':self.panorama.finish(a)
                else:self.panorama.cancel(a);self.restore_panorama()
                return
            if self.panorama.active() and kind in ('view','enable','settings','axis_start','axis_finish','reference','auto_start','tracking_start','color_diagnostic','image_control'):
                raise ValueError('全景拍摄或拼接期间保持图源、姿态和亮度设置；请先完成或取消全景')
            if self.controls.get('input_source')=='hdmi' and (kind in ('axis_start','axis_finish','reference','auto_start','tracking_start') or kind=='enable' and a.get('enabled')):
                raise ValueError('该功能使用实时摄像头，请先切换到摄像头输入')
            if kind=='color_diagnostic':
                enabled=a.get('enabled')
                if not isinstance(enabled,bool):raise ValueError('颜色诊断参数无效')
                if not self.port:raise ValueError('先连接开发板串口')
                if self.auto_alignment.state in ('collecting','solving'):
                    raise ValueError('先完成或取消自动标定，再切换颜色诊断画面')
                if self.tracking.active():
                    self.tracking.stop('已切换颜色诊断画面，跟随已停止。');self.end_visual_fallback()
                self.write_command(0x8c+int(enabled));return
            if kind=='image_control':
                name=a.get('control');enabled=a.get('enabled')
                codes={'gamma':0x86,'auto_exposure':0x88,'high_exposure':0x8e,'auto_white_balance':0x94}
                if name not in codes or not isinstance(enabled,bool):raise ValueError('图像开关参数无效')
                if not self.port or time.monotonic()-self.controls_received>1 or not self.controls.get('supported'):
                    raise ValueError('需要烧录网页控制版固件，并等待图像开关状态回报')
                if self.controls.get('input_source')=='hdmi' and name in ('auto_exposure','high_exposure','auto_white_balance'):
                    raise ValueError('HDMI回放的曝光与白平衡取决于录制的视频，当前模式不支持此控制')
                if name=='high_exposure' and not self.controls.get('high_exposure_supported'):
                    raise ValueError('高曝光测试需要先烧录 32 ms 高曝光版固件')
                if name=='auto_white_balance' and not self.controls.get('white_balance_supported'):
                    raise ValueError('自动白平衡开关需要先烧录Gamma联动与白平衡版固件')
                self.write_command(codes[name]+int(enabled));return
            if kind=='tracking_options':
                self.tracking.configure_composition(a['composition']);return
            if self.auto_alignment.state in ('collecting','solving') and kind in ('axis_start','axis_finish','reference','settings'):
                raise ValueError('先完成或取消自动标定，再修改安装关系或稳像设置')
            if kind in ('axis_start','axis_finish','reference','settings','auto_start') or (kind=='view' and (int(a['view'])<8 or int(a['view']) in (0x80,0x81))) or (kind=='enable' and not a['enabled']):
                if self.tracking.active():
                    self.tracking.stop('控制方式已改变，跟随已停止。');self.end_visual_fallback()
            if kind=='view':
                if int(a['view'])==0 and not self.controls.get('raw_view_supported'):
                    raise ValueError('原图按钮需要 fisheye5_storage_panorama_raw_20261028.sbit 固件')
                if int(a['view']) in (0x80,0x81):raise ValueError('此演示版仅使用真实摄像头；测试图源已移除')
                self.write_command(a['view'],a.get('sequence'))
            elif kind=='tracking_start':
                client=a.get('client_id')
                if not isinstance(client,str) or not 8<=len(client)<=80:raise ValueError('跟随控制已更新，请刷新网页后再启动')
                if not self.port or time.monotonic()-self.last_status>2 or not self.hardware.get('valid'):raise ValueError('先连接开发板并等待显示回报')
                if not self.hardware.get('tracking_capable'):raise ValueError('请先烧录 fisheye5_720p60_pipeline_demo_trim.sbit')
                if self.hardware.get('test'):raise ValueError('先返回摄像头图源')
                if self.auto_alignment.state in ('collecting','solving') or self.fusion.axis_samples is not None:raise ValueError('先结束安装标定')
                backend=a.get('backend','object')
                if backend not in ('object','person'):raise ValueError('跟随方式无效')
                camera=int(a.get('camera',0))
                if backend=='person':
                    if camera not in self.tracking.camera_indices:raise ValueError('先查找PC直采设备并选择HDMI采集卡')
                elif a.get('video_width')!=1280 or a.get('video_height')!=720:raise ValueError('先打开1280×720 HDMI采集画面')
                self.write_command(0x85);self.enabled=True;self.write_command(6)
                self.tracking_entered=False;self.tracking_deadline=time.monotonic()+2
                pose_ready=(self.fusion.bias_ready and self.fusion.reference is not None and self.fusion.alignment is not None
                            and not self.imu_health.paused and not self.imu_fault and self.last_sample and time.monotonic()-self.last_sample<=.15)
                self.tracking_imu_fallback=not pose_ready
                reference=self.fusion.reference if pose_ready else np.eye(3)
                self.tracking.arm(reference,self.image_y_sign,client,backend,camera,self.hardware.get('mirror_corrected',False))
            elif kind=='tracking_stop':
                self.tracking.request_stop(a);self.end_visual_fallback()
            elif kind=='axis_start':
                if self.enabled:self.write_command(0x84);self.enabled=False
                self.fusion.begin_axis();self.reference_source=None;self.error=''
            elif kind=='axis_finish':
                try:self.fusion.end_axis();self.error=''
                except ValueError as e:self.error=str(e);raise
            elif kind=='reference':
                self.fusion.set_reference();self.reference_source='manual';self.error=''
                self.config.update(calibration_version=2,alignment_calibrated=True,optical_axis=self.fusion.optical_axis.tolist(),
                                 imu_to_camera=self.fusion.alignment.tolist(),timestamp_offset_us=self.offset_us,
                                 image_y_sign=self.image_y_sign,
                                 zoom=self.zoom,mode=self.mode,
                                 timestamp_offset_calibrated=self.config.get('timestamp_offset_calibrated',False))
                self.save_config()
            elif kind=='enable':
                if a['enabled']:
                    if self.auto_alignment.state in ('collecting','solving'):raise ValueError('先完成或取消自动标定')
                    if not self.fusion.bias_ready or self.fusion.reference is None:raise ValueError('请完成静止零偏、光轴校准和水平基准设置')
                    if time.monotonic()-self.last_sample>.15:raise ValueError('IMU 数据已中断')
                    self.enabled=True;self.write_command(0x85)
                    if self.hardware.get('mode',0)==0:self.write_command(7)
                else:self.enabled=False;self.camera_resume=False;self.write_command(0x84)
            elif kind=='settings':
                mode=a.get('mode',self.mode);zoom=float(a.get('zoom',self.zoom));offset=float(a.get('offset_us',self.offset_us));sign=int(a.get('image_y_sign',self.image_y_sign))
                strength=a.get('shake_strength',self.shake_strength)
                if mode not in ('roll','lock3d','follow') or strength not in ('light','balanced','strong') or not 1<=zoom<=3 or not -50000<=offset<=50000 or sign not in (-1,1):raise ValueError('参数超出范围')
                if strength!=self.shake_strength:
                    self.shake_strength=strength;self.shake.set_strength(strength)
                self.mode=mode;self.zoom=zoom;self.offset_us=offset;self.image_y_sign=sign
                if self.config.get('alignment_calibrated'):
                    changed=offset!=float(self.config.get('timestamp_offset_us',0))
                    self.config.update(image_y_sign=sign,timestamp_offset_us=offset,zoom=zoom,mode=mode,shake_strength=strength)
                    if changed:self.config['timestamp_offset_calibrated']=False
                    self.save_config()
            elif kind=='auto_start':
                if not self.port or not self.hardware.get('valid') or self.hardware.get('mode')!=0 or self.hardware.get('test'):
                    raise ValueError('先打开HDMI采集画面，并按KEY0切到摄像头原图 RAW')
                if not self.fusion.bias_ready or time.monotonic()-self.last_sample>.15:raise ValueError('先连接IMU并静止约2秒')
                if self.enabled:self.write_command(0x84);self.enabled=False
                self.auto_alignment.start();self.calibration_pose_origin=None
                self.error=''
            elif kind=='auto_finish':
                if time.monotonic()-self.last_sample>.15:raise ValueError('IMU数据已中断，请重新采集')
                if len(self.fusion.accel)<100 or np.max(np.std(np.array(self.fusion.accel),axis=0))>.025:
                    raise ValueError('转动采集后将相机放稳约1秒，再结束并计算')
                self.auto_alignment.finish(self.apply_auto_alignment)
            elif kind=='auto_cancel':self.auto_alignment.cancel()
            else:raise ValueError('未知操作')

    def restore_panorama(self):
        old=self.panorama_restore
        if old is None:return
        self.panorama_restore=None
        if self.port:
            self.write_command(0x98);self.pending.clear()
            if old['enabled'] and self.controls.get('input_source')=='camera':
                self.enabled=True;self.write_command(0x85)

    def apply_hdmi_input_defaults(self):
        # Apply after HDMI has been accepted, and keep the camera's linked
        # Gamma/exposure preference for restoration on its next accepted frame.
        if self.controls.get('raw_view_supported') and self.hardware.get('mode')!=0:
            self.write_command(0)
        requested=self.controls.get('requested',{});applied=self.controls.get('applied',{})
        if self.controls.get('supported') and (requested.get('gamma') is not False or applied.get('gamma') is not False):
            self.write_command(0x86)

    def restore_camera_gamma(self):
        previous=self.camera_gamma_before_hdmi;self.camera_gamma_before_hdmi=None
        if previous is None or not self.controls.get('supported'):return
        requested=self.controls.get('requested',{});applied=self.controls.get('applied',{})
        if requested.get('gamma') is not previous or applied.get('gamma') is not previous:
            self.write_command(0x86+int(previous))

    def service_panorama(self):
        now=time.monotonic()
        if self.controls.get('panorama_marker') and self.panorama_restore is None and not self.panorama.active() and now-getattr(self,'orphan_marker_reset',0)>1:
            self.write_command(0x98);self.orphan_marker_reset=now
        if self.input_transition:
            t=self.input_transition
            if self.controls_received>t['started'] and self.controls.get('requested_source')==t['source'] and self.controls.get('input_source')==t['source'] and not self.controls.get('input_switch_busy') and (t['source']=='camera' or self.controls.get('input_signal_present') and self.controls.get('receiver_initialized') and self.controls.get('input_format_locked')):
                self.pending.clear();self.capture_events.clear();self.input_transition=None
                if t['source']=='hdmi':self.apply_hdmi_input_defaults()
                else:self.restore_camera_gamma()
                if t['source']=='camera' and self.camera_resume:
                    self.enabled=True;self.write_command(0x85);self.camera_resume=False
            elif now-t['started']>4:
                if t['source']=='hdmi':
                    # Cancel the hardware request as well: UI timeout alone
                    # leaves the selector waiting on the unavailable source.
                    self.write_command(0x96)
                    self.input_transition=dict(source='camera',started=now)
                    self.error=HDMI_UNAVAILABLE_ERROR
                else:
                    self.error=INPUT_TIMEOUT_ERROR;self.input_transition=None
        # A late source can recover after the four-second UI timeout.
        # Clear only this timeout, using a fresh, present, fully accepted input.
        source=self.controls.get('input_source')
        if (not self.input_transition and self.error==INPUT_TIMEOUT_ERROR and
            now-self.controls_received<=1 and source in ('camera','hdmi') and
            self.controls.get('requested_source')==source and
            not self.controls.get('input_switch_busy') and self.controls.get('input_signal_present') and
            (source=='camera' or self.controls.get('receiver_initialized') and self.controls.get('input_format_locked'))):
            self.error=''
        if self.panorama.state=='collecting' and now-self.panorama.last_request>8:
            self.panorama.cancel(reason='控制页停止发送图像，已退出全景并恢复原显示')
        if self.panorama_restore is not None and not self.panorama.active():self.restore_panorama()

    def panorama_frame(self,data):
        with self.lock:
            if self.controls.get('input_source')!='camera' or self.hardware.get('mode')!=0 or not self.controls.get('panorama_marker'):
                raise ValueError('等待摄像头完整RAW画面与源帧标记')
            event=self.capture_events.get(int(data['frame_id']));raw_tick=int(data['capture_tick'])
            if event is None or event[0]!=raw_tick:raise ValueError('源帧不属于当前采集会话，请等待新帧')
            # Use the pose of the tagged frame, never receipt time or the
            # stabilization compensation matrix. Visual fitting is fallback.
            pose=None
            q=self.fusion.at(event[1]+round(self.offset_us/10)) if self.fusion.bias_ready and self.fusion.alignment is not None else None
            if q is not None and time.monotonic()-self.last_sample<.15 and not self.imu_fault:
                basis=np.diag([1,self.image_y_sign,1]);pose=world_camera(q,self.fusion.alignment)@basis
            mirrored=self.hardware.get('mirror_corrected',False)
        return self.panorama.frame(data,pose,mirrored)

    def apply_auto_alignment(self,token,result):
        from attitude import rotation
        with self.lock:
            with self.auto_alignment.lock:
                if token!=self.auto_alignment.token or self.auto_alignment.state!='solving':return
                if not self.port or time.monotonic()-self.last_sample>.15:raise ValueError('IMU数据已中断；未更新原标定')
                alignment=np.asarray(result['imu_to_camera'],float)
                updated=dict(self.config)
                updated.update(calibration_version=3,alignment_calibrated=True,optical_axis=result['optical_axis'],
                               imu_to_camera=result['imu_to_camera'],automatic_alignment=result,
                               timestamp_offset_us=self.offset_us,image_y_sign=self.image_y_sign,
                               zoom=self.zoom,mode=self.mode,shake_strength=self.shake_strength)
                # Write successfully before changing the running calibration.
                previous=self.config;self.config=updated
                try:self.save_config()
                except Exception:self.config=previous;raise
                self.fusion.optical_axis=alignment[2].copy();self.fusion.alignment=alignment
                self.fusion.reference=rotation(self.fusion.q)@alignment.T
                self.fusion.axis_samples=None;self.reference_source='automatic';self.error=''
                self.auto_alignment.result=result;self.auto_alignment.state='complete'
                self.auto_alignment.poses.clear();self.auto_alignment.observations.clear()

    def calibration_frame(self,data):
        with self.lock:
            if self.hardware.get('mode')!=0 or self.hardware.get('test') or not self.hardware.get('valid'):
                self.auto_alignment.cancel();raise ValueError('画面离开摄像头原图，已取消本次自动标定')
            if time.monotonic()-self.last_sample>.15:raise ValueError('IMU数据中断')
        self.auto_alignment.frame(int(data['token']),float(data['captured_at']),data['jpeg'],horizontal_reversed=self.hardware.get('mirror_corrected',False))
        return self.auto_alignment.status()

    def tracking_frame(self,data):
        tick,current,latest_tick=self.tracking_context(int(data['frame_id']),int(data['capture_tick']))
        return self.tracking.submit(data,tick,current,latest_tick)

    def tracking_context(self,frame,raw_tick):
        with self.lock:
            if not self.port or not self.enabled:raise ValueError('请连接开发板并开启跟随')
            if not self.hardware.get('tracking_capable') or self.hardware.get('mode')!=2 or self.hardware.get('view')!=6 or self.hardware.get('test') or not self.hardware.get('valid'):raise ValueError('等待摄像头总览／跟随对比画面')
            event=self.capture_events.get(frame)
            if not event or raw_tick!=event[0]:raise ValueError('视频帧标记与开发板拍摄记录不匹配')
            tick=event[1]+round(self.offset_us/10)
            age=(self.clock.latest-event[1])*1e-5
            if age<0 or age>1:raise ValueError('采集卡画面超过1秒，请检查视频延迟')
            pose_ready=(self.fusion.bias_ready and self.fusion.reference is not None and self.fusion.alignment is not None
                        and not self.imu_health.paused and not self.imu_fault and self.last_sample and time.monotonic()-self.last_sample<=.15)
            if pose_ready:
                q=self.fusion.at(tick)
                if q is None:raise ValueError('该源帧尚无对应姿态')
                current=world_camera(q,self.fusion.alignment)
            else:
                # Image-only virtual following: camera motion is not stabilized.
                current=np.eye(3)
            latest_tick=self.clock.latest+round(self.offset_us/10)
        return tick,current,latest_tick

    def save_config(self):
        temporary=CONFIG.with_suffix('.json.tmp')
        temporary.write_text(json.dumps(self.config,ensure_ascii=False,indent=2,allow_nan=False),encoding='utf-8')
        temporary.replace(CONFIG)

    def diagnostic_summary(self):
        rows=list(self.diagnostic_history)
        if not rows:return dict(frames=0)
        lat=np.array([x['latency_ms'] for x in rows]);rnd=np.array([x['render_ms'] for x in rows])
        return dict(frames=len(rows),lat_mean_ms=float(lat.mean()),lat_p95_ms=float(np.percentile(lat,95)),lat_max_ms=float(lat.max()),render_mean_ms=float(rnd.mean()))

    def diagnostics_csv(self):
        import io
        with self.lock:
            stream=io.StringIO(newline='');rows=list(self.diagnostic_history)
            if rows:
                writer=csv.DictWriter(stream,fieldnames=list(dict.fromkeys(key for row in rows for key in row)));writer.writeheader();writer.writerows(rows)
            return stream.getvalue().encode('utf-8-sig')

    def status(self):
        with self.lock:
            f=self.fusion;now=time.monotonic()
            pose=None
            if f.bias_ready:
                from attitude import rotation
                r=rotation(f.q);pose=dict(roll=float(np.degrees(np.arctan2(r[2,1],r[2,2]))),pitch=float(np.degrees(np.arcsin(np.clip(-r[2,0],-1,1)))))
                if f.alignment is not None:
                    g=f.alignment@(-r.T@np.array([0.,0.,1.]))
                    pose=dict(roll=float(np.degrees(np.arctan2(g[0],g[1]))),pitch=float(np.degrees(np.arctan2(-g[2],np.hypot(g[0],g[1])))))
            attitude=camera_angles(f.q,f.alignment,f.reference) if f.bias_ready else None
            control_state=dict(self.controls);control_state['fresh']=bool(self.port and time.monotonic()-self.controls_received<1)
            return dict(available=True,app_id='wyc-unified-control',control_version=CONTROL_VERSION,project_root=str(ROOT),connected=self.port is not None,port=self.port.port if self.port else None,
                attitude=attitude,legacy_angle_osd=SEND_LEGACY_ANGLE_OSD,image_controls=control_state,
                online=bool(self.last_status and now-self.last_status<2),imu_online=bool(not self.imu_fault and self.last_sample and now-self.last_sample<.15),
                raw=self.last_raw,pose=pose,bias_ready=f.bias_ready,axis_calibrated=f.optical_axis is not None,
                axis_collecting=f.axis_samples is not None,axis_progress=f.axis_progress(),reference_ready=f.reference is not None,
                saved_calibration=bool(self.config.get('alignment_calibrated') and self.config.get('imu_to_camera')),reference_source=self.reference_source,
                imu_paused=self.imu_health.paused,imu_health=self.imu_health.status(now),enabled=self.enabled,mode=self.mode,zoom=self.zoom,offset_us=self.offset_us,image_y_sign=self.image_y_sign,
                serial_link=dict(phase=self.link_phase,resyncs=self.link_resyncs,recoveries=self.link_recoveries),
                frames_sent=self.frames_sent,samples=self.samples,sample_loss=self.sample_loss,
                crc_errors=self.decoder.crc_errors,rejected_acceleration=f.reject_acceleration,
                hardware=self.hardware,diagnostics=self.diagnostics,output_sync=getattr(self,'output_sync',None),
                diagnostics_stale=bool(self.diagnostics and time.time()-self.diagnostics['host_time']>1),
                diagnostic_summary=self.diagnostic_summary(),error=self.error,
                shake_strength=self.shake_strength,shake_correction_deg=round(self.shake.correction_deg,2),
                auto_alignment=self.auto_alignment.status(),
                tracking=self.tracking.status(),panorama=self.panorama.status(),input_transition=self.input_transition,
                timestamp_offset_calibrated=bool(self.config.get('timestamp_offset_calibrated',False)),report=str(self.log.name) if self.log else None)

controller=Controller()
recordings=Recordings(ROOT/'recordings')

class Handler(SimpleHTTPRequestHandler):
    def __init__(self,*a,**kw):super().__init__(*a,directory=str(ROOT/'web_control/dist'),**kw)
    def log_message(self,*a):pass
    def reply(self,value,code=200):
        body=json.dumps(value,ensure_ascii=False,allow_nan=False).encode('utf-8')
        self.send_response(code);self.send_header('Content-Type','application/json; charset=utf-8')
        self.send_header('Cache-Control','no-store');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    def do_GET(self):
        if self.path=='/api/panoramas':self.reply(controller.panorama.list())
        elif urlsplit(self.path).path=='/api/panorama/preview.jpg':
            with controller.panorama.lock:body=controller.panorama.preview
            if body is None:self.send_error(404,'Waiting for panorama');return
            self.send_response(200);self.send_header('Content-Type','image/jpeg');self.send_header('Cache-Control','no-store');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        elif self.path.startswith('/api/panoramas/'):
            try:
                identity,suffix=urlsplit(self.path).path.rsplit('/',1)[1].split('.',1)
                file=controller.panorama.file(identity,suffix);body=file.read_bytes()
                self.send_response(200);self.send_header('Content-Type','application/json' if suffix=='json' else 'image/png' if suffix.endswith('png') else 'image/jpeg');self.send_header('Content-Length',str(len(body)));self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(body)
            except (ValueError,OSError):self.send_error(404,'Panorama not found')
        elif self.path=='/api/recordings':self.reply(recordings.list())
        elif self.path.startswith('/api/recordings/') and urlsplit(self.path).path.endswith('/video'):
            try:self.recording_video(urlsplit(self.path).path.split('/')[3])
            except (ValueError,OSError) as error:self.reply(dict(error=str(error)),404)
        elif self.path=='/api/status':self.reply(controller.status())
        elif self.path=='/api/person/devices':
            try:self.reply(controller.tracking.devices())
            except Exception as e:self.reply(dict(error=str(e)),400)
        elif self.path.startswith('/api/person/preview.mjpg'):
            self.person_preview_stream()
        elif self.path.startswith('/api/person/preview.jpg'):
            try:body=controller.tracking.person.preview()
            except OSError:body=None
            if body is None:self.send_error(404,'Waiting for capture');return
            self.send_response(200);self.send_header('Content-Type','image/jpeg');self.send_header('Cache-Control','no-store');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        elif self.path=='/api/person/report.json':
            with controller.lock:
                core=list(controller.diagnostic_history)
                report=controller.tracking.person.report()
                report.update(imu_health=controller.imu_health.status(time.monotonic()),imu_events=list(controller.imu_health.events))
            report.update(core_rows=core,core_definition='原有FPGA同帧LAT，按core/fusion_person/fusion_object分别记录；仅相同显示布局可比较',
                          follow_display_latency_ms=None,follow_display_definition='完整目标运动到显示响应未由当前标记直接测得，需要实物测试')
            self.reply(report)
        elif self.path=='/api/diagnostics.csv':
            body=controller.diagnostics_csv();self.send_response(200);self.send_header('Content-Type','text/csv; charset=utf-8');self.send_header('Content-Disposition','attachment; filename="pipeline_diagnostics.csv"');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        elif self.path=='/api/ports':self.reply([dict(port=p.device,description=p.description) for p in list_ports.comports()])
        else:super().do_GET()
    def recording_video(self,identity):
        path=recordings.video(identity);length=path.stat().st_size;start=0;end=length-1;code=200
        request=self.headers.get('Range','')
        if request:
            import re
            match=re.fullmatch(r'bytes=(\d*)-(\d*)',request)
            if not match or not any(match.groups()):self.send_error(416);return
            a,b=match.groups()
            if a:start=int(a);end=min(length-1,int(b)) if b else length-1
            else:start=max(0,length-int(b))
            if start>=length or end<start:self.send_error(416);return
            code=206
        self.send_response(code);self.send_header('Content-Type','video/webm');self.send_header('Accept-Ranges','bytes')
        self.send_header('Content-Length',str(end-start+1));self.send_header('Cache-Control','no-store')
        if code==206:self.send_header('Content-Range',f'bytes {start}-{end}/{length}')
        self.end_headers()
        try:
            with path.open('rb') as f:
                f.seek(start);remaining=end-start+1
                while remaining:
                    block=f.read(min(65536,remaining))
                    if not block:break
                    self.wfile.write(block);remaining-=len(block)
        except (BrokenPipeError,ConnectionResetError):pass

    def person_preview_stream(self):
        person=controller.tracking.person
        with person.lock:
            token=person.token
            if not person.active():self.send_error(409,'Person capture is not active');return
        self.connection.settimeout(2)
        self.connection.setsockopt(socket.SOL_SOCKET,socket.SO_SNDBUF,65536)
        self.send_response(200)
        self.send_header('Content-Type','multipart/x-mixed-replace; boundary=wycframe')
        self.send_header('Cache-Control','no-store, no-cache, must-revalidate')
        self.send_header('X-Content-Type-Options','nosniff')
        self.send_header('Connection','close');self.end_headers();self.close_connection=True
        previous=None
        try:
            while True:
                with person.lock:
                    if token!=person.token or not person.active():break
                sample=person.preview_sample(previous)
                if sample is None:time.sleep(.003);continue
                previous,body=sample
                header=(f'--wycframe\r\nContent-Type: image/jpeg\r\nContent-Length: {len(body)}\r\nX-Preview-Stamp: {previous}\r\n\r\n').encode('ascii')
                # No per-viewer frame queue. After this write the next lookup
                # reads only the newest JPEG; slow clients time out and retry.
                self.wfile.write(header+body+b'\r\n');self.wfile.flush()
        except (OSError,ConnectionError):pass

    def do_POST(self):
        try:
            # Loopback-only server; reject browser requests from other origins.
            origin=self.headers.get('Origin','')
            if origin and origin not in (f'http://localhost:{self.server.server_port}',f'http://127.0.0.1:{self.server.server_port}'):
                raise ValueError('请求来源不匹配')
            size=int(self.headers.get('Content-Length','0'))
            if self.path.startswith('/api/recordings/') and self.path.endswith('/chunk'):
                self.connection.settimeout(10)
                result=recordings.append(self.path.split('/')[3],self.headers.get('X-Recording-Client',''),int(self.headers.get('X-Recording-Sequence','-1')),self.rfile,size)
                self.reply(result);return
            if not 0<size<(1000000 if self.path=='/api/panorama/frame' else 200000 if self.path=='/api/tracking/frame' else 160000 if self.path=='/api/calibration/frame' else 4096):raise ValueError('请求长度异常')
            data=json.loads(self.rfile.read(size))
            if self.path=='/api/panorama/frame':self.reply(controller.panorama_frame(data));return
            if self.path=='/api/recordings/start':
                with controller.lock:
                    if controller.panorama.active() or controller.input_transition:raise ValueError('请先完成全景或输入切换，再开始录像')
                    self.reply(recordings.start(data));return
            elif self.path=='/api/recordings/finish':self.reply(recordings.finish(data));return
            elif self.path=='/api/recordings/event':self.reply(recordings.event(data));return
            elif self.path=='/api/recordings/delete':self.reply(recordings.delete(data.get('id','')));return
            elif self.path=='/api/connect':controller.connect(data['port'])
            elif self.path=='/api/disconnect':controller.disconnect()
            elif self.path=='/api/action':controller.act(data)
            elif self.path=='/api/calibration/frame':
                self.reply(controller.calibration_frame(data));return
            elif self.path=='/api/tracking/frame':
                self.reply(controller.tracking_frame(data));return
            elif self.path=='/api/person/select':controller.tracking.person.select(data)
            elif self.path=='/api/person/reselect':controller.tracking.person.select(data,reselect=True)
            else:raise ValueError('未知接口')
            self.reply(controller.status())
        except Exception as e:self.reply(dict(error=str(e)),400)

def main(argv=None,browser_opener=None):
    parser=argparse.ArgumentParser();parser.add_argument('--port',type=int,default=8770);parser.add_argument('--no-browser',action='store_true');args=parser.parse_args(argv)
    server=ThreadingHTTPServer(('127.0.0.1',args.port),Handler)
    print(f'鱼眼矫正与稳像控制：http://localhost:{args.port}/',flush=True)
    if not args.no_browser:(browser_opener or webbrowser.open)(f'http://localhost:{args.port}/')
    try:server.serve_forever()
    except KeyboardInterrupt:pass
    finally:controller.disconnect();controller.tracking.shutdown();server.server_close()

if __name__=='__main__':main()
