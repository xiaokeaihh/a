"""Source-frame rays and a bounded, causal virtual camera (native 640x360)."""
import math
import cv2
import numpy as np
from attitude import rotation,unit

def source_pixel(u,v,horizontal_reversed=False):
    # HDMI RAW pane is the rounded 2x2 average of DDR rows 719,718,...
    x=2*float(u)+.5
    return np.array([1279-x if horizontal_reversed else x,718.5-2*float(v)])

def source_ray(u,v,k,d,horizontal_reversed=False):
    p=source_pixel(u,v,horizontal_reversed).reshape(1,1,2)
    xy=cv2.fisheye.undistortPoints(p,np.asarray(k,float),np.asarray(d,float)).ravel()
    if not np.all(np.isfinite(xy)) or np.linalg.norm(xy)>30:
        raise ValueError('目标位于镜头有效视野之外，请重新框选')
    return unit(np.r_[xy,1.])

def world_camera(q,alignment):
    return rotation(q)@np.asarray(alignment,float).T

def look_at(direction,reference,previous=None):
    z=unit(direction);y=np.asarray(reference,float)[:,1]
    x=np.cross(y,z)
    if np.linalg.norm(x)<.15:
        # Keep roll continuous near a vertical look direction.
        x=(previous if previous is not None else reference)[:,0]
        x=x-z*np.dot(x,z)
    x=unit(x);return np.column_stack([x,np.cross(z,x),z])

def target_matrix(current,desired,hfov,k,image_y_sign=1):
    f=640/(2*math.tan(math.radians(hfov)/2))
    out=np.array([[f,0,319.5],[0,f*k[1][1]/k[0][0],179.5],[0,0,1.]])
    sign=np.diag([1,image_y_sign,1])
    h=np.rint(sign@current.T@desired@sign@np.linalg.inv(out)*(1<<24)).astype(np.int64)
    if np.any(abs(h)>2147483647):raise ValueError('跟随矩阵超出硬件范围')
    return h

class Aim:
    def __init__(self,k,d,reference,sign=1,hfov=100,horizontal_reversed=False):
        self.k=k;self.d=d;self.reference=np.array(reference,float);self.sign=sign;self.hfov=hfov
        self.horizontal_reversed=bool(horizontal_reversed)
        self.direction=None;self.tick=None;self.velocity=np.zeros(3)
        self.smoothed=None;self.render_tick=None;self.desired=None

    def observe(self,bbox,tick,current):
        x,y,w,h=bbox
        direction=current@np.diag([1,self.sign,1])@source_ray(x+w/2,y+h/2,self.k,self.d,self.horizontal_reversed)
        if self.tick is not None:
            dt=(tick-self.tick)*1e-5
            if dt<=0:raise ValueError('跳过倒序目标观测')
            velocity=(direction-self.direction)/dt
            speed=np.linalg.norm(velocity);limit=math.radians(60)
            if speed>limit:velocity*=limit/speed
            self.velocity=.5*self.velocity+.5*velocity if dt<.4 else np.zeros(3)
        self.direction=unit(direction);self.tick=tick

    def matrix(self,tick,current):
        if self.direction is None:return None
        if tick<self.tick:return None
        age=max(0,(tick-self.tick)*1e-5)
        if age>.6:return None
        goal=unit(self.direction+self.velocity*min(age,.15))
        if self.smoothed is None:self.smoothed=goal
        elif self.render_tick is not None and tick>self.render_tick:
            dt=min(.1,(tick-self.render_tick)*1e-5)
            angle=math.acos(float(np.clip(np.dot(self.smoothed,goal),-1,1)))
            alpha=1-math.exp(-dt/.08)
            if angle>1e-6:alpha=min(alpha,math.radians(160)*dt/angle)
            self.smoothed=unit(self.smoothed*(1-alpha)+goal*alpha)
        self.render_tick=tick
        self.desired=look_at(self.smoothed,self.reference,self.desired)
        return target_matrix(current,self.desired,self.hfov,self.k,self.sign)

    def hold_matrix(self,tick,current):
        # Keep the last viewing direction, without extrapolating old target
        # motion. Current-frame IMU still compensates camera rotation.
        if self.desired is None or self.tick is None or not 0<=tick-self.tick<=100000:return None
        self.render_tick=tick
        return target_matrix(current,self.desired,self.hfov,self.k,self.sign)
