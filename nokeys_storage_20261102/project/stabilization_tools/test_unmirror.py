import unittest,struct,time,base64
from unittest.mock import patch
import numpy as np
import cv2
from tracking_geometry import Aim,source_pixel
from projection_reference import CFG,float_project
from tracking_mux import TrackingMux
from auto_alignment import AutoAlignment
from server import Controller

class UnmirrorTests(unittest.TestCase):
    def test_source_coordinates_and_legacy_compatibility(self):
        np.testing.assert_allclose(source_pixel(0,0),[.5,718.5])
        np.testing.assert_allclose(source_pixel(0,0,True),[1278.5,718.5])
        np.testing.assert_allclose(source_pixel(639,359,True),[.5,.5])

    def test_same_physical_target_and_centered_output(self):
        for sign in (1,-1):
            for x,y in [(260,110),(320,180),(405,235)]:
                old=Aim(CFG['source_K'],CFG['source_D'],np.eye(3),sign)
                new=Aim(CFG['source_K'],CFG['source_D'],np.eye(3),sign,horizontal_reversed=True)
                old.observe([x-15,y-15,30,30],10000,np.eye(3))
                new.observe([639-x-15,y-15,30,30],10000,np.eye(3))
                np.testing.assert_allclose(new.direction,old.direction,atol=1e-10)
                h=new.matrix(10000,np.eye(3))
                np.testing.assert_allclose(float_project(319.5,179.5,h),source_pixel(639-x,y,True),atol=.02)

    def test_firmware_capability_old_and_new(self):
        c=Controller()
        for flags,expected in [(0x28,False),(0x68,True),(0x6f,True)]:
            c.receive(3,struct.pack('<6BH',6,1,2,1,0,flags,0))
            self.assertEqual(c.hardware['mirror_corrected'],expected)

    def test_left_right_buttons_and_acknowledgments_remain_physical(self):
        from protocol import command
        class Port:
            def __init__(self):self.sent=[]
            def write(self,data):self.sent.append(data)
        c=Controller();c.port=Port()
        for flags in (0x28,0x68):
            for wire,logical in ((1,2),(2,1),(3,4),(4,3),(5,5),(6,6),(7,7)):
                c.receive(3,struct.pack('<6BH',wire,8,2,1,0,flags,0))
                expected=logical if flags&64 else wire
                self.assertEqual(c.hardware['view'],expected)
                c.write_command(expected,seq=9)
                self.assertEqual(c.port.sent[-1],command(9,wire))
            c.write_command(0x85,seq=10)
            self.assertEqual(c.port.sent[-1],command(10,0x85))
        c.port=None

    def test_imu_recovery_keeps_coordinate_convention(self):
        mux=TrackingMux(CFG['source_K'],CFG['source_D'],lambda *a:None)
        # No workers/capture are opened by this recovery check.
        for kind in ('object','person'):
            mux.current=getattr(mux,kind)
            mux.current.state='following'
            mux.current.aim=Aim(CFG['source_K'],CFG['source_D'],np.eye(3),horizontal_reversed=True)
            mux.reset_pose(np.eye(3))
            self.assertTrue(mux.current.aim.horizontal_reversed)
            mux.current.state='idle'
        mux.shutdown()

    def test_automatic_alignment_undoes_display_reflection(self):
        rng=np.random.default_rng(10)
        im=cv2.GaussianBlur(rng.integers(0,256,(360,640),dtype=np.uint8),(7,7),1.5)
        encoded=base64.b64encode(cv2.imencode('.jpg',im)[1]).decode()
        gray=cv2.imdecode(np.frombuffer(base64.b64decode(encoded),np.uint8),cv2.IMREAD_GRAYSCALE)
        a=AutoAlignment(CFG['source_K'],CFG['source_D']);token=a.start()
        a.frame(token,time.time(),encoded,horizontal_reversed=True)
        np.testing.assert_array_equal(a.previous,gray[:,::-1])

if __name__=='__main__':unittest.main()
