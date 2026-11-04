import time
import base64,json,math,struct,time,unittest
from unittest.mock import patch
import numpy as np
import cv2
from attitude import rotation
from tracking_geometry import Aim,source_pixel,source_ray,world_camera
from projection_reference import CFG,float_project
from tracking_worker import ObjectTracker
from target_tracking import TargetTracking
from protocol import crc8

def image(x=190,y=140):
    rng=np.random.default_rng(81)
    out=np.full((360,640,3),45,np.uint8)
    texture=rng.integers(0,256,(64,80,3),dtype=np.uint8)
    out[y:y+64,x:x+80]=texture
    cv2.rectangle(out,(x+4,y+4),(x+75,y+59),(30,220,180),2)
    return out

def jpeg(im):return base64.b64encode(cv2.imencode('.jpg',im,[cv2.IMWRITE_JPEG_QUALITY,85])[1]).decode()

class TrackingTests(unittest.TestCase):
    def test_raw_crop_orientation(self):
        np.testing.assert_allclose(source_pixel(0,0),[.5,718.5])
        np.testing.assert_allclose(source_pixel(639,359),[1278.5,.5])

    def test_center_ray_matches_selected_pixel_all_signs(self):
        for sign in (1,-1):
            for u,v in [(320,180),(220,110),(410,250)]:
                aim=Aim(CFG['source_K'],CFG['source_D'],np.eye(3),sign)
                aim.observe([u-20,v-20,40,40],10000,np.eye(3))
                h=aim.matrix(10000,np.eye(3))
                p=float_project(319.5,179.5,h)
                np.testing.assert_allclose(p,source_pixel(u,v),atol=.02)

    def test_static_world_target_camera_rotation_compensated(self):
        aim=Aim(CFG['source_K'],CFG['source_D'],np.eye(3))
        aim.observe([260,130,40,40],10000,np.eye(3))
        world=aim.direction.copy()
        for degree in (-40,0,30,90):
            q=np.array([math.cos(math.radians(degree)/2),0,0,math.sin(math.radians(degree)/2)])
            current=world_camera(q,np.eye(3));h=aim.matrix(11000,current)
            ray=h@np.array([319.5,179.5,1.]);ray/=np.linalg.norm(ray)
            np.testing.assert_allclose(current@ray,world,atol=2e-5)

    def test_causal_and_expired_observation(self):
        aim=Aim(CFG['source_K'],CFG['source_D'],np.eye(3))
        aim.observe([300,160,40,40],10000,np.eye(3))
        self.assertIsNone(aim.matrix(9999,np.eye(3)))
        self.assertIsNone(aim.matrix(70001,np.eye(3)))

    def test_smooth_direction_rate_bounded(self):
        aim=Aim(CFG['source_K'],CFG['source_D'],np.eye(3))
        aim.observe([300,160,40,40],10000,np.eye(3));aim.matrix(10000,np.eye(3));before=aim.smoothed.copy()
        aim.observe([350,160,40,40],13333,np.eye(3));aim.matrix(13333,np.eye(3))
        angle=math.degrees(math.acos(np.clip(np.dot(before,aim.smoothed),-1,1)))
        self.assertLessEqual(angle,160*.03333+1e-5)

    def test_csrt_motion_and_loss(self):
        if not hasattr(cv2,'TrackerCSRT_create'):self.skipTest('Use tracking runtime for CSRT test')
        tracker=ObjectTracker();tracker.process(image(),[190,140,80,64],now=1.);costs=[]
        for i in range(1,9):
            started=time.perf_counter();r=tracker.process(image(190+3*i,140+2*i),now=1.+i/30);costs.append((time.perf_counter()-started)*1000)
            self.assertFalse(r['lost']);x,y,w,h=r['bbox']
            self.assertLess(abs(x+w/2-(230+3*i)),7);self.assertLess(abs(y+h/2-(172+2*i)),7)
        self.assertTrue(tracker.process(np.full((360,640,3),45,np.uint8),now=1.3)['lost'])
        self.assertTrue(tracker.process(image(),now=1.31)['lost'])
        report={'synthetic_frames':8,'max_center_error_px':7,'mean_csrt_ms':float(np.mean(costs)),'max_csrt_ms':max(costs),'hardware_validated':False}
        from pathlib import Path
        (Path(__file__).resolve().parents[1]/'verification_tracking/tracker_test.json').write_text(json.dumps(report,indent=2))

    def test_texture_and_bounds_validation(self):
        tracker=ObjectTracker()
        with self.assertRaises(ValueError):tracker.process(image(),[-1,100,40,40])
        with self.assertRaises(ValueError):tracker.process(np.zeros((360,640,3),np.uint8),[200,100,50,50])

    def test_latest_queue_and_session_cancellation(self):
        t=TargetTracking(CFG['source_K'],CFG['source_D'])
        with patch.object(t,'_work'):
            token=t.arm(np.eye(3));t.state='following'
            for frame in range(10):t.submit(dict(token=token,frame_id=frame,jpeg='eA=='),frame+1,np.eye(3))
            self.assertEqual(t.pending['tick'],10);self.assertEqual(t.skipped,9)
            t.stop();self.assertIsNone(t.pending)
            with self.assertRaises(ValueError):t.submit(dict(token=token,frame_id=11,jpeg='eA=='),12,np.eye(3))

    def test_serial_metadata_gate_and_pose_bundle(self):
        from server import Controller
        c=Controller();c.port=type('Port',(),{'write':lambda self,p:len(p)})()
        c.enabled=True;c.last_sample=time.monotonic();c.hardware=dict(tracking_capable=True,mode=2,view=6,valid=True,test=False)
        c.clock.latest=10000;c.capture_events={37:(9000,9000)}
        c.fusion.alignment=np.eye(3);c.fusion.reference=np.eye(3);c.fusion.history.append((9000,np.array([1,0,0,0])))
        data=dict(token=0,frame_id=37,capture_tick=9001,jpeg='eA==')
        with self.assertRaisesRegex(ValueError,'不匹配'):c.tracking_frame(data)
        c.clock.latest=200001;data['capture_tick']=9000
        with self.assertRaisesRegex(ValueError,'超过1秒'):c.tracking_frame(data)
        c.tracking.shutdown();c.port=None

    def test_video_marker_format(self):
        payload=b'\xa5\x01'+struct.pack('<II',0xfffe1234,0xabcdef01);check=crc8(payload)
        self.assertEqual(len(payload+bytes([check,check^255])),12)

    def test_real_worker_ipc_and_confirmed_recovery(self):
        t=TargetTracking(CFG['source_K'],CFG['source_D'])
        def wait(predicate):
            deadline=time.monotonic()+3
            while not predicate() and time.monotonic()<deadline:time.sleep(.01)
            self.assertTrue(predicate(),t.status())
        try:
            token=t.arm(np.eye(3));wait(lambda:t.worker_ready)
            t.submit(dict(token=token,frame_id=1,jpeg=jpeg(image()),roi=[190,140,80,64]),10000,np.eye(3))
            wait(lambda:t.processed==1);self.assertEqual(t.state,'following')
            # A cold CSRT initialization may exceed the observation deadline;
            # the first fresh update must recover without relaxing that gate.
            started=time.perf_counter()
            t.submit(dict(token=token,frame_id=2,jpeg=jpeg(image(193,142))),20000,np.eye(3))
            t.status();self.assertLess(time.perf_counter()-started,.05)
            wait(lambda:t.processed==2)
            self.assertIsNotNone(t.matrix(20010,np.array([1,0,0,0]),np.eye(3)))
            t.submit(dict(token=token,frame_id=3,jpeg=jpeg(np.full((360,640,3),45,np.uint8))),30000,np.eye(3))
            wait(lambda:t.state in ('recovering','lost'))
            self.assertIsNotNone(t.matrix(30010,np.array([1,0,0,0]),np.eye(3)))
            generation=t.generation
            for frame in range(4,11):
                t.submit(dict(token=token,frame_id=frame,jpeg=jpeg(image())),frame*10000,np.eye(3))
                wait(lambda:t.processed==frame);time.sleep(.22)
                if t.reacquire_count:break
            self.assertEqual(t.state,'following');self.assertEqual(t.reacquire_count,1);self.assertEqual(t.generation,generation)
        finally:t.shutdown()

    def test_pose_packet_size_and_other_views_unchanged(self):
        from server import Controller
        from projection_reference import view_matrices
        c=Controller();sent=[];c.port=type('Port',(),{'write':lambda self,p:sent.append(p)})()
        c.enabled=True;c.last_sample=time.monotonic();c.hardware=dict(all_views_capable=True)
        c.fusion.bias_ready=True  # This case tests the calibrated IMU path, not visual fallback.
        c.fusion.alignment=np.eye(3);c.fusion.reference=np.eye(3);q=np.array([1,0,0,0])
        c.fusion.history.append((10000,q));c.pending.append((27,10000,10000))
        c.tracking.object.state='following';c.tracking.object.last_result=time.monotonic()
        c.tracking.object.aim=Aim(CFG['source_K'],CFG['source_D'],np.eye(3));c.tracking.object.aim.observe([210,140,80,60],10000,np.eye(3))
        c.flush_frames();self.assertEqual(len(sent[0]),230)
        values=np.array(struct.unpack('<54i',sent[0][13:-1])).reshape(6,3,3)
        # Identity pose here is a vertical optical axis: roll falls back to
        # the valid 3D reference while the target uses its continuous basis.
        expected=np.array(view_matrices(c.fusion.compensation(q,'lock3d'),c.zoom,c.image_y_sign))
        np.testing.assert_array_equal(values[:5],expected[:5]);self.assertFalse(np.array_equal(values[5],expected[5]))
        c.tracking.stop();c.mode='lock3d';c.pending.append((28,10000,10000));c.flush_frames()
        values=np.array(struct.unpack('<54i',sent[1][13:-1])).reshape(6,3,3)
        np.testing.assert_array_equal(values,expected);c.port=None;c.tracking.shutdown()

    def test_observer_cannot_automatically_stop_owner(self):
        t=TargetTracking(CFG['source_K'],CFG['source_D'])
        with patch.object(t,'_work'):
            token=t.arm(np.eye(3),client_id='capture-page')
            with self.assertRaisesRegex(ValueError,'本页未启动'):
                t.request_stop(dict(token=token,client_id='observer-page',cause='video_closed'))
            self.assertEqual(t.state,'waiting');self.assertEqual(t.token,token)
            t.request_stop(dict(token=token,client_id='capture-page',cause='video_closed'))
            self.assertEqual(t.state,'idle');self.assertIn('关闭HDMI',t.note)

    def test_legacy_and_stale_stop_requests_are_ignored(self):
        t=TargetTracking(CFG['source_K'],CFG['source_D'])
        with patch.object(t,'_work'):
            token=t.arm(np.eye(3),client_id='capture-page')
            with self.assertRaisesRegex(ValueError,'刷新网页'):t.request_stop({})
            with self.assertRaisesRegex(ValueError,'会话已变化'):
                t.request_stop(dict(token=token-1,client_id='capture-page',cause='video_closed'))
            self.assertEqual(t.state,'waiting');self.assertEqual(t.token,token)
            t.stop()

    def test_observer_frames_do_not_replace_owner(self):
        t=TargetTracking(CFG['source_K'],CFG['source_D'])
        with patch.object(t,'_work'):
            token=t.arm(np.eye(3),client_id='capture-page')
            with self.assertRaisesRegex(ValueError,'另一页面'):
                t.submit(dict(token=token,client_id='observer-page',frame_id=1,jpeg='eA=='),1,np.eye(3))
            self.assertIsNone(t.last_frame)
            result=t.submit(dict(token=token,client_id='capture-page',frame_id=1,jpeg='eA=='),1,np.eye(3))
            self.assertEqual(result['source_frame'],1);self.assertEqual(result['owner_client'],'capture-page')
            t.stop()

    def test_explicit_manual_stop_from_another_page_remains_available(self):
        t=TargetTracking(CFG['source_K'],CFG['source_D'])
        with patch.object(t,'_work'):
            token=t.arm(np.eye(3),client_id='capture-page')
            t.request_stop(dict(token=token,client_id='observer-page',cause='manual'))
            self.assertEqual(t.state,'idle')

    def test_legacy_start_requires_refresh_before_hardware_commands(self):
        from server import Controller
        c=Controller();sent=[];c.port=type('Port',(),{'write':lambda self,p:sent.append(p)})()
        with self.assertRaisesRegex(ValueError,'刷新网页'):c.act(dict(action='tracking_start',video_width=1280,video_height=720))
        self.assertEqual(sent,[]);c.port=None;c.tracking.shutdown()

    def test_old_observation_pauses_without_cancelling_fresh_pending_frame(self):
        t=TargetTracking(CFG['source_K'],CFG['source_D'])
        with patch.object(t,'_work'):
            t.arm(np.eye(3));t.state='following';t.last_result=time.monotonic()
            t.aim.observe([210,140,80,60],10000,np.eye(3));t.aim.matrix(10000,np.eye(3))
            generation=t.generation;t.pending={'tick':72000,'roi':None}
            h=t.matrix(72000,np.array([1,0,0,0]),np.eye(3))
            self.assertIsNotNone(h);self.assertTrue(t.timing_wait);self.assertEqual(t.state,'following')
            self.assertEqual(t.generation,generation);self.assertIsNotNone(t.pending)
            self.assertIsNone(t.matrix(110001,np.array([1,0,0,0]),np.eye(3)))
            self.assertEqual(t.state,'following');t.stop()

    def test_hold_uses_current_imu_without_old_motion_extrapolation(self):
        aim=Aim(CFG['source_K'],CFG['source_D'],np.eye(3))
        aim.observe([210,140,80,60],10000,np.eye(3));aim.matrix(10000,np.eye(3));desired=aim.desired.copy()
        aim.velocity=np.array([100.,0,0])
        q=np.array([math.cos(.2),0,0,math.sin(.2)]);current=world_camera(q,np.eye(3))
        h=aim.hold_matrix(80000,current);ray=h@np.array([319.5,179.5,1.]);ray/=np.linalg.norm(ray)
        np.testing.assert_allclose(current@ray,desired[:,2],atol=2e-5)
        self.assertIsNone(aim.hold_matrix(9999,current));self.assertIsNone(aim.hold_matrix(110001,current))

    def test_selecting_preserves_queued_init_and_accepts_update_after_dispatch(self):
        t=TargetTracking(CFG['source_K'],CFG['source_D'])
        with patch.object(t,'_work'):
            token=t.arm(np.eye(3))
            t.submit(dict(token=token,frame_id=1,jpeg='eA==',roi=[190,140,80,64]),10000,np.eye(3))
            init=t.pending
            t.submit(dict(token=token,frame_id=2,jpeg='eA=='),13333,np.eye(3));self.assertIs(t.pending,init)
            t.pending=None  # worker has dispatched the initialization
            t.submit(dict(token=token,frame_id=3,jpeg='eA=='),16666,np.eye(3))
            self.assertEqual(t.pending['frame_id'],3);self.assertIsNone(t.pending['roi']);t.stop()

    def test_real_worker_recovers_fresh_frame_after_slow_initial_selection(self):
        t=TargetTracking(CFG['source_K'],CFG['source_D'])
        def wait(predicate):
            deadline=time.monotonic()+3
            while not predicate() and time.monotonic()<deadline:time.sleep(.01)
            self.assertTrue(predicate(),t.status())
        try:
            token=t.arm(np.eye(3));wait(lambda:t.worker_ready)
            t.submit(dict(token=token,frame_id=1,jpeg=jpeg(image()),roi=[190,140,80,64]),10000,np.eye(3),latest_tick=85000)
            wait(lambda:t.processed==1);self.assertEqual(t.state,'following');self.assertTrue(t.timing_wait)
            self.assertGreater(t.result_age_ms,600);generation=t.generation
            # Fresh capture follows a 750ms frozen-selection gap. The first
            # CSRT update must actually validate its appearance, then recover.
            t.submit(dict(token=token,frame_id=2,jpeg=jpeg(image())),85000,np.eye(3),latest_tick=85050)
            wait(lambda:t.processed==2);self.assertEqual(t.state,'following');self.assertFalse(t.timing_wait)
            self.assertEqual(t.generation,generation);self.assertIsNotNone(t.matrix(85060,np.array([1,0,0,0]),np.eye(3)))
            self.assertEqual(t.observation_frame,2)
        finally:t.shutdown()

if __name__=='__main__':unittest.main()
