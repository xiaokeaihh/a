import unittest,math,time,struct,json,tempfile,base64
from pathlib import Path
import numpy as np
import cv2
from scipy.spatial.transform import Rotation
from attitude import rotation
from shake_filter import ShakeFilter
from auto_alignment import solve_alignment,angular_fit,AutoAlignment
from server import Controller
from protocol import crc8

def q_from_rotvec(v):
    a=Rotation.from_rotvec(v).as_quat();return a[[3,0,1,2]]

class NewBehavior(unittest.TestCase):
    def test_high_frequency_shake_is_reduced_on_all_axes(self):
        for axis in np.eye(3):
            f=ShakeFilter();actual=[];virtual=[]
            for i in range(4001):
                t=i*.002;v=axis*math.radians(1)*math.sin(2*math.pi*6*t)
                q=q_from_rotvec(v);f.update(i*200,q)
                if t>2:
                    actual.append(v@axis);virtual.append(Rotation.from_matrix(rotation(f.q)).as_rotvec()@axis)
            self.assertLess(np.std(virtual)/np.std(actual),.2)

    def test_deliberate_pan_follows_with_bounded_crop_and_stops(self):
        f=ShakeFilter();angles=[]
        for i in range(3001):
            t=i*.002;angle=min(t,3)*30
            q=q_from_rotvec([0,math.radians(angle),0]);f.update(i*200,q)
            self.assertLessEqual(f.correction_deg,4.00001)
            angles.append(math.degrees(Rotation.from_matrix(rotation(f.q)).as_rotvec()[1]))
        self.assertGreater(angles[1500],85)
        self.assertAlmostEqual(angles[-1],90,places=3)
        self.assertTrue(np.all(np.diff(angles)>=-1e-6))

    def test_roll_wrap_and_noncommuting_rotations_remain_proper(self):
        f=ShakeFilter()
        for i in range(2500):
            q=q_from_rotvec([.1*math.sin(i*.005),.2*math.sin(i*.01),i*.003])
            if i%2:q=-q
            f.update(i*200,q);r=f.compensation(i*200,q,np.eye(3))
            np.testing.assert_allclose(r.T@r,np.eye(3),atol=1e-10)
            self.assertAlmostEqual(np.linalg.det(r),1,places=10)
        self.assertLessEqual(len(f.history),5000)

    def test_historical_frame_not_live_pose_is_sent(self):
        c=Controller();c.mode='follow';c.enabled=True
        class Port:
            def __init__(self):self.writes=[]
            def write(self,p):self.writes.append(p)
        c.port=Port();c.fusion.bias_ready=True;c.fusion.alignment=np.eye(3);c.fusion.reference=np.eye(3)
        for i in range(501):
            tick=1000+i*200;q=q_from_rotvec([0,i*.001,0])
            c.fusion.history.append((tick,q));c.shake.update(tick,q)
        c.fusion.last_tick=tick;c.hardware={'all_views_capable':True}
        target=10100;c.last_sample=time.monotonic();c.pending.append((17,target,target));c.flush_frames()
        packet=c.port.writes[-1];self.assertEqual(len(packet),230)
        self.assertEqual(packet[-1],crc8(packet[2:-1]));self.assertEqual(struct.unpack('<II',packet[5:13]),(17,target))
        from projection_reference import view_matrices
        expected=view_matrices(c.shake.compensation(target,c.fusion.at(target),np.eye(3)))
        got=np.asarray(struct.unpack('<54i',packet[13:-1])).reshape(6,3,3)
        np.testing.assert_array_equal(got,expected)

    def test_reconnection_and_gaps_reset_old_filter(self):
        f=ShakeFilter();f.update(0,q_from_rotvec([0,0,0]));f.update(200,q_from_rotvec([.05,0,0]))
        f.update(10000,q_from_rotvec([1.,0,0]))
        self.assertEqual(len(f.history),1);self.assertLess(f.correction_deg,.00001)

    def test_strength_change_keeps_historical_frames_available(self):
        f=ShakeFilter()
        for i in range(100):f.update(i*200,q_from_rotvec([i*.001,0,0]))
        before=f.at(10500);f.set_strength('strong')
        np.testing.assert_array_equal(f.at(10500),before);self.assertEqual(len(f.history),100)

    def test_real_rotation_fit_ignores_moving_feature_outliers(self):
        rng=np.random.default_rng(42);a=np.c_[rng.uniform(-.7,.7,(180,2)),np.ones(180)];a/=np.linalg.norm(a,axis=1)[:,None]
        v=np.array([.03,-.02,.015]);r=Rotation.from_rotvec(v).as_matrix();b=a@r.T
        b[:30]=rng.normal(size=(30,3));b[:30]/=np.linalg.norm(b[:30],axis=1)[:,None]
        got,error=angular_fit(a,b);np.testing.assert_allclose(got,v,atol=1e-6);self.assertLess(error,1e-6)

    def test_jpeg_frames_are_tracked_in_calibrated_fisheye_coordinates(self):
        from projection_reference import CFG
        model=AutoAlignment(CFG['source_K'],CFG['source_D']);rng=np.random.default_rng(9)
        pixels=np.c_[model.k[0,2]+rng.uniform(-100,100,600),model.k[1,2]+rng.uniform(-100,100,600)]
        normal=cv2.fisheye.undistortPoints(pixels.reshape(-1,1,2),model.k,model.d).reshape(-1,2)
        rays=np.c_[normal,np.ones(len(normal))];vector=np.array([.025,-.018,.014]);r=Rotation.from_rotvec(vector).as_matrix()
        def jpeg(points):
            p,_=cv2.fisheye.projectPoints(points.reshape(-1,1,3),np.zeros(3),np.zeros(3),model.k,model.d)
            gray=np.zeros((360,640),np.uint8)
            for i,(x,y) in enumerate(p.reshape(-1,2)):
                cv2.circle(gray,(round(x),round(y)),2,150+i%105,-1)
            ok,data=cv2.imencode('.jpg',gray,[cv2.IMWRITE_JPEG_QUALITY,90]);self.assertTrue(ok)
            return base64.b64encode(data).decode()
        token=model.start();now=time.time();model.frame(token,now-.25,jpeg(rays));model.frame(token,now,jpeg(rays@r.T))
        self.assertEqual(len(model.observations),1,model.last_note)
        np.testing.assert_allclose(model.observations[0][2],vector,atol=.002)
        self.assertEqual(model.previous.shape,(360,640));self.assertEqual(model.frames,2)

    def synthetic_records(self,single_axis=False):
        def actual(t):
            v=np.array([.17*math.sin(2.1*t+.3),.22*math.sin(1.3*t),.13*math.sin(3.2*t)])
            if single_axis:v[1:]=0
            return q_from_rotvec(v)
        times=100+np.arange(0,15,.002);poses=[(float(t),actual(t-100)) for t in times]
        alignment=Rotation.from_rotvec([.3,-.2,.5]).as_matrix()
        frames=100+np.arange(.5,13,.075);obs=[]
        for a,b in zip(frames[:-1],frames[1:]):
            rv=cv2.Rodrigues(alignment@rotation(actual(b-100)).T@rotation(actual(a-100))@alignment.T)[0].ravel()
            obs.append((float(a+.18),float(b+.18),rv))
        return obs,poses,alignment

    def test_visual_imu_alignment_and_usb_lag_are_distinguished(self):
        obs,poses,a=self.synthetic_records();result=solve_alignment(obs,poses)
        np.testing.assert_allclose(result['imu_to_camera'],a,atol=.0002)
        self.assertAlmostEqual(result['visual_transport_delay_ms'],180,delta=1.1)
        self.assertFalse(result['timestamp_offset_calibrated'])

    def test_one_axis_motion_is_rejected(self):
        obs,poses,_=self.synthetic_records(True)
        with self.assertRaisesRegex(ValueError,'转动方向不足'):solve_alignment(obs,poses)

    def test_auto_calibration_requires_live_raw_camera(self):
        c=Controller()
        with self.assertRaisesRegex(ValueError,'原图'):c.act({'action':'auto_start'})
        self.assertEqual(c.auto_alignment.state,'idle')

    def test_failed_write_preserves_running_and_saved_calibration(self):
        c=Controller();c.port=object();c.last_sample=time.monotonic();c.fusion.alignment=np.eye(3)
        c.config={'timestamp_offset_us':1200,'alignment_calibrated':True};before=dict(c.config)
        token=c.auto_alignment.start();c.auto_alignment.state='solving'
        c.save_config=lambda:(_ for _ in ()).throw(OSError('write failed'))
        result={'imu_to_camera':Rotation.from_rotvec([.2,0,0]).as_matrix().tolist(),'optical_axis':[0,0,1]}
        with self.assertRaises(OSError):c.apply_auto_alignment(token,result)
        self.assertEqual(c.config,before);np.testing.assert_array_equal(c.fusion.alignment,np.eye(3))

    def test_cancellation_invalidates_delayed_solver_result(self):
        c=Controller();token=c.auto_alignment.start();c.auto_alignment.state='solving';c.auto_alignment.cancel()
        c.apply_auto_alignment(token,{});self.assertEqual(c.auto_alignment.state,'idle')

    def test_successful_calibration_keeps_offset_and_other_preferences(self):
        c=Controller();c.port=object();c.last_sample=time.monotonic()
        c.offset_us=2300;c.config={'timestamp_offset_us':2300,'timestamp_offset_calibrated':False,'custom_setting':'keep'}
        token=c.auto_alignment.start();c.auto_alignment.state='solving'
        result={'imu_to_camera':np.eye(3).tolist(),'optical_axis':[0,0,1]}
        from unittest.mock import patch
        import server
        with tempfile.TemporaryDirectory() as tmp,patch.object(server,'CONFIG',Path(tmp)/'camera_imu.json'):
            c.apply_auto_alignment(token,result);saved=json.loads((Path(tmp)/'camera_imu.json').read_text())
        self.assertEqual(saved['timestamp_offset_us'],2300);self.assertFalse(saved['timestamp_offset_calibrated'])
        self.assertEqual(saved['custom_setting'],'keep');self.assertEqual(c.auto_alignment.state,'complete')
        self.assertEqual(c.reference_source,'automatic');np.testing.assert_array_equal(c.fusion.alignment,np.eye(3))

    def test_manual_changes_cannot_race_automatic_calibration(self):
        c=Controller();c.auto_alignment.start()
        for action in ['axis_start','reference','settings']:
            with self.assertRaisesRegex(ValueError,'先完成或取消'):c.act({'action':action})

if __name__=='__main__':unittest.main()
