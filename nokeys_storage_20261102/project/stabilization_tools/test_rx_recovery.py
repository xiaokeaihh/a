import unittest,struct
from unittest.mock import patch
from server import Controller,INPUT_TIMEOUT_ERROR

class ReceiverRecoveryTests(unittest.TestCase):
    def controller(self):
        c=Controller();self.addCleanup(c.tracking.shutdown)
        c.error=INPUT_TIMEOUT_ERROR;c.controls_received=100
        c.controls=dict(input_source='hdmi',requested_source='hdmi',input_switch_busy=False,input_signal_present=True,receiver_initialized=True,input_format_locked=True)
        return c
    def test_late_valid_input_clears_only_its_old_timeout(self):
        c=self.controller()
        with patch('server.time.monotonic',return_value=100.5):c.service_panorama()
        self.assertEqual(c.error,'')
        c.error='independent serial error'
        with patch('server.time.monotonic',return_value=100.6):c.service_panorama()
        self.assertEqual(c.error,'independent serial error')
    def test_unready_or_stale_status_does_not_hide_timeout(self):
        for field in ['input_signal_present','receiver_initialized','input_format_locked']:
            c=self.controller();c.controls[field]=False
            with patch('server.time.monotonic',return_value=100.5):c.service_panorama()
            self.assertEqual(c.error,INPUT_TIMEOUT_ERROR)
        c=self.controller();c.controls['input_switch_busy']=True
        with patch('server.time.monotonic',return_value=100.5):c.service_panorama()
        self.assertEqual(c.error,INPUT_TIMEOUT_ERROR)
        c=self.controller()
        with patch('server.time.monotonic',return_value=102):c.service_panorama()
        self.assertEqual(c.error,INPUT_TIMEOUT_ERROR)
    def test_camera_recovery_does_not_require_hdmi_lock(self):
        c=self.controller();c.controls.update(input_source='camera',requested_source='camera',receiver_initialized=False,input_format_locked=False)
        with patch('server.time.monotonic',return_value=100.5):c.service_panorama()
        self.assertEqual(c.error,'')
    def test_version_two_status_has_precise_fallback_reasons(self):
        c=self.controller();admission=1|8|16|32
        flags=(2<<16)|(admission<<8)|(3<<5)|31
        c.receive(6,struct.pack('<7I',flags,123,456,2,3,789,890))
        self.assertEqual(c.output_sync['phase_state'],3)
        e=c.output_sync['early_admission'];self.assertTrue(e['source_timing_fault']);self.assertFalse(e['service_timing_fault']);self.assertTrue(e['fast_disabled'])
        c.receive(6,struct.pack('<7I',(1<<16)|31,123,456,2,3,789,890))
        self.assertNotIn('early_admission',c.output_sync)

if __name__=='__main__':unittest.main()
