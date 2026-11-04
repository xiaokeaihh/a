import io,json,math,struct,tempfile,time,unittest
from pathlib import Path
from unittest.mock import patch
import cv2
import numpy as np
from attitude_display import camera_angles
from attitude import rotation
from object_recovery import ObjectRecovery
from smart_composition import ComposedAim
from projection_reference import CFG,fixed_project
from protocol import Decoder,telemetry,attitude_packet,crc8
from recordings import Recordings,finalize_webm,vint

class WorkflowTests(unittest.TestCase):
    def test_camera_relative_angles_and_reference(self):
        for axis,name in [(0,'pitch'),(1,'yaw'),(2,'roll')]:
            vector=np.zeros(3);vector[axis]=math.sin(.2);q=np.r_[math.cos(.2),vector]
            value=camera_angles(q,np.eye(3),np.eye(3));self.assertAlmostEqual(value[name],math.degrees(.4),delta=.1)
            zero=camera_angles(q,np.eye(3),rotation(q));self.assertEqual([zero[k] for k in ('roll','pitch','yaw')],[0.,0.,0.])

    def test_new_telemetry_crc_and_real_control_ack(self):
        from server import Controller
        c=Controller();self.addCleanup(c.tracking.shutdown)
        payload=bytes([1,7,5,1,0,27,15,0]);packet=telemetry(5,payload)
        self.assertEqual(Decoder().feed(packet),[(5,payload)])
        self.assertEqual(Decoder().feed(packet[:-1]+bytes([packet[-1]^1])),[])
        c.receive(5,payload);s=c.status()['image_controls']
        self.assertTrue(s['supported']);self.assertTrue(s['applied']['gamma']);self.assertFalse(s['applied']['auto_exposure'])
        sent=[];c.port=type('Port',(),{'write':lambda self,b:sent.append(b)})()
        c.act(dict(action='image_control',control='gamma',enabled=True));self.assertEqual(sent[0][3],0x87)
        c.controls_received=time.monotonic()-2
        with self.assertRaisesRegex(ValueError,'固件'):c.act(dict(action='image_control',control='gamma',enabled=True))
        c.port=None
        p=attitude_packet(3,dict(roll=-12.3,pitch=45.6,yaw=179.9));self.assertEqual(crc8(p[2:-1]),p[-1]);self.assertEqual(struct.unpack('<3h',p[5:-1]),(-123,456,1799))

    def test_composition_size_limits_and_calibrated_coverage(self):
        fovs=[];aim=ComposedAim(CFG['source_K'],CFG['source_D'],np.eye(3))
        for phase,box in enumerate(([300,160,40,40],[200,80,240,200])):
            for frame in range(100):
                tick=10000+3333*(frame+phase*100);aim.observe(box,tick,np.eye(3));h=aim.matrix(tick,np.eye(3))
                self.assertTrue(aim.valid(h)[0]);self.assertGreaterEqual(aim.hfov,80);self.assertLessEqual(aim.hfov,110)
            fovs.append(aim.hfov)
            for x,y in ((0,0),(639,0),(0,359),(639,359),(320,180)):self.assertTrue(fixed_project(x,y,h)[2])
        self.assertGreater(fovs[1],fovs[0])

    def test_composition_lookahead_and_disabled_legacy_mode(self):
        aim=ComposedAim(CFG['source_K'],CFG['source_D'],np.eye(3))
        leads=[]
        for frame in range(20):
            tick=10000+frame*3333;aim.observe([270+frame,150,40,60],tick,np.eye(3));h=aim.matrix(tick,np.eye(3))
            leads.append(aim.lead_degrees)
        self.assertGreater(max(leads),0);self.assertLessEqual(max(leads),7.01)
        self.assertLessEqual(math.degrees(math.acos(np.clip(np.dot(aim.direction,aim.smoothed),-1,1))),10)
        aim.framing_enabled=False;aim.matrix(tick+1,np.eye(3));self.assertEqual(aim.lead_degrees,0)

    def test_recording_streaming_owner_order_limit_and_duration(self):
        # Minimal streaming WebM header, with Info and unknown-size Segment.
        info=b'\x2a\xd7\xb1\x83\x0f\x42\x40'
        header=b'\x1a\x45\xdf\xa3\x80\x18\x53\x80\x67'+b'\x01'+b'\xff'*7+b'\x15\x49\xa9\x66'+bytes([0x80+len(info)])+info
        body=header+b'\x1f\x43\xb6\x75\x81\x00'+b'X'*200
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[1]/'verification_smart_follow') as tmp:
            store=Recordings(tmp);row=store.start(dict(client_id='recording-page',mime='video/webm'))
            with self.assertRaises(ValueError):store.append(row['id'],'other-page',0,io.BytesIO(body),len(body))
            store.append(row['id'],'recording-page',0,io.BytesIO(body),len(body))
            with self.assertRaises(ValueError):store.append(row['id'],'recording-page',0,io.BytesIO(body),len(body))
            store.event(dict(id=row['id'],client_id='recording-page',time=1,type='手动标记'))
            result=store.finish(dict(id=row['id'],client_id='recording-page',duration=2.5,frames=75))
            self.assertEqual(result['state'],'ready');self.assertEqual(len(result['events']),1)
            self.assertIn(b'\x44\x89\x88'+struct.pack('>d',2500.),store.video(row['id']).read_bytes())
            self.assertEqual(store.list()[0]['id'],row['id']);self.assertIsNone(store.active)
            with self.assertRaises(ValueError):store.video('../escape')
            row2=store.start(dict(client_id='recording-page',mime='video/webm'))
            store.append(row2['id'],'recording-page',0,io.BytesIO(body),len(body))
            store.active['last_activity']-=61;store.active['accepted_duration']=2.5
            rows=store.list();self.assertIsNone(store.active)
            self.assertEqual(next(row for row in rows if row['id']==row2['id'])['state'],'partial')
            self.assertTrue(store.video(row2['id']).is_file())
            self.assertIsNotNone(store.start(dict(client_id='next-recording-page',mime='video/webm')))

class ObjectRecoveryTests(unittest.TestCase):
    def setUp(self):
        rng=np.random.default_rng(555);self.patch=rng.integers(0,256,(64,80,3),dtype=np.uint8)
        cv2.rectangle(self.patch,(4,4),(75,59),(10,230,40),3)
    def image(self,positions):
        image=np.full((360,640,3),35,np.uint8)
        for x,y in positions:image[y:y+64,x:x+80]=self.patch
        return image
    def test_three_confirmations_restore_original_after_occlusion(self):
        from tracking_worker import ObjectTracker
        if not hasattr(cv2,'TrackerCSRT_create'):self.skipTest('CSRT runtime required')
        t=ObjectTracker();t.process(self.image([(100,100)]),[100,100,80,64],now=1)
        result=t.process(self.image([]),now=1.2);self.assertTrue(result['lost'])
        for n in range(3):result=t.process(self.image([(380,180)]),now=2+n*.22)
        self.assertFalse(result['lost']);self.assertEqual(result['reacquire_count'],1)
        self.assertLess(abs(result['bbox'][0]-380),5)
    def test_two_similar_candidates_are_not_silently_selected(self):
        recovery=ObjectRecovery(self.patch)
        for _ in range(5):self.assertIsNone(recovery.find(self.image([(80,80),(400,180)])))
        for _ in range(2):self.assertIsNone(recovery.find(self.image([(400,180)])))
        self.assertIsNotNone(recovery.find(self.image([(400,180)])))
    def test_occluded_or_flat_scene_never_reacquires(self):
        recovery=ObjectRecovery(self.patch)
        for _ in range(5):self.assertIsNone(recovery.find(self.image([])))

if __name__=='__main__':unittest.main()
