import unittest,time
from unittest.mock import patch
from server import Controller

class Port:
    def __init__(self):self.packets=[];self.closed=False
    def write(self,data):self.packets.append(data)
    def flush(self):pass
    def close(self):self.closed=True

class InputSwitchTests(unittest.TestCase):
    def controller(self):
        c=Controller();c.port=Port();self.addCleanup(c.tracking.shutdown)
        c.controls=dict(input_switch_supported=True,input_source='camera',requested_source='camera',input_switch_busy=False)
        c.controls_received=100
        return c

    def test_absent_input_timeout_leaves_reselection_and_view_command_available(self):
        c=self.controller()
        with patch('server.time.monotonic',return_value=100):c.act(dict(action='input_source',source='hdmi'))
        c.controls.update(input_source='hdmi',requested_source='hdmi',input_switch_busy=True);c.controls_received=104.1
        with patch('server.time.monotonic',return_value=104.1):
            c.service_panorama()
            self.assertEqual(c.input_transition['source'],'camera');self.assertIn('720p',c.error)
            self.assertEqual(c.port.packets[-1][3],0x96)
            c.act(dict(action='input_source',source='camera'))
            c.act(dict(action='view',view=7,sequence=45))
        self.assertEqual(c.input_transition['source'],'camera')
        self.assertEqual(c.port.packets[-2][3],0x96);self.assertEqual(c.port.packets[-1][3],7)

    def test_pending_request_can_be_retargeted_before_timeout(self):
        c=self.controller()
        with patch('server.time.monotonic',return_value=100):
            c.act(dict(action='input_source',source='hdmi'))
            c.act(dict(action='input_source',source='camera'))
        self.assertEqual(c.input_transition['source'],'camera')
        self.assertEqual(c.port.packets[-1][3],0x96)

    def test_completion_requires_fresh_matching_request_and_idle_hardware(self):
        c=self.controller();c.controls.update(input_source='hdmi',requested_source='hdmi')
        with patch('server.time.monotonic',return_value=100):c.act(dict(action='input_source',source='camera'))
        c.controls.update(input_source='camera',input_switch_busy=False)
        with patch('server.time.monotonic',return_value=100.1):c.service_panorama()
        self.assertIsNotNone(c.input_transition,'Old status cannot acknowledge a new switch')
        c.controls_received=100.2
        with patch('server.time.monotonic',return_value=100.3):c.service_panorama()
        self.assertIsNotNone(c.input_transition,'A report for another request cannot acknowledge the switch')
        c.controls.update(requested_source='camera',input_switch_busy=True)
        with patch('server.time.monotonic',return_value=100.4):c.service_panorama()
        self.assertIsNotNone(c.input_transition)
        c.controls['input_switch_busy']=False
        with patch('server.time.monotonic',return_value=100.5):c.service_panorama()
        self.assertIsNone(c.input_transition)

    def test_retry_preserves_camera_stabilization_resume_and_manual_stop_cancels_it(self):
        c=self.controller();c.enabled=True
        with patch('server.time.monotonic',return_value=100):
            c.act(dict(action='input_source',source='hdmi'))
            c.act(dict(action='input_source',source='hdmi'))
        self.assertTrue(c.camera_resume)
        c.act(dict(action='enable',enabled=False));self.assertFalse(c.camera_resume)

    def test_disconnect_clears_prior_transition(self):
        c=self.controller();p=c.port;c.input_transition=dict(source='hdmi',started=100);c.camera_resume=True
        c.disconnect()
        self.assertTrue(p.closed);self.assertIsNone(c.input_transition);self.assertFalse(c.camera_resume)

    def test_failed_reconnect_does_not_retain_previous_switch_state(self):
        c=self.controller();c.port=None;c.input_transition=dict(source='hdmi',started=100);c.camera_resume=True
        with patch('server.serial.Serial',side_effect=OSError('test-only unavailable port')):
            with self.assertRaises(OSError):c.connect('TEST_PORT')
        self.assertIsNone(c.input_transition);self.assertFalse(c.camera_resume)

if __name__=='__main__':unittest.main()
