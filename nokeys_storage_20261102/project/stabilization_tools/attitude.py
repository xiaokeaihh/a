"""Timestamped quaternion fusion, sensor-axis calibration and frame lookup."""
from collections import deque
import math
import numpy as np

def multiply(a,b):
    w,x,y,z=a;s,u,v,t=b
    return np.array([w*s-x*u-y*v-z*t,w*u+x*s+y*t-z*v,w*v-x*t+y*s+z*u,w*t+x*v-y*u+z*s])

def unit(v):
    n=np.linalg.norm(v)
    if n<1e-12:raise ValueError('方向长度不足，请重新采集')
    return np.asarray(v,float)/n

def rotation(q):
    w,x,y,z=unit(q)
    return np.array([[1-2*(y*y+z*z),2*(x*y-z*w),2*(x*z+y*w)],
                     [2*(x*y+z*w),1-2*(x*x+z*z),2*(y*z-x*w)],
                     [2*(x*z-y*w),2*(y*z+x*w),1-2*(x*x+y*y)]])

def align_up(a):
    a=unit(a);b=np.array([0.,0.,1.]);c=np.dot(a,b)
    if c<-0.999999:return np.array([0.,1.,0.,0.])
    return unit(np.r_[1+c,np.cross(a,b)])

def interpolate(a,b,t):
    dot=float(np.dot(a,b))
    if dot<0:b=-b;dot=-dot
    if dot>.9995:return unit(a+(b-a)*t)
    angle=math.acos(min(1,dot))
    return (math.sin((1-t)*angle)*a+math.sin(t*angle)*b)/math.sin(angle)

class Fusion:
    def __init__(self):
        self.q=np.array([1.,0.,0.,0.]);self.bias=np.zeros(3)
        self.last_tick=None;self.history=deque(maxlen=5000)
        self.stationary=[];self.bias_ready=False;self.accel=deque(maxlen=250)
        self.axis_samples=None;self.optical_axis=None;self.alignment=None;self.reference=None
        self.last_axis_progress=None
        self.axis_min_rate=math.radians(.5)
        self.reject_acceleration=False;self.gaps=0

    def update(self,tick,raw):
        acc=np.array(raw[:3],float)/2048
        gyro=np.array(raw[3:],float)*(2000/32768)*math.pi/180
        self.accel.append(acc)
        dt=0 if self.last_tick is None else (tick-self.last_tick)*1e-5
        self.last_tick=tick
        if not self.bias_ready:
            if np.linalg.norm(gyro)<math.radians(3) and .85<np.linalg.norm(acc)<1.15:
                self.stationary.append((tick,gyro))
                if (tick-self.stationary[0][0])*1e-5>=2:
                    stationary_gyro=np.asarray([g for _,g in self.stationary])
                    self.bias=np.mean(stationary_gyro,axis=0)
                    # Accept deliberate slow calibration turns, while keeping
                    # stationary noise out of the optical-axis fit. This gate
                    # affects calibration samples only, not attitude fusion.
                    self.axis_min_rate=max(math.radians(.5),4*float(np.linalg.norm(np.std(stationary_gyro,axis=0))))
                    self.bias_ready=True;self.q=align_up(acc)
            else:self.stationary=[]
            return
        if dt<=0 or dt>.05:
            self.gaps+=1;return
        omega=gyro-self.bias
        if self.axis_samples is not None and np.linalg.norm(omega)>self.axis_min_rate:
            self.axis_samples.append(omega*dt)
        angle=np.linalg.norm(omega)*dt
        dq=np.r_[math.cos(angle/2),omega*dt/2] if angle<1e-8 else np.r_[math.cos(angle/2),unit(omega)*math.sin(angle/2)]
        self.q=unit(multiply(self.q,dq))
        # Compare the acceleration with the gyro prediction at this sample's
        # time, avoiding a one-sample phase lead during continuous rotation.
        self.reject_acceleration=not (.85<np.linalg.norm(acc)<1.15)
        if not self.reject_acceleration:
            predicted=rotation(self.q).T@np.array([0.,0.,1.])
            correction=1.5*np.cross(unit(acc),predicted)*dt
            self.q=unit(multiply(self.q,unit(np.r_[1.,correction/2])))
        self.history.append((tick,self.q.copy()))

    def at(self,tick):
        if not self.history or tick<self.history[0][0] or tick>self.history[-1][0]:return None
        lo,hi=0,len(self.history)-1
        while lo<hi:
            mid=(lo+hi)//2
            if self.history[mid][0]<tick:lo=mid+1
            else:hi=mid
        t1,q1=self.history[lo]
        if t1==tick:return q1.copy()
        t0,q0=self.history[lo-1]
        if t1-t0>5000:return None  # Never invent attitude through a >50-ms sample hole.
        return interpolate(q0,q1,(tick-t0)/(t1-t0))

    def begin_axis(self):
        if not self.bias_ready:raise ValueError('先保持相机静止，等待零偏校准完成')
        self.reference=None;self.alignment=None;self.optical_axis=None
        self.last_axis_progress=None
        self.axis_samples=[]

    def axis_measurement(self):
        values=np.asarray(self.axis_samples if self.axis_samples is not None else [],float).reshape(-1,3)
        lengths=np.linalg.norm(values,axis=1)
        values=values[lengths>1e-12];lengths=lengths[lengths>1e-12]
        progress=dict(samples=len(values),excursion_deg=0.,total_deg=0.,coherence=0.,required_deg=20.,minimum_rate_dps=math.degrees(self.axis_min_rate))
        if not len(values):return None,progress
        # Estimate an undirected axis: outward and return motion reinforce it.
        # Weight by angular travel so many small noisy samples cannot dominate.
        scatter=values.T@(values/lengths[:,None])
        _,vectors=np.linalg.eigh(scatter);axis=vectors[:,-1]
        projected=values@axis;position=np.r_[0.,np.cumsum(projected)]
        # The first deliberate turn defines clockwise, even after returning to
        # the start. This keeps the camera-axis sign independent of the endpoint.
        deliberate=np.flatnonzero(np.abs(position)>=math.radians(5))
        first=position[deliberate[0]] if len(deliberate) else position[np.argmax(np.abs(position))]
        if first<0:axis=-axis
        progress.update(excursion_deg=float(np.degrees(np.ptp(position))),
                        total_deg=float(np.degrees(np.sum(np.abs(projected)))),
                        coherence=float(np.sum(np.abs(projected))/np.sum(lengths)))
        return axis,progress

    def axis_progress(self):
        if self.axis_samples is not None:return self.axis_measurement()[1]
        return self.last_axis_progress or dict(samples=0,excursion_deg=0.,total_deg=0.,coherence=0.,required_deg=20.,minimum_rate_dps=math.degrees(self.axis_min_rate))

    def end_axis(self):
        if self.axis_samples is None:raise ValueError('请先点击“开始光轴校准”')
        axis,progress=self.axis_measurement();self.last_axis_progress=progress
        if progress['samples']<30:raise ValueError('有效旋转数据不足，请继续绕镜头轴转动后，再点击“结束光轴校准”')
        if progress['excursion_deg']<20-1e-6:
            raise ValueError(f"最大转动幅度为{progress['excursion_deg']:.1f}°，不足20°；可以继续转动后再次结束校准")
        if progress['coherence']<.95:raise ValueError('转动轴不稳定，请点击“开始光轴校准”重新采集，仅绕镜头轴转动')
        self.optical_axis=axis;self.axis_samples=None

    def set_reference(self):
        if self.optical_axis is None:raise ValueError('请先完成镜头光轴校准')
        if len(self.accel)<100:raise ValueError('静止数据不足')
        samples=np.array(self.accel)
        if np.max(np.std(samples,axis=0))>.025:raise ValueError('请停止转动，水平摆好相机后重试')
        gravity=-unit(samples.mean(axis=0));z=self.optical_axis
        y=unit(gravity-z*np.dot(gravity,z));x=unit(np.cross(y,z));y=np.cross(z,x)
        self.alignment=np.vstack([x,y,z])
        self.reference=rotation(self.q)@self.alignment.T

    def restore_calibration(self,axis,alignment):
        if not self.bias_ready:raise ValueError('等待静止零偏完成后才能恢复标定')
        z=np.asarray(axis,float);a=np.asarray(alignment,float)
        if z.shape!=(3,) or a.shape!=(3,3) or not np.all(np.isfinite(z)) or not np.all(np.isfinite(a)):
            raise ValueError('保存的安装标定格式无效，请重新校准')
        if abs(np.linalg.norm(z)-1)>.001 or np.max(abs(a@a.T-np.eye(3)))>.001 or abs(np.linalg.det(a)-1)>.001 or np.linalg.norm(a[2]-z)>.001:
            raise ValueError('保存的安装标定校验失败，请重新校准')
        self.optical_axis=z.copy();self.alignment=a.copy()
        # Reboot creates a new inertial heading. Keep the fixed installation
        # transform and use this session's initial camera pose for 3D lock.
        self.reference=rotation(self.q)@self.alignment.T

    def compensation(self,q,mode='roll'):
        if self.reference is None or self.alignment is None:raise ValueError('请先设置水平基准')
        current=rotation(q)@self.alignment.T
        relative=current.T@self.reference
        if mode=='lock3d':return relative
        # Horizontal lock uses the measured gravity projected onto the image
        # plane. Preserve the previous reference at the vertical singularity.
        gravity=self.alignment@(-rotation(q).T@np.array([0.,0.,1.]))
        if math.hypot(gravity[0],gravity[1])<.1:
            raise ValueError('镜头接近竖直方向，水平线方向不确定')
        angle=-math.atan2(gravity[0],gravity[1])
        c,s=math.cos(angle),math.sin(angle)
        return np.array([[c,-s,0],[s,c,0],[0,0,1]])

class Clock:
    def __init__(self):self.latest=None
    def unwrap(self,tick):
        if self.latest is None:self.latest=int(tick);return self.latest
        delta=((int(tick)-(self.latest&0xffffffff)+(1<<31))&0xffffffff)-(1<<31)
        absolute=self.latest+delta
        self.latest=max(self.latest,absolute)
        return absolute
