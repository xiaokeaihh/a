import math,unittest
import cv2
import numpy as np
from bbox_stabilizer import BoxStabilizer
from person_tracker import PersonTracker
from tracking_worker import ObjectTracker
from smart_composition import ComposedAim
from projection_reference import CFG

def box(cx=300,cy=180,w=80,h=140):return [cx-w/2,cy-h/2,w,h]
def center(b):return np.array(b[:2])+np.array(b[2:])/2
def scene():
    im=np.full((360,640,3),30,np.uint8)
    im[90:270,260:340]=[30,80,220]
    for y in range(95,265,10):cv2.line(im,(265,y),(335,y),(255,255,255),2)
    return im

class BoxStabilizerTests(unittest.TestCase):
    def test_stationary_center_and_size_noise_is_reduced(self):
        f=BoxStabilizer();f.reset(box(),0);rng=np.random.default_rng(17);raw=[];out=[]
        for n in range(1,500):
            b=box(300+rng.uniform(-3,3),180+rng.uniform(-3,3),80*rng.uniform(.95,1.05),140*rng.uniform(.95,1.05))
            s=f.update(b,n/30)
            if n>60:raw.append(np.r_[center(b),b[2:]]);out.append(np.r_[center(s),s[2:]])
        self.assertLess(np.std(out,axis=0)[:2].max(),np.std(raw,axis=0)[:2].max()*.2)
        self.assertLess(np.std(out,axis=0)[2:].max(),np.std(raw,axis=0)[2:].max()*.35)

    def test_single_large_outlier_does_not_change_box(self):
        f=BoxStabilizer();initial=f.reset(box(),0)
        for n in range(1,30):
            b=box(420,240,160,280) if n==10 else box()
            np.testing.assert_allclose(f.update(b,n/30),initial)

    def test_slow_true_motion_is_not_lost_in_deadzone(self):
        f=BoxStabilizer();f.reset(box(),0);first=None
        for n in range(1,120):
            out=f.update(box(300+.5*n),n/30)
            if first is None and center(out)[0]>300.1:first=n/30
        self.assertLess(first,.4)
        self.assertLess(abs(center(out)[0]-(300+.5*119)),8)

    def test_fast_motion_has_bounded_lag(self):
        f=BoxStabilizer();f.reset(box(180),0)
        for n in range(1,50):
            out=f.update(box(180+4*n),n/30)
            if n>10:self.assertLess(abs(center(out)[0]-(180+4*n)),15)

    def test_real_size_change_reaches_zoom(self):
        f=BoxStabilizer();f.reset(box(),0)
        for n in range(1,121):
            factor=1+n*.002
            out=f.update(box(w=80*factor,h=140*factor),n/30)
        np.testing.assert_allclose(out[2:],[80*factor,140*factor],rtol=.05)

    def test_reset_after_selection_or_recovery_never_blends_old_target(self):
        f=BoxStabilizer();f.reset(box(),0)
        new=box(500,150,40,60)
        np.testing.assert_allclose(f.reset(new,1),new)
        np.testing.assert_allclose(f.update(new,1.04),new)

    def test_duplicate_frames_do_not_accumulate_confirmation(self):
        f=BoxStabilizer();initial=f.reset(box(),1)
        for _ in range(20):np.testing.assert_allclose(f.update(box(310),1),initial)

    def test_edge_boxes_stay_in_image_and_invalid_boxes_are_rejected(self):
        f=BoxStabilizer()
        for n,b in enumerate(([0,0,20,40],[620,320,20,40],[610,310,30,50])):
            out=f.reset(b,n);self.assertGreaterEqual(out[0],0);self.assertGreaterEqual(out[1],0)
            self.assertLessEqual(out[0]+out[2],640);self.assertLessEqual(out[1]+out[3],360)
        for b in ([1,2,0,5],[1,2,float('nan'),5]):
            with self.assertRaises(ValueError):f.update(b,10)

    def test_person_box_and_selected_overlay_use_the_same_stable_observation(self):
        t=PersonTracker();t._flow=lambda gray:False;im=scene();rng=np.random.default_rng(13);rows=[]
        t.step(im,1,[dict(bbox=box(w=80,h=180),score=.9)])
        for n in range(1,160):
            b=box(300+rng.uniform(-3,3),180+rng.uniform(-3,3),80+rng.uniform(-3,3),180+rng.uniform(-6,6))
            r=t.step(im,1+n/30,[dict(bbox=b,score=.9)])
            self.assertEqual(r['state'],'following')
            chosen=next(p for p in r['people'] if p['id']==r['selected_id'])
            self.assertEqual(chosen['bbox'],r['bbox']);np.testing.assert_allclose(r['raw_bbox'],b)
            if n>40:rows.append(center(r['bbox']))
        self.assertLess(np.std(rows,axis=0).max(),.5)

    def test_object_output_is_filtered_after_appearance_validation(self):
        im=scene();t=ObjectTracker()
        # Deterministic tracker measurements exercise the real output path.
        t.create_tracker=lambda image,roi:None
        t.process(im,box(w=80,h=180),now=1)
        class JitterTracker:
            def __init__(self):self.n=0
            def update(self,image):
                self.n+=1;return True,box(300+(2 if self.n%2 else -2),180,80,180)
        t.tracker=JitterTracker();rows=[]
        for n in range(1,80):
            r=t.process(im,now=1+n/30);self.assertFalse(r['lost']);rows.append(center(r['bbox']))
        self.assertLess(np.std(rows,axis=0).max(),.1)

    def test_stabilized_box_drives_follow_and_size_hold_together(self):
        f=BoxStabilizer();a=ComposedAim(CFG['source_K'],CFG['source_D'],np.eye(3));n=0;sizes=[];fovs=[]
        for scale in (1.,.9,1.1):
            for _ in range(100):
                n+=1;tick=10000+n*3333;b=f.update(box(320,180,100*scale,140*scale),n/30)
                a.observe(b,tick,np.eye(3));h=a.matrix(tick,np.eye(3))
            # Measure the REAL raw target, not only its smoothed rectangle.
            from tracking_geometry import source_ray
            raw=box(320,180,100*scale,140*scale);x,y,w,hh=raw
            rays=np.column_stack([source_ray(u,v,a.k,a.d) for u,v in [(x,y),(x+w,y),(x,y+hh),(x+w,y+hh)]])
            p=np.linalg.solve(h/(1<<24),rays);sizes.append(np.ptp(p[:2]/p[2],axis=1));fovs.append(a.hfov)
        self.assertLess(fovs[1],fovs[0]);self.assertGreater(fovs[2],fovs[0])
        for size in sizes[1:]:np.testing.assert_allclose(size,sizes[0],rtol=.06)

if __name__=='__main__':unittest.main()
