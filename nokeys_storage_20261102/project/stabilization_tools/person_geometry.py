"""A bounded virtual view; clamp its direction before sampling outside source."""
import math
import numpy as np
from attitude import unit
from tracking_geometry import Aim,look_at,target_matrix

class SafeAim(Aim):
    def __init__(self,*args,**kwargs):
        super().__init__(*args,**kwargs);self.base_hfov=100;self.minimum_hfov=80;self.clamped=False;self.invalid_fraction=0.
        x,y=np.meshgrid(np.linspace(0,639,33),np.linspace(0,359,19))
        self.grid=np.stack([x.ravel(),y.ravel(),np.ones(x.size)],axis=0)
        self.margin=3.

    def valid(self,h):
        rays=(h/(1<<24))@self.grid;z=rays[2];norm=rays[:2]/np.maximum(z,1/64)
        radius=np.linalg.norm(norm,axis=0);theta=np.arctan(radius);td=theta.copy()
        for n,k in enumerate(self.d):td+=theta*k*theta**(2*n+2)
        gain=np.divide(td,radius,out=np.ones_like(td),where=radius>1e-10)
        sx=self.k[0][2]+self.k[0][0]*norm[0]*gain;sy=self.k[1][2]+self.k[1][1]*norm[1]*gain
        good=(z>=1/64)&(z<4)&(radius<64)&(sx>=self.margin)&(sx<=1279-self.margin)&(sy>=self.margin)&(sy<=719-self.margin)
        return bool(good.all()),float(1-good.mean())

    def _safe(self,current):
        goal=self.desired[:,2];self.clamped=False
        # Fixed steps make this small calculation bounded; it runs on the PC.
        for hfov in (100,95,90,85,80):
            h=target_matrix(current,self.desired,hfov,self.k,self.sign)
            if self.valid(h)[0]:
                self.hfov=min(hfov,self.hfov+.5)
                self.invalid_fraction=0.
                return target_matrix(current,self.desired,self.hfov,self.k,self.sign)
        optical=current[:,2]
        angle=math.acos(float(np.clip(np.dot(optical,goal),-1,1)))
        tangent=goal-optical*np.dot(optical,goal)
        if np.linalg.norm(tangent)<1e-7:
            tangent=self.desired[:,0]-optical*np.dot(self.desired[:,0],optical)
        if np.linalg.norm(tangent)<1e-7:tangent=np.cross(optical,np.array([1.,0.,0.]))
        tangent=unit(tangent)
        low,high=0.,1.;best=None
        for _ in range(9):
            a=(low+high)/2;direction=optical*math.cos(angle*a)+tangent*math.sin(angle*a)
            desired=look_at(direction,self.reference,self.desired)
            h=target_matrix(current,desired,80,self.k,self.sign)
            if self.valid(h)[0]:low=a;best=h
            else:high=a
        if best is None:
            desired=look_at(optical,self.reference,self.desired)
            best=target_matrix(current,desired,80,self.k,self.sign)
        self.hfov=80;self.clamped=True;self.invalid_fraction=self.valid(best)[1]
        return best

    def matrix(self,tick,current):
        h=super().matrix(tick,current)
        return None if h is None else self._safe(current)

    def hold_matrix(self,tick,current):
        if self.desired is None:return None
        # Hold a direction, never extrapolate a hidden person's motion.
        self.render_tick=tick
        return self._safe(current)
