import unittest,math
from unittest.mock import patch
import numpy as np
from bbox_stabilizer import BoxStabilizer
from smart_composition import ComposedAim
from projection_reference import CFG
from test_bbox_stabilizer import box,scene
from person_tracker import PersonTracker
from tracking_geometry import source_ray

class ZoomResponseTests(unittest.TestCase):
    def test_ten_percent_distance_step_responds_quickly_in_both_directions(self):
        for fps in (15,30):
            for scale in (.9,1.1):
                with self.subTest(fps=fps,scale=scale):
                    f=BoxStabilizer();a=ComposedAim(CFG['source_K'],CFG['source_D'],np.eye(3));values=[]
                    warm=fps*2
                    for n in range(warm+fps*2):
                        s=1 if n<warm else scale;now=n/fps;tick=10000+round(now*1e5)
                        b=f.update(box(320,180,100*s,140*s),now)
                        a.observe(b,tick,np.eye(3));h=a.matrix(tick,np.eye(3));values.append(a.hfov)
                        if n==warm-1:
                            x,y,w,hh=box(320,180,100,140)
                            rays=np.column_stack([source_ray(u,v,a.k,a.d) for u,v in [(x,y),(x+w,y),(x,y+hh),(x+w,y+hh)]])
                            p=np.linalg.solve(h/(1<<24),rays);reference=np.ptp(p[:2]/p[2],axis=1)
                    initial=values[warm-1];final=values[-1];span=abs(final-initial)
                    first=next((n-warm)/fps for n in range(warm,len(values)) if abs(values[n]-initial)>.2)
                    ninety=next((n-warm)/fps for n in range(warm,len(values)) if abs(values[n]-initial)>=.9*span)
                    self.assertLessEqual(first,.1);self.assertLessEqual(ninety,.3)
                    # Faster completion must still preserve the raw target size.
                    x,y,w,hh=box(320,180,100*scale,140*scale)
                    rays=np.column_stack([source_ray(u,v,a.k,a.d) for u,v in [(x,y),(x+w,y),(x,y+hh),(x+w,y+hh)]])
                    p=np.linalg.solve(h/(1<<24),rays);size=np.ptp(p[:2]/p[2],axis=1)
                    np.testing.assert_allclose(size,reference,rtol=.03)
                    motion=np.diff(values[warm:])*(1 if scale>1 else -1)
                    self.assertGreaterEqual(motion.min(),-1e-8)

    def test_flow_reusing_one_bad_size_does_not_confirm_it(self):
        f=BoxStabilizer();initial=f.reset(box(),0)
        for n in range(1,25):
            bad=n in (4,5) # one detector result reused by the next flow frame
            b=box(w=104,h=182) if bad else box()
            out=f.update(b,n/30,size_fresh=n%2==0)
            np.testing.assert_allclose(out[2:],initial[2:])

    def test_person_marks_flow_as_position_only(self):
        t=PersonTracker();t._flow=lambda gray:False
        t.step(scene(),1,[dict(bbox=box(w=80,h=180),score=.9)])
        with patch.object(t.output_box,'update',wraps=t.output_box.update) as update:
            t.step(scene(),1+1/30,None)
            self.assertFalse(update.call_args.kwargs['size_fresh'])

    def test_fifteen_hz_size_measurements_on_thirty_hz_frames_are_responsive(self):
        for scale in (.9,1.1):
            f=BoxStabilizer();a=ComposedAim(CFG['source_K'],CFG['source_D'],np.eye(3));values=[]
            for n in range(120):
                s=1 if n<60 else scale;tick=10000+round(n/30*1e5)
                b=f.update(box(320,180,100*s,140*s),n/30,size_fresh=n%2==0)
                a.observe(b,tick,np.eye(3));a.matrix(tick,np.eye(3));values.append(a.hfov)
            first=next((n-60)/30 for n in range(60,120) if abs(values[n]-values[59])>.2)
            self.assertLessEqual(first,.12)

    def test_correlated_small_size_noise_does_not_pump_zoom(self):
        f=BoxStabilizer();a=ComposedAim(CFG['source_K'],CFG['source_D'],np.eye(3));rng=np.random.default_rng(552);fovs=[];s=1
        for n in range(400):
            if n%2==0:s=1+rng.uniform(-.025,.025)
            tick=10000+round(n/30*1e5)
            b=f.update(box(320,180,100*s,140*s),n/30,size_fresh=n%2==0)
            a.observe(b,tick,np.eye(3));a.matrix(tick,np.eye(3))
            if n>60:fovs.append(a.hfov)
        self.assertLess(np.ptp(fovs),.3)

    def test_repeated_render_at_same_tick_does_not_advance_zoom(self):
        a=ComposedAim(CFG['source_K'],CFG['source_D'],np.eye(3));a.observe(box(),10000,np.eye(3));a.matrix(10000,np.eye(3))
        a.observe(box(w=100,h=180),15000,np.eye(3));a.matrix(15000,np.eye(3));initial=a.hfov
        for _ in range(20):a.matrix(15000,np.eye(3));self.assertEqual(a.hfov,initial)

if __name__=='__main__':unittest.main()
