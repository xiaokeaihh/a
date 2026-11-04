import struct,unittest
from protocol import Decoder,telemetry
from server import Controller

class OutputSyncTests(unittest.TestCase):
 def test_fragmented_mixed_packets_keep_legacy_and_new_crc(self):
  legacy=telemetry(5,bytes([5,1,1,0,0,0,139,15]))
  payload=struct.pack('<7I',0x1001f,22000,2100000,2,3,19000,22004)
  new=telemetry(6,payload);bad=bytearray(new);bad[-1]^=1
  stream=b'noise'+legacy+bytes(bad)+new+telemetry(3,bytes(8));d=Decoder();out=[]
  for offset in range(0,len(stream),3):out+=d.feed(stream[offset:offset+3])
  self.assertEqual([x[0] for x in out],[5,6,3]);self.assertEqual(out[1][1],payload);self.assertEqual(d.crc_errors,1)

 def test_sync_packet_is_separate_from_controls_and_frame_diagnostics(self):
  c=Controller();self.addCleanup(c.tracking.shutdown)
  controls=dict(c.controls);hardware=dict(c.hardware);diagnostics=dict(c.diagnostics)
  c.receive(6,struct.pack('<7I',0x1001f,22000,2100000,2,3,19000,22004))
  s=c.status()['output_sync'];self.assertTrue(s['phase_locked']);self.assertTrue(s['following_input'])
  self.assertEqual(s['worst_ready_ms'],16.8);self.assertEqual(s['phase_acquisitions'],3)
  self.assertEqual(c.controls,controls);self.assertEqual(c.hardware,hardware);self.assertEqual(c.diagnostics,diagnostics)

 def test_old_firmware_has_no_synthetic_lock_state(self):
  c=Controller();self.addCleanup(c.tracking.shutdown)
  c.receive(5,bytes([5,1,1,0,0,0,139,15]))
  self.assertIsNone(c.status()['output_sync'])

 def test_csv_keeps_sync_state_with_original_frame_measurements(self):
  c=Controller();self.addCleanup(c.tracking.shutdown)
  c.receive(6,struct.pack('<7I',0x1001f,22000,2100000,2,3,19000,22004))
  values=[0]*40;values[0]=7;values[1]=(600<<16)|(4<<8)|6;values[2]=170;values[3]=160
  c.receive(4,struct.pack('<40I',*values))
  text=c.diagnostics_csv().decode('utf-8-sig')
  self.assertIn('sync_phase_locked',text);self.assertIn('latency_ms',text)
  self.assertEqual(c.diagnostics['latency_ms'],17);self.assertTrue(c.diagnostics['sync_phase_locked'])
