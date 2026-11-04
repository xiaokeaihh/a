import unittest,time,struct
from unittest.mock import patch
import numpy as np
from imu_health import ImuHealth
from person_tracker import PersonTracker
from person_geometry import SafeAim
from attitude import Fusion
from server import Controller
from projection_reference import CFG


def scene(people):
    image=np.full((360,640,3),30,np.uint8)
    for box,color in people:
        x,y,w,h=map(int,box);image[y:y+h,x:x+w]=color
    return image

def observations(people):return [dict(bbox=box,score=.95) for box,color in people]


class PersonRecoveryTests(unittest.TestCase):
    red=(10,30,230);blue=(230,30,10)
    def selected(self):
        tracker=PersonTracker();people=[([80,80,70,180],self.red)]
        tracker.step(scene(people),1,observations(people));tracker.step(scene([]),4,[])
        return tracker

    def test_original_returns_far_away_after_long_absence(self):
        t=self.selected();people=[([500,100,70,180],self.red)]
        for now in [7.,7.1,7.2,7.3]:r=t.step(scene(people),now,observations(people))
        self.assertEqual(r['state'],'following');self.assertEqual(r['selected_id'],1)
        self.assertEqual(r['reacquire_count'],1);self.assertEqual(r['reacquire_reason'],'appearance')
        np.testing.assert_array_equal(t.velocity,[0,0])

    def test_stable_single_entrant_automatically_continues_even_if_appearance_changes(self):
        t=self.selected();people=[([400,80,70,180],self.blue)]
        first=t.step(scene(people),8,observations(people));self.assertEqual(first['state'],'lost')
        for now in [8.1,8.2,8.3,8.4]:r=t.step(scene(people),now,observations(people))
        self.assertEqual(r['state'],'following');self.assertEqual(r['reacquire_reason'],'single_person')
        self.assertNotEqual(r['selected_id'],1,'Do not claim a verified old identity for a new appearance')

    def test_original_is_preferred_among_multiple_people(self):
        t=self.selected();people=[([280,80,70,180],self.blue),([490,80,70,180],self.red)]
        for now in [8.,8.1,8.2,8.3]:r=t.step(scene(people),now,observations(people))
        self.assertEqual(r['state'],'following');self.assertEqual(r['selected_id'],1)
        self.assertEqual(r['bbox'][0],490)

    def test_ambiguous_people_do_not_force_an_identity_switch(self):
        t=self.selected();people=[([280,80,70,180],self.red),([490,80,70,180],self.red)]
        for now in [8.,8.1,8.2,8.3,8.4]:r=t.step(scene(people),now,observations(people))
        self.assertEqual(r['state'],'lost');self.assertEqual(r['reacquire_count'],0)

    def test_one_brief_detection_does_not_relock(self):
        t=self.selected();people=[([400,80,70,180],self.blue)]
        t.step(scene(people),8,observations(people));t.step(scene([]),8.15,[])
        r=t.step(scene(people),8.4,observations(people));self.assertEqual(r['state'],'lost')


class ImuRecoveryTests(unittest.TestCase):
    def test_timeout_pauses_once_and_fresh_samples_automatically_resume(self):
        h=ImuHealth();h.sample(10.,1000)
        self.assertEqual(h.poll(10.2,True,True,True),'pause')
        self.assertIsNone(h.poll(10.3,True,True,True));self.assertEqual(h.pauses,1)
        for i in range(36):
            now=10.4+i*.01;h.sample(now,1200+i*200);event=h.poll(now,True,True,True)
        self.assertFalse(h.paused);self.assertEqual(h.resumes,1)
        self.assertGreater(h.status(now)['max_host_gap_ms'],300)
        self.assertEqual(h.status(now)['max_sensor_gap_ms'],2)

    def test_invalid_chip_or_unrestored_calibration_cannot_resume(self):
        h=ImuHealth();h.sample(10.,1000);h.poll(10.2,True,False,False)
        for i in range(60):
            now=10.3+i*.01;h.sample(now,1200+i*200);h.poll(now,True,True,False)
        self.assertTrue(h.paused);self.assertEqual(h.resumes,0)

    def test_user_disable_cancels_automatic_resume(self):
        h=ImuHealth();h.sample(10.,1000);h.poll(10.2,True,True,True)
        h.poll(10.3,False,True,True)
        for i in range(50):h.sample(10.4+i*.01,1200+i*200);h.poll(10.4+i*.01,False,True,True)
        self.assertFalse(h.paused);self.assertEqual(h.resumes,0)

    def controller(self):
        c=Controller();writes=[];c.port=type('P',(),{'write':lambda self,p:writes.append(p)})()
        c.enabled=True;c.fusion.bias_ready=True;c.fusion.reference=np.eye(3);c.fusion.alignment=np.eye(3)
        c.last_sample=100.;c.imu_health.sample(100.,10000)
        c.tracking.current=c.tracking.person;p=c.tracking.person;p.state='following';p.token=7
        p.aim=SafeAim(CFG['source_K'],CFG['source_D'],np.eye(3));p.result=dict(selected_id=3,state='following')
        return c,writes

    def test_controller_keeps_visual_tracking_and_sends_resume_once(self):
        c,writes=self.controller();p=c.tracking.person
        with patch('server.time.monotonic',return_value=100.2):c.check_imu_health();c.check_imu_health()
        self.assertTrue(c.enabled);self.assertTrue(p.active());self.assertEqual(p.token,7);self.assertEqual(len(writes),0);self.assertTrue(c.tracking_imu_fallback)
        for i in range(36):
            now=100.4+i*.01;c.last_sample=now;c.imu_health.sample(now,10200+i*200)
            with patch('server.time.monotonic',return_value=now):c.check_imu_health()
        self.assertEqual(len(writes),1);self.assertFalse(c.imu_health.paused);self.assertFalse(c.tracking_imu_fallback);self.assertEqual(p.token,7)
        self.assertEqual(p.result['selected_id'],3);self.assertIsNone(p.aim.direction)
        c.port=None;c.tracking.shutdown()

    def test_stale_pose_is_not_sent_during_pause(self):
        c,writes=self.controller();c.pending.append((1,10000,10000))
        c.fusion.history.append((10000,np.array([1.,0,0,0])))
        with patch('server.time.monotonic',return_value=100.2):c.flush_frames()
        self.assertFalse(writes);self.assertFalse(c.pending)
        c.port=None;c.tracking.shutdown()

    def test_interpolation_does_not_bridge_a_sensor_sampling_hole(self):
        f=Fusion();q=np.array([1.,0,0,0]);f.history.extend([(100,q),(7000,q)])
        self.assertIsNone(f.at(3500));np.testing.assert_array_equal(f.at(7000),q)


class SerialRecoveryTests(unittest.TestCase):
    def controller(self):
        class Port:
            def __init__(self):self.baudrate=921600;self.writes=[]
            def write(self,p):self.writes.append(p)
            def reset_input_buffer(self):pass
        c=Controller();c.port=Port();c.opened_at=1;c.last_packet=10
        return c

    def test_imu_only_gap_does_not_reprobe_an_alive_serial_link(self):
        c=self.controller();c.last_packet=12.1;c.last_sample=9
        with patch('server.time.monotonic',return_value=12.2):c.check_serial_link()
        self.assertFalse(c.port.writes);self.assertEqual(c.link_resyncs,0)

    def test_board_reset_resynchronizes_rate_and_timestamp_epoch(self):
        c=self.controller();c.enabled=True;c.clock.latest=900000;c.fusion.history.append((900000,np.array([1.,0,0,0])))
        c.tracking.current=c.tracking.person;c.tracking.person.state='following'
        with patch('server.time.monotonic',return_value=12.2):c.check_serial_link()
        self.assertEqual(c.port.baudrate,115200);self.assertFalse(c.enabled);self.assertFalse(c.tracking.active())
        self.assertIsNone(c.clock.latest);self.assertFalse(c.fusion.history)
        with patch('server.time.monotonic',return_value=12.24):c.check_serial_link()
        self.assertEqual(c.port.baudrate,921600)
        with patch('server.time.monotonic',return_value=12.3):
            c.receive(3,struct.pack('<6BH',6,0,2,1,0,47,0));c.check_serial_link()
        self.assertEqual(c.link_phase,'idle');self.assertEqual(c.link_recoveries,1)
        c.port=None;c.tracking.shutdown()

    def test_unsupported_firmware_does_not_trigger_a_busy_retry_loop(self):
        c=self.controller()
        with patch('server.time.monotonic',return_value=12.2):c.check_serial_link()
        with patch('server.time.monotonic',return_value=12.24):c.check_serial_link()
        for now in [12.3,12.5,13,14,15]:
            with patch('server.time.monotonic',return_value=now):c.check_serial_link()
        self.assertEqual(c.link_resyncs,1)

if __name__=='__main__':unittest.main()
