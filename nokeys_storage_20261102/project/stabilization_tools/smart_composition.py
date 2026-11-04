"""Bounded target framing; use calibrated rays, never a second image resample."""
import math
import numpy as np
from attitude import unit
from person_geometry import SafeAim
from tracking_geometry import source_ray,look_at,target_matrix

class ComposedAim(SafeAim):
    def __init__(self,*args,**kwargs):
        super().__init__(*args,**kwargs)
        self.framing_enabled=True;self.corners=None;self.requested_hfov=100.
        self.framing_hfov=100.;self.lead_degrees=0.;self.target_clipped=False
        self.actual_desired=None;self.framing_tick=None
        # Hold a world-space target direction, never a stale output matrix:
        # real camera rotation must still be compensated by current-frame IMU.
        self.motion_pending=None;self.motion_pending_tick=None
        self.accepted_tick=None
        self.zoom_goal=None;self.zoom_pending=None;self.zoom_hits=0
        self.zoom_active_until=-1;self.zoom_motion_sign=0
        self.zoom_observation_tick=None
        self.size_reference=None;self.size_limited=False

    def _observe_direction(self,bbox,tick,current):
        x,y,w,h=bbox
        measured=unit(current@np.diag([1,self.sign,1])@source_ray(
            x+w/2,y+h/2,self.k,self.d,self.horizontal_reversed))
        if self.tick is None:
            self.direction=measured;self.tick=self.accepted_tick=tick
            return
        dt=(tick-self.tick)*1e-5
        if dt<=0:raise ValueError('跳过倒序目标观测')
        dot=float(np.clip(np.dot(self.direction,measured),-1,1))
        angle=math.acos(dot)
        tangent=measured-self.direction*dot
        # An anchored 2.2-degree dead zone rejects detector/flow jitter without
        # random-walk drift. Slow genuine motion accumulates against the anchor.
        accept=angle>math.radians(6.)
        if angle>math.radians(2.2):
            tangent=unit(tangent)
            consistent=(self.motion_pending is not None and
                self.motion_pending_tick is not None and
                0<tick-self.motion_pending_tick<=25000 and
                np.dot(tangent,self.motion_pending)>.7)
            accept=accept or consistent
            self.motion_pending=tangent;self.motion_pending_tick=tick
        else:
            self.motion_pending=None;self.motion_pending_tick=None
        if accept:
            elapsed=(tick-self.accepted_tick)*1e-5
            velocity=(measured-self.direction)/max(elapsed,1e-5)
            speed=np.linalg.norm(velocity);limit=math.radians(60)
            if speed>limit:velocity*=limit/speed
            self.velocity=.5*self.velocity+.5*velocity if elapsed<.4 else np.zeros(3)
            self.direction=measured;self.accepted_tick=tick
            self.motion_pending=None;self.motion_pending_tick=None
        else:
            # Stop extrapolating/leading a stationary person. Small nonzero
            # velocities otherwise magnify box noise and keep the view moving.
            self.velocity*=math.exp(-dt/.06)
            if np.linalg.norm(self.velocity)<math.radians(1):self.velocity[:]=0
        self.tick=tick

    def _zoom_target(self,requested):
        if self.zoom_goal is None:self.zoom_goal=float(requested)
        # Render calls may outnumber detections: confirmation counts distinct
        # observations only. Substantial, already-filtered scale changes can
        # update the goal immediately in either zoom direction.
        if self.zoom_observation_tick==self.tick:return self.zoom_goal
        self.zoom_observation_tick=self.tick
        difference=requested-self.zoom_goal
        if abs(difference)>4:
            self.zoom_motion_sign=1 if difference>0 else -1
            self.zoom_active_until=self.tick+25000
            self.zoom_goal=float(requested);self.zoom_pending=None;self.zoom_hits=0
        elif self.tick<=self.zoom_active_until and difference*self.zoom_motion_sign>.35:
            # Once real zoom motion is confirmed, follow its remaining scale
            # change without accumulating another two-degree error each time.
            self.zoom_goal=float(requested);self.zoom_pending=None;self.zoom_hits=0
        elif abs(requested-self.zoom_goal)<=2:
            self.zoom_pending=None;self.zoom_hits=0
        else:
            side=1 if requested>self.zoom_goal else -1
            self.zoom_hits=self.zoom_hits+1 if side==self.zoom_pending else 1
            self.zoom_pending=side
            if self.zoom_hits>=3:
                self.zoom_motion_sign=side;self.zoom_active_until=self.tick+20000
                self.zoom_goal=float(requested);self.zoom_pending=None;self.zoom_hits=0
        return self.zoom_goal

    def observe(self,bbox,tick,current):
        self._observe_direction(bbox,tick,current)
        x,y,w,h=bbox
        points=[(x,y),(x+w,y),(x,y+h),(x+w,y+h),(x+w/2,y),(x+w/2,y+h)]
        basis=current@np.diag([1,self.sign,1])
        self.corners=np.column_stack([basis@source_ray(min(639,max(0,u)),min(359,max(0,v)),self.k,self.d,self.horizontal_reversed) for u,v in points])

    def _target_extent(self,desired):
        if self.corners is None:return None
        rays=desired.T@self.corners
        if np.any(rays[2]<=.05):return None
        # Translation-independent apparent size: centering/lead must not look
        # like a scale change and start a zoom feedback loop.
        xy=rays[:2]/rays[2]
        return max(float(np.ptp(xy[0]))/.65,
                   float(np.ptp(xy[1]))*(640/360)*(self.k[1][1]/self.k[0][0])/.68)/2

    def _fit_fov(self,desired):
        extent=self._target_extent(desired)
        if extent is None:return 110.
        if self.size_reference is None:return 100.
        requested=math.degrees(2*math.atan(extent/max(self.size_reference,1e-8)))
        self.size_limited=requested<80 or requested>110
        return float(np.clip(requested,80,110))

    def _bounded(self,current,base,max_expand=.5):
        goal=self.desired[:,2];self.clamped=False
        candidates=list(np.arange(float(base),80.,-5.))+[80.]
        for fov in candidates:
            candidate=target_matrix(current,self.desired,fov,self.k,self.sign)
            if self.valid(candidate)[0]:
                self.hfov=min(float(fov),self.hfov+max_expand)
                self.actual_desired=self.desired;self.invalid_fraction=0.
                return target_matrix(current,self.desired,self.hfov,self.k,self.sign)
        # Reuse exactly the existing 80-degree direction-limiting fallback.
        h=super()._safe(current);self.actual_desired=None
        return h

    def matrix(self,tick,current):
        if not self.framing_enabled:
            self.lead_degrees=0.;self.requested_hfov=100.
            return super().matrix(tick,current)
        if self.direction is None or self.tick is None or not 0<=tick-self.tick<=60000:return None
        age=(tick-self.tick)*1e-5
        predicted=unit(self.direction+self.velocity*min(age,.15))
        lead=self.velocity*.18;lead-=predicted*np.dot(predicted,lead)
        length=np.linalg.norm(lead)
        if length>math.tan(math.radians(7)):lead*=math.tan(math.radians(7))/length
        self.lead_degrees=math.degrees(math.atan(np.linalg.norm(lead)))
        goal=unit(predicted+lead)
        dt=.03333 if self.render_tick is None else max(0,min(.1,(tick-self.render_tick)*1e-5))
        if self.smoothed is None:self.smoothed=goal
        elif dt>0:
            angle=math.acos(float(np.clip(np.dot(self.smoothed,goal),-1,1)))
            alpha=1-math.exp(-dt/.08)
            if angle<math.radians(.03):self.smoothed=goal
            else:
                alpha=min(alpha,math.radians(160)*dt/angle)
                self.smoothed=unit(self.smoothed*(1-alpha)+goal*alpha)
        self.render_tick=tick;self.desired=look_at(self.smoothed,self.reference,self.desired)
        self.requested_hfov=self._fit_fov(self.desired)
        error=self._zoom_target(self.requested_hfov)-self.framing_hfov
        # Time-based response in both directions, independent of capture FPS.
        # Remove the extra 15deg/s crawl after a scale change was confirmed.
        rate=100. if abs(error)>4 else 60.
        change=np.clip(error*(1-math.exp(-dt/.07)),-rate*dt,rate*dt)
        self.framing_hfov=float(np.clip(self.framing_hfov+change,80,110))
        h=self._bounded(current,self.framing_hfov,max_expand=80*dt)
        if self.size_reference is None:
            extent=self._target_extent(self.actual_desired if self.actual_desired is not None else self.desired)
            if extent is not None and extent>1e-8:
                # Lock the size actually seen in the first valid follow view.
                self.size_reference=extent/math.tan(math.radians(self.hfov)/2)
                self.zoom_goal=self.framing_hfov=self.hfov
        if self.corners is not None:
            rays=(h/(1<<24));out=np.linalg.solve(rays,np.diag([1,self.sign,1])@current.T@self.corners)
            self.target_clipped=bool(np.any(out[2]<=0) or np.any(out[0]/np.maximum(out[2],1e-9)<0) or np.any(out[0]/np.maximum(out[2],1e-9)>639) or np.any(out[1]/np.maximum(out[2],1e-9)<0) or np.any(out[1]/np.maximum(out[2],1e-9)>359))
        return h

    def hold_matrix(self,tick,current):
        if self.desired is None:return None
        dt=.03333 if self.render_tick is None else max(0,min(.1,(tick-self.render_tick)*1e-5))
        self.render_tick=tick;self.lead_degrees=0.
        return self._bounded(current,self.framing_hfov,max_expand=40*dt) if self.framing_enabled else super().hold_matrix(tick,current)

    def framing_status(self):
        return dict(enabled=self.framing_enabled,hfov=round(float(self.hfov),1),requested_hfov=round(float(self.requested_hfov),1),
                    minimum_hfov=80,maximum_hfov=110,lead_degrees=round(float(self.lead_degrees),1),
                    target_clipped=self.target_clipped,view_clamped=self.clamped,
                    size_hold_enabled=self.framing_enabled,
                    size_limited=bool(self.size_limited or self.clamped or abs(self.hfov-self.requested_hfov)>2))
