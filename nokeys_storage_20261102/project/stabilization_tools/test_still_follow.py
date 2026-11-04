import json,math,unittest
import numpy as np
from smart_composition import ComposedAim
from projection_reference import CFG
from attitude import rotation

def box(cx=320,cy=180,w=100,h=160):return [cx-w/2,cy-h/2,w,h]
def angular(a,b):return math.degrees(math.acos(float(np.clip(np.dot(a,b),-1,1))))

class StillFollowTests(unittest.TestCase):
    def aim(self):return ComposedAim(CFG['source_K'],CFG['source_D'],np.eye(3))
    def test_static_center_and_size_noise_keeps_view_still(self):
        rng=np.random.default_rng(1422);a=self.aim();directions=[];fovs=[]
        a.observe(box(),10000,np.eye(3));a.matrix(10000,np.eye(3))
        for n in range(1,240):
            tick=10000+n*5000
            a.observe(box(320+rng.uniform(-3,3),180+rng.uniform(-3,3),
                100+rng.uniform(-4,4),160+rng.uniform(-6,6)),tick,np.eye(3))
            h=a.matrix(tick+1500,np.eye(3))
            self.assertTrue(a.valid(h)[0])
            if n>60:directions.append(a.desired[:,2].copy());fovs.append(a.hfov)
        span=max(angular(directions[0],v) for v in directions)
        self.assertLess(span,.03);self.assertLess(np.ptp(fovs),.05)
        self.assertEqual(a.lead_degrees,0)

    def test_continuous_slow_motion_eventually_leaves_anchored_deadzone(self):
        a=self.aim();first_move=None
        for n in range(100):
            tick=10000+n*5000;a.observe(box(300+.8*n),tick,np.eye(3));a.matrix(tick,np.eye(3))
            if n==0:start=a.direction.copy()
            elif first_move is None and angular(start,a.direction)>.1:first_move=n*.05
        self.assertIsNotNone(first_move);self.assertLessEqual(first_move,.4)
        self.assertGreater(angular(start,a.direction),8)
        self.assertLess(angular(a.smoothed,a.direction),3)

    def test_large_real_move_reacts_without_waiting_for_confirmation(self):
        a=self.aim();a.observe(box(300),10000,np.eye(3));start=a.direction.copy()
        a.observe(box(335),15000,np.eye(3));a.matrix(15000,np.eye(3))
        self.assertGreater(angular(start,a.direction),3)

    def test_one_medium_detection_outlier_does_not_pan(self):
        a=self.aim();a.observe(box(),10000,np.eye(3));anchor=a.direction.copy()
        a.observe(box(327),15000,np.eye(3));a.matrix(15000,np.eye(3))
        a.observe(box(),20000,np.eye(3));a.matrix(20000,np.eye(3))
        self.assertLess(angular(anchor,a.direction),.001)
        self.assertEqual(np.linalg.norm(a.velocity),0)

    def test_real_size_change_still_changes_framing(self):
        a=self.aim()
        for n in range(80):
            tick=10000+n*5000;a.observe(box(w=40,h=60),tick,np.eye(3));a.matrix(tick,np.eye(3))
        start=a.hfov
        for n in range(80,160):
            tick=10000+n*5000;a.observe(box(w=260,h=260),tick,np.eye(3));a.matrix(tick,np.eye(3))
        self.assertGreater(a.hfov,start+5)

    def test_stationary_target_does_not_freeze_camera_compensation(self):
        a=self.aim();a.observe(box(),10000,np.eye(3));h0=a.matrix(10000,np.eye(3));d=a.direction.copy()
        # Hold the world-space target while the actual camera rotates.
        turn=rotation(np.array([math.cos(.02),0,math.sin(.02),0]))
        h1=a.matrix(15000,turn)
        np.testing.assert_allclose(a.direction,d)
        self.assertFalse(np.array_equal(h0,h1));self.assertTrue(a.valid(h1)[0])

    def test_motion_then_static_noise_settles_without_creep(self):
        a=self.aim();rng=np.random.default_rng(72);matrices=[]
        for n in range(180):
            tick=10000+n*5000
            cx=280+1.5*n if n<40 else 338.5+rng.uniform(-2,2)
            cy=180 if n<40 else 180+rng.uniform(-2,2)
            a.observe(box(cx,cy),tick,np.eye(3));h=a.matrix(tick,np.eye(3))
            if n>80:matrices.append(h.copy())
        for h in matrices:np.testing.assert_array_equal(h,matrices[0])

    def test_pose_consistent_world_target_rejects_camera_motion_as_person_motion(self):
        import cv2
        a=self.aim();a.observe(box(),10000,np.eye(3));world=a.direction.copy()
        for n in range(1,60):
            turn=rotation(np.array([math.cos(n*.001),0,math.sin(n*.001),0]))
            local=turn.T@world
            pixel=cv2.fisheye.distortPoints((local[:2]/local[2]).reshape(1,1,2),
                np.array(CFG['source_K']),np.array(CFG['source_D'])).ravel()
            cx=(pixel[0]-.5)/2;cy=(718.5-pixel[1])/2
            tick=10000+n*5000;a.observe(box(cx,cy),tick,turn);h=a.matrix(tick,turn)
            self.assertLess(angular(a.direction,world),.001)
            self.assertTrue(a.valid(h)[0])

    def test_repeated_render_calls_do_not_confirm_observation_twice(self):
        a=self.aim();a.observe(box(w=80,h=100),10000,np.eye(3));a.matrix(10000,np.eye(3))
        a.zoom_goal=90.;a._fit_fov=lambda desired:94.
        a.observe(box(w=85,h=105),15000,np.eye(3))
        for tick in range(15000,19000,100):a.matrix(tick,np.eye(3))
        self.assertEqual(a.zoom_goal,90.)

    def projected_size(self,a,h):
        p=np.linalg.solve(h/(1<<24),a.corners);xy=p[:2]/p[2]
        return np.ptp(xy,axis=1)

    def test_farther_and_closer_keep_output_target_size(self):
        a=self.aim();sizes=[];fovs=[];n=0
        for scale in (1.,.9,1.1,1.):
            for _ in range(70):
                n+=1;tick=10000+n*5000
                a.observe(box(w=100*scale,h=140*scale),tick,np.eye(3));h=a.matrix(tick,np.eye(3))
            sizes.append(self.projected_size(a,h));fovs.append(a.hfov)
        self.assertLess(fovs[1],fovs[0]);self.assertGreater(fovs[2],fovs[0])
        for size in sizes[1:]:np.testing.assert_allclose(size,sizes[0],rtol=.015)

    def test_slow_distance_change_has_bounded_size_error(self):
        a=self.aim();n=0;errors=[]
        for scale in np.r_[np.ones(50),np.linspace(1.,.9,60),np.linspace(.9,1.1,100)]:
            n+=1;tick=10000+n*5000
            a.observe(box(w=100*scale,h=140*scale),tick,np.eye(3));h=a.matrix(tick,np.eye(3))
            size=self.projected_size(a,h)
            if n==50:reference=size
            if n>50:errors.append(max(abs(size/reference-1)))
        self.assertLess(max(errors),.06)

    def test_zoom_limits_are_reported_and_view_remains_valid(self):
        a=self.aim();n=0
        for scale in (1.,.5,2.):
            for _ in range(80):
                n+=1;tick=10000+n*5000
                a.observe(box(w=60*scale,h=80*scale),tick,np.eye(3));h=a.matrix(tick,np.eye(3))
                self.assertTrue(a.valid(h)[0]);self.assertTrue(80<=a.hfov<=110)
            if scale!=1.:self.assertTrue(a.framing_status()['size_limited'])

if __name__=='__main__':unittest.main()
