import unittest,struct
from unittest.mock import patch
from server import Controller,HDMI_UNAVAILABLE_ERROR
from test_input_switch import Port

class HdmiWatchdogTests(unittest.TestCase):
    def test_version_five_jitter_and_failure_metadata_preserves_both_phases(self):
        c=self.controller();reason=(1<<1)|(1<<5)
        c.receive(6,struct.pack('<7I',(5<<16)|31,664272,1000000,9,(231<<16)|2,
            0x80000000|(768<<21)|123456,(reason<<21)|665565))
        s=c.output_sync
        self.assertTrue(s['certified_base_profile'])
        self.assertEqual(s['last_ready_phase_pixels'],123456)
        self.assertEqual(s['last_output_phase_pixels'],665565)
        self.assertEqual(s['stability']['jitter_peak_cycles'],768)
        self.assertEqual(s['stability']['jitter_allowance_cycles'],768)
        self.assertEqual(s['stability']['last_failure_reasons'],['source_budget','writer_protocol'])
        c.receive(6,struct.pack('<7I',(4<<16)|31,1,2,9,2,0x80000000|123,456))
        self.assertNotIn('stability',c.output_sync)
    def test_version_four_certified_profile_does_not_corrupt_ready_phase(self):
        c=self.controller()
        c.receive(6,struct.pack('<7I',(4<<16)|31,664272,1000000,9,(231<<16)|2,0x80000000|123456,234567))
        self.assertTrue(c.output_sync['certified_base_profile'])
        self.assertEqual(c.output_sync['last_ready_phase_pixels'],123456)
        self.assertEqual(c.output_sync['last_output_phase_pixels'],234567)
        self.assertEqual(c.output_sync['clock_switches'],9)
        c.receive(6,struct.pack('<7I',(3<<16)|31,1,2,9,2,123456,234567))
        self.assertNotIn('certified_base_profile',c.output_sync)
        self.assertEqual(c.output_sync['last_ready_phase_pixels'],123456)
    def controller(self):
        c=Controller();c.port=Port();self.addCleanup(c.tracking.shutdown)
        c.controls_received=100
        c.controls=dict(input_switch_supported=True,input_source='hdmi',requested_source='hdmi',
            input_switch_busy=False,input_signal_present=False,receiver_initialized=True,input_format_locked=False)
        return c
    def test_same_invalid_hdmi_resends_retry_but_healthy_hdmi_is_noop(self):
        c=self.controller()
        with patch('server.time.monotonic',return_value=100):c.act(dict(action='input_source',source='hdmi'))
        self.assertEqual(c.port.packets[-1][3],0x97)
        c.input_transition=None;c.controls.update(input_signal_present=True,input_format_locked=True)
        n=len(c.port.packets)
        with patch('server.time.monotonic',return_value=100):c.act(dict(action='input_source',source='hdmi'))
        self.assertEqual(len(c.port.packets),n)
    def test_timeout_cancels_hardware_request_then_confirms_camera_and_restores_imu(self):
        c=self.controller();c.input_transition=dict(source='hdmi',started=96);c.camera_resume=True
        with patch('server.time.monotonic',return_value=100.1):c.service_panorama()
        self.assertEqual(c.port.packets[-1][3],0x96)
        self.assertEqual(c.input_transition['source'],'camera');self.assertEqual(c.error,HDMI_UNAVAILABLE_ERROR)
        c.controls.update(input_source='camera',requested_source='camera',input_signal_present=True)
        c.controls_received=100.2
        with patch('server.time.monotonic',return_value=100.3):c.service_panorama()
        self.assertIsNone(c.input_transition);self.assertTrue(c.enabled);self.assertFalse(c.camera_resume)
        self.assertEqual(c.port.packets[-1][3],0x85);self.assertEqual(c.error,HDMI_UNAVAILABLE_ERROR)
    def test_version_three_receiver_metadata_keeps_clock_counter(self):
        c=self.controller();metadata=(123<<8)|(3<<6)|32|16|8|4|1
        c.receive(6,struct.pack('<7I',(3<<16)|31,1,2,(metadata<<16)|17,(231<<16)|3,4,5))
        s=c.output_sync;self.assertEqual(s['clock_switches'],17)
        self.assertEqual(s['phase_acquisitions'],3);self.assertTrue(s['input_activity']['pixel_clock'] and s['input_activity']['vsync'] and s['input_activity']['data_enable']);self.assertTrue(s['input_activity']['qualified']);
        r=s['receiver_recovery'];self.assertEqual(r['total'],123);self.assertEqual(r['attempts'],3)
        self.assertTrue(r['limited'] and r['pending'] and r['resetting'] and r['clock_valid'] and r['requested_hdmi'])
        self.assertFalse(r['video_present'])
        c.receive(6,struct.pack('<7I',(2<<16)|31,1,2,18,3,4,5))
        self.assertEqual(c.output_sync['clock_switches'],18);self.assertNotIn('receiver_recovery',c.output_sync)
    def test_unready_report_cannot_acknowledge_hdmi_switch(self):
        c=self.controller();c.input_transition=dict(source='hdmi',started=99)
        with patch('server.time.monotonic',return_value=100.1):c.service_panorama()
        self.assertIsNotNone(c.input_transition)
        c.controls.update(input_signal_present=True,input_format_locked=True)
        with patch('server.time.monotonic',return_value=100.2):c.service_panorama()
        self.assertIsNone(c.input_transition)
