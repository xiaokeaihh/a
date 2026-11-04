import unittest,struct,json,math,time,io
from unittest.mock import patch
import numpy as np
from protocol import *
from attitude import Fusion,rotation,Clock,unit
from projection_reference import matrix,view_matrices,float_project,ROOT,VIEWS
from server import Controller

def raw(angle,rate=0,bias=0):
    a=math.radians(angle)
    return [round(-math.sin(a)*2048),round(-math.cos(a)*2048),0,0,0,round((rate+bias)*32768/2000)]

class Tests(unittest.TestCase):
    def test_failed_connect_releases_port_and_never_claims_connected(self):
        class FailedPort:
            def __init__(self):self.closed=False
            def set_buffer_size(self,**kwargs):pass
            def reset_input_buffer(self):pass
            def write(self,data):raise OSError('USB device removed')
            def close(self):self.closed=True
        port=FailedPort();controller=Controller()
        with patch('server.serial.Serial',return_value=port):
            with self.assertRaises(OSError):controller.connect('COM7')
        self.assertTrue(port.closed)
        self.assertIsNone(controller.port)
        self.assertFalse(controller.status()['connected'])

    def test_removed_device_disconnect_still_closes_port_and_log(self):
        class FailedPort:
            def __init__(self):self.closed=False
            def write(self,data):raise OSError('USB device removed')
            def close(self):self.closed=True
        controller=Controller();port=FailedPort();log=io.StringIO()
        controller.port=port;controller.log=log;controller.enabled=True
        controller.disconnect()
        self.assertTrue(port.closed and log.closed)
        self.assertFalse(controller.status()['connected'])
        self.assertFalse(controller.enabled)
        self.assertIn('已释放串口',controller.error)

    def test_exposure_firmware_marker_is_not_assumed_on_old_board(self):
        controller=Controller()
        controller.receive(3,struct.pack('<6BH',7,5,3,1,0,15,0))
        self.assertFalse(controller.hardware['boosted_exposure'])
        controller.receive(3,struct.pack('<6BH',7,5,3,1,0,31,0))
        self.assertTrue(controller.hardware['boosted_exposure'])
        self.assertTrue(controller.hardware['all_views_capable'])
        self.assertEqual(controller.status()['app_id'],'wyc-unified-control')

    def test_wire_corruption_and_fragmentation(self):
        d=Decoder();packet=telemetry(1,struct.pack('<HIBB6h',3,1000,0x47,1,*raw(0)))
        bad=bytearray(packet);bad[9]^=0x55
        found=[]
        for byte in b'noise'+bad+packet:found+=d.feed(bytes([byte]))
        self.assertEqual(len(found),1);self.assertEqual(d.crc_errors,1)
        self.assertEqual(struct.unpack('<HIBB6h',found[0][1])[1],1000)
        h=matrix().flat;p=pose_packet(7,123,456,[int(x) for x in h]);self.assertEqual(len(p),50)
        self.assertEqual(crc8(p[2:-1]),p[-1]);self.assertEqual(struct.unpack('<BII9i',p[4:-1])[1:3],(123,456))

    def test_clock_wrap_and_out_of_order_frame(self):
        c=Clock();a=c.unwrap(0xfffffff0);b=c.unwrap(20)
        self.assertEqual(b-a,36);self.assertEqual(c.unwrap(0xfffffff8),a+8);self.assertEqual(c.unwrap(30),b+10)

    def test_fusion_calibration_and_full_roll(self):
        f=Fusion();tick=0
        for _ in range(1100):tick+=200;f.update(tick,raw(0,bias=.5))
        self.assertTrue(f.bias_ready);f.begin_axis()
        for i in range(1,251):tick+=200;f.update(tick,raw(i*.18,90,.5))
        f.end_axis();np.testing.assert_allclose(f.optical_axis,[0,0,1],atol=1e-6)
        for i in range(249,-1,-1):tick+=200;f.update(tick,raw(i*.18,-90,.5))
        for _ in range(400):tick+=200;f.update(tick,raw(0,bias=.5))
        f.set_reference();np.testing.assert_allclose(f.alignment,np.eye(3),atol=.01)
        for i in range(1,2001):
            tick+=200;angle=i*.18;f.update(tick,raw(angle,90,.5))
            if i%250==0:
                r=f.compensation(f.q,'roll');expected=np.array([[math.cos(math.radians(-angle)),-math.sin(math.radians(-angle)),0],
                   [math.sin(math.radians(-angle)),math.cos(math.radians(-angle)),0],[0,0,1]])
                np.testing.assert_allclose(r,expected,atol=.003)
        q=f.at(tick-100);self.assertIsNotNone(q);self.assertAlmostEqual(np.linalg.norm(q),1)
        f.update(tick+200,[0,-4096,0,0,0,round(.5*32768/2000)])
        self.assertTrue(f.reject_acceleration)

    def test_frame_pose_is_historical(self):
        c=Controller()
        class Port:
            def __init__(self):self.writes=[]
            def write(self,p):self.writes.append(p)
        c.port=Port();c.enabled=True;c.last_sample=time.monotonic();c.mode='lock3d'
        c.fusion.alignment=np.eye(3);c.fusion.reference=np.eye(3);c.fusion.bias_ready=True
        c.fusion.history.extend([(1000,np.array([1.,0,0,0])),(1200,np.array([math.cos(.2),0,0,math.sin(.2)])),(1400,np.array([math.cos(.4),0,0,math.sin(.4)]))])
        c.fusion.last_tick=1400;c.pending.append((25,1100,1100));c.flush_frames()
        values=struct.unpack('<BII9i',c.port.writes[0][4:-1]);self.assertEqual(values[1:3],(25,1100))
        expected=matrix(rotation(c.fusion.at(1100)).T).ravel()
        np.testing.assert_array_equal(values[3:],expected)

    def test_calibration_rejects_wrong_motion(self):
        f=Fusion();f.bias_ready=True;f.axis_samples=[np.array([.0001,0,0])]*40
        with self.assertRaises(ValueError):f.end_axis()
        c=Controller()
        with self.assertRaises(ValueError):c.act({'action':'enable','enabled':True})

    def test_axis_out_and_back_keeps_excursion_and_direction(self):
        f=Fusion();f.bias_ready=True;f.last_tick=0;f.begin_axis();tick=0
        for i in range(1,251):tick+=200;f.update(tick,raw(i*.18,90))
        for i in range(249,-1,-1):tick+=200;f.update(tick,raw(i*.18,-90))
        p=f.axis_progress()
        self.assertAlmostEqual(p['excursion_deg'],45,delta=.02)
        self.assertAlmostEqual(p['total_deg'],90,delta=.04)
        f.end_axis();np.testing.assert_allclose(f.optical_axis,[0,0,1],atol=1e-6)
        self.assertIsNone(f.axis_samples);self.assertAlmostEqual(f.axis_progress()['excursion_deg'],45,delta=.02)

    def test_short_motion_can_continue_without_reset(self):
        f=Fusion();f.bias_ready=True;f.begin_axis()
        axis=unit([.6,.8,0]);step=axis*math.radians(.1)
        f.axis_samples.extend([step]*100)
        with self.assertRaisesRegex(ValueError,'10.0'):f.end_axis()
        self.assertIsNotNone(f.axis_samples)
        f.axis_samples.extend([step]*350+[-step]*450)
        f.end_axis();np.testing.assert_allclose(f.optical_axis,axis,atol=1e-6)

    def test_repeated_small_wiggles_do_not_pass_20_degree_gate(self):
        f=Fusion();f.bias_ready=True;f.begin_axis();step=np.array([0,0,math.radians(.1)])
        f.axis_samples=([step]*30+[-step]*30)*10
        self.assertGreater(f.axis_progress()['total_deg'],20)
        self.assertAlmostEqual(f.axis_progress()['excursion_deg'],3)
        with self.assertRaisesRegex(ValueError,'不足20'):f.end_axis()
        f.axis_samples=[np.array([math.radians(.1),0,0])]*450+[step]*450
        with self.assertRaisesRegex(ValueError,'转动轴不稳定'):f.end_axis()

    def test_saved_axis_is_not_restored_during_recalibration(self):
        c=Controller();c.config={'alignment_calibrated':True,'optical_axis':[0,1,0]}
        c.fusion.bias_ready=True;c.fusion.optical_axis=np.array([0,1,0])
        c.act({'action':'axis_start'})
        c.receive(1,struct.pack('<HIBB6h',1,1000,0x47,1,*raw(0)))
        self.assertIsNone(c.fusion.optical_axis)
        self.assertTrue(c.status()['axis_collecting']);self.assertFalse(c.status()['axis_calibrated'])

    def test_complete_saved_calibration_restores_without_motion(self):
        c=Controller();c.config={'alignment_calibrated':True,'optical_axis':[0,0,1],'imu_to_camera':np.eye(3).tolist()}
        for i in range(1100):c.receive(1,struct.pack('<HIBB6h',i,i*200,0x47,1,*raw(37,bias=.5)))
        s=c.status();self.assertTrue(s['reference_ready']);self.assertEqual(s['reference_source'],'saved')
        np.testing.assert_allclose(c.fusion.compensation(c.fusion.q,'lock3d'),np.eye(3),atol=1e-6)
        a=math.radians(-37);expected=np.array([[math.cos(a),-math.sin(a),0],[math.sin(a),math.cos(a),0],[0,0,1]])
        np.testing.assert_allclose(c.fusion.compensation(c.fusion.q,'roll'),expected,atol=.001)
        f=Fusion();f.bias_ready=True
        with self.assertRaises(ValueError):f.restore_calibration([0,0,1],np.zeros((3,3)))
        self.assertIsNone(f.reference)

    def test_full_pose_bundle_and_view_directions(self):
        hs=view_matrices();packet=pose_bundle(3,123,456,hs)
        self.assertEqual(len(packet),230);self.assertEqual(packet[3:5],bytes([0x91,2]))
        self.assertEqual(packet[-1],crc8(packet[2:-1]))
        values=struct.unpack('<BII54i',packet[4:-1]);self.assertEqual(values[:3],(2,123,456))
        np.testing.assert_array_equal(np.asarray(values[3:]).reshape(6,3,3),hs)
        np.testing.assert_array_equal(hs[0],matrix())
        # Compare against the project's independent fixed-view geometry.
        import sys;sys.path.insert(0,str(ROOT/'quality_tools'))
        from balanced_geometry import project
        for h,c in zip(hs[1:],[q['config'] for q in VIEWS['quadrants']]+[VIEWS['central_full']['config']]):
            for x,y in [(0,0),(639,359),(320,180),(0,359),(639,0)]:
                actual=float_project(x,y,h);expected=project(c,np.array(float(x*2)),np.array(float(y*2)))
                np.testing.assert_allclose(actual,[expected[0],expected[1]],atol=.02)

    def test_all_views_receive_matching_historical_pose(self):
        c=Controller()
        class Port:
            def __init__(self):self.writes=[]
            def write(self,p):self.writes.append(p)
        c.port=Port();c.enabled=True;c.last_sample=time.monotonic();c.mode='lock3d';c.hardware={'all_views_capable':True}
        c.fusion.alignment=np.eye(3);c.fusion.reference=np.eye(3);c.fusion.bias_ready=True
        c.fusion.history.extend([(1000,np.array([1.,0,0,0])),(1200,np.array([math.cos(.2),0,0,math.sin(.2)]))])
        c.fusion.last_tick=1200;c.pending.append((25,1100,1100));c.flush_frames()
        values=struct.unpack('<BII54i',c.port.writes[0][4:-1]);self.assertEqual(values[1:3],(25,1100))
        expected=view_matrices(rotation(c.fusion.at(1100)).T)
        np.testing.assert_array_equal(np.asarray(values[3:]).reshape(6,3,3),expected)

    def test_enabling_stabilization_keeps_selected_quad(self):
        c=Controller()
        class Port:
            def __init__(self):self.writes=[]
            def write(self,p):self.writes.append(p)
        c.port=Port();c.hardware={'view':5,'mode':1};c.last_sample=time.monotonic()
        c.fusion.bias_ready=True;c.fusion.reference=np.eye(3)
        c.act({'action':'enable','enabled':True})
        self.assertEqual(len(c.port.writes),1);self.assertEqual(c.port.writes[0][3],0x85)

    def test_raw_display_does_not_claim_stabilization(self):
        c=Controller();c.receive(3,struct.pack('<6BH',7,1,0,1,0,7,0))
        self.assertFalse(c.hardware['stabilized'])
        c.receive(3,struct.pack('<6BH',7,1,3,1,0,7,0));self.assertTrue(c.hardware['stabilized'])

    def test_stuck_spi_data_is_not_reported_online(self):
        c=Controller();c.receive(1,struct.pack('<HIBB6h',1,1000,0x47,1,*raw(0)))
        self.assertTrue(c.status()['imu_online'])
        c.receive(1,struct.pack('<HIBB6h',2,1200,0x47,1,*([-1]*6)))
        self.assertFalse(c.status()['imu_online']);self.assertFalse(c.fusion.bias_ready)

if __name__=='__main__':
    result=unittest.main(exit=False)
    passed=result.result.wasSuccessful()
    (ROOT/'verification_stabilization/pc_report.json').write_text(json.dumps({'passed':passed,'tests':result.result.testsRun,'hardware_tested':False},indent=2))
    if not passed:raise SystemExit(1)
