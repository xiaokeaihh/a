"""Visual/IMU installation calibration. USB delay is a nuisance parameter,
never a claimed exposure timestamp calibration. Frames are not retained."""
from collections import deque
import base64,threading,time
import cv2
import numpy as np
from attitude import rotation,interpolate

def fit_rotation(source,target):
    u,_,vt=np.linalg.svd(np.asarray(target).T@np.asarray(source))
    return u@np.diag([1.,1.,np.linalg.det(u@vt)])@vt

def angular_fit(a,b):
    if len(a)<40:raise ValueError('画面有效特征不足，请对准有纹理的固定场景')
    rng=np.random.default_rng(29);best=np.zeros(len(a),bool)
    for _ in range(100):
        pick=rng.choice(len(a),3,replace=False);r=fit_rotation(a[pick],b[pick])
        residual=np.arccos(np.clip(np.sum((a@r.T)*b,axis=1),-1,1))
        good=residual<.008
        if good.sum()>best.sum():best=good
    if best.sum()<40 or best.mean()<.65:raise ValueError('画面不符合刚性旋转，请减少平移并避开移动物体')
    r=fit_rotation(a[best],b[best])
    residual=np.arccos(np.clip(np.sum((a[best]@r.T)*b[best],axis=1),-1,1))
    return cv2.Rodrigues(r)[0].ravel(),float(np.median(residual))

def pose_at(records,t):
    stamps=np.asarray([x[0] for x in records]);i=int(np.searchsorted(stamps,t))
    if i==0 or i>=len(records):return None
    t0,q0=records[i-1];t1,q1=records[i]
    if t1-t0>.025:return None
    return interpolate(q0,q1,(t-t0)/(t1-t0))

def solve_alignment(observations,poses):
    if len(observations)<50:raise ValueError('有效画面运动不足，请继续缓慢左右、上下及绕镜头转动')
    if len(poses)<100:raise ValueError('有效IMU记录不足，请重新连接后采集')
    stamps=np.asarray([x[0] for x in poses]);quats=np.asarray([x[1] for x in poses])
    starts=np.asarray([x[0] for x in observations]);ends=np.asarray([x[1] for x in observations])
    visual=np.asarray([x[2] for x in observations])
    def sample(t):
        indices=np.searchsorted(stamps,t)
        good=(indices>0)&(indices<len(stamps));indices=np.clip(indices,1,len(stamps)-1)
        good &= stamps[indices]-stamps[indices-1]<.025
        qs=[interpolate(quats[i-1],quats[i],float((x-stamps[i-1])/(stamps[i]-stamps[i-1]))) for x,i in zip(t,indices)]
        return qs,good
    def evaluate(delay):
        prev,g0=sample(starts-delay);curr,g1=sample(ends-delay)
        gyro=np.asarray([cv2.Rodrigues(rotation(b).T@rotation(a))[0].ravel() for a,b in zip(prev,curr)])
        use=g0&g1&(np.linalg.norm(gyro,axis=1)>.003)&(np.linalg.norm(visual,axis=1)>.003)
        if use.sum()<50:return None
        a,b=gyro[use],visual[use]
        for _ in range(3):
            alignment=fit_rotation(a,b);res=np.linalg.norm(a@alignment.T-b,axis=1)
            limit=max(.003,float(np.median(res))*2.5);keep=res<limit
            if keep.sum()<40:return None
            a,b=a[keep],b[keep]
        residual=float(np.sqrt(np.mean(np.sum((a@alignment.T-b)**2,axis=1))))
        scale=float(np.sqrt(np.mean(np.sum(b*b,axis=1))))
        eigen=np.linalg.eigvalsh(a.T@a)
        return dict(score=residual/max(scale,.001),alignment=alignment,
                    residual_deg=float(np.degrees(residual)),axes_ratio=float(eigen[-2]/max(eigen[-1],1e-12)),
                    angular_travel_deg=float(np.degrees(np.linalg.norm(a,axis=1).sum())),pairs=len(a),delay=delay)
    candidates=[x for d in np.arange(-.10,.801,.01) if (x:=evaluate(float(d))) is not None]
    if not candidates:raise ValueError('IMU或画面时间记录不足，请重新连接后采集')
    best=min(candidates,key=lambda x:x['score'])
    refined=[x for d in np.arange(best['delay']-.01,best['delay']+.0101,.001) if (x:=evaluate(float(d))) is not None]
    best=min(refined,key=lambda x:x['score'])
    if best['axes_ratio']<.06:raise ValueError('转动方向不足，请同时做左右、上下转动，不能只绕镜头转一圈')
    if best['angular_travel_deg']<25:raise ValueError('转动幅度不足，请增加左右和上下转动幅度')
    if best['score']>.25 or best['residual_deg']>1.:
        raise ValueError('图像与IMU运动不一致，请减少平移、缩短曝光或重新对焦后重试')
    # A boundary minimum cannot establish a reliable transport alignment.
    if not -.09<best['delay']<.79:raise ValueError('视频延迟超出搜索范围，请关闭占用采集卡的其他程序后重试')
    return dict(imu_to_camera=best['alignment'].tolist(),optical_axis=best['alignment'][2].tolist(),
                fit_error_deg=best['residual_deg'],relative_error=best['score'],valid_pairs=best['pairs'],
                axes_ratio=best['axes_ratio'],visual_transport_delay_ms=best['delay']*1000,
                timestamp_offset_calibrated=False)

class AutoAlignment:
    def __init__(self,k,d):
        self.k=np.asarray(k,float).copy();self.k[:2]*=.5;self.d=np.asarray(d,float)
        self.lock=threading.RLock();self.token=0;self.state='idle';self.started=0
        self.poses=deque(maxlen=15000);self.observations=[];self.previous=None;self.previous_time=None
        self.frames=0;self.rejected=0;self.error='';self.result=None;self.last_note='';self.busy=False
        yy,xx=np.indices((360,640));self.mask=(((xx-self.k[0,2])**2+(yy-self.k[1,2])**2)<min(640,360)**2*.42**2).astype(np.uint8)*255

    def start(self):
        with self.lock:
            if self.state in ('collecting','solving'):raise ValueError('自动标定正在进行')
            self.token+=1;self.state='collecting';self.started=time.monotonic()
            self.poses.clear();self.observations.clear();self.previous=None;self.previous_time=None
            self.frames=self.rejected=0;self.error='';self.result=None;self.last_note=''
            return self.token

    def cancel(self):
        with self.lock:self.token+=1;self.state='idle';self.previous=None;self.poses.clear();self.observations.clear();self.result=None

    def add_pose(self,t,q):
        with self.lock:
            if self.state=='collecting' and time.monotonic()-self.started<=26:self.poses.append((float(t),q.copy()))

    def frame(self,token,captured_at,jpeg,horizontal_reversed=False):
        with self.lock:
            if token!=self.token or self.state!='collecting':raise ValueError('标定采集已结束')
            if self.busy:raise ValueError('上一帧尚未处理')
            if time.monotonic()-self.started>25:raise ValueError('已达到25秒采集上限，请结束并计算或重新开始')
            if len(jpeg)>140000:raise ValueError('标定图像过大')
            now=time.time()
            if not np.isfinite(captured_at) or abs(captured_at-now)>2:raise ValueError('采集时间无效或请求排队过久')
            if self.previous_time is not None and not .025<captured_at-self.previous_time<.5:raise ValueError('跳过重复帧或间隔过大的帧')
            self.busy=True
        try:
            encoded=base64.b64decode(jpeg,validate=True)
            gray=cv2.imdecode(np.frombuffer(encoded,np.uint8),cv2.IMREAD_GRAYSCALE)
            if gray is None or gray.shape!=(360,640):raise ValueError('自动标定仅接受640×360原图预览')
            if horizontal_reversed:gray=cv2.flip(gray,1)
            observation=None;note=''
            if self.previous is not None:
                try:
                    p=cv2.goodFeaturesToTrack(self.previous,300,.015,8,mask=self.mask)
                    if p is None or len(p)<40:raise ValueError('场景纹理不足')
                    q,ok,_=cv2.calcOpticalFlowPyrLK(self.previous,gray,p,None,winSize=(21,21),maxLevel=3)
                    back,ok2,_=cv2.calcOpticalFlowPyrLK(gray,self.previous,q,None,winSize=(21,21),maxLevel=3)
                    good=ok.ravel().astype(bool)&ok2.ravel().astype(bool)&(np.linalg.norm((back-p).reshape(-1,2),axis=1)<1.)
                    a=cv2.fisheye.undistortPoints(p[good].reshape(-1,1,2),self.k,self.d).reshape(-1,2)
                    b=cv2.fisheye.undistortPoints(q[good].reshape(-1,1,2),self.k,self.d).reshape(-1,2)
                    a=np.c_[a,np.ones(len(a))];b=np.c_[b,np.ones(len(b))]
                    a/=np.linalg.norm(a,axis=1)[:,None];b/=np.linalg.norm(b,axis=1)[:,None]
                    vector,_=angular_fit(a,b)
                    if np.linalg.norm(vector)>.002:observation=(self.previous_time,captured_at,vector)
                    else:note='画面运动较小，请缓慢左右、上下及绕镜头转动'
                except (ValueError,cv2.error) as e:note=str(e)
            with self.lock:
                if token!=self.token or self.state!='collecting':return
                self.frames+=1;self.previous=gray;self.previous_time=captured_at;self.last_note=note
                if observation is not None:self.observations.append(observation)
                elif self.frames>1:self.rejected+=1
        finally:
            with self.lock:self.busy=False

    def finish(self,apply):
        with self.lock:
            if self.state!='collecting' or self.busy:raise ValueError('等待当前采集帧完成后再结束标定')
            if len(self.observations)<50:raise ValueError('有效运动不足，请继续采集左右、上下转动')
            token=self.token;observations=list(self.observations);poses=list(self.poses)
            self.state='solving';self.previous=None
        def run():
            try:
                result=solve_alignment(observations,poses)
                # Controller validates the token while holding its own lock.
                apply(token,result)
            except Exception as e:
                with self.lock:
                    if token==self.token:self.state='failed';self.error=str(e)
        threading.Thread(target=run,daemon=True).start()

    def status(self):
        with self.lock:
            return dict(state=self.state,token=self.token,frames=self.frames,valid_pairs=len(self.observations),
                        rejected_pairs=self.rejected,elapsed_seconds=round(time.monotonic()-self.started,1) if self.started and self.state in ('collecting','solving') else 0,
                        error=self.error,note=self.last_note,result=self.result,
                        max_seconds=25,timestamp_offset_calibrated=False)
