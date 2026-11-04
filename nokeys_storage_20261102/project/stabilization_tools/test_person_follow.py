import json,math,time,unittest
from pathlib import Path
from unittest.mock import patch
import cv2
import numpy as np
from person_capture import marker
from person_tracker import PersonTracker,clip_box
from person_geometry import SafeAim
from person_inference import PersonDetector
from projection_reference import CFG,fixed_project
from attitude import rotation
from protocol import crc8
from person_follow import PersonFollow

def scene(boxes):
    image=np.zeros((360,640,3),np.uint8)+30
    for box,color in boxes:
        x,y,w,h=map(int,box);image[y:y+h,x:x+w]=color
        for yy in range(y+5,y+h-5,12):cv2.line(image,(x+5,yy),(x+w-5,yy),(255,255,255),1)
    return image

class PersonTests(unittest.TestCase):
    def test_single_person_automatically_locks(self):
        tracker=PersonTracker();box=[100,80,80,180]
        result=tracker.step(scene([(box,(20,40,230))]),1,[dict(bbox=box,score=.9)])
        self.assertEqual(result['state'],'following');self.assertEqual(result['selected_id'],1)

    def test_multiple_people_require_selection_and_do_not_hop(self):
        tracker=PersonTracker();a=[100,80,80,180];b=[400,80,80,180]
        result=tracker.step(scene([(a,(20,40,230)),(b,(230,40,20))]),1,[dict(bbox=a,score=.9),dict(bbox=b,score=.9)])
        self.assertEqual(result['state'],'waiting');tracker.select(1)
        result=tracker.step(scene([(b,(230,40,20))]),1.5,[dict(bbox=b,score=.9)])
        self.assertEqual(result['selected_id'],1);self.assertEqual(result['state'],'recovering')
        np.testing.assert_allclose(result['bbox'],a)

    def test_short_occlusion_recovers_same_identity(self):
        tracker=PersonTracker();box=[100,80,80,180];image=scene([(box,(20,40,230))])
        tracker.step(image,1,[dict(bbox=box,score=.9)])
        result=tracker.step(scene([]),1.5,[]);self.assertEqual(result['state'],'recovering')
        moved=[120,80,80,180]
        result=tracker.step(scene([(moved,(20,40,230))]),2,[dict(bbox=moved,score=.9)])
        self.assertEqual(result['state'],'following');self.assertEqual(result['selected_id'],1)
        np.testing.assert_allclose(result['bbox'],moved)

    def test_expired_identity_waits_for_confirmed_automatic_recovery(self):
        tracker=PersonTracker();box=[100,80,80,180];image=scene([(box,(20,40,230))])
        tracker.step(image,1,[dict(bbox=box,score=.9)])
        result=tracker.step(image,3.5,[dict(bbox=box,score=.9)])
        self.assertEqual(result['state'],'lost');self.assertEqual(result['selected_id'],1)
        for now in [3.6,3.7,3.8]:result=tracker.step(image,now,[dict(bbox=box,score=.9)])
        self.assertEqual(result['state'],'following');self.assertEqual(result['selected_id'],1)

    def test_partial_box_is_clipped_instead_of_declared_lost(self):
        np.testing.assert_allclose(clip_box([630,100,30,100]),[630,100,10,100])
        tracker=PersonTracker();box=[610,80,30,180]
        result=tracker.step(scene([(box,(20,40,230))]),1,[dict(bbox=[610,80,60,180],score=.9)])
        self.assertEqual(result['state'],'following');self.assertEqual(result['bbox'][2],30)

    def test_native_frame_marker_requires_crc(self):
        image=np.zeros((720,1280,3),np.uint8);data=bytearray(b'\xa5\x01'+(123).to_bytes(4,'little')+(4567).to_bytes(4,'little'))
        data.extend([crc8(data),crc8(data)^255])
        for bit in range(96):
            x=1088+(bit%24)*8;y=(bit//24)*8
            image[y:y+8,x:x+8]=255 if data[bit//8]&(1<<(bit%8)) else 0
        self.assertEqual(marker(image),dict(frame_id=123,capture_tick=4567))
        image[0:8,1088:1096]=255-image[0:8,1088:1096]
        self.assertIsNone(marker(image))

    def test_edge_view_is_valid_in_fixed_hardware_reference(self):
        for sign in (1,-1):
            for u,v in [(320,180),(520,180),(590,60),(60,320)]:
                aim=SafeAim(CFG['source_K'],CFG['source_D'],np.eye(3),sign)
                aim.observe([u-10,v-20,20,40],10000,np.eye(3));h=aim.matrix(10000,np.eye(3))
                self.assertTrue(aim.valid(h)[0],(sign,u,v))
                for x,y in [(0,0),(639,0),(0,359),(639,359),(319,179),(160,90),(480,270)]:
                    self.assertTrue(fixed_project(x,y,h)[2],(sign,u,v,x,y))
                self.assertGreaterEqual(aim.hfov,80)

    def test_opposite_held_direction_does_not_generate_nan(self):
        aim=SafeAim(CFG['source_K'],CFG['source_D'],np.eye(3))
        aim.observe([310,160,20,40],10000,np.eye(3));aim.matrix(10000,np.eye(3))
        h=aim.hold_matrix(80000,rotation(np.array([0.,0.,1.,0.])))
        self.assertTrue(np.isfinite(h).all());self.assertTrue(aim.valid(h)[0])

    def test_report_keeps_unmeasured_display_and_gpu_memory_explicit(self):
        follow=PersonFollow(CFG['source_K'],CFG['source_D'],lambda *a:None)
        report=follow.report();self.assertIsNone(report['status']['gpu_memory_mib'])
        self.assertEqual(report['status']['fpga_extra_framebuffer_bytes'],0)
        self.assertEqual(report['status']['frame_queue_capacity'],1)

    def test_person_follow_preserves_other_five_pose_matrices(self):
        from server import Controller
        from projection_reference import view_matrices
        import struct
        c=Controller();sent=[];c.port=type('Port',(),{'write':lambda self,p:sent.append(p)})()
        c.enabled=True;c.last_sample=time.monotonic();c.hardware=dict(all_views_capable=True);c.mode='lock3d'
        c.fusion.bias_ready=True  # This test exercises the calibrated IMU path.
        c.fusion.alignment=np.eye(3);c.fusion.reference=np.eye(3);q=np.array([1.,0.,0.,0.])
        c.fusion.history.append((10000,q));c.pending.append((27,10000,10000))
        c.tracking.current=c.tracking.person;p=c.tracking.person;p.state='following';p.last_result=time.monotonic();p.result={'state':'following'}
        p.aim=SafeAim(CFG['source_K'],CFG['source_D'],np.eye(3));p.aim.observe([200,100,80,180],10000,np.eye(3))
        c.flush_frames();self.assertEqual(len(sent[0]),230)
        values=np.array(struct.unpack('<54i',sent[0][13:-1])).reshape(6,3,3)
        expected=np.array(view_matrices(c.fusion.compensation(q,'lock3d'),c.zoom,c.image_y_sign))
        np.testing.assert_array_equal(values[:5],expected[:5]);self.assertFalse(np.array_equal(values[5],expected[5]))
        c.port=None;c.tracking.shutdown()

class RealModelTests(unittest.TestCase):
    def test_actual_small_model_detects_people_and_fits_frame_budget(self):
        config=json.loads(Path(__file__).with_name('person_runtime.json').read_text())
        detector=PersonDetector(config['model']);self.assertEqual(detector.provider,'DmlExecutionProvider')
        sample=Path(r'D:\python prince\Lib\site-packages\ultralytics\assets\bus.jpg')
        image=cv2.resize(cv2.imread(str(sample)),(640,360));times=[]
        for _ in range(15):people=detector.detect(image);times.append(detector.last_ms)
        self.assertGreaterEqual(len(people),3)
        self.assertLess(float(np.percentile(times[3:],95)),33.3)
        self.assertLess(Path(config['model']).stat().st_size,12*1048576)
        out=Path(__file__).resolve().parents[1]/'verification_tracking/person_model_benchmark.json'
        out.write_text(json.dumps(dict(provider=detector.provider,gpu=detector.gpu_name,mean_ms=float(np.mean(times[3:])),p95_ms=float(np.percentile(times[3:],95)),
            people=len(people),model_bytes=Path(config['model']).stat().st_size,hardware_follow_validated=False),ensure_ascii=False,indent=2),encoding='utf-8')

if __name__=='__main__':unittest.main()
