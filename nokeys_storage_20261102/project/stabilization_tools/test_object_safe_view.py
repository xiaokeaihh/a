"""Object follow must apply the person's view bounds on every steering path."""
import math,time,unittest
from unittest.mock import patch
import numpy as np
from attitude import rotation
from person_geometry import SafeAim
from projection_reference import CFG,fixed_project
from target_tracking import TargetTracking
from tracking_geometry import Aim,world_camera
from tracking_mux import TrackingMux

Q=np.array([1.,0.,0.,0.])
IDENTITY=np.eye(3)

class ObjectSafeViewTests(unittest.TestCase):
    def arm(self,mirrored=False,sign=1):
        t=TargetTracking(CFG['source_K'],CFG['source_D'])
        with patch.object(t,'_work'):t.arm(IDENTITY,sign,horizontal_reversed=mirrored)
        t.aim.framing_enabled=False  # Exercise the retained legacy view mode.
        t.state='following';t.last_result=time.monotonic()
        self.addCleanup(t.shutdown)
        return t

    def assert_covered(self,h):
        self.assertTrue(np.isfinite(h).all())
        for y in np.linspace(0,359,13,dtype=int):
            for x in np.linspace(0,639,21,dtype=int):
                sx,sy,valid=fixed_project(int(x),int(y),h)
                self.assertTrue(valid,(x,y,sx,sy))

    def test_edge_views_match_person_method_in_all_coordinate_conventions(self):
        for sign in (1,-1):
            for mirrored in (False,True):
                for u,v in ((320,180),(520,180),(590,60),(60,320)):
                    with self.subTest(sign=sign,mirrored=mirrored,u=u,v=v):
                        t=self.arm(mirrored,sign)
                        person=SafeAim(CFG['source_K'],CFG['source_D'],IDENTITY,sign,horizontal_reversed=mirrored)
                        box=[u-10,v-20,20,40]
                        for aim in (t.aim,person):aim.observe(box,10000,IDENTITY)
                        h=t.matrix(10000,Q,IDENTITY)
                        np.testing.assert_array_equal(h,person.matrix(10000,IDENTITY))
                        self.assert_covered(h)
                        self.assertEqual(t.status()['hfov'],person.hfov)
                        self.assertEqual(t.status()['view_clamped'],person.clamped)

    def test_edge_reduces_invalid_samples_instead_of_forcing_target_to_center(self):
        t=self.arm();box=[580,40,20,40]
        old=Aim(CFG['source_K'],CFG['source_D'],IDENTITY)
        old.observe(box,10000,IDENTITY);t.aim.observe(box,10000,IDENTITY)
        old_h=old.matrix(10000,IDENTITY);new_h=t.matrix(10000,Q,IDENTITY)
        self.assertGreater(t.aim.valid(old_h)[1],.05)
        self.assertTrue(t.aim.valid(new_h)[0]);self.assertTrue(t.status()['view_clamped'])
        self.assertEqual(t.status()['hfov'],80)
        self.assert_covered(new_h)

    def test_fov_recovers_smoothly_after_target_returns(self):
        t=self.arm();t.aim.observe([580,40,20,40],10000,IDENTITY);t.matrix(10000,Q,IDENTITY)
        previous=t.aim.hfov;self.assertLess(previous,100)
        for frame in range(1,101):
            tick=10000+3333*frame;t.last_result=time.monotonic()
            t.aim.observe([310,160,20,40],tick,IDENTITY)
            h=t.matrix(tick,Q,IDENTITY)
            self.assertTrue(t.aim.valid(h)[0])
            self.assertLessEqual(t.aim.hfov-previous,.50001)
            previous=t.aim.hfov
        self.assertEqual(previous,100);self.assertFalse(t.status()['view_clamped'])

    def test_timing_hold_stays_safe_and_keeps_original_expiry(self):
        t=self.arm();t.aim.observe([310,160,20,40],10000,IDENTITY);t.matrix(10000,Q,IDENTITY)
        t.timing_wait=True
        for degree in (0,70,180):
            q=np.array([math.cos(math.radians(degree)/2),0,math.sin(math.radians(degree)/2),0])
            h=t.matrix(80000,q,IDENTITY);current=world_camera(q,IDENTITY)
            self.assertTrue(t.aim.valid(h)[0],degree);self.assert_covered(h)
        self.assertIsNone(t.matrix(9999,Q,IDENTITY))
        self.assertIsNone(t.matrix(110001,Q,IDENTITY))

    def test_imu_recovery_keeps_safe_view_and_mirror_convention(self):
        mux=TrackingMux(CFG['source_K'],CFG['source_D'],lambda *a:None)
        self.addCleanup(mux.shutdown)
        with patch.object(mux.object,'_work'):mux.arm(IDENTITY,client_id='object-page',horizontal_reversed=True)
        mux.object.state='following';mux.reset_pose(rotation(np.array([1.,0.,0.,0.])),-1)
        self.assertIsInstance(mux.object.aim,SafeAim)
        self.assertTrue(mux.object.aim.horizontal_reversed)
        self.assertEqual(mux.object.aim.sign,-1);self.assertTrue(mux.object.timing_wait)
        self.assertIsNone(mux.object.matrix(10000,Q,IDENTITY))
        mux.object.aim.observe([580,40,20,40],10000,IDENTITY)
        mux.object.last_result=time.monotonic();mux.object.timing_wait=False
        self.assert_covered(mux.object.matrix(10000,Q,IDENTITY))

    def test_reselection_resets_fov_and_old_motion_without_dropping_safe_aim(self):
        t=self.arm(mirrored=True);t.aim.observe([580,40,20,40],10000,IDENTITY);t.matrix(10000,Q,IDENTITY)
        t.submit(dict(token=t.token,frame_id=2,jpeg='eA==',roi=[300,160,20,40]),13333,IDENTITY)
        self.assertIsInstance(t.aim,SafeAim);self.assertTrue(t.aim.horizontal_reversed)
        self.assertIsNone(t.aim.direction);self.assertEqual(t.aim.hfov,100)
        self.assertFalse(t.status()['view_clamped']);np.testing.assert_array_equal(t.aim.velocity,np.zeros(3))

if __name__=='__main__':unittest.main()
