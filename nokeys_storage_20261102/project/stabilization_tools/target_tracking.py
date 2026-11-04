"""One worker, one in-flight job and one replaceable latest frame."""
from pathlib import Path
import json,os,subprocess,sys,threading,time
import numpy as np
from smart_composition import ComposedAim as SafeAim
from tracking_geometry import world_camera

class TargetTracking:
    ACTIVE=('waiting','selecting','following','recovering','lost')
    def __init__(self,k,d):
        self.k=k;self.d=d;self.lock=threading.RLock();self.condition=threading.Condition(self.lock)
        self.token=0;self.generation=0;self.state='idle';self.note='先打开HDMI画面并连接IMU。'
        self.pending=None;self.proc=None;self.thread=None;self.worker_ready=False
        self.bbox=None;self.score=0.;self.compute_ms=0.;self.last_tick=None;self.last_frame=None
        self.last_received=0.;self.last_result=0.;self.started=0.;self.processed=0;self.skipped=0;self.aim=None
        self.runtime=Path(__file__).with_name('tracking_runtime.json')
        self.closed=False
        self.owner_client=''
        self.latest_camera_tick=None;self.observation_tick=None;self.observation_frame=None
        self.timing_wait=False;self.result_age_ms=0.;self.input_age_ms=0.
        self.reacquire_count=0;self.reacquire_reason=''

    def python(self):
        if self.runtime.exists():
            path=Path(json.loads(self.runtime.read_text(encoding='utf-8'))['python'])
            if path.is_file():return str(path)
        return sys.executable

    def active(self):
        with self.lock:return self.state in self.ACTIVE

    def arm(self,reference,sign=1,client_id='',horizontal_reversed=False):
        with self.condition:
            self.token+=1;self.generation+=1;self.state='waiting';self.note='正在等待带帧标记的摄像头对比画面。'
            self.owner_client=client_id
            self.started=time.monotonic();self.last_received=self.last_result=0.;self.last_tick=self.last_frame=None
            self.latest_camera_tick=None;self.observation_tick=self.observation_frame=None
            self.timing_wait=False;self.result_age_ms=self.input_age_ms=0.
            self.pending=None;self.bbox=None;self.score=0.;self.processed=self.skipped=0
            self.reacquire_count=0;self.reacquire_reason=''
            self.aim=SafeAim(self.k,self.d,reference,sign,horizontal_reversed=horizontal_reversed)
            if not self.thread or not self.thread.is_alive():
                self.thread=threading.Thread(target=self._work,daemon=True);self.thread.start()
            return self.token

    def reset_pose(self,reference,sign=1):
        with self.lock:
            if not self.active():return
            mirrored=self.aim.horizontal_reversed if self.aim else False
            self.aim=SafeAim(self.k,self.d,reference,sign,horizontal_reversed=mirrored)
            self.observation_tick=self.observation_frame=None;self.timing_wait=True

    def stop(self,note='跟随已停止，可重新进入。'):
        with self.condition:
            self.token+=1;self.generation+=1;self.state='idle';self.note=note;self.pending=None;self.bbox=None;self.aim=None;self.owner_client=''
            self.timing_wait=False
            self.condition.notify_all()

    def request_stop(self,data):
        with self.lock:
            cause=data.get('cause');client=data.get('client_id')
            if cause not in ('manual','video_closed') or not isinstance(client,str) or not 8<=len(client)<=80:
                raise ValueError('跟随控制已更新，请刷新网页后再操作')
            if data.get('token')!=self.token:raise ValueError('跟随会话已变化，请等待页面更新')
            if cause=='video_closed' and client!=self.owner_client:
                raise ValueError('本页未启动此跟随，不能因本页视频状态自动停止')
            if not self.active():return
            self.stop('启动跟随的页面已关闭HDMI画面，跟随已停止。' if cause=='video_closed' else '跟随已停止，可重新进入。')

    def submit(self,data,tick,current,latest_tick=None):
        with self.condition:
            if int(data['token'])!=self.token or not self.active():raise ValueError('本次跟随已结束')
            if self.owner_client and data.get('client_id')!=self.owner_client:
                raise ValueError('跟随在另一页面运行，本页仅查看状态')
            if self.last_tick is not None and tick<=self.last_tick and data.get('roi') is None:raise ValueError('跳过重复或倒序源帧')
            if latest_tick is not None:self.latest_camera_tick=max(self.latest_camera_tick or latest_tick,latest_tick)
            source_age=max(0,((self.latest_camera_tick or tick)-tick)*1e-5)
            self.input_age_ms=source_age*1000
            jpeg=data['jpeg']
            if not isinstance(jpeg,str) or len(jpeg)>180000:raise ValueError('跟踪图像过大')
            roi=data.get('roi')
            if roi is not None:
                if len(roi)!=4 or not all(np.isfinite(x) for x in roi):raise ValueError('目标框无效')
                x,y,w,h=map(int,roi)
                if w<12 or h<12 or x<0 or y<0 or x+w>640 or y+h>360:raise ValueError('框选至少12×12像素，并保持在总览内')
                self.generation+=1;self.state='selecting';self.note='正在锁定框选目标。';self.bbox=None
                self.timing_wait=False;self.observation_tick=self.observation_frame=None
                framing_enabled=self.aim.framing_enabled
                self.aim=SafeAim(self.k,self.d,self.aim.reference,self.aim.sign,
                                 horizontal_reversed=self.aim.horizontal_reversed)
                self.aim.framing_enabled=framing_enabled
            elif self.state not in ('selecting','following','recovering','lost'):
                self.last_received=time.monotonic();self.last_tick=tick;self.last_frame=int(data['frame_id'])
                self.state='lost' if self.state=='lost' else 'waiting'
                if self.state=='waiting':self.note='在左侧总览中拖动框选一个有纹理的物体。'
                return self.status()
            # Preserve an initialization that has not reached the worker yet.
            # Once initialization is in flight, queue the newest update instead
            # of discarding all frames that arrive during initialization.
            if self.state=='selecting' and roi is None and self.pending is not None and self.pending.get('roi') is not None:return self.status()
            if self.pending is not None:self.skipped+=1
            self.pending=dict(generation=self.generation,token=self.token,frame_id=int(data['frame_id']),jpeg=jpeg,roi=roi,tick=tick,current=current,submitted=time.monotonic(),source_age=source_age)
            self.last_tick=tick;self.last_frame=int(data['frame_id']);self.last_received=time.monotonic()
            self.condition.notify();return self.status()

    def _work(self):
        try:
            proc=subprocess.Popen([self.python(),'-X','utf8','-B',str(Path(__file__).with_name('tracking_worker.py'))],
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,encoding='utf-8',bufsize=1,
                creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
            self.proc=proc
            ready=json.loads(proc.stdout.readline())
            if not ready.get('ready'):raise ValueError('需要安装支持CSRT的OpenCV contrib运行环境')
            with self.lock:self.worker_ready=True
            while True:
                with self.condition:
                    self.condition.wait_for(lambda:self.pending is not None or self.closed)
                    if self.closed:return
                    job=self.pending;self.pending=None
                context=job['current'];payload={k:v for k,v in job.items() if k not in ('current','submitted','source_age')}
                proc.stdin.write(json.dumps(payload,allow_nan=False)+'\n');proc.stdin.flush()
                result=json.loads(proc.stdout.readline())
                with self.lock:
                    if job['token']!=self.token or job['generation']!=self.generation or not self.active():continue
                    self.compute_ms=result['compute_ms'];self.last_result=time.monotonic();self.processed+=1
                    self.score=result['score'];self.bbox=result['bbox']
                    self.observation_tick=job['tick'];self.observation_frame=job['frame_id']
                    age=max(job['source_age']+time.monotonic()-job['submitted'],((self.latest_camera_tick or job['tick'])-job['tick'])*1e-5)
                    self.result_age_ms=age*1000
                    self.reacquire_count=result.get('reacquire_count',self.reacquire_count);self.reacquire_reason=result.get('reacquire_reason','')
                    if result.get('error'):
                        self.state='waiting';self.bbox=None;self.note=result['error']
                    elif result.get('lost'):
                        self.state=result.get('state','recovering');self.bbox=None;self.timing_wait=False
                        self.note='目标暂时不可见，保持视角并自动寻找。' if self.state=='recovering' else '正在自动寻找原物体；外观连续确认后接续，无需重新框选。'
                        if self.reacquire_reason:self.note+=' '+self.reacquire_reason
                    elif age>.6:
                        self.state='following';self._pause(age)
                    else:
                        if result.get('reacquired'):
                            enabled=self.aim.framing_enabled
                            self.aim=SafeAim(self.k,self.d,self.aim.reference,self.aim.sign,horizontal_reversed=self.aim.horizontal_reversed)
                            self.aim.framing_enabled=enabled
                        self.aim.observe(self.bbox,job['tick'],context)
                        self.state='following';self.timing_wait=False;self.note='正在平滑跟随框选目标；左侧保留完整总览。'
        except Exception as error:
            with self.lock:self.state='error';self.note='跟踪计算中断：'+str(error);self.worker_ready=False;self.pending=None
        finally:
            if self.proc:
                if self.proc.poll() is None:self.proc.terminate()
                try:self.proc.wait(timeout=1)
                except subprocess.TimeoutExpired:self.proc.kill();self.proc.wait(timeout=1)
                for pipe in (self.proc.stdin,self.proc.stdout):
                    if pipe:pipe.close()

    def matrix(self,tick,q,alignment):
        with self.lock:
            self.latest_camera_tick=max(self.latest_camera_tick or tick,tick)
            if self.state not in ('following','recovering','lost') or not self.aim:return None
            current=world_camera(q,alignment)
            if self.state in ('recovering','lost'):return self._hold_matrix(tick,current)
            if time.monotonic()-self.last_result>.8:
                self._pause(max(.8,((tick-(self.observation_tick or tick))*1e-5)))
                return self._hold_matrix(tick,current)
            if self.timing_wait:return self._hold_matrix(tick,current)
            matrix=self.aim.matrix(tick,current)
            if matrix is None and self.aim.tick is not None and tick>=self.aim.tick:
                self._pause((tick-self.aim.tick)*1e-5);return self._hold_matrix(tick,current)
            return matrix

    def _hold_matrix(self,tick,current):
        # Object observations keep their original one-second expiry. SafeAim
        # still checks the held view against the current camera orientation.
        if self.aim.tick is None or not 0<=tick-self.aim.tick<=100000:return None
        return self.aim.hold_matrix(tick,current)

    def _pause(self,age):
        self.timing_wait=True;self.note=f'画面或跟踪延迟约{age*1000:.0f}ms，暂停目标跟随，等待新帧自动恢复。'

    def _lose(self,note):
        self.generation+=1;self.state='lost';self.note=note;self.bbox=None;self.pending=None;self.aim.direction=None
        self.timing_wait=False

    def status(self):
        with self.lock:
            if self.active() and time.monotonic()-max(self.started,self.last_received)>3:
                self.stop('HDMI源帧标记中断，跟随已停止；请检查采集卡和烧录文件。')
            return dict(state=self.state,token=self.token,owner_client=self.owner_client,note=self.note,bbox=self.bbox,score=round(self.score,3),
                compute_ms=round(self.compute_ms,1),processed=self.processed,skipped=self.skipped,source_frame=self.last_frame,
                timing_wait=self.timing_wait,input_age_ms=round(self.input_age_ms,1),result_age_ms=round(self.result_age_ms,1),observation_frame=self.observation_frame,
                hfov=self.aim.hfov if self.aim else 100,worker_ready=self.worker_ready,
                view_clamped=bool(self.aim and self.aim.clamped),auto_reacquire=True,
                reacquire_count=self.reacquire_count,reacquire_reason=self.reacquire_reason)

    def shutdown(self):
        self.stop()
        with self.condition:self.closed=True;self.condition.notify_all()
        if self.proc and self.proc.poll() is None:self.proc.terminate()
        if self.thread and self.thread is not threading.current_thread():self.thread.join(timeout=1)
