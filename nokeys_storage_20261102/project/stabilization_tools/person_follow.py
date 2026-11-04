"""Frame-matched target directions. PC capture/AI never blocks serial output."""
from pathlib import Path
import json,os,subprocess,threading,time,uuid
from preview_buffer import PreviewBuffer
from smart_composition import ComposedAim as SafeAim
from tracking_geometry import world_camera

class PersonFollow:
    def __init__(self,k,d,context):
        self.k=k;self.d=d;self.context=context;self.lock=threading.RLock();self.token=0;self.owner_client=''
        self.state='idle';self.note='选择PC直采设备，开启人的自动跟随。';self.proc=None;self.thread=None;self.aim=None
        self.started=0.;self.last_received=0.;self.last_result=0.;self.observation_tick=None;self.latest_tick=None
        self.result={};self.info={};self.timing_wait=False;self.result_age_ms=0.;self.input_age_ms=0.
        self.runtime=Path(__file__).with_name('person_runtime.json');self.preview_path=None;self.worker_ready=False
        self.measurements=[];self.preview_buffer=None

    def active(self):
        with self.lock:return self.state in ('waiting','following','lost')

    def arm(self,reference,sign=1,client_id='',camera=0,horizontal_reversed=False):
        self.stop()
        config=json.loads(self.runtime.read_text(encoding='utf-8'))
        if not Path(config['python']).is_file() or not Path(config['model']).is_file():raise ValueError('人的推理环境或模型缺失')
        with self.lock:
            self.token+=1;token=self.token;self.owner_client=client_id;self.state='waiting';self.note='正在加载人的小模型并打开PC直采。'
            self.started=time.monotonic();self.last_received=self.last_result=0.;self.observation_tick=self.latest_tick=None
            self.result={};self.info={};self.worker_ready=False;self.timing_wait=False;self.result_age_ms=self.input_age_ms=0.;self.measurements=[];self.preview_buffer=None
            self.aim=SafeAim(self.k,self.d,reference,sign,horizontal_reversed=horizontal_reversed)
            self.preview_path=Path(config['cache'])/'preview.jpg'
            self.preview_buffer=PreviewBuffer('Local\\WYCPreview_'+uuid.uuid4().hex)
            preview_name=self.preview_buffer.name
            self.thread=threading.Thread(target=self._work,args=(config,int(camera),token,preview_name),daemon=True);self.thread.start()
            return token

    def _work(self,config,camera,token,preview_name):
        proc=None
        try:
            proc=subprocess.Popen([config['python'],'-X','utf8','-B',str(Path(__file__).with_name('person_worker.py')),
                '--config',str(self.runtime),'--camera',str(camera),'--preview',str(self.preview_path),'--preview-map',preview_name],stdin=subprocess.PIPE,stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,text=True,encoding='utf-8',bufsize=1,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
            with self.lock:
                if token!=self.token:proc.terminate();return
                self.proc=proc
            for line in proc.stdout:
                message=json.loads(line);kind=message.get('kind')
                # Never acquire the controller lock while holding our own lock.
                context=None;context_error=None
                if kind=='frame':
                    try:context=self.context(message['frame_id'],message['capture_tick'])
                    except ValueError as e:context_error=str(e)
                with self.lock:
                    if token!=self.token:return
                    self.last_received=time.monotonic()
                    if kind=='ready':self.info=message;self.worker_ready=True
                    elif kind=='error':self.state='error';self.note=message['note'];return
                    elif kind in ('waiting','selection_error'):self.note=message['note']
                    elif kind=='frame':
                        self.result=message;self.last_result=time.monotonic()
                        self.measurements.append({k:message.get(k) for k in ('frame_id','compute_ms','inference_ms','tracking_ms','tracking_fps','process_rss_mib','process_peak_rss_mib')})
                        self.measurements=self.measurements[-1800:]
                        if context is None:
                            self.timing_wait=True;self.note=context_error or '等待当前画面的对应姿态。';continue
                        tick,current,latest=context;age=max(0,(latest-tick)*1e-5)
                        self.latest_tick=latest;self.result_age_ms=age*1000
                        local_age=max(0,time.monotonic()-message['captured_local'])
                        self.input_age_ms=max(0,(age-local_age)*1000)
                        phase=message['state'];self.timing_wait=age>.6
                        if self.timing_wait:self.note=f'目标观测距拍摄约{age*1000:.0f}ms，等待新帧。'
                        elif phase=='following' and message.get('visible') and (self.observation_tick is None or tick>self.observation_tick):
                            try:
                                self.aim.observe(message['bbox'],tick,current);self.observation_tick=tick;self.state='following'
                                self.note=f"正在跟随人物 {message['selected_id']}；离开后会持续自动寻找。"
                            except ValueError:
                                self.timing_wait=True;self.note='人物接近标定模型的有效视野边界，保持视角并等待有效位置。'
                        elif phase=='waiting':self.state='waiting';self.note='检测到多人时，请点击总览中的目标；单人会自动锁定。'
                        elif phase=='recovering':self.state='following';self.note='目标暂时不可见，保持视角并尝试恢复原目标。'
                        elif phase=='lost':self.state='lost';self.note='人物暂时离开，正在自动寻找；单人稳定出现后自动接续，多人优先匹配原目标。'
                        self.measurements[-1]['result_age_ms']=self.result_age_ms
            with self.lock:
                if token==self.token and self.active():self.state='error';self.note='人的推理进程已结束，请重新启动。'
        except Exception as error:
            with self.lock:
                if token==self.token:self.state='error';self.note='人的跟随启动失败：'+str(error)
        finally:
            if proc:
                if proc.poll() is None:proc.terminate()
                try:proc.wait(timeout=1)
                except subprocess.TimeoutExpired:proc.kill();proc.wait(timeout=1)
                for pipe in (proc.stdin,proc.stdout):
                    if pipe:pipe.close()
            with self.lock:
                if token==self.token:self.proc=None;self.worker_ready=False

    def reset_pose(self,reference,sign=1):
        with self.lock:
            if not self.active():return
            mirrored=self.aim.horizontal_reversed if self.aim else False
            self.aim=SafeAim(self.k,self.d,reference,sign,horizontal_reversed=mirrored);self.observation_tick=None
            self.timing_wait=True;self.note='IMU已恢复，等待当前源帧的有效姿态后自动继续。'

    def select(self,data,reselect=False):
        with self.lock:
            if data.get('token')!=self.token or data.get('client_id')!=self.owner_client or not self.active():raise ValueError('此页面不拥有当前跟随会话')
            if not self.proc or not self.worker_ready:raise ValueError('请等待模型和直采画面就绪')
            payload=dict(action='reselect') if reselect else dict(action='select',id=int(data['id']))
            self.proc.stdin.write(json.dumps(payload)+'\n');self.proc.stdin.flush()
            if self.aim is not None:
                previous=self.aim
                self.aim=SafeAim(self.k,self.d,previous.reference,previous.sign,
                    horizontal_reversed=previous.horizontal_reversed)
                self.aim.framing_enabled=previous.framing_enabled
                self.observation_tick=None

    def matrix(self,tick,q,alignment):
        with self.lock:
            self.latest_tick=tick
            if not self.active() or self.aim is None or self.aim.direction is None:return None
            current=world_camera(q,alignment)
            if self.timing_wait or self.result.get('state')!='following' or time.monotonic()-self.last_result>.4:return self.aim.hold_matrix(tick,current)
            h=self.aim.matrix(tick,current)
            return h if h is not None else self.aim.hold_matrix(tick,current)

    def stop(self,note='人的跟随已停止，采集卡已释放。'):
        with self.lock:
            self.token+=1;self.state='idle';self.note=note;self.owner_client='';self.aim=None;self.timing_wait=False
            proc=self.proc;self.proc=None;self.worker_ready=False
            if self.preview_buffer:self.preview_buffer.close();self.preview_buffer=None
            if proc and proc.poll() is None:proc.terminate()

    def request_stop(self,data):
        with self.lock:
            if data.get('cause') not in ('manual','video_closed') or data.get('token')!=self.token or not isinstance(data.get('client_id'),str):raise ValueError('跟随会话已变化，请刷新页面')
            if data['cause']=='video_closed' and data['client_id']!=self.owner_client:raise ValueError('其它页面不能自动停止此跟随')
            self.stop()

    def status(self):
        with self.lock:
            if self.active() and time.monotonic()-max(self.started,self.last_received)>15:self.stop('PC直采或推理回报中断，请重新启动。')
            r=self.result;aim=self.aim
            return dict(kind='person',state=self.state,phase=r.get('state','loading'),token=self.token,owner_client=self.owner_client,note=self.note,
                bbox=r.get('bbox'),score=round(r.get('score',0),3),compute_ms=round(r.get('compute_ms',0),1),processed=r.get('processed',0),skipped=0,
                source_frame=r.get('frame_id'),observation_frame=r.get('frame_id'),timing_wait=self.timing_wait,input_age_ms=round(self.input_age_ms,1),
                result_age_ms=round(self.result_age_ms,1),hfov=aim.hfov if aim else 100,worker_ready=self.worker_ready,
                people=r.get('people',[]),selected_id=r.get('selected_id'),inference_ms=round(r.get('inference_ms',0),2),tracking_ms=round(r.get('tracking_ms',0),2),
                tracking_fps=r.get('tracking_fps',0),process_rss_mib=r.get('process_rss_mib',0),process_peak_rss_mib=r.get('process_peak_rss_mib',0),
                gpu_memory_mib=None,frame_queue_capacity=1,fpga_extra_framebuffer_bytes=0,fpga_rtl_changed=False,
                preview_fps=r.get('preview_fps',0),preview_frames=r.get('preview_frames',0),preview_encode_ms=r.get('preview_encode_ms',0),
                preview_target_fps=30,preview_queue_capacity=1,auto_reacquire=True,
                reacquire_count=r.get('reacquire_count',0),reacquire_reason=r.get('reacquire_reason',''),
                view_clamped=bool(aim and aim.clamped),preview_available=bool(self.preview_buffer and self.preview_buffer.ready()),model=self.info)

    def preview(self):
        sample=self.preview_sample()
        return sample[1] if sample else None

    def preview_sample(self, previous=None):
        with self.lock:
            if self.preview_buffer:return self.preview_buffer.sample(previous)
            path=self.preview_path
        if not path:return None
        try:
            if previous is not None and path.stat().st_mtime_ns==previous:return None
            with path.open('rb') as source:
                stamp=os.fstat(source.fileno()).st_mtime_ns
                if stamp==previous:return None
                return stamp,source.read()
        except OSError:return None

    def report(self):
        with self.lock:return dict(status=self.status(),rows=list(self.measurements),definitions=dict(
            compute_ms='PC开始处理当前图像到输出目标结果；不含FPGA和采集卡',
            result_age_ms='源帧拍摄计时到目标结果的观测年龄；不是完整随动显示延迟',
            tracking_fps='PC实际处理的不同源帧频率',process_rss_mib='独立采集与推理进程的工作集，含运行时',
            gpu_memory_mib='当前未获取，不能解释为0',fpga_extra_framebuffer_bytes='本次PC人的跟随相对原tracking版新增FPGA帧缓存为0'))

    def shutdown(self):
        self.stop()
        if self.thread and self.thread is not threading.current_thread():self.thread.join(timeout=1)
