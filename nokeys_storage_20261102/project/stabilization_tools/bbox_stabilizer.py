"""Causal box stabilization shared by drawing, pan and size-holding zoom.

Keep raw tracker state for identity/appearance checks. Stabilize only accepted
output observations; never feed the held box back into optical flow or CSRT.
"""
from collections import deque
import math
import numpy as np


class BoxStabilizer:
    def __init__(self):
        self.history=deque(maxlen=3)
        self.size_history=deque(maxlen=3);self.size_last_time=None
        self.value=None;self.last_time=None
        self.center_pending=None;self.center_hits=0
        self.size_pending=np.zeros(2);self.size_hits=np.zeros(2,dtype=int)
        self.scale_active_until=-math.inf;self.scale_direction=0

    @staticmethod
    def encode(box):
        b=np.asarray(box,dtype=float)
        if b.shape!=(4,) or not np.isfinite(b).all() or min(b[2:])<=0:
            raise ValueError('Invalid tracking box')
        x,y,w,h=b
        return np.array([x+w/2,y+h/2,math.log(w),math.log(h)])

    def box(self):
        if self.value is None:return None
        cx,cy,lw,lh=self.value;w,h=np.exp([lw,lh])
        x=max(0.,cx-w/2);y=max(0.,cy-h/2)
        right=min(640.,cx+w/2);bottom=min(360.,cy+h/2)
        return [float(x),float(y),float(max(0.,right-x)),float(max(0.,bottom-y))]

    def reset(self,box=None,now=None):
        self.history.clear();self.value=None;self.last_time=None
        self.size_history.clear();self.size_last_time=None
        self.center_pending=None;self.center_hits=0
        self.size_pending[:]=0;self.size_hits[:]=0
        self.scale_active_until=-math.inf;self.scale_direction=0
        if box is not None:
            self.value=self.encode(box);self.last_time=now
            self.history.append(self.value.copy())
            self.size_history.append(self.value[2:].copy());self.size_last_time=now
        return self.box()

    def update(self,box,now,size_fresh=True):
        measured=self.encode(box)
        if not math.isfinite(now):raise ValueError('Invalid box timestamp')
        if self.value is None or self.last_time is None or now-self.last_time>.5:
            return self.reset(box,now)
        if now<=self.last_time:return self.box()
        dt=min(.2,now-self.last_time);self.last_time=now
        self.history.append(measured)
        size_dt=dt
        if size_fresh:
            if self.size_last_time is not None:size_dt=min(.2,now-self.size_last_time)
            self.size_last_time=now
            self.size_history.append(measured[2:].copy())
        # Median rejects a one-frame bad detection, independently for center
        # and logarithmic dimensions. Three samples are history, not a queue.
        if len(self.history)<3:return self.box()
        median=np.median(np.array(self.history),axis=0)
        delta=median[:2]-self.value[:2];distance=float(np.linalg.norm(delta))
        # The dead zone is anchored to the published center. Slow true motion
        # accumulates against it instead of being discarded frame by frame.
        if distance<=4:
            self.center_pending=None;self.center_hits=0
        else:
            direction=delta/distance
            consistent=self.center_pending is not None and np.dot(direction,self.center_pending)>.7
            self.center_hits=self.center_hits+1 if consistent else 1
            self.center_pending=direction
            # A median outside the zone plus a current observation supporting
            # the same motion already confirms two samples. Avoid adding two
            # more frames of lag after the median's rejection of a lone spike.
            current_delta=measured[:2]-self.value[:2]
            supported=np.linalg.norm(current_delta)>4 and np.dot(current_delta,delta)>0
            if self.center_hits>=2 or supported:
                alpha=1-math.exp(-dt/(.035 if distance>8 else .075))
                self.value[:2]+=alpha*delta
        # Center motion must not change size. Width and height have separate
        # proportional thresholds so real approach/recession still reaches zoom.
        # Flow updates position between person detections. Reusing the last
        # detector dimensions is not an independent scale confirmation.
        if not size_fresh or len(self.size_history)<3:return self.box()
        size_median=np.median(np.array(self.size_history),axis=0)
        size_error=size_median-self.value[2:]
        current_error=measured[2:]-self.value[2:]
        coherent=(size_error[0]*size_error[1]>0 and
                  np.min(np.abs(size_error))>math.log(1.045) and
                  np.all(current_error*size_error>0))
        if coherent:
            # Two median-supported, same-direction scale changes already
            # reject a lone spike. Do not make real distance motion wait for
            # the normal small-noise confirmation again.
            self.scale_direction=1 if size_error[0]>0 else -1
            self.scale_active_until=now+.22
        for i in range(2):
            error=size_median[i]-self.value[i+2]
            fast=now<=self.scale_active_until and error*self.scale_direction>0
            threshold=math.log(1.01 if fast else 1.025)
            if abs(error)<=threshold:
                self.size_hits[i]=0;self.size_pending[i]=0
            else:
                side=1 if error>0 else -1
                self.size_hits[i]=self.size_hits[i]+1 if self.size_pending[i]==side else 1
                self.size_pending[i]=side
                if fast or self.size_hits[i]>=3:
                    alpha=1-math.exp(-size_dt/(.05 if fast else .06 if abs(error)>.12 else .12))
                    self.value[i+2]+=alpha*error
        return self.box()
