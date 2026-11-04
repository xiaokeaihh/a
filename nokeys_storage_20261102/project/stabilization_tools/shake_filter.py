"""Causal rotation smoothing; no future frames or image buffers are used."""
from collections import deque
import math
import numpy as np
from attitude import unit,interpolate,rotation

class ShakeFilter:
    def __init__(self,strength='balanced',max_angle_deg=4.):
        self.set_strength(strength)
        self.max_angle=math.radians(max_angle_deg)
        self.history=deque(maxlen=5000)
        self.q=None;self.tick=None;self.correction_deg=0.

    def set_strength(self,strength):
        self.tau={'light':.10,'balanced':.18,'strong':.28}[strength]

    def update(self,tick,q):
        q=unit(q)
        dt=0 if self.tick is None else (tick-self.tick)*1e-5
        if self.q is None or not 0<dt<=.05:
            self.q=q.copy()
            if self.tick is not None:self.history.clear()
        else:
            self.q=interpolate(self.q,q,-math.expm1(-dt/self.tau))
            angle=2*math.acos(float(np.clip(abs(np.dot(self.q,q)),0,1)))
            # Follow an intentional pan before correction exceeds its budget.
            if angle>self.max_angle:
                self.q=interpolate(q,self.q,self.max_angle/angle)
        self.tick=int(tick)
        self.correction_deg=math.degrees(2*math.acos(float(np.clip(abs(np.dot(self.q,q)),0,1))))
        self.history.append((int(tick),self.q.copy()))

    def at(self,tick):
        if not self.history or not self.history[0][0]<=tick<=self.history[-1][0]:return None
        lo,hi=0,len(self.history)-1
        while lo<hi:
            mid=(lo+hi)//2
            if self.history[mid][0]<tick:lo=mid+1
            else:hi=mid
        t1,q1=self.history[lo]
        if t1==tick:return q1.copy()
        t0,q0=self.history[lo-1]
        return interpolate(q0,q1,(tick-t0)/(t1-t0))

    def compensation(self,tick,actual,alignment):
        virtual=self.at(tick)
        if virtual is None:raise ValueError('消抖姿态历史尚未就绪，请保持连接')
        current=rotation(actual)@alignment.T
        target=rotation(virtual)@alignment.T
        return current.T@target
